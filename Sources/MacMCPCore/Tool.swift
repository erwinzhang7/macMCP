import Foundation

/// One content block of a tool result (mirrors MCP's content union).
/// Copied (and made `public`) from safari-mcp/driver/.../MCP/Tool.swift.
public enum ContentBlock {
    case text(String)
    case image(base64: String, mimeType: String)

    public func toJSON() -> JSONValue {
        switch self {
        case .text(let t):
            return ["type": "text", "text": .string(t)]
        case .image(let data, let mime):
            return ["type": "image", "data": .string(data), "mimeType": .string(mime)]
        }
    }

    /// Reconstruct a content block from its JSON (used by the shim to relay agent results).
    public static func fromJSON(_ v: JSONValue) -> ContentBlock? {
        switch v["type"]?.stringValue {
        case "text": return .text(v["text"]?.stringValue ?? "")
        case "image":
            return .image(
                base64: v["data"]?.stringValue ?? "",
                mimeType: v["mimeType"]?.stringValue ?? "image/png")
        default: return nil
        }
    }
}

/// The result of a tool call.
public struct ToolResult {
    public var content: [ContentBlock]
    public var isError: Bool

    public init(content: [ContentBlock], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func text(_ s: String) -> ToolResult { ToolResult(content: [.text(s)]) }
    public static func failure(_ s: String) -> ToolResult {
        ToolResult(content: [.text(s)], isError: true)
    }
    public static func image(base64: String, mimeType: String = "image/png", caption: String? = nil)
        -> ToolResult
    {
        var blocks: [ContentBlock] = []
        if let caption { blocks.append(.text(caption)) }
        blocks.append(.image(base64: base64, mimeType: mimeType))
        return ToolResult(content: blocks)
    }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = ["content": .array(content.map { $0.toJSON() })]
        if isError { obj["isError"] = .bool(true) }
        return .object(obj)
    }

    /// Reconstruct a ToolResult from its JSON (the shim relays the agent's result verbatim).
    public static func fromJSON(_ v: JSONValue) -> ToolResult {
        let blocks = (v["content"]?.arrayValue ?? []).compactMap { ContentBlock.fromJSON($0) }
        return ToolResult(content: blocks, isError: v["isError"]?.boolValue ?? false)
    }
}

/// Errors a tool handler may throw; surfaced to the client as an `isError` result.
public struct ToolError: Error, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { self.description = message }
}

/// A registered tool: name, human description, JSON Schema for inputs, and a handler.
public struct ToolSpec {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    public let handler: (JSONValue) throws -> ToolResult

    public init(
        name: String, description: String, inputSchema: JSONValue,
        handler: @escaping (JSONValue) throws -> ToolResult
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.handler = handler
    }
}

/// Small helpers for reading tool arguments out of a JSONValue object.
public struct Args {
    public let raw: JSONValue
    public init(_ raw: JSONValue) { self.raw = raw }

    public func string(_ key: String) -> String? { raw[key]?.stringValue }
    public func requiredString(_ key: String) throws -> String {
        guard let v = raw[key]?.stringValue, !v.isEmpty else {
            throw ToolError("Missing required argument '\(key)'")
        }
        return v
    }
    public func int(_ key: String) -> Int? { raw[key]?.intValue }
    public func double(_ key: String) -> Double? { raw[key]?.doubleValue }
    public func bool(_ key: String) -> Bool? { raw[key]?.boolValue }
    public func array(_ key: String) -> [JSONValue]? { raw[key]?.arrayValue }
}

/// The set of tools the server exposes. Order is preserved for `tools/list`.
public final class ToolRegistry {
    public private(set) var all: [ToolSpec] = []
    private var byName: [String: ToolSpec] = [:]

    public init() {}

    public func register(_ spec: ToolSpec) {
        all.append(spec)
        byName[spec.name] = spec
    }

    public func tool(named name: String) -> ToolSpec? { byName[name] }

    /// The `tools/list` payload: `{ "tools": [ {name, description, inputSchema}, ... ] }`.
    public func listJSON() -> JSONValue {
        let tools = all.map { spec -> JSONValue in
            [
                "name": .string(spec.name),
                "description": .string(spec.description),
                "inputSchema": spec.inputSchema,
            ]
        }
        return ["tools": .array(tools)]
    }
}
