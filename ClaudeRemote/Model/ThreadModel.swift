import SwiftUI
import Combine

/// Backs a single channel, local (lazy tail of the on-disk transcript) or remote
/// (streamed lines from the agent). Either way the view renders `items`, plus an
/// optimistic echo of a just-sent message and a "working" indicator so remote
/// sends feel instant instead of waiting for the round-trip.
@MainActor
final class ThreadModel: ObservableObject {
    @Published var items: [TimelineItem] = []
    @Published var isLoading = true
    @Published var optimisticUser: String?   // shown immediately after send
    @Published var optimisticThumbs: [UIImage] = []   // picked image previews while uploading
    @Published var working = false           // "Claude is working…" until the turn completes
    @Published var workStartedAt: Date?       // turn start (from vibTTY's hook clock) — drives the elapsed readout
    @Published var sendFailure: String?       // delivery failure from the agent — shown, never swallowed

    /// A newer session owns this project's pane — offer a jump (never auto-switch).
    /// `.redirected` = your message actually landed there; `.newer` = passive notice.
    struct JumpHint: Equatable {
        enum Reason { case redirected, newer }
        let sessionId: String
        let reason: Reason
    }
    @Published var jumpHint: JumpHint?
    @Published var listedIds: Set<String> = []   // for the banner's "ready" state
    /// Live copy of THIS session from the latest pushed list — the thread was
    /// opened with a value snapshot, so agent exit/restart while it's on screen
    /// must flow through here (badge + composer react in real time).
    @Published var liveSession: Session?
    @Published var pendingPermissions: [PermissionRequest] = []
    @Published var gridFrame: String?         // latest terminal-mirror grid (P4)
    @Published var revision = 0               // bumped on every (re)parse — drives stream-scroll

    private let sessionId: String
    private let isRemote: Bool
    private let live: Bool
    private let url: URL?
    private let isCodex: Bool   // route to CodexTranscript instead of TranscriptParser
    private let cwd: String     // session working dir — the key agentState events arrive under

    /// True once vibTTY has reported a real hook-driven agent state for this cwd.
    /// From then on `working` follows that truth and the transcript-silence
    /// heuristic is demoted to a long crash-safety timeout.
    private var hasAgentTruth = false
    private var stateBag = Set<AnyCancellable>()

    // local
    private let loader: TranscriptLoader?
    private var watcher: DispatchSourceFileSystemObject?
    private var reloadWork: DispatchWorkItem?

    // remote
    private weak var relay: RelayClient?
    private var rawLines: [String] = []
    // D: incremental decode — records for the already-decoded rawLines prefix.
    // JSON decode is the hot half of a reparse; deltas only decode NEW lines and
    // the timeline is rebuilt from cached records (pure in-memory assembly).
    private var cachedRecords: [RawRecord] = []
    private var decodedLineCount = 0
    private var workTimeout: DispatchWorkItem?
    private var remoteReparseWork: DispatchWorkItem?

    private var started = false

    init(session: Session, relay: RelayClient? = nil) {
        sessionId = session.id
        isRemote = session.isRemote
        live = session.isLive
        url = session.fileURL
        isCodex = session.agent == .codex
        cwd = session.path
        self.relay = session.isRemote ? relay : nil
        let codex = session.agent == .codex
        loader = (!session.isRemote) ? session.fileURL.map { TranscriptLoader(url: $0, codex: codex) } : nil
    }

    func start() {
        guard !started else { return }
        started = true
        #if DEBUG
        if ProcessInfo.processInfo.environment["CR_STREAM"] != nil, sessionId == "cc-stress" {
            isLoading = false
            startMockStream()   // streaming-shape benchmark: full parser pipeline
            return
        }
        if let mock = MockTimeline.timeline(forSessionId: sessionId) {
            items = mock
            isLoading = false
            return
        }
        #endif
        if isRemote {
            // Ground truth for "working": vibTTY's hook state machine, keyed by cwd.
            relay?.$agentStates
                .compactMap { $0[self.cwd] }
                .removeDuplicates()
                .sink { [weak self] info in self?.applyAgentTruth(info) }
                .store(in: &stateBag)
            // Session ids currently listed — drives the jump banner's ready state
            // (the watcher-pushed list usually lands within ~1s of a takeover).
            relay?.$sessions
                .map { Set($0.map(\.id)) }
                .removeDuplicates()
                .sink { [weak self] ids in self?.listedIds = ids }
                .store(in: &stateBag)
            relay?.$sessions
                .compactMap { [sessionId] list in list.first { $0.id == sessionId } }
                .removeDuplicates { $0.canDrive == $1.canDrive && $0.agentAlive == $1.agentAlive }
                .sink { [weak self] s in self?.liveSession = s }
                .store(in: &stateBag)
            relay?.subscribe(id: sessionId) { [weak self] update in
                guard let self else { return }
                switch update {
                case let .prepend(lines):
                    // LAZY history: older batches park in a buffer and the UI
                    // is not touched at all — no reparse, no list churn. They
                    // splice in only when the user actually scrolls near the
                    // top (mountOlderIfNeeded), at which point the insert is
                    // both expected and instant (bytes are already here).
                    guard !lines.isEmpty else { return }
                    self.pendingOlder = lines + self.pendingOlder
                case let .full(lines):
                    self.pendingOlder = []
                    self.rawLines = self.capped(lines)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        guard let self else { return }
                        if self.rawLines.count < 120, !self.pendingOlder.isEmpty {
                            self.mountOlderIfNeeded()
                        }
                    }
                    self.cachedRecords = []
                    self.decodedLineCount = 0
                    self.reparseRemote()
                case let .delta(lines):
                    let expected = self.rawLines.count + lines.count
                    self.rawLines = self.capped(self.rawLines + lines)
                    if self.rawLines.count != expected {
                        // The head got trimmed by the cap — cached records no longer
                        // line up with the buffer. Rebuild from scratch next pass.
                        self.cachedRecords = []
                        self.decodedLineCount = 0
                    }
                    self.scheduleReparseRemote()
                case let .sent(ok, error, landed):
                    // Delivery ack only (not turn completion) — but a FAILURE must
                    // surface: kill the optimistic UI and show why.
                    if !ok {
                        self.working = false
                        self.workStartedAt = nil
                        self.optimisticUser = nil
                        self.workTimeout?.cancel()
                        self.sendFailure = Self.friendlySendError(error)
                    } else if let landed, landed != self.sessionId {
                        // The pane is running a NEWER conversation — the message
                        // landed there, and the reply will stream there too. This
                        // thread stays quiet; offer a jump instead of a ghost wait.
                        self.working = false
                        self.workStartedAt = nil
                        self.optimisticUser = nil
                        self.workTimeout?.cancel()
                        self.jumpHint = JumpHint(sessionId: landed, reason: .redirected)
                    }
                case let .permission(req):
                    if !self.pendingPermissions.contains(where: { $0.id == req.id }) {
                        self.pendingPermissions.append(req)
                    }
                case let .grid(frame): self.gridFrame = frame
                }
            }
        } else {
            Task {
                if let loader {
                    let timeline = await loader.initial()
                    items = timeline.items
                }
                isLoading = false
                startWatching()
            }
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        if isRemote { relay?.unsubscribe(id: sessionId); relay?.setMirror(id: sessionId, on: false) }
        #if DEBUG
        mockStream?.invalidate()
        mockStream = nil
        #endif
    }
    // NOTE: the legacy ThreadView also renders from this model; it needs no `.sent`
    // handling of its own (failures surface via `sendFailure`).

    #if DEBUG
    // MARK: CR_STREAM — streaming-shape benchmark (simulator only)

    private var mockStream: Timer?
    private var mockLines: [String] = []

    /// Feeds claude-format JSONL through the REAL parser pipeline (decode → build →
    /// adapter stamps → exyte diff) on a timer, mimicking a live turn: the trailing
    /// assistant group grows in place, and every 6th tick starts a new turn. This is
    /// what proves the trailing-group id stays stable (no blink/slide) while
    /// streaming — and exercises the working indicator.
    private func startMockStream() {
        func rec(_ obj: [String: Any]) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
        }
        let iso = ISO8601DateFormatter()
        var step = 0
        working = true
        workStartedAt = Date()
        mockLines.append(rec(["type": "user", "timestamp": iso.string(from: Date()),
                              "message": ["role": "user", "content": "Kick off the streaming benchmark."]]))
        rawLines.append(mockLines[mockLines.count - 1])
        scheduleReparseRemote()
        mockStream = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                step += 1
                let ts = iso.string(from: Date())
                if step % 6 == 0 {
                    self.mockLines.append(rec(["type": "user", "timestamp": ts,
                                               "message": ["role": "user", "content": "Follow-up #\(step): keep going."]]))
                } else {
                    self.mockLines.append(rec(["type": "assistant", "timestamp": ts,
                                               "message": ["role": "assistant", "model": "claude-sonnet-4-5-20250101",
                                                           "content": [["type": "text",
                                                                        "text": "Streamed chunk \(step) — the trailing message must grow **in place**: no blink, no slide, just new lines appearing."]]]]))
                }
                // Feed the REAL incremental pipeline (delta decode + cached-record
                // assemble) so the benchmark measures production behavior.
                let newLine = self.mockLines.removeLast()
                self.mockLines.append(newLine)
                self.rawLines.append(newLine)
                self.scheduleReparseRemote()
            }
        }
    }
    #endif

    // MARK: terminal mirror (P4)

    func setTerminalMirror(_ on: Bool) {
        guard isRemote else { return }
        if !on { gridFrame = nil }
        relay?.setMirror(id: sessionId, on: on)
    }

    func sendTerminalText(_ text: String, enter: Bool) {
        guard isRemote else { return }
        relay?.sendTerminalText(id: sessionId, text: text, enter: enter)
    }

    func sendTerminalKeys(_ keys: [String]) {
        guard isRemote else { return }
        relay?.sendTerminalKeys(id: sessionId, keys: keys)
    }

    // MARK: send (remote) + optimistic state

    func send(_ text: String, attachments: [PickedAttachment] = []) {
        guard isRemote, let relay else { return }
        optimisticUser = text.isEmpty && !attachments.isEmpty ? attachmentSummary(attachments) : text
        optimisticThumbs = attachments.compactMap(\.thumbnail)
        working = true
        workStartedAt = Date()   // instant feedback; replaced by the hook's turn clock
        sendFailure = nil

        guard !attachments.isEmpty else {
            relay.sendMessage(id: sessionId, text: text)
            scheduleWorkingIdle(after: hasAgentTruth ? 600 : 25)
            return
        }
        // Upload files first, then send the message referencing them. A failure here
        // must NOT send a message with missing files — surface it instead.
        Task { [weak self] in
            guard let self else { return }
            do {
                let ids = try await AttachmentUploader.upload(attachments, session: sessionId, via: relay)
                self.optimisticThumbs = []
                relay.sendMessage(id: sessionId, text: text, attachments: ids)
                self.scheduleWorkingIdle(after: self.hasAgentTruth ? 600 : 25)
            } catch {
                self.working = false
                self.workStartedAt = nil
                self.optimisticUser = nil
                self.optimisticThumbs = []
                self.workTimeout?.cancel()
                self.sendFailure = "Attachment failed · \(error.localizedDescription)"
            }
        }
    }

    /// Splice ONE PAGE of buffered older history into the timeline — called
    /// when the user scrolls near the top; reaching the top again mounts the
    /// next page (Discord-style). Small slices keep the table's height
    /// re-estimation error (and thus the anchor compensation error) tiny.
    func mountOlderIfNeeded() {
        guard !pendingOlder.isEmpty else { return }
        // Page cut aligns to a USER record: a user turn always starts a new
        // group, so the seam between this page and the next never merges —
        // the NEXT mount is then a pure tail insert (no boundary-group id
        // shift, no fallback to the table-reloading slow path).
        let page = 48
        var take = min(page, pendingOlder.count)
        // Extend to a user-record seam (never merges with the next page) but
        // CAP the walk — a marathon assistant turn with no user record in
        // sight once swallowed a 209-line buffer into one mega-mount.
        let cap = min(page * 2, pendingOlder.count)
        while take < cap {
            if pendingOlder[pendingOlder.count - take].contains("\"type\":\"user\"") { break }
            take += 1
        }
        let slice = Array(pendingOlder.suffix(take))
        pendingOlder.removeLast(take)
        rawLines = capped(slice + rawLines)
        cachedRecords = []
        decodedLineCount = 0
        // Immediate (not debounced): back-to-back mounts must land as
        // SEPARATE small tail-inserts — the debounce once fused three pages
        // into one 220-line mega-update that rippled the whole table.
        reparseRemote()
        // Keep a screen and a half of runway: a thin initial frame (a few
        // lines) back-fills page by page WITHOUT waiting for a scroll event.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            if self.rawLines.count < 120, !self.pendingOlder.isEmpty {
                self.mountOlderIfNeeded()
            }
        }
    }

    private func attachmentSummary(_ items: [PickedAttachment]) -> String {
        items.count == 1 ? "📎 \(items[0].name)" : "📎 \(items.count) attachments"
    }

    /// The user's model/effort choice for THIS session (applied via slash commands).
    /// The transcript remains the source of truth for what the agent actually runs;
    /// this drives the composer chip immediately.
    @Published var chosenModel: String?    // short arg, e.g. "sonnet"
    @Published var chosenEffort: String?   // "low" | "medium" | "high" | "max"
    /// Live context footprint from the transcript (last assistant turn's prompt
    /// tokens) — drives the composer's progress ring. Claude-family only.
    @Published var contextTokens: Int?
    private var pendingOlder: [String] = []

    /// Slash commands are instant TUI actions, not conversation turns — deliver
    /// without the optimistic bubble / working indicator (failures still surface
    /// through the sent-ack path).
    func sendCommand(_ command: String) {
        guard isRemote, let relay else { return }
        sendFailure = nil
        relay.sendMessage(id: sessionId, text: command)
    }

    private static func friendlySendError(_ error: String) -> String {
        switch error {
        case "pane-not-ready": return "Not delivered — the vibTTY pane isn't awake yet. Try again."
        case "no pane hosting this session": return "Not delivered — no vibTTY pane hosts this session."
        case "remote control disabled": return "Not delivered — remote control is off in vibTTY."
        case "agent-not-running": return "Not delivered — no agent is running in that pane."
        case "agent-start-timeout": return "Not delivered — couldn't resume the agent in that pane."
        default: return "Not delivered · \(error)"
        }
    }

    /// Truth path: vibTTY reported this cwd's hook-driven agent state. `working`
    /// follows it exactly — a silent 30s tool no longer drops the indicator, and
    /// Stop/StopFailure clear it the moment the turn actually ends.
    private func applyAgentTruth(_ info: RelayClient.AgentStateInfo) {
        hasAgentTruth = true
        // The pane may host a DIFFERENT session in this cwd — that one's activity
        // must not light up this thread. Surface it as a passive jump hint instead
        // (unless a send-redirect already claimed the banner).
        if let sid = info.sessionId, sid != sessionId {
            working = false
            workStartedAt = nil
            if jumpHint?.reason != .redirected {
                jumpHint = JumpHint(sessionId: sid, reason: .newer)
            }
            return
        }
        // Pane is back on OUR session — a stale passive hint no longer applies.
        if jumpHint?.reason == .newer { jumpHint = nil }
        let busy = ["thinking", "tool", "compacting", "needsPermission"].contains(info.state)
        working = busy
        if busy {
            workStartedAt = info.since ?? workStartedAt ?? Date()
            scheduleWorkingIdle(after: 600)   // crash safety: a lost Stop hook can't pin it forever
        } else {
            workStartedAt = nil
            workTimeout?.cancel()
            optimisticUser = nil
        }
    }

    /// Fallback while no hook truth exists (older vibTTY): the remote transcript
    /// arrives in debounced chunks, so hold `working` and refresh this timer on
    /// every update; clear after a stretch of silence. 25s tolerates slow tools
    /// far better than the old 10s (which dropped the indicator mid-task).
    private func scheduleWorkingIdle(after seconds: TimeInterval = 25) {
        workTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.working = false
            self?.workStartedAt = nil
            self?.optimisticUser = nil
        }
        workTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func resolvePermission(_ req: PermissionRequest, allow: Bool) {
        relay?.resolvePermission(id: req.id, decision: allow ? "allow" : "deny")
        pendingPermissions.removeAll { $0.id == req.id }
    }

    // MARK: remote parse

    /// Keep only the most recent lines so a long live session doesn't grow the
    /// re-parse + SwiftUI diff unboundedly (that's what made x-relay lag + stutter
    /// on keyboard toggles — the whole timeline was rebuilt from thousands of
    /// accumulated lines every update).
    private let maxRawLines = 800
    private func capped(_ lines: [String]) -> [String] {
        lines.count > maxRawLines ? Array(lines.suffix(maxRawLines)) : lines
    }

    /// Coalesce bursts of live deltas — a live session streams many lines while
    /// Claude works, and rebuilding the whole timeline on each one churned the
    /// list (and collided with keyboard/scroll layout). Debounce to one rebuild.
    private func scheduleReparseRemote() {
        remoteReparseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reparseRemote() }
        remoteReparseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func reparseRemote() {
        // Codex transcripts keep the simple full-reparse path (different format,
        // far less traffic than a live Claude stream).
        if isCodex {
            let lines = rawLines
            let spid = Perf.begin("reparse")
            Task.detached(priority: .userInitiated) {
                let data = lines.joined(separator: "\n").data(using: .utf8) ?? Data()
                let timeline = CodexTranscript.timeline(from: data)
                await MainActor.run {
                    Perf.end("reparse", spid, "lines=\(lines.count) items=\(timeline.items.count)")
                    self.applyParsed(timeline)
                }
            }
            return
        }

        // Claude: decode ONLY the not-yet-decoded suffix, then assemble the whole
        // timeline from cached records — assembly is pure in-memory (no JSON) so a
        // delta tick costs O(Δ) decode instead of O(session).
        let priorCount = decodedLineCount
        let newLines = Array(rawLines.dropFirst(min(priorCount, rawLines.count)))
        let spid = Perf.begin("reparse")
        Task.detached(priority: .userInitiated) {
            let data = newLines.joined(separator: "\n").data(using: .utf8) ?? Data()
            let fresh = TranscriptParser.decodeLines(data)
            await MainActor.run {
                // A .full reset (or cap trim) raced in — this pass's baseline is
                // stale; the reset already queued its own full pass.
                guard self.decodedLineCount == priorCount else {
                    Perf.end("reparse", spid, "stale")
                    return
                }
                self.cachedRecords += fresh
                self.decodedLineCount = priorCount + newLines.count
                let snapshot = self.cachedRecords
                Task.detached(priority: .userInitiated) {
                    let t0 = CFAbsoluteTimeGetCurrent()
                    let out = TranscriptParser.build(snapshot)
                    let buildMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                    await MainActor.run {
                        Perf.end("reparse", spid, "Δ=\(newLines.count) recs=\(snapshot.count) items=\(out.timeline.items.count)")
                        #if DEBUG
                        NSLog("[perf] reparse Δ=%d recs=%d items=%d build=%.1fms",
                              newLines.count, snapshot.count, out.timeline.items.count, buildMs)
                        #endif
                        self.contextTokens = out.contextTokens
                        self.applyParsed(out.timeline)
                    }
                }
            }
        }
    }

    private func applyParsed(_ timeline: ChatTimeline) {
        items = timeline.items
        revision += 1
        isLoading = false
        // The real user message streamed in → drop the optimistic copy.
        if let opt = optimisticUser, lastUserText() == opt {
            optimisticUser = nil
        }
        // Still getting updates → the agent is active; keep the indicator up.
        if working { scheduleWorkingIdle(after: hasAgentTruth ? 600 : 25) }
    }

    private func lastUserText() -> String? {
        for item in items.reversed() {
            if case let .user(m) = item { return m.text }
        }
        return nil
    }

    // MARK: local live-tail

    private func startWatching() {
        guard live, watcher == nil, let url else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .attrib], queue: .global())
        src.setEventHandler { [weak self] in
            Task { @MainActor in self?.scheduleReparse() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    private func scheduleReparse() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reparseLocal() }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func reparseLocal() {
        Task {
            if let loader, let timeline = await loader.appended() {
                items = timeline.items
                revision += 1
            }
        }
    }
}
