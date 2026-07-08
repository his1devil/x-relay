import Foundation
import CryptoKit
import Network

/// A pending tool-permission request the Mac agent is blocked on, awaiting the
/// phone's Allow/Deny.
struct PermissionRequest: Identifiable, Equatable {
    let id: String
    let tool: String
    let command: String?
    let path: String?
    let preview: String?
}

/// The phone side of the relay link. Connects out to the relay, joins the paired
/// room, and exchanges AES-GCM frames with the Mac agent: receives the session
/// list + transcript lines, and sends messages that drive Claude on the Mac.
/// Designed to be a drop-in alternate data source — it produces the same
/// `[Session]` + raw transcript lines the local file source does.
@MainActor
final class RelayClient: ObservableObject {
    enum ConnState: Equatable { case offline, connecting, online }
    enum ThreadUpdate {
        case full([String]); case delta([String])
        /// An older batch of the initial tail — prepend before current lines.
        case prepend([String])
        /// `session` = the session the message ACTUALLY landed in, when the pane
        /// was running a newer conversation than the one the phone targeted.
        case sent(ok: Bool, error: String, session: String?)
        case permission(PermissionRequest); case grid(String)
    }

    /// Live agent status for a cwd, as reported by vibTTY's hook state machine
    /// (thinking/tool/idle/…). Ground truth for the "working" indicator — the phone
    /// stops guessing from transcript silence.
    struct AgentStateInfo: Equatable {
        let state: String
        let since: Date?
        /// Exact session running in the pane (hook payload) — nil on older vibTTY,
        /// where consumers fall back to newest-in-cwd attribution.
        var sessionId: String? = nil
    }

    @Published var state: ConnState = .offline
    @Published var sessions: [Session] = []
    @Published var paired = false
    @Published var lastError = ""
    /// cwd → live agent state (from vibTTY hook events + the sessions list).
    @Published private(set) var agentStates: [String: AgentStateInfo] = [:]

    // Diagnostics (surfaced in the sessions-list header marker) to pinpoint where
    // the remote session list breaks: total frames / encrypted-data frames /
    // decrypt failures / last decrypted message type.
    @Published var dbgFrames = 0
    @Published var dbgData = 0
    @Published var dbgDecryptFail = 0
    @Published var dbgLastType = "-"

    private let defaultsKey = "cr.pairing"
    private var pairing: PairingInfo?

    /// Stable identity for the paired Mac (its relay room) — RelayHub keys devices
    /// on this for dedupe and management.
    var roomId: String? { pairing?.room }

    /// Human label for the device list: the Mac's hostname once a session list has
    /// arrived, else a short room prefix.
    var deviceLabel: String {
        if let host = sessions.first?.host, !host.isEmpty, host != "remote" { return host }
        if let room = pairing?.room { return "Mac · \(String(room.prefix(6)))" }
        return "Mac"
    }
    /// The relay is a direct `ws://<ip>:443` endpoint. Bypass any system proxy/VPN
    /// PAC (URLSession honours it by default and it silently breaks the ws connect on
    /// some carrier/corporate networks — the same trap vibTTY hit), and fail fast so
    /// our own reconnect logic drives recovery instead of URLSession's ~60s hang.
    private var urlSession: URLSession = RelayClient.makeSession()

    private static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.connectionProxyDictionary = [:]
        cfg.waitsForConnectivity = false
        // NOT 15s: for a WebSocket task this bounds each outstanding receive() —
        // cellular RRC wake-ups routinely stretch the relay's 10s ka gap past 15s,
        // so the app kept strangling its OWN healthy socket ("Reconnecting…" loop
        // on mobile data). Liveness is ours (ka-based, 22s) + 12s connect watchdog.
        cfg.timeoutIntervalForRequest = 120
        return URLSession(configuration: cfg)
    }

    /// After a network transition/suspension, URLSession's pool can go ZOMBIE:
    /// every new task resumes but no callback ever fires — not even an error —
    /// so nothing reaches the wire (the relay sees zero joins) while the app
    /// cycles "Reconnecting…" forever. Only a fresh session recovers; a cold
    /// app launch "fixing it" was exactly this. Invalidate + rebuild.
    private func rebuildSession(_ why: String) {
        NSLog("[xrelay] rebuilding URLSession (%@)", why)
        urlSession.invalidateAndCancel()
        urlSession = Self.makeSession()
    }
    private var task: URLSessionWebSocketTask?
    private var connectWatchdog: DispatchWorkItem?
    private var handlers: [String: (ThreadUpdate) -> Void] = [:]
    private var subscribed: Set<String> = []
    private var reconnectAttempts = 0
    private var intentionalClose = false
    /// Consecutive connect attempts that died in `.connecting` (watchdog fired).
    /// 2+ in a row = the session pool itself is suspect → rebuild it.
    private var consecutiveStalls = 0
    /// Real progress only (frame received / went online) — NEVER refreshed by
    /// connect() itself, so the deep-rescue clock can't be starved by a
    /// watchdog→reconnect cycle that goes nowhere.
    private var lastProgressAt = Date()

    // Liveness: a dead/half-open socket (network switch, sleep) does NOT make
    // `task.receive` fail — it just hangs. So we actively probe with WebSocket
    // pings + watch for network-path changes, and force a fresh socket the moment
    // the link looks dead. Without this the app sits "online" on a dead socket:
    // stale (graying) session list + sends that vanish (threads spin forever).
    private var pathMonitor: NWPathMonitor?
    private var lastPathSig: String?
    private var heartbeat: Timer?
    private var lastRxAt = Date()        // last time ANY frame (incl. relay `ka` beacon) arrived
    private var lastForceAt = Date.distantPast   // debounce for forceReconnect

    var isOnline: Bool { state == .online }

    // MARK: pairing lifecycle

    func loadPersistedPairing() {
        guard let s = UserDefaults.standard.string(forKey: defaultsKey),
              let info = RelayCrypto.parsePairing(s) else { return }
        pairing = info
        paired = true
    }

    @discardableResult
    func pair(with string: String, persist: Bool = true) -> Bool {
        guard let info = RelayCrypto.parsePairing(string) else { return false }
        let changed = pairing?.room != info.room || pairing?.url != info.url
        pairing = info
        paired = true
        if persist {
            UserDefaults.standard.set(string.trimmingCharacters(in: .whitespacesAndNewlines), forKey: defaultsKey)
        }
        // Re-pairing MUST rebuild against the new pairing. Tear down any live/in-flight
        // socket first — otherwise `connect()`'s `task == nil` guard no-ops and we stay
        // stuck on the OLD room. Drop per-room state when the room actually changed.
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connectWatchdog?.cancel()
        reconnectAttempts = 0
        if changed {
            subscribed.removeAll()
            handlers.removeAll()
            sessions = []
        }
        connect()
        return true
    }

    func unpair() {
        intentionalClose = true
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connectWatchdog?.cancel()
        stopHeartbeat()
        stopPathMonitor()
        pairing = nil
        paired = false
        sessions = []
        state = .offline
    }

    // MARK: connection

    /// One-time transport migration: plaintext ws:// on the bare relay IP is
    /// killed by DPI middleboxes on corporate/carrier networks (HTTP to the
    /// IP didn't even load). Existing pairings carry the old URL; rewrite
    /// them to the TLS endpoint so nobody has to re-scan a QR.
    /// Candidate transports, ONE relay box (rooms don't bridge across
    /// relays, so every candidate must terminate at the same node):
    ///  1. wss on the domain — the good path; dead while the ICP-pending
    ///     domain gets SNI-RST'd on EVERY port (yes, 8443 too)
    ///  2. plaintext ws to the bare IP:8787 — no SNI, no Host, nothing for
    ///     the middlebox to match; survives the block at home networks
    /// The last URL that reached .online is remembered and tried first.
    static let candidates: [URL] = [
        URL(string: "wss://relay.zhanghuanyang.com")!,
        URL(string: "ws://8.160.186.31:8787")!,
    ]
    private static let lastGoodKey = "cr.relay.lastGood"
    private var candidateIndex = 0

    func currentURL() -> URL {
        if candidateIndex == 0, let saved = UserDefaults.standard.string(forKey: Self.lastGoodKey),
           let u = URL(string: saved), Self.candidates.contains(u) {
            return u
        }
        return Self.candidates[candidateIndex % Self.candidates.count]
    }

    func advanceCandidate() {
        candidateIndex = (candidateIndex + 1) % Self.candidates.count
    }

    func markCandidateGood() {
        UserDefaults.standard.set(currentURL().absoluteString, forKey: Self.lastGoodKey)
    }

    static func migrated(_ url: URL) -> URL {
        // Legacy pairings (Tencent IP / the domain) all route into the
        // candidate chain; custom relays (dev/self-hosted) pass through.
        guard let host = url.host,
              host == "118.89.71.154" || host == "relay.zhanghuanyang.com" || host == "8.160.186.31"
        else { return url }
        return candidates[0]
    }

    func connect() {
        guard let pairing else { return }
        // Idempotent: callers race (.task + scenePhase both fire on launch). A
        // live/in-flight task means we're already connected/connecting — don't
        // stack a second socket (that left a stale connection in the room and
        // dropped pushed frames). handleDisconnect nils `task` before any retry.
        guard task == nil else { return }
        intentionalClose = false
        state = .connecting
        let isManaged = Self.migrated(pairing.url) == Self.candidates[0]
        let t = urlSession.webSocketTask(with: isManaged ? currentURL() : pairing.url)
        t.maximumMessageSize = 32 * 1024 * 1024  // default is 1 MB — thread frames can exceed it
        task = t
        t.resume()
        lastRxAt = Date()
        // NOTE: lastProgressAt is deliberately NOT touched here — only real
        // received frames count as progress (see deep rescue).
        // `join` establishes the room; it's queued and flushed once the socket opens.
        // The session `list` + re-subscribe are sent from `requestListAndResubscribe()`
        // the moment the first received frame confirms we're actually online — sending
        // them here (pre-open) can drop them if the handshake stalls.
        sendRaw(["t": "join", "room": pairing.room, "role": "client"])
        receiveLoop()
        startHeartbeat()
        startPathMonitor()
        scheduleConnectWatchdog()
    }

    /// Ask for the session list + re-subscribe open threads over a socket we KNOW is
    /// live. Called when the first frame flips us to `.online`.
    private func requestListAndResubscribe() {
        sendApp(["type": "list"])
        for id in subscribed { sendApp(["type": "subscribe", "id": id, "proto": 2]) }
    }

    /// Bound a stalled handshake: if we haven't reached `.online` within 12s, rebuild
    /// the socket instead of sitting in `.connecting` (URLSession would otherwise hang
    /// ~60s). Cancelled the instant we go online.
    private func scheduleConnectWatchdog() {
        connectWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .connecting, !self.intentionalClose else { return }
            self.consecutiveStalls += 1
            if self.consecutiveStalls >= 2 {
                // Two stalls back-to-back: assume a poisoned pool, not a slow
                // network — rebuilding is cheap and idempotent.
                self.rebuildSession("connect stalled ×\(self.consecutiveStalls)")
            }
            self.forceReconnect("connect stalled (no open in 12s, ×\(self.consecutiveStalls))")
        }
        connectWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
    }

    private func handleDisconnect() {
        state = .offline
        task = nil
        // Heartbeat stays ALIVE while paired — it hosts the stalled-reconnect
        // rescue, which must survive every disconnected state.
        connectWatchdog?.cancel()
        guard !intentionalClose, pairing != nil else { return }
        reconnectAttempts += 1
        // Rotate the transport candidate after a couple of failures on the
        // current one — the domain's SNI-RST kills every handshake instantly,
        // so waiting out full backoff on a dead candidate wastes minutes.
        if reconnectAttempts % 2 == 0 { advanceCandidate() }
        // Only escalate to a visible message once a few quick retries have all
        // failed — i.e. the relay is genuinely unreachable, not just a blip. Cleared
        // the instant a frame arrives (receiveLoop success).
        if reconnectAttempts >= 4 {
            lastError = "Trouble reaching the relay — still retrying…"
        }
        let delay = min(Double(reconnectAttempts) * 1.5, 8)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.intentionalClose, self.state == .offline else { return }
            self.connect()
        }
    }

    /// Tear down a (possibly half-open) socket and reconnect promptly. Used when a
    /// probe/send fails or the network path changes — unlike `handleDisconnect`
    /// this nils `task` so the `connect()` guard passes, and reconnects fast
    /// (no backoff) since the link genuinely just changed.
    private func forceReconnect(_ reason: String) {
        guard !intentionalClose, pairing != nil else { return }
        // Debounce: collapse a burst of triggers (path flaps, send errors) into one
        // reconnect so we never thrash a connection that's trying to establish.
        guard Date().timeIntervalSince(lastForceAt) > 2 else { return }
        lastForceAt = Date()
        NSLog("[xrelay] forceReconnect: \(reason)")
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        lastError = ""   // a deliberate reconnect (path change / stale link) — stay optimistic
        if state != .connecting { state = .connecting }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.intentionalClose, self.task == nil else { return }
            self.connect()
        }
    }

    /// Foreground / on-demand liveness check: reconnect if there's no socket,
    /// else actively probe (a half-open socket still reports `.online`).
    func ensureLive() {
        guard paired, !intentionalClose else { return }
        if task == nil { connect() }
        else if Date().timeIntervalSince(lastRxAt) > livenessTimeout {
            forceReconnect("foreground: stale link")
        } else if state == .online {
            // The link survived backgrounding, but every push the agent sent
            // while iOS had the socket suspended is GONE (the relay doesn't
            // buffer). Pull one fresh list so toggled panes / agent flips
            // show up without a manual pull-to-refresh.
            requestSessions()
        }
    }

    // MARK: liveness — heartbeat + network path

    /// Seconds without ANY frame (incl. the relay's 10s `ka` beacon) before we
    /// treat the socket as dead. ~2 missed beacons.
    private let livenessTimeout: TimeInterval = 22

    private func startHeartbeat() {
        stopHeartbeat()
        // We rely on the relay's `ka` beacon (every 10s) to keep `lastRxAt` fresh
        // on a live link; this just watches for it going stale. (No WS sendPing —
        // its pong callback is unreliable on iOS and caused false reconnects.)
        let t = Timer(timeInterval: 7, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkLiveness() }
        }
        // .common, NOT default: a scheduledTimer pauses while the user scrolls
        // (UITracking mode) — the watchdog heartbeat must never pause.
        RunLoop.main.add(t, forMode: .common)
        heartbeat = t
    }

    private func stopHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = nil
    }

    private func checkLiveness() {
        guard paired, !intentionalClose else { return }
        let idle = Date().timeIntervalSince(lastRxAt)
        if state == .online, task != nil {
            if idle > livenessTimeout {
                forceReconnect("no frames for \(Int(livenessTimeout))s (stale socket)")
            }
            return
        }
        // NOT online. One-shot recovery paths can be swallowed by races — and
        // worse, a watchdog→forceReconnect→connect cycle refreshes lastRxAt
        // every ~12s, which STARVED the old 30s rescue while zombie tasks
        // burned forever. This deep rescue clocks on lastProgressAt (real
        // frames only): 40s with zero progress → nuke the session pool and
        // start truly fresh. Repeats every 40s for as long as we're down.
        let stalled = Date().timeIntervalSince(lastProgressAt)
        if stalled > 40 {
            NSLog("[xrelay] deep rescue: no progress %.0fs — full session reset", stalled)
            task?.cancel()
            task = nil
            rebuildSession("deep rescue")
            lastProgressAt = Date()   // pace the next deep rescue, NOT starved by connect()
            lastRxAt = Date()
            connect()
        }
    }

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.handlePathUpdate(path) }
        }
        monitor.start(queue: DispatchQueue(label: "cr.path.monitor"))
        pathMonitor = monitor
    }

    private func stopPathMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPathSig = nil
    }

    /// The network path changed. Wi-Fi↔cellular / drop→restore leaves the old
    /// socket half-open, so reconnect on any *real* change (not the first call)
    /// while paired + reachable.
    private func handlePathUpdate(_ path: NWPath) {
        // Signature from the interface the path is actively USING — NOT
        // `availableInterfaces`, which churns (cellular appears/disappears in the
        // available set as the radio sleeps even while Wi-Fi stays primary) and
        // would spuriously reconnect in a loop.
        let using: String
        if path.usesInterfaceType(.wifi) { using = "wifi" }
        else if path.usesInterfaceType(.cellular) { using = "cellular" }
        else if path.usesInterfaceType(.wiredEthernet) { using = "wired" }
        else { using = "other" }
        let sig = "\(path.status):\(using)"
        defer { lastPathSig = sig }
        guard let previous = lastPathSig else { return }   // first report — just record
        guard sig != previous, paired, !intentionalClose else { return }
        if path.status == .satisfied {
            forceReconnect("network changed (\(previous) → \(sig))")
        } else {
            state = .offline   // unreachable — let the next satisfied update reconnect
        }
    }

    // MARK: thread subscription / drive

    func subscribe(id: String, handler: @escaping (ThreadUpdate) -> Void) {
        handlers[id] = handler
        subscribed.insert(id)
        sendApp(["type": "subscribe", "id": id, "proto": 2])
    }

    func unsubscribe(id: String) {
        handlers[id] = nil
        subscribed.remove(id)
        sendApp(["type": "unsubscribe", "id": id])
    }

    func sendMessage(id: String, text: String, attachments: [String] = []) {
        var msg: [String: Any] = ["type": "send", "id": id, "text": text]
        if !attachments.isEmpty { msg["attachments"] = attachments }
        sendApp(msg)
    }

    // MARK: attachments (chunked upload → vibTTY reassembles into a file)

    /// Per-attachment upload state, published so the uploader can await completion
    /// and the composer can show progress / failure.
    enum AttachState: Equatable { case uploading(received: Int, total: Int); case complete; case failed(String) }
    @Published private(set) var attachStates: [String: AttachState] = [:]

    func announceAttachment(id: String, session: String, name: String, mime: String, size: Int, sha: String, total: Int) {
        attachStates[id] = .uploading(received: 0, total: total)
        sendApp(["type": "attach", "id": id, "session": session, "name": name, "mime": mime, "size": size, "sha": sha, "total": total])
    }

    func sendChunk(id: String, seq: Int, base64: String) {
        sendApp(["type": "chunk", "id": id, "seq": seq, "data": base64])
    }

    func clearAttachState(_ id: String) { attachStates[id] = nil }

    func requestSessions() {
        sendApp(["type": "list"])
    }

    /// Spawn a new session on the paired Mac: the agent host launches the chosen
    /// coding agent (`claude`/`til`) in `cwd`, tags the new session with that agent,
    /// and runs `prompt` as the first instruction if given.
    func newSession(cwd: String, agent: AgentKind, prompt: String) {
        sendApp(["type": "spawn", "cwd": cwd, "agent": agent.command, "prompt": prompt])
    }

    // MARK: terminal mirror (P4)

    /// Tell the agent to start/stop streaming the pane's terminal grid for `id`.
    func setMirror(id: String, on: Bool) {
        sendApp(["type": "mirror", "id": id, "on": on])
    }

    /// Type text into the mirrored pane (optionally followed by Enter).
    func sendTerminalText(id: String, text: String, enter: Bool) {
        sendApp(["type": "key", "id": id, "text": text, "enter": enter])
    }

    /// Send special keys (up/down/left/right/enter/esc/tab) to the mirrored pane.
    func sendTerminalKeys(id: String, keys: [String]) {
        sendApp(["type": "key", "id": id, "keys": keys])
    }

    func resolvePermission(id: String, decision: String) {
        sendApp(["type": "permission-decision", "id": id, "decision": decision])
    }

    // MARK: send

    private func sendRaw(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(str)) { [weak self] error in
            guard let error else { return }
            // A send that errors on an "online" socket means it's actually dead
            // (the classic half-open after a network switch) — recover now so the
            // message isn't silently lost (which is what spun threads forever).
            Task { @MainActor in
                guard let self, self.state == .online else { return }
                self.forceReconnect("send failed: \(error.localizedDescription)")
            }
        }
    }

    private func sendApp(_ obj: [String: Any]) {
        guard let pairing,
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let enc = RelayCrypto.encrypt(data, key: pairing.key) else { return }
        sendRaw(["t": "data", "enc": enc])
    }

    // MARK: receive

    private func receiveLoop() {
        let current = task
        current?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === current else { return }
                switch result {
                case let .success(message):
                    self.lastRxAt = Date()
                    self.lastProgressAt = Date()   // REAL progress — feeds the deep rescue
                    self.consecutiveStalls = 0
                    if self.state != .online {
                        self.lastError = ""
                        self.state = .online
                        self.markCandidateGood()
                        self.reconnectAttempts = 0
                        self.connectWatchdog?.cancel()
                        self.requestListAndResubscribe()
                    }
                    switch message {
                    case let .string(text): self.handleFrame(text)
                    case let .data(d): if let s = String(data: d, encoding: .utf8) { self.handleFrame(s) }
                    @unknown default: break
                    }
                    self.receiveLoop()
                case let .failure(error):
                    // errno-53 "Software caused connection abort" & its siblings
                    // (ECONNRESET/ENOTCONN, networkConnectionLost, cancelled) are
                    // EXPECTED transient drops — backgrounding, Wi-Fi↔cellular, NAT
                    // idle-timeout. The reconnect loop below handles them, so never
                    // flash raw POSIX jargon at the user: keep lastError empty and the
                    // banner shows a calm "Reconnecting…". A friendly message surfaces
                    // only once retries keep failing (handleDisconnect).
                    NSLog("[xrelay] ws failure: %@", String(describing: error))
                    self.lastError = ""
                    self.handleDisconnect()
                }
            }
        }
    }

    private func handleFrame(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["t"] as? String else { return }
        dbgFrames += 1

        if t == "peer", (obj["role"] as? String) == "agent", (obj["status"] as? String) == "online" {
            sendApp(["type": "list"])
            for id in subscribed { sendApp(["type": "subscribe", "id": id, "proto": 2]) }
            return
        }
        if t == "data", let enc = obj["enc"] as? String, let pairing {
            dbgData += 1
            if let plain = RelayCrypto.decrypt(enc, key: pairing.key),
               let msg = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] {
                dbgLastType = msg["type"] as? String ?? "?"
                handleApp(msg)
            } else {
                dbgDecryptFail += 1
            }
        }
    }

    private func handleApp(_ msg: [String: Any]) {
        switch msg["type"] as? String {
        case "sessions":
            if let arr = msg["sessions"] as? [[String: Any]] {
                sessions = arr.compactMap { Self.session(from: $0) }
                // REBUILD live agent states from the list (authoritative snapshot of
                // pane state). Merging left stale "working" entries behind when a
                // pane closed or its Stop event was missed while backgrounded.
                var rebuilt: [String: AgentStateInfo] = [:]
                for dict in arr {
                    if let cwd = dict["cwd"] as? String, !cwd.isEmpty,
                       let st = dict["agentState"] as? String, !st.isEmpty {
                        let since = (dict["agentSince"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                        rebuilt[cwd] = AgentStateInfo(state: st, since: since, sessionId: dict["agentSession"] as? String)
                    }
                }
                if rebuilt != agentStates { agentStates = rebuilt }
            }
        case "agentState":
            if let cwd = msg["cwd"] as? String, let st = msg["state"] as? String {
                let since = (msg["since"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                agentStates[cwd] = AgentStateInfo(state: st, since: since, sessionId: msg["session"] as? String)
            }
        case "thread":
            if let id = msg["id"] as? String, let lines = msg["lines"] as? [String] {
                NSLog("[halx-rx] thread id=%@ lines=%d prepend=%d",
                      String(id.prefix(8)), lines.count, (msg["prepend"] as? Bool) == true ? 1 : 0)
                if (msg["prepend"] as? Bool) == true {
                    handlers[id]?(.prepend(lines))
                } else {
                    handlers[id]?(.full(lines))
                }
            }
        case "event":
            if let id = msg["id"] as? String, let lines = msg["lines"] as? [String] {
                handlers[id]?(.delta(lines))
            }
        case "grid":
            if let id = msg["id"] as? String, let frame = msg["frame"] as? String {
                handlers[id]?(.grid(frame))
            }
        case "sent":
            // Delivery ack from the agent — `ok:false` means the inject FAILED
            // (dormant pane, no pane, control off); surface it, never swallow it.
            if let id = msg["id"] as? String {
                handlers[id]?(.sent(ok: msg["ok"] as? Bool ?? true,
                                    error: msg["error"] as? String ?? "",
                                    session: msg["session"] as? String))
            }
        case "permission":
            if let id = msg["id"] as? String, let session = msg["session"] as? String {
                let req = PermissionRequest(
                    id: id,
                    tool: msg["tool"] as? String ?? "Tool",
                    command: msg["command"] as? String,
                    path: msg["path"] as? String,
                    preview: msg["preview"] as? String
                )
                handlers[session]?(.permission(req))
            }
        case "attachAck":
            if let id = msg["id"] as? String {
                if msg["complete"] as? Bool == true { attachStates[id] = .complete }
                else if let err = msg["error"] as? String { attachStates[id] = .failed(err) }
                else if let r = msg["received"] as? Int, let t = msg["total"] as? Int {
                    attachStates[id] = .uploading(received: r, total: t)
                }
            }
        case "error":
            NSLog("[relay] agent error: %@", msg["msg"] as? String ?? "?")
        default:
            break
        }
    }

    // MARK: session mapping

    private static func session(from dict: [String: Any]) -> Session? {
        guard let id = dict["id"] as? String else { return nil }
        let mtime = (dict["mtime"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Session(
            id: id,
            name: dict["name"] as? String ?? id,
            path: dict["path"] as? String ?? "",
            host: (dict["host"] as? String) ?? "remote",
            gitBranch: nil,
            lastActivity: mtime,
            snippet: snippetText(dict["snippet"] as? String),
            status: status(mtime),
            fileURL: nil,
            isLive: true,
            isRemote: true,
            agent: AgentKind.from(dict["agent"] as? String),
            model: (dict["model"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            canDrive: (dict["canDrive"] as? Bool) ?? true,
            agentAlive: (dict["agentAlive"] as? Bool) ?? true,
            defaultModel: dict["defaultModel"] as? String,
            defaultEffort: dict["defaultEffort"] as? String,
            cwdLive: (dict["cwdLive"] as? Bool) ?? false
        )
    }

    private static func snippetText(_ t: String?) -> String {
        guard let t else { return "Idle · no recent activity" }
        let one = t.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = one.count > 64 ? String(one.prefix(64)) + "…" : one
        return "Claude · \(capped)"
    }

    private static func status(_ d: Date?) -> SessionStatus {
        guard let d else { return .idle }
        let age = Date().timeIntervalSince(d)
        if age < 600 { return .running }
        if age < 6 * 3600 { return .idle }
        return .done
    }
}
