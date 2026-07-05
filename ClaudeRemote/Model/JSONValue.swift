import Foundation

/// A permissive JSON value, used for tool inputs (`tool_use.input`) and tool
/// result payloads (`tool_result.content`), whose shapes vary per tool.
indirect enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            self = .null
        }
    }

    subscript(_ key: String) -> JSONValue? {
        if case let .object(o) = self { return o[key] }
        return nil
    }

    var stringValue: String? {
        switch self {
        case let .string(s): return s
        case let .number(n): return n == n.rounded() ? String(Int(n)) : String(n)
        case let .bool(b): return String(b)
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case let .array(a) = self { return a }
        return nil
    }

    var intValue: Int? {
        switch self {
        case let .number(n): return Int(n)
        case let .string(s): return Int(s)
        default: return nil
        }
    }

    /// Flatten arbitrary content into a human-readable string. Tool results are
    /// usually plain strings, but can be an array of `{type:text, text:…}` blocks.
    /// Hashable (synthesized) so timeline items can carry a content fingerprint —
    /// the chat list reloads a row only when its fingerprint actually changed.
    var flattenedText: String {
        switch self {
        case let .string(s): return s
        case let .number(n): return n == n.rounded() ? String(Int(n)) : String(n)
        case let .bool(b): return String(b)
        case .null: return ""
        case let .array(items):
            return items.map { item in
                if let t = item["text"]?.stringValue { return t }
                return item.flattenedText
            }.joined(separator: "\n")
        case let .object(o):
            if let t = o["text"]?.stringValue { return t }
            return o.values.map { $0.flattenedText }.joined(separator: "\n")
        }
    }
}

extension JSONValue: Hashable {}
