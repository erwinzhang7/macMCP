import Foundation
import MacMCPCore

#if canImport(Darwin)
    import Darwin
#endif

/// Owns the agent's state and the unix-socket server, and maps request envelopes to
/// responses. Extracted from `main.swift` so the menu-bar app entry point can own the
/// lifecycle while this stays UI-agnostic.
///
/// Tool handlers run on a single serial background queue (`workQueue`): one tool at a time,
/// and never on the main thread — so ScreenCaptureKit's async capture (bridged to sync via a
/// semaphore) can't deadlock, while AppKit/AX work that needs main hops there explicitly.
final class AgentCore {
    let permissions = Permissions()
    let inventory = AppInventory()
    let router: ToolRouter
    private var server: AgentServer?
    private let workQueue = DispatchQueue(label: "macmcp.work")

    init() {
        router = ToolRouter(inventory: inventory, permissions: permissions)
    }

    /// Single-instance guard, then bind + serve. Exits the process if another agent is live.
    func start() {
        if let existing = try? UnixSocket.connect(path: AgentPaths.socketPath) {
            close(existing)
            log("another agent is already running — exiting")
            exit(0)
        }
        let srv = AgentServer(socketPath: AgentPaths.socketPath) { [weak self] req in
            guard let self else {
                return Wire.errorResponse(id: req["id"]?.intValue ?? 0, message: "agent gone")
            }
            return self.dispatch(req)
        }
        do {
            try srv.start()
        } catch {
            log("FATAL: could not start agent server: \(error)")
            exit(1)
        }
        server = srv
        log("agent ready — \(router.registry.all.count) tools")
    }

    var connectionCount: Int { server?.connectionCount ?? 0 }

    private func dispatch(_ req: JSONValue) -> JSONValue {
        let id = req["id"]?.intValue ?? 0
        switch req["method"]?.stringValue ?? "" {
        case "tools/list":
            return Wire.resultResponse(id: id, result: router.registry.listJSON())
        case "tools/call":
            guard let name = req["name"]?.stringValue else {
                return Wire.errorResponse(id: id, message: "tools/call missing 'name'")
            }
            guard let tool = router.registry.tool(named: name) else {
                return Wire.errorResponse(id: id, message: "Unknown tool: \(name)")
            }
            let args = req["arguments"] ?? .object([:])
            return workQueue.sync {
                do {
                    return Wire.resultResponse(id: id, result: try tool.handler(args).toJSON())
                } catch {
                    return Wire.resultResponse(
                        id: id,
                        result: ToolResult.failure(
                            "\(name) failed: \(String(describing: error))"
                        ).toJSON())
                }
            }
        case let other:
            return Wire.errorResponse(id: id, message: "unknown method: \(other)")
        }
    }
}
