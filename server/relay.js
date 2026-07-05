// Claude Remote relay — a blind WebSocket forwarder.
//
// Both the Mac agent and the phone connect OUT to this relay (so neither needs
// an inbound port / NAT hole). They join a `room` (a public random id from the
// pairing payload) and the relay forwards every `data` frame to the other peers
// in that room. Payloads are AES-GCM encrypted end-to-end with a key the relay
// never sees — so this process is a dumb pipe that cannot read any content.
//
// Listens on MULTIPLE ports (default 443 + 8787) sharing one `rooms` map: 443 is
// carrier-friendly (mobile networks often block non-standard ports like 8787, so
// a phone on cellular times out on 8787 but connects on 443), 8787 stays for the
// Mac agent / local. A phone on :443 and the agent on :8787 land in the SAME room
// (one process, shared map) and are bridged.

import { WebSocketServer } from "ws";
import http from "node:http";
import crypto from "node:crypto";

const PORTS = (process.env.PORTS || "443,8787")
  .split(",").map((p) => Number(p.trim())).filter(Boolean);
const rooms = new Map();      // room -> Set<ws>
const allSockets = new Set(); // for the keepalive sweep across all ports
const ipSocks = new Map();    // ip -> Set<ws> (per-IP cap, NEWEST wins)
const ipJoins = new Map();    // ip -> recent join timestamps (throttle)
const roomDigests = new Map(); // room -> Map<sha256(enc), ts> (blind replay guard)

function onConnection(ws, req) {
  ws.ip = req?.socket?.remoteAddress || "?";
  // Per-IP cap, newest-wins: a reconnecting client must never be locked out by
  // its own half-dead predecessors — evict the OLDEST socket from this IP
  // instead of rejecting the fresh one.
  let mine = ipSocks.get(ws.ip);
  if (!mine) { mine = new Set(); ipSocks.set(ws.ip, mine); }
  if (mine.size >= 8) {
    const oldest = mine.values().next().value;
    console.log(`[limit] conn cap ${ws.ip} — evicting oldest (room=${oldest.room || "-"})`);
    try { oldest.terminate(); } catch {}
    mine.delete(oldest);
  }
  mine.add(ws);
  allSockets.add(ws);
  console.log(`[conn] from ${ws.ip} port=${req?.socket?.localPort}`);
  ws.isAlive = true;
  ws.on("pong", () => { ws.isAlive = true; });

  ws.on("message", (raw) => {
    let msg;
    try { msg = JSON.parse(raw.toString()); } catch { return; }
    ws.isAlive = true;   // any inbound traffic proves the link

    if (msg.t === "join" && typeof msg.room === "string") {
      // Join throttle: 30/min per IP still makes room scanning impractical on top
      // of the 64-bit room space, but no longer trips a phone that flaps across
      // networks (two paired Macs = two joins per reconnect cycle).
      const now = Date.now();
      const jr = ipJoins.get(ws.ip) || [];
      const recent = jr.filter((t) => now - t < 60_000);
      recent.push(now);
      ipJoins.set(ws.ip, recent);
      if (recent.length > 30) { console.log(`[limit] join flood ${ws.ip}`); ws.close(); return; }
      ws.room = msg.room;
      ws.role = msg.role === "agent" ? "agent" : "client";
      if (!rooms.has(ws.room)) rooms.set(ws.room, new Set());
      rooms.get(ws.room).add(ws);
      console.log(`[join] room=${ws.room} role=${ws.role} ip=${ws.ip} peers=${rooms.get(ws.room).size}`);
      announce(ws.room, ws, { t: "peer", role: ws.role, status: "online" });
      for (const peer of rooms.get(ws.room)) {
        if (peer !== ws && peer.readyState === 1) {
          ws.send(JSON.stringify({ t: "peer", role: peer.role, status: "online" }));
        }
      }
      return;
    }

    if (msg.t === "data" && ws.room) {
      const s = raw.toString();
      // Frame size cap (largest legit frames are ~1MB thread tails).
      if (s.length > 8 * 1024 * 1024) { console.log(`[limit] oversize ${s.length}B ${ws.ip}`); return; }
      // Per-socket token bucket: 100 msg/s sustained, burst 300.
      const now = Date.now();
      ws.tokens = Math.min(300, (ws.tokens ?? 300) + ((now - (ws.tokensAt ?? now)) / 1000) * 100);
      ws.tokensAt = now;
      if (ws.tokens < 1) { return; }
      ws.tokens -= 1;
      // Blind replay guard: random-IV AES-GCM means two honest frames are never
      // byte-identical — an EXACT duplicate ciphertext within the window is a
      // replay (or a client bug) and is dropped without decrypting anything.
      if (typeof msg.enc === "string") {
        const digest = crypto.createHash("sha256").update(msg.enc).digest("base64");
        let seen = roomDigests.get(ws.room);
        if (!seen) { seen = new Map(); roomDigests.set(ws.room, seen); }
        if (seen.has(digest)) { console.log(`[replay] dropped dup in ${ws.room}`); return; }
        seen.set(digest, now);
        if (seen.size > 4096) {
          for (const [k, t] of seen) { if (now - t > 600_000 || seen.size > 4096) seen.delete(k); else break; }
        }
      }
      announce(ws.room, ws, s); // forward verbatim (ciphertext)
    }
  });

  ws.on("close", () => {
    const mine = ipSocks.get(ws.ip);
    if (mine) { mine.delete(ws); if (mine.size === 0) ipSocks.delete(ws.ip); }
    allSockets.delete(ws);
    if (ws.room) console.log(`[close] room=${ws.room} role=${ws.role} ip=${ws.ip}`);
    if (ws.room && rooms.has(ws.room)) {
      const set = rooms.get(ws.room);
      set.delete(ws);
      announce(ws.room, ws, { t: "peer", role: ws.role, status: "offline" });
      if (set.size === 0) rooms.delete(ws.room);
    }
  });

  ws.on("error", () => {});
}

function announce(room, fromWs, payload) {
  const set = rooms.get(room);
  if (!set) return;
  const data = typeof payload === "string" ? payload : JSON.stringify(payload);
  const isData = data.includes('"t":"data"');
  for (const peer of set) {
    if (peer === fromWs) continue;
    if (isData) console.log(`[fwd] ${data.length}B from=${fromWs.role} -> ${peer.role} rs=${peer.readyState}`);
    if (peer.readyState === 1) peer.send(data);
  }
}

// Keep connections warm AND give clients a reliable liveness beacon. Every 10s we
// send each socket both a WS ping (NAT keepalive) and a tiny `{"t":"ka"}` DATA
// frame. The client counts ANY received frame as "alive" — the WS pong callback is
// unreliable on iOS, so this explicit beacon (a real message the client's receive
// loop sees) is what lets the phone detect a dead/half-open socket: no `ka` for
// ~20s ⇒ reconnect. Genuinely dead sockets also fire 'close' and are reaped there.
const KA = '{"t":"ka"}';
setInterval(() => {
  for (const ws of allSockets) {
    if (ws.readyState !== 1) continue;
    // Zombie reaping: a peer that answered neither ping (pong) nor sent anything
    // for a full sweep is a half-open corpse from a network switch — terminate it
    // so it stops holding a per-IP slot and a stale room membership. (This was
    // missing: dead sockets lingered until the kernel's ~15min TCP timeout.)
    if (ws.isAlive === false) {
      console.log(`[reap] dead peer ip=${ws.ip} room=${ws.room || "-"} role=${ws.role || "-"}`);
      try { ws.terminate(); } catch {}
      continue;
    }
    ws.isAlive = false;
    try { ws.ping(); } catch {}
    try { ws.send(KA); } catch {}
  }
}, 10000);

// One HTTP+WS server per port, all sharing `rooms`.
for (const port of PORTS) {
  const httpServer = http.createServer((req, res) => {
    res.writeHead(200, { "content-type": "text/plain" });
    res.end("claude-remote relay ok\n");
  });
  const wss = new WebSocketServer({ server: httpServer });
  wss.on("connection", onConnection);
  httpServer.on("error", (e) => console.error(`[relay] port ${port} error:`, e.message));
  httpServer.listen(port, () => console.log(`[relay] listening on ws://0.0.0.0:${port}`));
}
