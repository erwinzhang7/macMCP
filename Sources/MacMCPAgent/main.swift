import Foundation
import MacMCPCore

#if canImport(Darwin)
    import Darwin
#endif

// The macMCP agent: the persistent process that owns the per-app permission allowlist and
// (in later phases) the macOS TCC grants, the work layer, the menu bar, and the network
// extension. It serves tool calls to every shim over a unix-domain socket.
//
// Phase 1 is headless (no menu bar yet): it wires the default-tier tools and runs the socket
// server. The menu-bar UI arrives in Phase 2.

logPrefix = "[macmcp-agent]"
AgentPaths.ensureSupportDir()

// Single instance: if another agent already answers on the socket, step aside.
if let existing = try? UnixSocket.connect(path: AgentPaths.socketPath) {
    close(existing)
    log("another agent is already running — exiting")
    exit(0)
}

let permissions = Permissions()
let inventory = AppInventory()
let router = ToolRouter(inventory: inventory, permissions: permissions)
let registry = router.registry

/// Map one request envelope to a response envelope. Tool handlers run on the main thread so
/// later AX/ScreenCaptureKit/AppKit work is main-thread-safe; connection threads block here.
func dispatch(_ req: JSONValue) -> JSONValue {
    let id = req["id"]?.intValue ?? 0
    switch req["method"]?.stringValue ?? "" {
    case "tools/list":
        return Wire.resultResponse(id: id, result: registry.listJSON())
    case "tools/call":
        guard let name = req["name"]?.stringValue else {
            return Wire.errorResponse(id: id, message: "tools/call missing 'name'")
        }
        guard let tool = registry.tool(named: name) else {
            return Wire.errorResponse(id: id, message: "Unknown tool: \(name)")
        }
        let args = req["arguments"] ?? .object([:])
        var response = Wire.errorResponse(id: id, message: "no result")
        let work = {
            do {
                response = Wire.resultResponse(id: id, result: try tool.handler(args).toJSON())
            } catch {
                response = Wire.resultResponse(
                    id: id,
                    result: ToolResult.failure(
                        "\(name) failed: \(String(describing: error))"
                    ).toJSON())
            }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
        return response
    case let other:
        return Wire.errorResponse(id: id, message: "unknown method: \(other)")
    }
}

let server = AgentServer(socketPath: AgentPaths.socketPath, dispatch: dispatch)
do {
    try server.start()
} catch {
    log("FATAL: could not start agent server: \(error)")
    exit(1)
}
log("agent ready — \(registry.all.count) tools")
dispatchMain()
