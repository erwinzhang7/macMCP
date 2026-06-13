import Foundation

/// Shared file-system locations for the agent.
public enum AgentPaths {
    /// ~/Library/Application Support/macMCP
    public static var supportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/macMCP", isDirectory: true)
    }

    /// The unix-domain socket the shim connects to and the agent listens on.
    public static var socketPath: String {
        supportDir.appendingPathComponent("agent.sock").path
    }

    public static func ensureSupportDir() {
        try? FileManager.default.createDirectory(
            at: supportDir, withIntermediateDirectories: true)
    }
}

/// IPC framing + envelope helpers for the shim↔agent channel. Newline-delimited JSON, the
/// same discipline as the MCP stdio channel: one compact JSON object per line.
///
/// Request  (shim → agent): { "id": <int>, "method": "tools/call"|"tools/list",
///                            "name"?: "<tool>", "arguments"?: {...} }
/// Response (agent → shim): { "id": <int>, "result": {...} } | { "id": <int>, "error": "<msg>" }
public enum Wire {
    /// Encode a JSON value as one newline-terminated line.
    public static func frame(_ value: JSONValue) -> Data {
        var d = (try? value.encoded()) ?? Data("{}".utf8)
        d.append(0x0A)
        return d
    }

    public static func request(id: Int, method: String, name: String?, arguments: JSONValue?)
        -> JSONValue
    {
        var obj: [String: JSONValue] = ["id": .int(id), "method": .string(method)]
        if let name { obj["name"] = .string(name) }
        if let arguments { obj["arguments"] = arguments }
        return .object(obj)
    }

    public static func resultResponse(id: Int, result: JSONValue) -> JSONValue {
        ["id": .int(id), "result": result]
    }

    public static func errorResponse(id: Int, message: String) -> JSONValue {
        ["id": .int(id), "error": .string(message)]
    }
}

/// Accumulates raw socket bytes and yields complete newline-delimited JSON values. One
/// instance per connection (the shim's client and each of the agent's accepted connections).
public final class LineBuffer {
    private var buf = Data()
    public init() {}

    /// Feed a chunk of bytes; returns every complete JSON line now available.
    public func append(_ data: Data) -> [JSONValue] {
        buf.append(data)
        var out: [JSONValue] = []
        while let nl = buf.firstIndex(of: 0x0A) {
            let lineData = Data(buf[buf.startIndex..<nl])
            let next = buf.index(after: nl)
            buf = next < buf.endIndex ? Data(buf[next...]) : Data()
            if !lineData.isEmpty, let v = try? JSONValue.decode(lineData) { out.append(v) }
        }
        return out
    }
}
