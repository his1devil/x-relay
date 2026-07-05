import Foundation

/// The renderable conversation: a flat list of timeline items in display order.
struct ChatTimeline {
    var items: [TimelineItem]
}

enum TimelineItem: Identifiable {
    case dateDivider(id: String, label: String)
    case system(SystemNote)
    case user(UserMessage)
    case assistant(AssistantGroup)

    var id: String {
        switch self {
        case let .dateDivider(id, _): return id
        case let .system(n): return n.id
        case let .user(m): return m.id
        case let .assistant(g): return g.id
        }
    }
}

struct SystemNote: Identifiable {
    /// `compact` = context-compaction boundary; `summary` = away-summary content;
    /// `continued` = the "session continued from a previous conversation"
    /// mega-prompt (collapsed to a chip, full text in a sheet).
    enum Kind { case slashCommand, interrupted, note, compact, summary, continued }
    let id: String
    let kind: Kind
    let text: String
    let time: Date?
}

struct UserMessage: Identifiable {
    let id: String
    let text: String
    let time: Date?
    /// Image blocks sent with the message (phone attachments become real image
    /// content once Claude's composer converts the path pill). Transcripts embed
    /// the bytes (base64), so thumbnails render straight from here — decoding to
    /// UIImage happens lazily in the view through a downscale cache.
    var images: [Data] = []
    var imageCount: Int { images.count }
}

/// A contiguous run of Claude output (one "Claude · APP" message group in the
/// Discord design), spanning however many assistant records until the next
/// real user turn.
struct AssistantGroup: Identifiable {
    let id: String
    let time: Date?
    var blocks: [Block]
    var model: String? = nil
    var hasThinking: Bool = false
}

enum Block: Identifiable {
    case text(id: String, text: String)
    case thinking(id: String, text: String)
    case tool(ToolCall)

    var id: String {
        switch self {
        case let .text(id, _): return id
        case let .thinking(id, _): return id
        case let .tool(call): return call.id
        }
    }
}

/// One hunk of a `structuredPatch` (real line numbers + unified-diff lines).
struct DiffHunk {
    let oldStart: Int
    let oldLines: Int
    let newStart: Int
    let newLines: Int
    let lines: [String]   // each prefixed with "+", "-" or " "
}

struct ToolResult {
    let text: String
    let isError: Bool
    var stdout: String?
    var stderr: String?
    var patch: [DiffHunk]?
    /// Image blocks in the result (e.g. Read on a screenshot) — text flattening
    /// drops them, so surface a count for an 🖼 chip in the embed.
    var imageCount: Int = 0
}

/// A diff line with real old/new line numbers (nil on the side it doesn't exist).
struct DiffRowData: Identifiable {
    let id = UUID()
    let oldNo: Int?
    let newNo: Int?
    let sign: String
    let code: String
}

enum ToolKind {
    case bash, edit, write, read, search, todo, task, question, generic
    case agent      // Agent/Task — subagent launches
    case file       // SendUserFile — files handed to the user
    case skill      // Skill invocations
    case schedule   // ScheduleWakeup
    case mcp        // mcp__server__tool calls
}

// MARK: - Content fingerprints
//
// Hashable (synthesized) so every timeline item has a cheap content fingerprint.
// The chat list derives per-row redraw stamps from it: a row reloads only when its
// content actually changed, and a whole update is skipped when nothing did.
extension SystemNote: Hashable {}
extension UserMessage: Hashable {}
extension DiffHunk: Hashable {}
extension ToolResult: Hashable {}
extension ToolCall: Hashable {}
extension Block: Hashable {}
extension AssistantGroup: Hashable {}
extension TimelineItem: Hashable {}

/// One `tool_use` block with its matched `tool_result` (if any), plus the
/// display derivations each embed style needs.
struct ToolCall: Identifiable {
    let id: String
    let name: String
    let input: JSONValue
    let result: ToolResult?

    var kind: ToolKind {
        switch name {
        case "Bash": return .bash
        case "Edit", "MultiEdit": return .edit
        case "Write", "NotebookEdit": return .write
        case "Read": return .read
        case "Grep", "Glob", "ToolSearch", "WebSearch", "WebFetch": return .search
        case "TodoWrite": return .todo
        case "TaskCreate", "TaskUpdate": return .task
        case "AskUserQuestion": return .question
        case "Agent", "Task": return .agent
        case "SendUserFile": return .file
        case "Skill": return .skill
        case "ScheduleWakeup": return .schedule
        default: return name.hasPrefix("mcp__") ? .mcp : .generic
        }
    }

    // MARK: subagents (Agent tool)

    var agentType: String? { input["subagent_type"]?.stringValue }
    var agentDescription: String? { input["description"]?.stringValue }
    var agentPrompt: String? { input["prompt"]?.stringValue }

    // MARK: SendUserFile

    var sentFiles: [String] {
        input["files"]?.arrayValue?.compactMap { $0.stringValue } ?? []
    }
    var sentCaption: String? { input["caption"]?.stringValue }

    // MARK: Skill

    var skillName: String? { input["skill"]?.stringValue }
    var skillArgs: String? { input["args"]?.stringValue }

    // MARK: ScheduleWakeup

    var scheduleReason: String? { input["reason"]?.stringValue }
    var scheduleDelay: Int? { input["delaySeconds"]?.intValue }

    // MARK: MCP (mcp__server__tool)

    var mcpParts: (server: String, tool: String)? {
        guard name.hasPrefix("mcp__") else { return nil }
        let parts = name.dropFirst(5).components(separatedBy: "__")
        guard let server = parts.first, !server.isEmpty else { return nil }
        let tool = parts.dropFirst().joined(separator: "__")
        return (server, tool.isEmpty ? "call" : tool)
    }

    // MARK: file-based tools

    var filePath: String? { input["file_path"]?.stringValue }

    var fileName: String? {
        guard let p = filePath else { return nil }
        return (p as NSString).lastPathComponent
    }

    var fileDir: String? {
        guard let p = filePath else { return nil }
        let dir = (p as NSString).deletingLastPathComponent
        return dir.isEmpty ? nil : (dir as NSString).lastPathComponent + "/"
    }

    // MARK: bash

    var bashCommand: String? { input["command"]?.stringValue }
    var bashDescription: String? { input["description"]?.stringValue }

    // MARK: edit diff

    /// (old, new) string pairs — one for an Edit, several for a MultiEdit.
    private func editPairs() -> [(String, String)] {
        if let edits = input["edits"]?.arrayValue {
            return edits.map { ($0["old_string"]?.stringValue ?? "", $0["new_string"]?.stringValue ?? "") }
        }
        return [(input["old_string"]?.stringValue ?? "", input["new_string"]?.stringValue ?? "")]
    }

    /// Diff rows with real line numbers. Prefers the result's `structuredPatch`
    /// (true hunks + line numbers + context); falls back to deriving from the
    /// old/new strings (no numbers) when the patch isn't available.
    func diffRows(maxRows: Int = .max) -> [DiffRowData] {
        var rows: [DiffRowData] = []
        if let hunks = result?.patch, !hunks.isEmpty {
            for h in hunks {
                var o = h.oldStart
                var n = h.newStart
                for line in h.lines {
                    let sign = line.first.map(String.init) ?? " "
                    let code = String(line.dropFirst())
                    switch sign {
                    case "+": rows.append(.init(oldNo: nil, newNo: n, sign: "+", code: code)); n += 1
                    case "-": rows.append(.init(oldNo: o, newNo: nil, sign: "-", code: code)); o += 1
                    default: rows.append(.init(oldNo: o, newNo: n, sign: " ", code: code)); o += 1; n += 1
                    }
                    if rows.count >= maxRows { return rows }
                }
            }
            return rows
        }
        for (old, new) in editPairs() {
            for l in old.split(separator: "\n", omittingEmptySubsequences: false) where !old.isEmpty {
                rows.append(.init(oldNo: nil, newNo: nil, sign: "-", code: String(l)))
                if rows.count >= maxRows { return rows }
            }
            for l in new.split(separator: "\n", omittingEmptySubsequences: false) where !new.isEmpty {
                rows.append(.init(oldNo: nil, newNo: nil, sign: "+", code: String(l)))
                if rows.count >= maxRows { return rows }
            }
        }
        return rows
    }

    private func lineCount(_ s: String) -> Int {
        s.isEmpty ? 0 : s.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    var addCount: Int {
        if let hunks = result?.patch {
            return hunks.flatMap(\.lines).filter { $0.hasPrefix("+") }.count
        }
        return editPairs().reduce(0) { $0 + lineCount($1.1) }
    }

    var delCount: Int {
        if let hunks = result?.patch {
            return hunks.flatMap(\.lines).filter { $0.hasPrefix("-") }.count
        }
        return editPairs().reduce(0) { $0 + lineCount($1.0) }
    }

    // MARK: todos

    struct TodoItem: Identifiable {
        let id = UUID()
        let status: String   // pending | in_progress | completed
        let text: String
    }

    func todos() -> [TodoItem] {
        guard let arr = input["todos"]?.arrayValue else { return [] }
        return arr.map {
            TodoItem(
                status: $0["status"]?.stringValue ?? "pending",
                text: $0["content"]?.stringValue ?? $0["activeForm"]?.stringValue ?? ""
            )
        }
    }

    // MARK: questions (AskUserQuestion)

    struct Question: Identifiable {
        let id = UUID()
        let header: String
        let prompt: String
        let options: [String]
    }

    func questions() -> [Question] {
        guard let arr = input["questions"]?.arrayValue else { return [] }
        return arr.map { q in
            let opts = (q["options"]?.arrayValue ?? []).compactMap { $0["label"]?.stringValue }
            return Question(
                header: q["header"]?.stringValue ?? "",
                prompt: q["question"]?.stringValue ?? "",
                options: opts
            )
        }
    }

    // MARK: search / generic

    var searchQuery: String? {
        input["pattern"]?.stringValue
            ?? input["query"]?.stringValue
            ?? input["url"]?.stringValue
    }

    /// A one-line summary of the input for the generic embed.
    var genericSummary: String {
        if case let .object(o) = input {
            let parts = o.prefix(3).map { key, value -> String in
                "\(key): \(value.stringValue ?? value.flattenedText.prefix(40).description)"
            }
            return parts.joined(separator: "  ·  ")
        }
        return input.flattenedText
    }

    /// Header label shown on the embed.
    var title: String {
        switch kind {
        case .bash: return "Terminal"
        case .edit: return "Edited \(fileName ?? "file")"
        case .write: return "Created \(fileName ?? "file")"
        case .read: return "Read \(fileName ?? "file")"
        case .search: return name
        case .todo, .task: return "To-dos"
        case .question: return "Asked a question"
        case .agent: return "Subagent"
        case .file: return "Sent files"
        case .skill: return "Skill"
        case .schedule: return "Scheduled a check-in"
        case .mcp: return mcpParts?.tool ?? name
        case .generic: return name
        }
    }
}
