import Foundation

/// A minimal, dependency-free JSON value. Used for JSON-RPC envelopes, tool arguments,
/// results, hand-written JSON Schemas, and the shim↔agent IPC. Codable so we can decode
/// stdin/socket lines and encode responses with Foundation's JSONEncoder/JSONDecoder.
///
/// Copied (and made `public`) from safari-mcp/driver/.../MCP/JSONValue.swift so both the
/// shim and the agent can share one representation across the package boundary.
public enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// MARK: - Accessors

extension JSONValue {
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int(d)
        default: return nil
        }
    }
    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    /// Object member access: `value["key"]`.
    public subscript(_ key: String) -> JSONValue? { objectValue?[key] }

    public var isNull: Bool { if case .null = self { return true }; return false }
}

// MARK: - Literals (so JSON Schemas read like plain dictionaries)

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral v: String) { self = .string(v) }
}
extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral v: Bool) { self = .bool(v) }
}
extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral v: Int) { self = .int(v) }
}
extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral v: Double) { self = .double(v) }
}
extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}
extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

// MARK: - Serialization helpers

extension JSONValue {
    /// Compact, single-line JSON (no embedded newlines) — required for stdio/socket framing.
    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
