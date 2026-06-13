import Foundation

/// A hand-rolled MCP server over stdio. Implements just enough of JSON-RPC 2.0 and the
/// MCP lifecycle (initialize / tools/list / tools/call / ping) to serve Claude Code.
/// No SDK, no transport library — newline-delimited JSON on stdin/stdout.
///
/// Copied (and made `public`) from safari-mcp/driver/.../MCP/Server.swift. In macMCP the
/// shim runs this loop and its registered tool handlers forward each call to the agent.
public final class MCPServer {
    private let name: String
    private let version: String
    private let registry: ToolRegistry
    private let out = FileHandle.standardOutput

    /// Default protocol version advertised if the client doesn't pin one.
    private let defaultProtocolVersion = "2025-06-18"

    public init(name: String, version: String, registry: ToolRegistry) {
        self.name = name
        self.version = version
        self.registry = registry
    }

    /// Blocking run loop. Reads one JSON-RPC message per line until stdin closes.
    public func run() {
        log("ready on stdio — \(registry.all.count) tools registered")
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8),
                let message = try? JSONValue.decode(data)
            else {
                log("dropping unparseable line")
                continue
            }
            handle(message)
        }
        log("stdin closed — exiting")
    }

    // MARK: - Dispatch

    private func handle(_ message: JSONValue) {
        let id = message["id"]  // may be .int, .string, or absent (notification)
        guard let method = message["method"]?.stringValue else {
            return  // not a request/notification we understand
        }
        let params = message["params"] ?? .object([:])

        switch method {
        case "initialize":
            respond(id, result: initializeResult(params))
        case "notifications/initialized", "initialized":
            break  // notification — no response
        case "ping":
            respond(id, result: .object([:]))
        case "tools/list":
            respond(id, result: registry.listJSON())
        case "tools/call":
            handleToolCall(id, params)
        default:
            if id != nil {
                respondError(id, code: -32601, message: "Method not found: \(method)")
            }
        }
    }

    private func initializeResult(_ params: JSONValue) -> JSONValue {
        let proto = params["protocolVersion"]?.stringValue ?? defaultProtocolVersion
        return [
            "protocolVersion": .string(proto),
            "capabilities": ["tools": .object([:])],
            "serverInfo": ["name": .string(name), "version": .string(version)],
        ]
    }

    private func handleToolCall(_ id: JSONValue?, _ params: JSONValue) {
        guard let name = params["name"]?.stringValue else {
            respondError(id, code: -32602, message: "tools/call missing 'name'")
            return
        }
        guard let tool = registry.tool(named: name) else {
            respondError(id, code: -32602, message: "Unknown tool: \(name)")
            return
        }
        let arguments = params["arguments"] ?? .object([:])
        do {
            let result = try tool.handler(arguments)
            respond(id, result: result.toJSON())
        } catch {
            // Tool failures are reported as a result with isError:true (not a protocol
            // error) so the model sees the message and can react.
            respond(
                id,
                result: ToolResult.failure("\(name) failed: \(String(describing: error))").toJSON())
        }
    }

    // MARK: - Output

    private func respond(_ id: JSONValue?, result: JSONValue) {
        guard let id else { return }  // don't reply to notifications
        emit(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func respondError(_ id: JSONValue?, code: Int, message: String) {
        guard let id else { return }
        emit([
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": .int(code), "message": .string(message)],
        ])
    }

    private func emit(_ value: JSONValue) {
        guard var data = try? value.encoded() else {
            log("failed to encode response")
            return
        }
        data.append(0x0A)  // newline-delimited framing
        out.write(data)
    }
}
