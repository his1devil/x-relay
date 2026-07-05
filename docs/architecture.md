# HALX — Architecture & Design

HALX (repo `x-relay`, app display name **HALX**, was "Claude Remote") is a native
iOS client that renders **Claude Code** sessions as a Discord‑style instant
messenger — assistant messages, thinking, tool calls, diffs, permission prompts —
and lets you **drive Claude from your phone**, across networks.

It is explicitly **not a terminal mirror**: the phone renders structured events
parsed from Claude Code's transcript, with native SwiftUI UI.

---

## 1. The three components

```
   ┌─────────────┐         ┌──────────────────┐         ┌────────────────────────┐
   │  iOS app    │  wss/ws │   relay (Node)   │  ws     │   Mac agent (Node)     │
   │  (HALX)     │ ───────▶│  blind forwarder │◀─────── │  server/agent.js       │
   │  SwiftUI    │ ◀────── │  server/relay.js │ ───────▶│                        │
   └─────────────┘  room   │  8.160.186.31    │  room   │  watches ~/.claude     │
                            └──────────────────┘         │  spawns `claude -p`    │
                                                          └──────────┬─────────────┘
                                                                     │ reads/append
                                                            ~/.claude/projects/**.jsonl
                                                                     │
                                                                 `claude` CLI
```

1. **iOS app** (`ClaudeRemote/`) — SwiftUI. Two data sources behind one UI:
   - **local**: reads this Mac's real `~/.claude/projects/**/*.jsonl` (simulator,
     via `SIMULATOR_HOST_HOME`) or bundled fixtures (device, dev only).
   - **remote**: streams sessions + transcript lines from the Mac agent through
     the relay. This is the product path.
2. **relay** (`server/relay.js`) — a **blind WebSocket forwarder**. Peers join a
   `room` and it forwards every `data` frame to the other peers. Payloads are
   end‑to‑end AES‑GCM encrypted; the relay only sees `room` + ciphertext. Runs on
   a **public server** so phone and Mac can reach it from any network.
3. **Mac agent** (`server/agent.js`) — watches `~/.claude/projects`, streams
   `sessions`/`thread`/`event` to the phone, and on `send` drives Claude via the
   `claude` CLI. The transcript file is the sync substrate.

The transcript JSONL is the **single source of truth**. Everything the phone
shows is parsed from it; driving Claude appends to it; the watcher streams the
append back. No separate state to keep in sync.

---

## 2. Data flow

### Read path (open a session)
1. Phone connects to the relay, joins the paired `room`, sends `{type:list}`.
2. Agent replies `{type:sessions,[…]}` — id, cwd, name, mtime, snippet per
   session (cheap head/tail reads, no full parse).
3. Phone opens a thread → `{type:subscribe,id}`.
4. Agent `sendThread`: sends the **last ~400 lines** of that transcript
   (`{type:thread,id,lines}`) — tail‑first so multi‑MB sessions open instantly —
   and starts a chokidar watcher on the file.
5. Phone parses the lines (`TranscriptParser`) → `ChatTimeline` → renders.
6. On file change the agent sends `{type:event,id,lines}` (only the appended
   lines); the phone appends + reparses.

### Drive path (send a message from the phone)
1. Phone (remote session) shows an **optimistic** user bubble + "Claude is
   working…", then sends `{type:send,id,text}`.
2. Agent `drive(id,text)` spawns (per message; not a persistent process):
   ```
   claude --resume <id> -p "<text>" --output-format json \
     --permission-mode default --settings ~/.xrelay/perm-settings.json
   ```
   in the session's `cwd`, with `env = process.env + XRELAY_PERM_SOCK`.
3. `--resume` continues the same session → the turn appends to the same
   transcript → the watcher streams the new lines back as `event` deltas.
4. When the process exits, agent sends `{type:sent,id,ok}` → phone clears the
   working indicator.
5. Mutating tools pause for phone approval — see §5.

### Process model & efficiency
Each `send` spawns a **fresh, short‑lived** `claude -p` process that runs the one
turn and **exits** — so processes never accumulate (at most one running per
message; no leak, no idle daemon eating RAM). The cost is **per‑message
overhead**: CLI startup (~0.5–1s) + reloading the session context on `--resume`.
Anthropic‑side prompt caching makes the resumed context cheap to re‑prime, so the
token cost is mostly cache reads, not a full re‑send.

This one‑shot model is the v1 choice: simplest and most reliable, with the
transcript as the clean handoff. The efficient upgrade — for rapid back‑and‑forth
— is a **persistent PTY‑held `claude`** that stays warm and receives injected
input (the seedex/vibTTY approach: no respawn, context stays loaded). It's more
complex (PTY lifecycle, stream‑json parsing, single‑owner) and is the planned
"fold the agent into vibTTY" direction (§10), not a v1 need.

---

## 3. iOS app structure (`ClaudeRemote/`)

- `App/ClaudeRemoteApp.swift` — `@main`; injects `SessionStore`, `ThemeController`,
  `RelayClient` as environment objects.
- `Theme/` — `Theme.swift` (Discord palette, `dark`/`light`, `isDark`),
  `AppFont.swift` (Hanken Grotesk variable + JetBrains Mono; SwiftUI + UIKit
  variants).
- `Model/`
  - `RawTranscript.swift` — lenient `Decodable` for one JSONL line (only the
    fields rendered; `toolUseResult` is a TARGETED struct, not a full `JSONValue`,
    or big sessions explode the decode).
  - `TranscriptParser.swift` — two‑pass: build a tool_use_id→result map, then a
    flat `[TimelineItem]` (user / assistant‑group / system / date‑divider).
  - `Timeline.swift` — the render model (`AssistantGroup` with `model` + thinking,
    `ToolCall` with kind/diffRows/etc.).
  - `TranscriptLoader.swift` — `actor`; off‑main file I/O. `initial()` tail‑reads
    the last ~2MB for big files; `appended()` reads only new bytes from EOF.
  - `ThreadModel.swift` — backs one channel (local live‑tail or remote stream);
    optimistic echo, working indicator, pending permissions; coalesces/caps live
    updates (§6).
  - `SessionStore.swift` — session list (cheap metadata + DispatchSource watcher).
  - `RelayClient.swift` — `URLSessionWebSocketTask` to the relay; `RelayCrypto`
    AES‑GCM; pair/connect/subscribe/send/resolvePermission; auto‑reconnect.
  - `RelayCrypto.swift` — CryptoKit AES‑GCM matching the Node `iv|tag|ct` layout.
- `Views/`
  - `RootView` (splash + offline banner + nav), `SessionsListView` (HALX header,
    time‑grouped list), `ThreadView` (header + transcript + composer),
    `DiffView`, `PairingView`, `NewSessionView`, `LockView`, `QRScannerView`.
  - `Timeline/` — `TimelineViews` (user/assistant/system rows), `ToolEmbedView`
    (Bash/Edit→Diff/Write/Read/Search/Todo/Question/generic embeds + `CodeSheet`
    drawer).
  - `Components/` — `RichText`+`MarkdownText`+`MarkdownCache` (markdown, §7),
    `Badges`, `ChatExtras` (PermissionCard, ConnectionBanner, WorkingIndicator),
    `SignalMark` (logo), `Formatters`.

---

## 4. Pairing & crypto

- The agent mints an identity `{ room (16 hex), key (32 bytes) }`, **persisted**
  in `~/.xrelay/identity.json` so restarting the agent keeps the same QR.
- The pairing payload is `base64({ url, room, key })`, shown as a QR
  (`qrcode-terminal`) and pasteable. Phone scans (AVFoundation) or pastes;
  `RelayClient` persists it in `UserDefaults`.
- Transport security: AES‑256‑GCM, key in the QR only — **never transmitted**.
  Relay sees room + ciphertext. Envelope = `base64(iv[12] | tag[16] | ct)` (Node)
  ↔ CryptoKit (Swift). v1 simple shared‑key; Noise/forward‑secrecy is a later
  upgrade (deliberately deferred).

---

## 5. Interactive permissions

So you can approve Claude's actions from the phone:
- Agent injects a `PreToolUse` hook via `--settings ~/.xrelay/perm-settings.json`
  (only into spawned sessions — the user's global `~/.claude` is untouched). The
  hook (`~/.xrelay/perm-hook.cjs`) talks to the agent over a unix socket
  (`xrelay-perm-<room>.sock`).
- **Gated tools** = Bash / Write / Edit / MultiEdit / NotebookEdit (everything
  else auto‑allows so the turn never stalls on reads). Phone offline ⇒ auto‑deny;
  290s timeout ⇒ deny.
- Protocol: agent → `{type:permission,id,session,tool,command,path,preview}`;
  phone → `{type:permission-decision,id,decision}`.
- UI: a gold **PermissionCard** (Allow/Deny + command/diff preview) in the thread;
  the tool_use embed also renders above it (it's written before the hook fires).

---

## 6. Performance design

- **Tail‑first**: agent `sendThread` caps to the last ~400 lines; local
  `TranscriptLoader.initial()` reads only the last ~2MB of big files.
- **Bounded live updates** (`ThreadModel`): remote `rawLines` are **capped to the
  last 800** and delta reparses are **debounced 0.3s** — a live session (e.g. the
  in‑progress x‑relay session) otherwise rebuilt the whole timeline from
  thousands of accumulated lines on every streamed line, which stuttered the list
  and collided with keyboard layout changes.
- **Markdown caches**: `MarkdownCache` memoizes parsed blocks by source string so
  scrolling a `LazyVStack` never re‑parses.
- **Stable ForEach ids**: diff‑preview / todos / questions iterate
  `enumerated().offset`, never `id = UUID()` (which churned a new identity each
  render).
- **Off‑main parsing**: `TranscriptLoader` is an `actor`; remote reparse runs in a
  `Task.detached`.

---

## 7. Rendering pipeline (markdown)

Assistant/user prose → `RichText`, a **hand‑rolled, synchronous** block renderer
(`MarkdownBlock.parse` → native SwiftUI views): paragraphs, bold headings,
fenced code (tap → `CodeSheet` bottom drawer), ordered/unordered lists, GFM
tables, blockquotes, rules; inline bold/italic/`code`‑chip/links via
`MarkdownText` (`AttributedString`).

> **Why hand‑rolled, not MarkdownUI?** MarkdownUI (tried, then removed) measures
> block heights **asynchronously**, which makes `LazyVStack` scroll positions
> unreliable on any layout change — the thread blanked on initial load and on
> every keyboard toggle (scroll landing in empty space, recovering on dismiss).
> Synchronous heights ⇒ stable scroll. Trade‑off: no nested lists / task lists /
> some GFM edge cases.

---

## 8. Keyboard handling (hard‑won)

The composer is a **native SwiftUI `TextField(axis:.vertical)`** (auto‑grow,
1–5 lines). This is deliberate:

- A custom `UITextView` composer (needed for an inline `/command` chip) **breaks
  SwiftUI's keyboard avoidance**. Every workaround failed: manual
  `KeyboardObserver` + padding double‑moved on the sim; `.ignoresSafeArea(.keyboard)`
  + padding didn't lift on device; `.safeAreaInset` mislaid the bar; a full
  `inputAccessoryView` VC‑hosting refactor made content vanish.
- With a native `TextField`, SwiftUI's own avoidance moves the stack with the
  keyboard; `defaultScrollAnchor(.bottom)` + synchronous heights keep the latest
  visible; tap‑to‑dismiss via `@FocusState`; swipe via
  `.scrollDismissesKeyboard(.interactively)`.
- Trade‑off: no inline `/command` chip in the input (the whole field tints
  blurple when the draft starts with `/`); the **timeline** still renders slash
  commands as chips (`CommandChip`).

(Diagnostics: a tiny `vN` marker in the thread header confirms the installed
build; `CR_FOCUS` autofocuses the field for headless keyboard testing.)

---

## 9. Backend deployment

- Relay runs on a **public server** (Alibaba Cloud `8.160.186.31`) at
  `/root/app/relay/`, as a **systemd unit** `xrelay-relay` (`Restart=always`,
  PORT 8787). Inbound 8787 must be open in the **cloud security group** (the
  server's own firewalld is off). Relay also answers plain HTTP `GET / → "ok"`
  for a reachability probe.
- Mac agent points at it: `RELAY=ws://8.160.186.31:8787 npm run agent`.
- **Proxy**: the spawned `claude` inherits the agent's env; if none is set,
  `captureLoginShellProxy()` reads `HTTPS_PROXY`/etc. from the login shell
  (`~/.zshrc`) — handy when traveling. The agent→relay socket itself is direct.
- Watch it on the desktop: `tail -f /tmp/cr-agent.log` (drive/permission/push
  logs), `tail -f ~/.claude/projects/*/<id>.jsonl` (the turn landing),
  `claude --resume <id>` (same session in a TUI — shares the transcript, not the
  process).
- iOS networking gotcha: plain `ws://` to a public IP needs
  `NSAppTransportSecurity → NSAllowsArbitraryLoads = true` **as the only ATS key**
  (adding `NSAllowsLocalNetworking` makes iOS 10+ ignore ArbitraryLoads).

---

## 10. Status & roadmap

Done: full Discord‑style rendering, live local data, remote read + drive,
QR pairing, on‑device install, interactive permissions, theme persistence,
optimistic echo, offline banner, tail‑first, structured diffs, time‑grouped
session list, launch splash, markdown (headings/lists/tables/code/quotes),
drawers for big content, keyboard avoidance.

Remaining (see [`ios-roadmap.md`](ios-roadmap.md)): search, live agent status,
new‑session dispatch from phone, stop/interrupt, settings, APNs push, multi‑Mac,
iPad, accessibility; backend: `wss`/TLS, Noise upgrade, fold the Node agent into
vibTTY.

See also [`event-rendering.md`](event-rendering.md) for the full transcript event
taxonomy and per‑type render plan.

---

### Dev / test hooks (strip before release)
`CR_PAIRING`, `CR_AUTOPUSH` / `CR_AUTOPUSH_ID`, `CR_AUTOSEND`, `CR_TOP`,
`CR_LIGHT`, `CR_SHEET`, `CR_LOCK`, `CR_FOCUS` (env, via `SIMCTL_CHILD_*` on the
simulator). The `vN` header marker is a debug build stamp.
