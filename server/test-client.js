// Headless stand-in for the phone — used to test the relay + agent loop without
// the iOS app.
//
//   node test-client.js "<pairing-base64>"                  # list + tail first session
//   node test-client.js "<pairing>" --session <id>          # tail a specific session
//   node test-client.js "<pairing>" --session <id> --send "your message"
//
// Prints decoded agent messages; for transcript lines it surfaces user/assistant
// text and tool names so you can see the loop close.

import { WebSocket } from "ws";
import crypto from "node:crypto";

const pairingB64 = process.argv[2];
if (!pairingB64) { console.error("usage: node test-client.js <pairing> [--session <id>] [--send <text>]"); process.exit(1); }
const argSession = argVal("--session");
const argSend = argVal("--send");
const permMode = argVal("--perm") || "allow";   // auto-respond to permission asks
function argVal(flag) { const i = process.argv.indexOf(flag); return i >= 0 ? process.argv[i + 1] : null; }

const { url, room, key: keyB64 } = JSON.parse(Buffer.from(pairingB64, "base64").toString("utf8"));
const key = Buffer.from(keyB64, "base64");

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

let subId = argSession;
let sentAlready = false;

const ws = new WebSocket(url);
ws.on("open", () => {
  ws.send(JSON.stringify({ t: "join", room, role: "client" }));
  console.log("[client] joined room", room);
  send({ type: "list" });
});
ws.on("message", (raw) => {
  let m; try { m = JSON.parse(raw.toString()); } catch { return; }
  if (m.t === "peer") { console.log(`[client] peer ${m.role} ${m.status}`); if (m.role === "agent" && m.status === "online") send({ type: "list" }); return; }
  if (m.t !== "data") return;
  let msg; try { msg = dec(m.enc); } catch (e) { console.error("[client] decrypt fail", e.message); return; }
  onAgent(msg);
});
ws.on("error", (e) => console.error("[client] ws error", e.message));

function send(obj) { ws.send(JSON.stringify({ t: "data", enc: enc(obj) })); }

function onAgent(msg) {
  switch (msg.type) {
    case "sessions": {
      console.log(`\n[client] sessions (${msg.sessions.length}):`);
      msg.sessions.slice(0, 8).forEach((s) => console.log(`  ${s.id.slice(0, 8)}  ${s.name.padEnd(16)} ${s.snippet ? s.snippet.slice(0, 48) : ""}`));
      if (!subId && msg.sessions[0]) subId = msg.sessions[0].id;
      if (subId) { console.log(`\n[client] subscribing ${subId.slice(0, 8)}…`); send({ type: "subscribe", id: subId }); }
      break;
    }
    case "thread":
      console.log(`[client] thread ${msg.id.slice(0, 8)} — ${msg.lines.length} lines`);
      summarize(msg.lines.slice(-6));
      maybeSend();
      break;
    case "event":
      console.log(`\n[client] +event ${msg.id.slice(0, 8)} — ${msg.lines.length} new line(s):`);
      summarize(msg.lines);
      break;
    case "permission":
      console.log(`\n[client] 🔐 PERMISSION ${msg.id}: ${msg.tool} — ${(msg.command || msg.path || msg.preview || "").slice(0, 80)}`);
      console.log(`[client] auto-${permMode}`);
      send({ type: "permission-decision", id: msg.id, decision: permMode });
      break;
    case "sent":
      console.log(`[client] sent ack: ok=${msg.ok}${msg.error ? " error=" + msg.error : ""}`);
      break;
    case "pong": console.log("[client] pong"); break;
    case "error": console.error("[client] agent error:", msg.msg); break;
  }
}

function maybeSend() {
  if (argSend && !sentAlready) {
    sentAlready = true;
    console.log(`\n[client] >>> sending: ${argSend}`);
    send({ type: "send", id: subId, text: argSend });
  }
}

function summarize(lines) {
  for (const ln of lines) {
    try {
      const o = JSON.parse(ln);
      const c = o.message?.content;
      if (o.type === "user" && typeof c === "string") console.log(`    user: ${c.slice(0, 70)}`);
      else if (Array.isArray(c)) {
        for (const b of c) {
          if (b.type === "text" && b.text?.trim()) console.log(`    ${o.type}: ${b.text.trim().slice(0, 70)}`);
          else if (b.type === "tool_use") console.log(`    tool: ${b.name}`);
          else if (b.type === "tool_result") console.log(`    result(${o.type})`);
        }
      }
    } catch {}
  }
}
