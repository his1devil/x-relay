import Foundation

/// Parser for OpenAI **Codex CLI** "rollout" transcripts
/// (`~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`). It maps the Codex
/// schema onto the SAME `ChatTimeline` the Claude `TranscriptParser` produces, so
/// every existing timeline view renders Codex sessions unchanged — the only thing
/// the app branches on is which parser to call (by `Session.agent == .codex`).
///
/// Each line is `{timestamp, type, payload}`. `type` ∈ `session_meta`,
/// `turn_context`, `event_msg`, `response_item`, `compacted`. We render from
/// **`response_item`** (the canonical conversation log); `event_msg`
/// (token_count / task_* / agent_* — duplicates) and `turn_context` are skipped.
enum CodexTranscript {

    // MARK: line decode
    //
    // Payloads are heterogeneous (message / reasoning / function_call / …), so
    // JSONSerialization to `[String: Any]` is simpler + more forgiving than Codable.

    private static func records(_ data: Data) -> [[String: Any]] {
        var out: [[String: Any]] = []
        out.reserveCapacity(max(16, data.count / 512))
        for slice in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if var obj = try? JSONSerialization.jsonObject(with: Data(slice)) as? [String: Any] {
                // Stable per-record anchor: the raw line's hash never changes
                // when history is PREPENDED above it (a positional counter
                // renumbered every row on prepend → full delete/insert churn
                // + stale HeightOracle hits under reused ids).
                obj["__lineKey"] = lineKey(slice)
                out.append(obj)
            }
        }
        return out
    }

    private static func lineKey(_ slice: Data.SubSequence) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in slice { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 36)
    }

    // MARK: session metadata (for the list row) — all in `session_meta` (line 0)

    static func sessionId(from data: Data) -> String? {
        guard let m = meta(data) else { return nil }
        return (m["session_id"] as? String) ?? (m["id"] as? String)
    }

    static func cwd(from data: Data) -> String? { meta(data)?["cwd"] as? String }

    static func model(from data: Data) -> String? {
        // The real model id lives in `turn_context.payload.model` (e.g. "gpt-5.4");
        // session_meta only carries `model_provider` ("openai"), which we don't show.
        for r in records(data) where (r["type"] as? String) == "turn_context" {
            if let p = r["payload"] as? [String: Any], let m = p["model"] as? String, !m.isEmpty {
                return m
            }
        }
        return meta(data)?["model"] as? String
    }

    private static func meta(_ data: Data) -> [String: Any]? {
        for r in records(data) where (r["type"] as? String) == "session_meta" {
            return r["payload"] as? [String: Any]
        }
        return nil
    }

    /// First genuine user prompt (skips the AGENTS.md / `<…>` system preamble) — for
    /// the channel title. Prefers the clean `event_msg/user_message`.
    static func firstPrompt(from data: Data) -> String? {
        let recs = records(data)
        for r in recs {
            if (r["type"] as? String) == "event_msg",
               let p = r["payload"] as? [String: Any], (p["type"] as? String) == "user_message",
               let m = p["message"] as? String, isRealPrompt(m) { return m.trimmed }
        }
        for r in recs where (r["type"] as? String) == "response_item" {
            guard let p = r["payload"] as? [String: Any],
                  (p["type"] as? String) == "message", (p["role"] as? String) == "user",
                  let txt = contentText(p["content"]), isRealPrompt(txt) else { continue }
            return txt.trimmed
        }
        return nil
    }

    // MARK: timeline

    static func timeline(from data: Data) -> ChatTimeline {
        let recs = records(data)

        // Pass A: tool outputs keyed by call_id.
        var outputs: [String: String] = [:]
        for r in recs where (r["type"] as? String) == "response_item" {
            guard let p = r["payload"] as? [String: Any] else { continue }
            let pt = p["type"] as? String
            if pt == "function_call_output" || pt == "custom_tool_call_output",
               let cid = p["call_id"] as? String {
                outputs[cid] = outputText(p["output"])
            }
        }

        // Pass B: build items. Assistant text / reasoning / tool calls between two
        // user turns collapse into one AssistantGroup (matches the Claude grouping).
        var items: [TimelineItem] = []
        var group: AssistantGroup?
        var counter = 0
        var recKey = ""
        var recSeq = 0
        func nid(_ p: String) -> String {
            if recKey.isEmpty { counter += 1; return "cx-\(p)-\(counter)" }
            recSeq += 1
            return "cx-\(p)-\(recKey)-\(recSeq)"
        }
        func flush() {
            if let g = group, !g.blocks.isEmpty { items.append(.assistant(g)) }
            group = nil
        }
        func openGroup(_ time: Date?) {
            if group == nil { group = AssistantGroup(id: nid("grp"), time: time, blocks: []) }
        }

        for r in recs where (r["type"] as? String) == "response_item" {
            guard let p = r["payload"] as? [String: Any] else { continue }
            recKey = r["__lineKey"] as? String ?? ""
            recSeq = 0
            let time = date(r["timestamp"] as? String)
            switch p["type"] as? String {
            case "message":
                let role = p["role"] as? String
                let txt = contentText(p["content"]) ?? ""
                if role == "user" {
                    if isRealPrompt(txt) {
                        flush()
                        items.append(.user(UserMessage(id: nid("usr"), text: txt.trimmed, time: time)))
                    }
                } else if role == "assistant" {
                    if !txt.trimmed.isEmpty {
                        openGroup(time)
                        group?.blocks.append(.text(id: nid("txt"), text: txt))
                    }
                }
                // developer / system → skip

            case "reasoning":
                if let s = reasoningText(p), !s.isEmpty {
                    openGroup(time)
                    group?.blocks.append(.thinking(id: nid("thk"), text: s))
                    group?.hasThinking = true
                }

            case "function_call", "custom_tool_call", "web_search_call", "local_shell_call":
                openGroup(time)
                group?.blocks.append(.tool(toolCall(p, outputs: outputs, fallbackID: nid("tool"))))

            default:
                break
            }
        }
        flush()
        return ChatTimeline(items: items)
    }

    // MARK: tool mapping
    //
    // Normalize the common Codex tools onto Claude-shaped `ToolCall`s so they reuse
    // the nice embeds (Bash / WebSearch); everything else renders as a generic embed.

    private static func toolCall(_ p: [String: Any], outputs: [String: String], fallbackID: String) -> ToolCall {
        let cid = p["call_id"] as? String ?? fallbackID
        let pt = p["type"] as? String
        let result = outputs[cid].map { out in
            ToolResult(text: out, isError: false, stdout: out, stderr: nil, patch: nil)
        }

        if pt == "web_search_call" {
            let q = ((p["action"] as? [String: Any])?["query"] as? String) ?? ""
            return ToolCall(id: cid, name: "WebSearch", input: .object(["query": .string(q)]), result: result)
        }

        let name = (p["name"] as? String) ?? (pt ?? "tool")
        let args = decodeArguments(p)

        if name == "exec_command" || name == "shell" || pt == "local_shell_call" {
            let cmd = args?["cmd"]?.stringValue
                ?? args?["command"]?.stringValue
                ?? shellJoin((p["action"] as? [String: Any])?["command"])
                ?? ""
            return ToolCall(id: cid, name: "Bash", input: .object(["command": .string(cmd)]), result: result)
        }

        // apply_patch / other custom tools carry a raw string `input`.
        if let inputStr = p["input"] as? String {
            return ToolCall(id: cid, name: name, input: .string(inputStr), result: result)
        }
        return ToolCall(id: cid, name: name, input: args ?? .object([:]), result: result)
    }

    private static func decodeArguments(_ p: [String: Any]) -> JSONValue? {
        guard let s = p["arguments"] as? String, let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: d)
    }

    private static func shellJoin(_ any: Any?) -> String? {
        if let arr = any as? [String] { return arr.joined(separator: " ") }
        return any as? String
    }

    // MARK: content / output extraction

    /// `content` is `[{type: input_text|output_text|text, text}]` (or rarely a string).
    private static func contentText(_ content: Any?) -> String? {
        if let arr = content as? [[String: Any]] {
            let parts = arr.compactMap { b -> String? in
                switch b["type"] as? String {
                case "input_text", "output_text", "text": return b["text"] as? String
                default: return nil
                }
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        return content as? String
    }

    private static func reasoningText(_ p: [String: Any]) -> String? {
        if let summary = p["summary"] as? [[String: Any]] {
            let parts = summary.compactMap { $0["text"] as? String }
            if !parts.isEmpty { return parts.joined(separator: "\n") }
        }
        return contentText(p["content"])
    }

    /// `function_call_output.output` is a string; `custom_tool_call_output.output`
    /// wraps `{output, metadata}` as a JSON string — unwrap to the inner text.
    private static func outputText(_ output: Any?) -> String {
        if let s = output as? String {
            if let d = s.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let inner = o["output"] as? String { return inner }
            return s
        }
        if let o = output as? [String: Any], let inner = o["output"] as? String { return inner }
        return ""
    }

    // MARK: misc

    private static func isRealPrompt(_ s: String) -> Bool {
        let t = s.trimmed
        if t.isEmpty { return false }
        if t.hasPrefix("<") { return false }
        if t.hasPrefix("# AGENTS.md instructions") { return false }
        return true
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
