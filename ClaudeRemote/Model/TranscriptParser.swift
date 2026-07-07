import Foundation

enum TranscriptParser {
    struct Output {
        let timeline: ChatTimeline
        let cwd: String?
        let gitBranch: String?
        let lastActivity: Date?
        let lastAssistantText: String?
        /// Live context footprint (prompt-side tokens of the LAST assistant turn).
        var contextTokens: Int? = nil
    }

    /// Convenience: decode + build in one shot (used for the tail-snippet path).
    static func parse(jsonl data: Data) -> Output {
        build(decodeLines(data))
    }

    /// Decode complete JSONL lines into records. One bad line never sinks the
    /// rest. Fast bulk split — used both for full files and appended deltas.
    static func decodeLines(_ data: Data) -> [RawRecord] {
        let decoder = JSONDecoder()
        var records: [RawRecord] = []
        records.reserveCapacity(max(16, data.count / 512))
        for slice in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let r = try? decoder.decode(RawRecord.self, from: Data(slice)) {
                records.append(r)
            }
        }
        return records
    }

    /// First genuine user prompt (skips slash-commands, tool results, meta records,
    /// interrupts) — used to title a session in the drawer. Returns trimmed text.
    static func firstUserPrompt(_ records: [RawRecord]) -> String? {
        for r in records where r.type == "user" && r.isMeta != true {
            switch r.message?.content {
            case let .text(s):
                if isRealPrompt(s) { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
            case let .blocks(blocks):
                let texts = blocks.filter { $0.type == "text" }.compactMap { $0.text }
                if let first = texts.first(where: { isRealPrompt($0) }) {
                    return first.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            default:
                break
            }
        }
        return nil
    }

    /// First model id seen in the records (assistant turns carry `message.model`).
    static func firstModel(_ records: [RawRecord]) -> String? {
        for r in records {
            if let m = r.message?.model, !m.isEmpty { return m }
        }
        return nil
    }

    /// Build the renderable timeline from already-decoded records. Pure in-memory
    /// work (no I/O, no JSON decode) so incremental re-builds stay cheap.
    static func build(_ records: [RawRecord]) -> Output {
        // Pass A: tool_use id -> result (incl. rich `toolUseResult` metadata).
        // Sidechain (subagent) records never feed the main thread.
        var results: [String: ToolResult] = [:]
        for r in records where r.type == "user" && r.isSidechain != true {
            if case let .blocks(blocks)? = r.message?.content {
                let tur = r.toolUseResult
                let patch = tur?.structuredPatch?.compactMap { h -> DiffHunk? in
                    guard let lines = h.lines else { return nil }
                    return DiffHunk(oldStart: h.oldStart ?? 0, oldLines: h.oldLines ?? 0,
                                    newStart: h.newStart ?? 0, newLines: h.newLines ?? 0, lines: lines)
                }
                for b in blocks where b.type == "tool_result" {
                    guard let id = b.toolUseId else { continue }
                    var images = 0
                    if case let .array(items)? = b.content {
                        images = items.filter { $0["type"]?.stringValue == "image" }.count
                    }
                    results[id] = ToolResult(
                        text: b.content?.flattenedText ?? "",
                        isError: b.isError ?? false,
                        stdout: tur?.stdout,
                        stderr: tur?.stderr,
                        patch: (patch?.isEmpty ?? true) ? nil : patch,
                        imageCount: images
                    )
                }
            }
        }

        var timed: [(time: Date?, item: TimelineItem)] = []
        var openBlocks: [Block] = []
        var openTime: Date?
        var openModel: String?
        var openHasThinking = false
        var counter = 0
        var recBase = ""
        var recSeq = 0
        func nextID(_ p: String) -> String {
            if recBase.isEmpty { counter += 1; return "\(p)-\(counter)" }
            recSeq += 1
            return "\(p)-\(recBase)-\(recSeq)"
        }

        func flushGroup() {
            guard !openBlocks.isEmpty else { openTime = nil; openModel = nil; openHasThinking = false; return }
            // Anchor the group id to its FIRST block (stable while streaming). The old
            // `nextID("grp")` was assigned at flush time, so the trailing group's id
            // shifted on every appended block — the list saw delete+insert (the visible
            // message blinked out and slid back) instead of an in-place reload.
            let g = AssistantGroup(id: "grp-\(openBlocks[0].id)", time: openTime, blocks: openBlocks,
                                   model: openModel, hasThinking: openHasThinking)
            timed.append((openTime, .assistant(g)))
            openBlocks = []
            openTime = nil
            openModel = nil
            openHasThinking = false
        }

        var cwd: String?
        var gitBranch: String?
        var lastActivity: Date?
        var contextTokens: Int?

        for r in records {
            recBase = r.uuid.map { String($0.prefix(8)) } ?? ""
            recSeq = 0
            if r.isSidechain == true { continue }   // subagent turns live under their Task embed
            let t = parseDate(r.timestamp)
            if let t { lastActivity = t }
            if cwd == nil, let c = r.cwd { cwd = c }
            if gitBranch == nil, let g = r.gitBranch, !g.isEmpty { gitBranch = g }

            switch r.type {
            case "assistant":
                if let u = r.message?.usage, u.contextTokens > 0 { contextTokens = u.contextTokens }
                guard case let .blocks(blocks)? = r.message?.content else { continue }
                if openTime == nil { openTime = t }
                if openModel == nil, let m = r.message?.model, !m.isEmpty { openModel = m }
                for b in blocks {
                    switch b.type {
                    case "text":
                        let s = (b.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !s.isEmpty { openBlocks.append(.text(id: nextID("txt"), text: b.text ?? s)) }
                    case "thinking":
                        let s = (b.thinking ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !s.isEmpty { openBlocks.append(.thinking(id: nextID("thk"), text: s)); openHasThinking = true }
                    case "tool_use":
                        openBlocks.append(.tool(ToolCall(
                            id: b.id ?? nextID("tool"),
                            name: b.name ?? "Tool",
                            input: b.input ?? .null,
                            result: b.id.flatMap { results[$0] }
                        )))
                    default:
                        break
                    }
                }

            case "user":
                if r.isMeta == true { continue }
                switch r.message?.content {
                case let .text(s):
                    if let note = slashCommandNote(s, time: t, id: nextID("sys")) {
                        flushGroup(); timed.append((t, .system(note)))
                    } else if isContinuation(s) {
                        // The compaction mega-prompt — render a chip, not a wall of text.
                        flushGroup()
                        timed.append((t, .system(SystemNote(id: nextID("sys"), kind: .continued,
                                                            text: s.trimmingCharacters(in: .whitespacesAndNewlines), time: t))))
                    } else if isRealPrompt(s) {
                        flushGroup()
                        timed.append((t, .user(UserMessage(id: nextID("usr"), text: s.trimmingCharacters(in: .whitespacesAndNewlines), time: t))))
                    }
                case let .blocks(blocks):
                    let texts = blocks.filter { $0.type == "text" }.compactMap { $0.text }
                    // Transcript image blocks carry base64 payloads — decode to bytes
                    // here (cheap), pixels are decoded lazily in the view layer.
                    let images = blocks.filter { $0.type == "image" }
                        .compactMap { $0.source?.data.flatMap { Data(base64Encoded: $0) } }
                    if texts.contains(where: { $0.contains("[Request interrupted by user]") }) {
                        flushGroup()
                        timed.append((t, .system(SystemNote(id: nextID("sys"), kind: .interrupted, text: "You interrupted Claude", time: t))))
                    } else if let cont = texts.first(where: { isContinuation($0) }) {
                        flushGroup()
                        timed.append((t, .system(SystemNote(id: nextID("sys"), kind: .continued,
                                                            text: cont.trimmingCharacters(in: .whitespacesAndNewlines), time: t))))
                    } else if let first = texts.first(where: { isRealPrompt($0) }) {
                        flushGroup()
                        timed.append((t, .user(UserMessage(id: nextID("usr"), text: stripImagePills(first),
                                                           time: t, images: images))))
                    } else if !images.isEmpty {
                        // Image-only message (text was consumed into the pill).
                        flushGroup()
                        timed.append((t, .user(UserMessage(id: nextID("usr"), text: "", time: t, images: images))))
                    }
                case .none:
                    break
                }

            case "system":
                // Non-message system records (dropped entirely before this).
                let body = r.content?.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                switch r.subtype {
                case "compact_boundary":
                    flushGroup()
                    timed.append((t, .system(SystemNote(id: nextID("sys"), kind: .compact,
                                                        text: "Conversation compacted", time: t))))
                case "away_summary":
                    if !body.isEmpty {
                        flushGroup()
                        timed.append((t, .system(SystemNote(id: nextID("sys"), kind: .summary, text: body, time: t))))
                    }
                case "local_command":
                    if let note = slashCommandNote(body, time: t, id: nextID("sys")) {
                        flushGroup(); timed.append((t, .system(note)))
                    }
                case "bridge_status", "scheduled_task_fire", "model_refusal_fallback":
                    if !body.isEmpty {
                        flushGroup()
                        let capped = body.count > 200 ? String(body.prefix(200)) + "…" : body
                        timed.append((t, .system(SystemNote(id: nextID("sys"), kind: .note, text: capped, time: t))))
                    }
                default:
                    break   // turn_duration / stop_hook_summary etc — pure meta, not rendered
                }

            default:
                break
            }
        }
        flushGroup()

        var items: [TimelineItem] = []
        var lastDay: String?
        for entry in timed {
            if let time = entry.time {
                let day = dayKey(time)
                if day != lastDay {
                    items.append(.dateDivider(id: "div-\(day)", label: dayLabel(time)))
                    lastDay = day
                }
            }
            items.append(entry.item)
        }

        let lastText = timed.reversed().compactMap { entry -> String? in
            if case let .assistant(g) = entry.item {
                for block in g.blocks.reversed() {
                    if case let .text(_, text) = block { return text }
                }
            }
            return nil
        }.first

        return Output(timeline: ChatTimeline(items: items), cwd: cwd, gitBranch: gitBranch,
                      lastActivity: lastActivity, lastAssistantText: lastText,
                      contextTokens: contextTokens)
    }

    // MARK: - helpers

    private static func isRealPrompt(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if t.hasPrefix("<") { return false }
        if t == "[Request interrupted by user]" { return false }
        return true
    }

    /// The synthetic prompt injected after context compaction ("This session is
    /// being continued from a previous conversation…") — thousands of words of
    /// summary that would otherwise render as a giant user bubble.
    private static func isContinuation(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("This session is being continued from a previous conversation")
    }

    /// Drop Claude's composer pill placeholders ("[Image #1]") from user text —
    /// the image itself is carried as an image block and rendered as a chip.
    private static func stripImagePills(_ s: String) -> String {
        s.replacingOccurrences(of: #"\[Image #\d+\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func slashCommandNote(_ s: String, time: Date?, id: String) -> SystemNote? {
        guard let r = s.range(of: "<command-name>"), let end = s.range(of: "</command-name>") else { return nil }
        let name = String(s[r.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let cmd = name.hasPrefix("/") ? name : "/\(name)"
        return SystemNote(id: id, kind: .slashCommand, text: cmd, time: time)
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    private static let dayLabelFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM d, yyyy"; return f
    }()

    private static func dayKey(_ d: Date) -> String { dayKeyFormatter.string(from: d) }
    private static func dayLabel(_ d: Date) -> String { dayLabelFormatter.string(from: d) }
}
