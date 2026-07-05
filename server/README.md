# Claude Remote — server (v1)

Node relay + Mac agent that bridge the iOS app to Claude Code on this machine.
v1 goal: get the functional loop working (read + drive) with the simplest viable
encryption. The Mac agent is intentionally a thin, documented-surface-only layer
(watch `~/.claude/projects` + `claude --resume -p`) so it can later be
reimplemented in Swift inside vibTTY without protocol changes.

## Architecture

```
[iOS app / test-client] ──ws──> [relay] <──ws── [agent] ── ~/.claude/projects
        client role                room        agent role        + claude --resume -p
```

- **relay.js** — blind WebSocket forwarder. Routes by `room`; never sees plaintext.
- **agent.js** — watches transcripts, streams sessions/threads/events, and drives
  Claude on `send`. Mints the pairing payload `{url, room, key}` on start.
- **test-client.js** — headless phone stand-in for testing.

Payloads are AES-256-GCM with `key` (32 random bytes in the pairing payload).
The relay only sees `room` + ciphertext. This is the "simplest" v1 crypto — a
proper Noise/CryptoKit handshake with forward secrecy is a later upgrade.

## Run

```bash
npm install

# terminal 1
npm run relay                      # ws://localhost:8787  (PORT=… to change)

# terminal 2
npm run agent                      # prints a PAIRING string (base64)
# env: RELAY=ws://host:8787  CLAUDE_PERMISSION_MODE=acceptEdits  CLAUDE_BIN=claude

# terminal 3 — paste the PAIRING string
node test-client.js "<PAIRING>"                          # list + tail newest session
node test-client.js "<PAIRING>" --session <uuid>          # tail a specific session
node test-client.js "<PAIRING>" --session <uuid> --send "say hi"   # drive Claude
```

## Protocol (inside the encrypted envelope)

client → agent: `{type:"list"}` · `{type:"subscribe",id}` · `{type:"unsubscribe",id}` ·
`{type:"send",id,text}` · `{type:"ping"}`

agent → client: `{type:"sessions",sessions:[…]}` · `{type:"thread",id,lines:[…]}` ·
`{type:"event",id,lines:[…]}` (raw transcript JSONL lines) · `{type:"sent",id,ok}` ·
`{type:"pong"}` · `{type:"error",msg}`

`thread`/`event` ship raw transcript JSONL lines so the iOS app reuses its
existing `TranscriptParser`.

## Notes

- `CLAUDE_PERMISSION_MODE` defaults to `acceptEdits`. Driving in headless mode has
  no TTY to approve tool prompts; routing permission requests to the phone is a
  later feature. Use `bypassPermissions` only on a machine/session you trust.
- Remote across networks: deploy `relay.js` somewhere both sides can reach and set
  `RELAY=wss://…`; localhost is for bring-up.
