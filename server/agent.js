// Claude Remote Mac agent (v1).
//
// Watches this machine's ~/.claude/projects, streams sessions + transcript
// events to the paired phone through the relay, and drives Claude when the
// phone sends a message: `claude --resume <id> -p "<text>"` continues the same
// session and appends to the same transcript, which the file watcher then
// streams back — the transcript file is the sync substrate (verified).
//
// Pairing: on start it mints { url, room, key } and prints it (base64) for the
// phone to scan/enter. Payloads are AES-256-GCM with `key`; the relay only sees
// `room` + ciphertext.

import { WebSocket } from "ws";
import chokidar from "chokidar";
import qrcode from "qrcode-terminal";
import crypto from "node:crypto";
import os from "node:os";
import path from "node:path";
import net from "node:net";
import { spawn, execSync } from "node:child_process";
import {
  openSync, readSync, closeSync, statSync, readFileSync, readdirSync,
  mkdirSync, writeFileSync, unlinkSync,
} from "node:fs";
import { readdir } from "node:fs/promises";

const RELAY = process.env.RELAY || "ws://localhost:8787";
const PROJECTS = path.join(os.homedir(), ".claude", "projects");
const PERMISSION = process.env.CLAUDE_PERMISSION_MODE || "acceptEdits";
const CLAUDE_BIN = process.env.CLAUDE_BIN || "claude";

// ---- pairing identity (persisted so restarting the agent keeps the same QR) ----
const IDENTITY_PATH = path.join(os.homedir(), ".xrelay", "identity.json");
let room, key;
try {
  const saved = JSON.parse(readFileSync(IDENTITY_PATH, "utf8"));
  room = saved.room;
  key = Buffer.from(saved.key, "base64");
} catch {
  room = crypto.randomBytes(8).toString("hex");
  key = crypto.randomBytes(32);
  try {
    mkdirSync(path.dirname(IDENTITY_PATH), { recursive: true });
    writeFileSync(IDENTITY_PATH, JSON.stringify({ room, key: key.toString("base64") }));
  } catch {}
}
const pairing = Buffer.from(
  JSON.stringify({ url: RELAY, room, key: key.toString("base64") })
).toString("base64");

// Reuse the terminal's / login shell's proxy for the Claude we spawn. We pass
// `env: process.env` to spawn, so any HTTPS_PROXY already in the agent's env is
// inherited. If none is set (e.g. running under launchd with its minimal env),
// read it once from the login shell so a proxy exported in ~/.zshrc — handy when
// traveling on a restricted network — is still picked up.
const PROXY_KEYS = ["HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "ALL_PROXY"];
function captureLoginShellProxy() {
  if (PROXY_KEYS.some((k) => process.env[k] || process.env[k.toLowerCase()])) return;
  try {
    const shell = process.env.SHELL || "/bin/zsh";
    const out = execSync(`${shell} -lc 'printf "%s\\t%s\\t%s\\t%s" "$HTTPS_PROXY" "$HTTP_PROXY" "$NO_PROXY" "$ALL_PROXY"'`,
      { timeout: 5000 }).toString().split("\t");
    PROXY_KEYS.forEach((k, i) => { if (out[i]) process.env[k] = out[i]; });
  } catch {}
}
captureLoginShellProxy();

console.log("\n=== Claude Remote agent ===");
console.log("relay   :", RELAY);
console.log("projects:", PROJECTS);
console.log("proxy   :", PROXY_KEYS.map((k) => process.env[k] && `${k}=${process.env[k]}`).filter(Boolean).join("  ") || "(none — direct)");
console.log("\nPAIRING — scan this QR in the app (or paste the string below):\n");
qrcode.generate(pairing, { small: true });
console.log("\n" + pairing + "\n");

// ---- crypto ----
function enc(obj) {
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv("aes-256-gcm", key, iv);
  const ct = Buffer.concat([c.update(JSON.stringify(obj), "utf8"), c.final()]);
  return Buffer.concat([iv, c.getAuthTag(), ct]).toString("base64");
}
function dec(b64) {
  const buf = Buffer.from(b64, "base64");
  const d = crypto.createDecipheriv("aes-256-gcm", key, buf.subarray(0, 12));
  d.setAuthTag(buf.subarray(12, 28));
  return JSON.parse(Buffer.concat([d.update(buf.subarray(28)), d.final()]).toString("utf8"));
}

// ---- transcript helpers ----
function headCwd(file) {
  try {
    const size = Math.min(16384, statSync(file).size);
    const fd = openSync(file, "r");
    const buf = Buffer.alloc(size);
    readSync(fd, buf, 0, size, 0);
    closeSync(fd);
    for (const ln of buf.toString("utf8").split("\n")) {
      try { const o = JSON.parse(ln); if (o.cwd) return o.cwd; } catch {}
    }
  } catch {}
  return null;
}

function tailSnippet(file) {
  try {
    const size = statSync(file).size;
    const start = Math.max(0, size - 65536);
    const fd = openSync(file, "r");
    const buf = Buffer.alloc(size - start);
    readSync(fd, buf, 0, buf.length, start);
    closeSync(fd);
    let text = buf.toString("utf8");
    if (start > 0) { const i = text.indexOf("\n"); if (i >= 0) text = text.slice(i + 1); }
    const lines = text.split("\n").filter(Boolean);
    for (let i = lines.length - 1; i >= 0; i--) {
      try {
        const o = JSON.parse(lines[i]);
        if (o.type === "assistant" && Array.isArray(o.message?.content)) {
          for (let j = o.message.content.length - 1; j >= 0; j--) {
            const b = o.message.content[j];
            if (b.type === "text" && b.text?.trim()) return b.text.trim();
          }
        }
      } catch {}
    }
  } catch {}
  return null;
}

function tildify(p) {
  const home = os.homedir();
  return p && p.startsWith(home) ? "~" + p.slice(home.length) : p;
}

async function listSessions() {
  let projDirs = [];
  try { projDirs = await readdir(PROJECTS); } catch { return []; }
  const out = [];
  for (const d of projDirs) {
    const dir = path.join(PROJECTS, d);
    let files = [];
    try { files = (await readdir(dir)).filter((f) => f.endsWith(".jsonl")); } catch { continue; }
    for (const f of files) {
      const file = path.join(dir, f);
      let st; try { st = statSync(file); } catch { continue; }
      const cwd = headCwd(file) || d;
      out.push({
        id: f.replace(/\.jsonl$/, ""),
        cwd,
        name: path.basename(cwd),
        path: tildify(cwd),
        mtime: st.mtimeMs,
        snippet: tailSnippet(file),
      });
    }
  }
  out.sort((a, b) => b.mtime - a.mtime);
  return out.slice(0, 60);
}

function findFile(id) {
  // ~/.claude/projects/*/<id>.jsonl — id is a uuid, so a direct scan is fine.
  try {
    for (const d of readdirSync(PROJECTS)) {
      const file = path.join(PROJECTS, d, `${id}.jsonl`);
      try { statSync(file); return file; } catch {}
    }
  } catch {}
  return null;
}

function readAppended(file, offset) {
  const size = statSync(file).size;
  if (size <= offset) return { lines: [], offset };
  const fd = openSync(file, "r");
  const buf = Buffer.alloc(size - offset);
  readSync(fd, buf, 0, buf.length, offset);
  closeSync(fd);
  const text = buf.toString("utf8");
  const lastNL = text.lastIndexOf("\n");
  if (lastNL < 0) return { lines: [], offset };
  const complete = text.slice(0, lastNL);
  const lines = complete.split("\n").filter(Boolean);
  return { lines, offset: offset + Buffer.byteLength(complete, "utf8") + 1 };
}

// ---- interactive permission ----
//
// When a phone-driven Claude turn wants to use a MUTATING tool, a PreToolUse
// hook (injected only into our spawned sessions via --settings, so the user's
// global ~/.claude is untouched) blocks and asks the phone to Allow/Deny. The
// hook talks to this agent over a unix socket; the agent relays to the phone.
const XRELAY_DIR = path.join(os.homedir(), ".xrelay");
const HOOK_PATH = path.join(XRELAY_DIR, "perm-hook.cjs");
const PERM_SETTINGS_PATH = path.join(XRELAY_DIR, "perm-settings.json");
const PERM_SOCK = path.join(os.tmpdir(), `xrelay-perm-${room}.sock`);

// Tools that require phone approval. Everything else (reads, search, todos, …)
// is auto-allowed by the hook so the turn never stalls on safe work.
const GATED_TOOLS = ["Bash", "Write", "Edit", "MultiEdit", "NotebookEdit"];

const HOOK_BODY = `// xrelay PreToolUse permission hook (auto-generated).
const net = require("node:net");
const GATED = ${JSON.stringify(GATED_TOOLS)};
let input = "";
process.stdin.on("data", (d) => (input += d));
process.stdin.on("end", () => {
  let req = {};
  try { req = JSON.parse(input); } catch {}
  const tool = req.tool_name || "";
  if (!GATED.includes(tool)) return decide("allow", "auto");
  const sock = process.env.XRELAY_PERM_SOCK;
  if (!sock) return decide("deny", "no-agent");
  let buf = "", done = false;
  const finish = (d, r) => { if (!done) { done = true; decide(d, r); } };
  const c = net.createConnection(sock, () => {
    c.write(JSON.stringify({ tool_name: tool, tool_input: req.tool_input, session_id: req.session_id, cwd: req.cwd }) + "\\n");
  });
  c.on("data", (d) => {
    buf += d;
    const nl = buf.indexOf("\\n");
    if (nl >= 0) { let r = {}; try { r = JSON.parse(buf.slice(0, nl)); } catch {} finish(r.decision === "allow" ? "allow" : "deny", "user"); try { c.end(); } catch {} }
  });
  c.on("error", () => finish("deny", "sock-error"));
  setTimeout(() => { try { c.destroy(); } catch {}; finish("deny", "timeout"); }, 295000);
});
function decide(decision, reason) {
  process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: decision, permissionDecisionReason: "xrelay: " + reason } }));
  process.exit(0);
}
`;

let permSeq = 0;
const pendingPerms = new Map(); // id -> { conn, timer }
let clientOnline = false;

function setupPermission() {
  try {
    mkdirSync(XRELAY_DIR, { recursive: true });
    writeFileSync(HOOK_PATH, HOOK_BODY);
    writeFileSync(PERM_SETTINGS_PATH, JSON.stringify({
      hooks: {
        PreToolUse: [{
          matcher: "*",
          hooks: [{ type: "command", command: `"${process.execPath}" "${HOOK_PATH}"`, timeout: 300 }],
        }],
      },
    }, null, 2));
    try { unlinkSync(PERM_SOCK); } catch {}
    const server = net.createServer((conn) => {
      let buf = "";
      conn.on("data", (d) => {
        buf += d;
        const nl = buf.indexOf("\n");
        if (nl >= 0) {
          let req;
          try { req = JSON.parse(buf.slice(0, nl)); } catch { conn.end(); return; }
          onPermissionRequest(req, conn);
        }
      });
      conn.on("error", () => {});
    });
    server.on("error", (e) => console.error("[agent] perm socket error:", e.message));
    server.listen(PERM_SOCK, () => console.log("[agent] permission socket:", PERM_SOCK));
  } catch (e) {
    console.error("[agent] permission setup failed:", e.message);
  }
}

function onPermissionRequest(req, conn) {
  if (!clientOnline) { reply(conn, "deny", "phone offline"); return; }
  const id = "perm-" + (++permSeq);
  const timer = setTimeout(() => {
    if (pendingPerms.has(id)) { pendingPerms.delete(id); reply(conn, "deny", "timeout"); }
  }, 290000);
  pendingPerms.set(id, { conn, timer });
  const ti = req.tool_input || {};
  console.log(`[perm] ask ${id} ${req.tool_name}`);
  send({
    type: "permission", id, session: req.session_id, tool: req.tool_name,
    command: ti.command, path: ti.file_path, preview: permPreview(req.tool_name, ti),
  });
}

function resolvePermission(id, decision) {
  const p = pendingPerms.get(id);
  if (!p) return;
  pendingPerms.delete(id);
  clearTimeout(p.timer);
  console.log(`[perm] ${id} -> ${decision}`);
  reply(p.conn, decision === "allow" ? "allow" : "deny", "user");
}

function reply(conn, decision, reason) {
  try { conn.write(JSON.stringify({ decision, reason }) + "\n"); conn.end(); } catch {}
}

function permPreview(tool, ti) {
  const cap = (s) => (s || "").slice(0, 1200);
  if (tool === "Bash") return cap(ti.command);
  if (tool === "Write") return cap(ti.content);
  if (tool === "Edit") return cap("- " + (ti.old_string || "") + "\n+ " + (ti.new_string || ""));
  if (tool === "MultiEdit") return cap((ti.edits || []).map((e) => "- " + (e.old_string || "") + "\n+ " + (e.new_string || "")).join("\n"));
  return "";
}

// ---- relay connection ----
let ws = null;
const subs = new Map(); // id -> { file, offset, watcher }

function send(obj) {
  if (ws && ws.readyState === 1) ws.send(JSON.stringify({ t: "data", enc: enc(obj) }));
}

async function pushSessions() {
  const sessions = await listSessions();
  console.log(`[push] sessions n=${sessions.length}`);
  send({ type: "sessions", sessions });
}

function subscribe(id) {
  if (subs.has(id)) { sendThread(id); return; }
  const file = findFile(id);
  if (!file) { send({ type: "error", msg: `unknown session ${id}` }); return; }
  const offset = statSync(file).size;
  const watcher = chokidar.watch(file, { ignoreInitial: true, awaitWriteFinish: { stabilityThreshold: 120, pollInterval: 40 } });
  const entry = { file, offset, watcher };
  watcher.on("change", () => {
    const r = readAppended(entry.file, entry.offset);
    entry.offset = r.offset;
    if (r.lines.length) send({ type: "event", id, lines: r.lines });
  });
  subs.set(id, entry);
  sendThread(id);
}

// Tail-first: sending a multi-MB transcript whole is slow (internet transfer +
// decrypt + parse on the phone) and can blow the WS frame limit. On subscribe
// send only the last ~600KB AND cap to the last N lines — recent context opens
// fast; the live watcher then streams new lines (small frames) from EOF.
const THREAD_TAIL = 600_000;
const THREAD_MAX_LINES = 400;
function sendThread(id) {
  const file = findFile(id);
  if (!file) return;
  const size = statSync(file).size;
  let text;
  if (size > THREAD_TAIL) {
    const fd = openSync(file, "r");
    const buf = Buffer.alloc(THREAD_TAIL);
    readSync(fd, buf, 0, THREAD_TAIL, size - THREAD_TAIL);
    closeSync(fd);
    text = buf.toString("utf8");
    const nl = text.indexOf("\n");
    if (nl >= 0) text = text.slice(nl + 1); // drop the partial leading line
  } else {
    text = readFileSync(file, "utf8");
  }
  let lines = text.split("\n").filter(Boolean);
  if (lines.length > THREAD_MAX_LINES) lines = lines.slice(-THREAD_MAX_LINES);
  console.log(`[thread] ${id} lines=${lines.length} (size=${size})`);
  send({ type: "thread", id, lines });
  const e = subs.get(id);
  if (e) e.offset = size;
}

function unsubscribe(id) {
  const e = subs.get(id);
  if (e) { e.watcher.close(); subs.delete(id); }
}

function drive(id, text) {
  const file = findFile(id);
  if (!file) { send({ type: "error", msg: `unknown session ${id}` }); return; }
  const cwd = headCwd(file) || os.homedir();
  // `default` mode + our PreToolUse hook (via --settings) = the hook is the
  // gatekeeper: auto-allow safe tools, ask the phone for mutating ones.
  const args = ["--resume", id, "-p", text, "--output-format", "json",
                "--permission-mode", "default", "--settings", PERM_SETTINGS_PATH];
  console.log(`[drive] ${id} in ${cwd}: ${JSON.stringify(text).slice(0, 60)}`);
  const child = spawn(CLAUDE_BIN, args, { cwd, env: { ...process.env, XRELAY_PERM_SOCK: PERM_SOCK } });
  let err = "";
  child.stderr.on("data", (d) => { err += d.toString(); });
  child.on("error", (e) => send({ type: "sent", id, ok: false, error: String(e) }));
  child.on("close", (code) => {
    send({ type: "sent", id, ok: code === 0, code, error: code === 0 ? undefined : err.slice(0, 300) });
    // The new turn is already on disk; nudge a tail read in case the watcher
    // event was coalesced.
    const e = subs.get(id);
    if (e) {
      const r = readAppended(e.file, e.offset);
      e.offset = r.offset;
      if (r.lines.length) send({ type: "event", id, lines: r.lines });
    }
  });
}

function handle(msg) {
  console.log(`[recv] ${msg.type}`);
  switch (msg.type) {
    case "list": pushSessions(); break;
    case "subscribe": subscribe(msg.id); break;
    case "unsubscribe": unsubscribe(msg.id); break;
    case "send": drive(msg.id, msg.text); break;
    case "permission-decision": resolvePermission(msg.id, msg.decision); break;
    case "ping": send({ type: "pong" }); break;
  }
}

function connect() {
  ws = new WebSocket(RELAY);
  ws.on("open", () => {
    ws.send(JSON.stringify({ t: "join", room, role: "agent" }));
    console.log("[agent] connected to relay");
  });
  ws.on("message", (raw) => {
    let m; try { m = JSON.parse(raw.toString()); } catch { return; }
    if (m.t === "data") { try { handle(dec(m.enc)); } catch (e) { console.error("[agent] bad frame", e.message); } }
    else if (m.t === "peer" && m.role === "client") {
      console.log(`[peer] client ${m.status}`);
      clientOnline = m.status === "online";
      if (clientOnline) {
        // Re-push a few times: on a flaky link the first frame can be missed
        // while the phone is still settling its connection.
        pushSessions();
        setTimeout(() => { if (clientOnline) pushSessions(); }, 1500);
        setTimeout(() => { if (clientOnline) pushSessions(); }, 4000);
      }
    }
  });
  ws.on("close", () => { console.log("[agent] relay closed, retrying in 2s"); setTimeout(connect, 2000); });
  ws.on("error", (e) => { console.error("[agent] ws error:", e.message); });
}

// Live session-list updates: watch the projects tree, debounce, re-push.
let pushTimer = null;
chokidar
  .watch(PROJECTS, { depth: 2, ignoreInitial: true, awaitWriteFinish: { stabilityThreshold: 150, pollInterval: 50 } })
  .on("all", () => {
    clearTimeout(pushTimer);
    pushTimer = setTimeout(() => pushSessions(), 300);
  });

setupPermission();
connect();
