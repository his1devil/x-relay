import Foundation

/// One line of a Claude Code transcript JSONL (`~/.claude/projects/<cwd>/<uuid>.jsonl`).
/// Decoded permissively — only the fields the renderer needs, everything else ignored.
struct RawRecord: Decodable {
    let type: String?
    let timestamp: String?
    let isMeta: Bool?
    let isSidechain: Bool?
    let cwd: String?
    let gitBranch: String?
    let version: String?
    let sessionId: String?
    let message: RawMessage?

    /// Rich tool-result metadata at the record's top level. Decoded into a
    /// TARGETED struct (only the fields we render) — decoding the whole thing as
    /// a `JSONValue` would build huge enum trees for `originalFile`/`content` and
    /// choke on big sessions.
    let toolUseResult: RawToolUseResult?

    // event-specific (non-message records)
    let subtype: String?
    let mode: String?
    let permissionMode: String?
    let lastPrompt: String?
    /// Top-level `content` on `system` records (away summaries, compact notices,
    /// local commands…). Lenient: non-string shapes on other record types decode
    /// to nil instead of sinking the whole record.
    let content: LenientString?
}

/// Decodes a string when present, silently nil for anything else — never throws,
/// so it can ride along on records whose `content` is an object/array.
struct LenientString: Decodable {
    let value: String?
    init(from decoder: Decoder) {
        value = try? decoder.singleValueContainer().decode(String.self)
    }
}

struct RawMessage: Decodable {
    let role: String?
    let content: RawContent?
    let model: String?
    let usage: RawUsage?
}

/// Token usage on assistant records — powers the context-progress ring.
struct RawUsage: Decodable {
    let inputTokens: Int?
    let cacheCreationInputTokens: Int?
    let cacheReadInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }

    /// Prompt-side tokens ≈ live context footprint (what statuslines show).
    var contextTokens: Int {
        (inputTokens ?? 0) + (cacheCreationInputTokens ?? 0) + (cacheReadInputTokens ?? 0)
    }
}

/// Only the tool-result fields we render. Decoding is lenient: `toolUseResult`
/// is sometimes a string/array (not an object) for some tools, so a failed
/// keyed-container read just leaves everything nil instead of dropping the record.
struct RawToolUseResult: Decodable {
    let stdout: String?
    let stderr: String?
    let structuredPatch: [RawHunk]?

    enum CodingKeys: String, CodingKey { case stdout, stderr, structuredPatch }

    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        stdout = (try? c?.decodeIfPresent(String.self, forKey: .stdout)) ?? nil
        stderr = (try? c?.decodeIfPresent(String.self, forKey: .stderr)) ?? nil
        structuredPatch = (try? c?.decodeIfPresent([RawHunk].self, forKey: .structuredPatch)) ?? nil
    }
}

struct RawHunk: Decodable {
    let oldStart: Int?
    let oldLines: Int?
    let newStart: Int?
    let newLines: Int?
    let lines: [String]?
}

/// `message.content` is polymorphic: a bare string (typed prompt) or an array
/// of typed blocks (text / thinking / tool_use / tool_result).
enum RawContent: Decodable {
    case text(String)
    case blocks([RawBlock])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = .text(s)
        } else if let b = try? c.decode([RawBlock].self) {
            self = .blocks(b)
        } else {
            self = .blocks([])
        }
    }
}

struct RawBlock: Decodable {
    let type: String
    let text: String?
    let thinking: String?
    let id: String?
    let name: String?
    let input: JSONValue?
    let toolUseId: String?
    let content: JSONValue?
    let isError: Bool?
    /// Image blocks embed their payload: `source.type == "base64"` + data.
    let source: RawImageSource?

    enum CodingKeys: String, CodingKey {
        case type, text, thinking, id, name, input, content, source
        case toolUseId = "tool_use_id"
        case isError = "is_error"
    }
}

struct RawImageSource: Decodable {
    let type: String?
    let mediaType: String?
    let data: String?

    enum CodingKeys: String, CodingKey {
        case type, data
        case mediaType = "media_type"
    }
}
