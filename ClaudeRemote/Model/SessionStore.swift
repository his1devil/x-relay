import SwiftUI

/// Data source for the sessions list.
///
/// When the app runs in the iOS Simulator it reads this Mac's **real**
/// `~/.claude/projects/**/*.jsonl` (resolved via `SIMULATOR_HOST_HOME`) and
/// live-watches the directory, so the list reflects actual local sessions and
/// updates as Claude Code writes. On a real device (no host access) it falls
/// back to the transcripts bundled under `Resources/Fixtures`. Swapping in a
/// relay source later only touches `sourceURLs()` / the watcher.
@MainActor
final class SessionStore: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var isLoading = false
    @Published private(set) var isLive = false
    private var mockMode = false   // DEBUG preview: don't let load/refresh clobber mock data

    private var watcher: DispatchSourceFileSystemObject?
    private var reloadWork: DispatchWorkItem?

    func load() {
        guard !isLoading, !mockMode else { return }
        isLoading = true
        let live = Self.liveProjectsDir() != nil
        isLive = live
        Task.detached(priority: .userInitiated) {
            let urls = Self.sourceURLs()
            var acc: [Session] = []
            for url in urls {
                guard let s = Self.buildSession(url: url, live: live) else { continue }
                acc.append(s)
                acc.sort { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
                let snapshot = acc
                await MainActor.run { self.sessions = snapshot }
            }
            let codex = Self.codexSessions(live: Self.codexLiveDir() != nil)
            if !codex.isEmpty {
                acc.append(contentsOf: codex)
                acc.sort { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
                let snapshot = acc
                await MainActor.run { self.sessions = snapshot }
            }
            await MainActor.run {
                self.isLoading = false
                self.startWatching()
            }
        }
    }

#if DEBUG
    /// Screenshot/dev only (`SIMCTL_CHILD_CR_MOCK=1`): sample sessions across a
    /// few projects + statuses so the drawer's project grouping is visible without
    /// a real pairing. Never compiled into release.
    func loadMock() {
        mockMode = true
        let now = Date()
        func s(_ id: String, _ name: String, _ path: String, _ host: String, _ ago: TimeInterval,
               _ snippet: String, _ status: SessionStatus, _ agent: AgentKind = .claude,
               _ model: String = "claude-sonnet-4-5-20250101", _ branch: String? = "main") -> Session {
            Session(id: id, name: name, path: path, host: host, gitBranch: branch,
                    lastActivity: now.addingTimeInterval(-ago), snippet: snippet, status: status,
                    agent: agent, model: model)
        }
        var rows: [Session] = []
        if ProcessInfo.processInfo.environment["CR_FILE"] != nil {
            rows.append(s("cc-file", "real-replay", "~/dev/replay", "studio.local", 10, "Claude · real transcript replay (CR_FILE)", .idle))
        }
        sessions = rows + [
            s("cc-stress", "perf-stress", "~/dev/stress", "studio.local", 30, "Claude · 300 heavy items (perf benchmark)", .idle),
            s("cc-auth", "auth-refactor", "~/dev/api", "studio.local", 120, "Claude · auth tests are green", .needs, .claude, "claude-sonnet-4-5-20250101", "feat/login"),
            s("cc-pay", "payments-api", "~/dev/api", "studio.local", 5400, "Claude · stripe webhook wired up", .idle),
            s("cc-dash", "dashboard", "~/dev/web", "studio.local", 60, "Claude · rebuilding the charts module", .running, .claude, "claude-opus-4-1-20250101"),
            s("cc-mkt", "marketing-site", "~/dev/web", "studio.local", 90000, "Claude · shipped the hero section", .done),
            s("til-etl", "data-pipeline", "~/dev/etl", "gpu-box", 200, "TIL · batch job retried clean", .running, .til, "claude-sonnet-4-5-20250101", "main"),
            s("til-train", "train-eval", "~/dev/ml", "gpu-box", 900, "TIL · eval run queued", .needs, .til, "claude-opus-4-1-20250101", nil),
        ]
        isLoading = false
    }
#endif

    /// Re-scan (pull-to-refresh / scene re-activation / live FS event). Builds
    /// the new list in the background and swaps it in atomically — no clear, so
    /// the list never flashes empty.
    func refresh() {
        guard !mockMode else { return }
        let live = Self.liveProjectsDir() != nil
        Task.detached(priority: .userInitiated) {
            let urls = Self.sourceURLs()
            var acc = urls.compactMap { Self.buildSession(url: $0, live: live) }
            acc.append(contentsOf: Self.codexSessions(live: Self.codexLiveDir() != nil))
            acc.sort { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
            let snapshot = acc
            await MainActor.run {
                self.isLive = live
                self.sessions = snapshot
            }
        }
    }

    // MARK: live directory watching

    private func startWatching() {
        guard watcher == nil, let dir = Self.liveProjectsDir() else { return }
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .rename], queue: .global())
        src.setEventHandler { [weak self] in
            Task { @MainActor in self?.scheduleReload() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: sources

    nonisolated static func liveProjectsDir() -> URL? {
        guard let host = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] else { return nil }
        let dir = URL(fileURLWithPath: host).appendingPathComponent(".claude/projects")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return dir
    }

    // MARK: Codex sessions (Path A: a second source dir, agent identified by location)

    nonisolated static func codexLiveDir() -> URL? {
        guard let host = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] else { return nil }
        let dir = URL(fileURLWithPath: host).appendingPathComponent(".codex/sessions")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return dir
    }

    /// `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, newest first, capped.
    nonisolated private static func codexURLs(cap: Int = 40) -> [URL] {
        guard let dir = codexLiveDir(),
              let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var files: [(URL, Date)] = []
        for case let f as URL in en where f.pathExtension == "jsonl" && f.lastPathComponent.hasPrefix("rollout-") {
            let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            files.append((f, m))
        }
        return files.sorted { $0.1 > $1.1 }.prefix(cap).map { $0.0 }
    }

    nonisolated static func codexSessions(live: Bool) -> [Session] {
        codexURLs().compactMap { buildCodexSession(url: $0, live: live) }
    }

    nonisolated static func buildCodexSession(url: URL, live: Bool) -> Session? {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        // Codex tool-output lines are huge, so a small head can miss the first turn's
        // `turn_context` (model) + the user prompt; read a larger window.
        let head = headBytes(url, 524288)
        guard let cwd = CodexTranscript.cwd(from: head) else { return nil }   // not a rollout → skip
        let id = CodexTranscript.sessionId(from: head) ?? url.deletingPathExtension().lastPathComponent
        let name = sessionTitle(from: CodexTranscript.firstPrompt(from: head))
            ?? relativeTitle(mtime) ?? "codex session"
        return Session(
            id: id, name: name, path: tildePath(cwd) ?? cwd, host: "local",
            gitBranch: nil, lastActivity: mtime, snippet: "Codex session",
            status: status(for: mtime), fileURL: url, isLive: live,
            agent: .codex, model: CodexTranscript.model(from: head)
        )
    }

    /// First ~64 KB of a file, trimmed to the last complete line.
    nonisolated private static func headBytes(_ url: URL, _ bytes: Int = 65536) -> Data {
        guard let h = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: bytes)) ?? Data()
        if let lastNL = data.lastIndex(of: 0x0A) {
            return data.subdata(in: data.startIndex ..< data.index(after: lastNL))
        }
        return data
    }

    nonisolated private static func sourceURLs() -> [URL] {
        if let dir = liveProjectsDir() {
            return liveTranscriptURLs(in: dir)
        }
        return bundledJSONLURLs()
    }

    /// Every `*.jsonl` under each project subdirectory, newest first, capped.
    nonisolated private static func liveTranscriptURLs(in dir: URL, cap: Int = 60) -> [URL] {
        let fm = FileManager.default
        let projects = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var files: [(URL, Date)] = []
        for project in projects {
            let jsonls = (try? fm.contentsOfDirectory(
                at: project,
                includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for f in jsonls where f.pathExtension == "jsonl" {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                files.append((f, m))
            }
        }
        return files.sorted { $0.1 > $1.1 }.prefix(cap).map { $0.0 }
    }

    nonisolated private static func bundledJSONLURLs() -> [URL] {
        // DEBUG-only: demo transcripts are a development convenience. A release
        // build must NEVER ship (or surface) bundled conversations — a fresh
        // install showed the developer's own sessions to brand-new users.
        #if DEBUG
        if let u = Bundle.main.urls(forResourcesWithExtension: "jsonl", subdirectory: nil), !u.isEmpty { return u }
        if let u = Bundle.main.urls(forResourcesWithExtension: "jsonl", subdirectory: "Fixtures"), !u.isEmpty { return u }
        if let resURL = Bundle.main.resourceURL,
           let en = FileManager.default.enumerator(at: resURL, includingPropertiesForKeys: nil) {
            return en.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
        }
        #endif
        return []
    }

    // MARK: build

    /// Build the list row from CHEAP metadata only — file mtime for the time,
    /// the head for the project path, the tail for the snippet. The full
    /// timeline is never parsed here (that happens lazily when a thread opens),
    /// so the list stays instant and low-memory even with many large transcripts.
    nonisolated static func buildSession(url: URL, live: Bool) -> Session? {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let records = headRecords(url)
        let (cwd, gitBranch) = meta(from: records)
        let id = url.deletingPathExtension().lastPathComponent
        // Title the session by its first real prompt (distinct per session within a
        // project); fall back to a timestamp, then the dir name. The project grouping
        // still keys on `path` (cwd), so the project header carries the dir name.
        let name = sessionTitle(from: TranscriptParser.firstUserPrompt(records))
            ?? relativeTitle(mtime) ?? projectName(from: cwd) ?? id
        return Session(
            id: id,
            name: name,
            path: tildePath(cwd) ?? "",
            host: "local",
            gitBranch: gitBranch,
            lastActivity: mtime,
            snippet: snippetText(tailSnippet(url)),
            status: status(for: mtime),
            fileURL: url,
            isLive: live,
            model: TranscriptParser.firstModel(records)
        )
    }

    /// Decoded records from the file head (~64 KB) — enough to carry the initial
    /// cwd/gitBranch records AND the first user prompt that titles the session.
    nonisolated private static func headRecords(_ url: URL, bytes: Int = 65536) -> [RawRecord] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: bytes)) ?? Data()
        let complete: Data
        if let lastNL = data.lastIndex(of: 0x0A) {
            complete = data.subdata(in: data.startIndex ..< data.index(after: lastNL))
        } else {
            complete = data
        }
        return TranscriptParser.decodeLines(complete)
    }

    /// First record carrying cwd + gitBranch.
    nonisolated private static func meta(from records: [RawRecord]) -> (String?, String?) {
        for r in records {
            if let cwd = r.cwd, !cwd.isEmpty {
                return (cwd, r.gitBranch?.isEmpty == false ? r.gitBranch : nil)
            }
        }
        return (nil, nil)
    }

    /// Condense a prompt into a one-line channel title (first line, collapsed
    /// whitespace, capped).
    nonisolated static func sessionTitle(from prompt: String?) -> String? {
        guard let prompt else { return nil }
        let firstLine = prompt.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? prompt
        let collapsed = firstLine
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        let cap = 42
        return collapsed.count > cap
            ? String(collapsed.prefix(cap)).trimmingCharacters(in: .whitespaces) + "…"
            : collapsed
    }

    nonisolated private static func relativeTitle(_ date: Date?) -> String? {
        guard let date else { return nil }
        let f = DateFormatter()
        f.dateFormat = "MMM d · HH:mm"
        return f.string(from: date)
    }

    /// Last assistant text from the file tail (~64 KB) — for the row snippet.
    nonisolated private static func tailSnippet(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let window: UInt64 = 65536
        let start = size > window ? size - window : 0
        try? h.seek(toOffset: start)
        let data = (try? h.readToEnd()) ?? Data()
        var slice = data
        if start > 0, let firstNL = data.firstIndex(of: 0x0A) {
            slice = data.subdata(in: data.index(after: firstNL) ..< data.endIndex)
        }
        for r in TranscriptParser.decodeLines(slice).reversed() where r.type == "assistant" {
            if case let .blocks(blocks)? = r.message?.content {
                for b in blocks.reversed() where b.type == "text" {
                    if let t = b.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                        return t
                    }
                }
            }
        }
        return nil
    }

    // MARK: derivations

    nonisolated private static func projectName(from cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return (cwd as NSString).lastPathComponent
    }

    nonisolated private static func tildePath(_ cwd: String?) -> String? {
        guard let cwd else { return nil }
        let comps = cwd.split(separator: "/").map(String.init)
        if comps.count >= 2, comps[0] == "Users" {
            return "~/" + comps.dropFirst(2).joined(separator: "/")
        }
        return cwd
    }

    nonisolated private static func snippetText(_ text: String?) -> String {
        guard let text else { return "Idle · no recent activity" }
        let oneLine = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = oneLine.count > 64 ? String(oneLine.prefix(64)) + "…" : oneLine
        return "Claude · \(capped)"
    }

    nonisolated private static func status(for last: Date?) -> SessionStatus {
        guard let last else { return .idle }
        let age = Date().timeIntervalSince(last)
        if age < 600 { return .running }
        if age < 6 * 3600 { return .idle }
        return .done
    }
}
