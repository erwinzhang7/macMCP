import Foundation
import MacMCPCore

#if canImport(Darwin)
    import Darwin
#endif

/// Blocking unix-socket client used by the shim to forward MCP tool calls to the agent.
///
/// The shim's MCP loop is synchronous and single-threaded, so this client is too: each
/// `call` writes one framed request and reads lines until the matching `id` comes back.
/// If the agent isn't running we try to launch it, then poll-connect with backoff.
final class AgentClient {
    private var fd: Int32 = -1
    private var lineBuf = LineBuffer()
    private var pending: [Int: JSONValue] = [:]
    private var nextId = 1
    private let recvTimeoutSeconds = 180

    init() {
        connectOrLaunch()
    }

    /// Send a request and block for its response. Returns the `result` payload.
    /// Throws `ToolError` on transport failure or an `error` envelope from the agent.
    func call(method: String, name: String?, arguments: JSONValue?) throws -> JSONValue {
        do {
            return try send(method: method, name: name, arguments: arguments)
        } catch {
            // One reconnect-and-retry: the agent may have restarted between calls.
            log("ipc call failed (\(error)); reconnecting…")
            reconnect()
            return try send(method: method, name: name, arguments: arguments)
        }
    }

    // MARK: - Internals

    private func send(method: String, name: String?, arguments: JSONValue?) throws -> JSONValue {
        guard fd >= 0 else { throw ToolError("agent not connected") }
        let id = nextId
        nextId += 1
        let req = Wire.request(id: id, method: method, name: name, arguments: arguments)
        try UnixSocket.writeAll(fd, Wire.frame(req))

        // Read until the response with our id arrives.
        while true {
            if let resp = pending.removeValue(forKey: id) {
                return try unwrap(resp, id: id)
            }
            guard let chunk = try UnixSocket.readAvailable(fd) else {
                throw ToolError("agent closed the connection")
            }
            if chunk.isEmpty { continue }  // EINTR
            for value in lineBuf.append(chunk) {
                if let rid = value["id"]?.intValue {
                    pending[rid] = value
                }
            }
        }
    }

    private func unwrap(_ resp: JSONValue, id: Int) throws -> JSONValue {
        if let err = resp["error"]?.stringValue { throw ToolError(err) }
        guard let result = resp["result"] else {
            throw ToolError("malformed response for id \(id)")
        }
        return result
    }

    private func connectOrLaunch() {
        if tryConnect() { return }
        log("agent not reachable — attempting to launch it")
        launchAgent()
        // Poll-connect with backoff for up to ~6s while the agent binds its socket.
        let deadline = Date().addingTimeInterval(6)
        var delay: useconds_t = 150_000
        while Date() < deadline {
            usleep(delay)
            if tryConnect() { return }
            delay = min(delay * 2, 600_000)
        }
        log("could not reach the agent after launch attempt")
    }

    private func tryConnect() -> Bool {
        AgentPaths.ensureSupportDir()
        guard let newFD = try? UnixSocket.connect(path: AgentPaths.socketPath) else { return false }
        fd = newFD
        UnixSocket.setReceiveTimeout(fd, seconds: recvTimeoutSeconds)
        lineBuf = LineBuffer()
        pending.removeAll()
        log("connected to agent at \(AgentPaths.socketPath)")
        return true
    }

    private func reconnect() {
        if fd >= 0 { close(fd); fd = -1 }
        connectOrLaunch()
    }

    /// Launch the agent without pulling AppKit into the shim. Order of preference:
    ///   1. $MACMCP_AGENT_BIN (explicit dev override) — run the binary directly, detached.
    ///   2. a `macmcp-agent` binary next to this shim (the SwiftPM dev layout).
    ///   3. /Applications/macMCP.app (installed) — `open` it.
    private func launchAgent() {
        if let override = ProcessInfo.processInfo.environment["MACMCP_AGENT_BIN"] {
            spawn(executable: override, args: [])
            return
        }
        let shimDir = (CommandLine.arguments.first.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().path
        }) ?? "."
        let sibling = shimDir + "/macmcp-agent"
        if FileManager.default.isExecutableFile(atPath: sibling) {
            spawn(executable: sibling, args: [])
            return
        }
        for appPath in ["/Applications/macMCP.app", NSHomeDirectory() + "/Applications/macMCP.app"] {
            if FileManager.default.fileExists(atPath: appPath) {
                spawn(executable: "/usr/bin/open", args: [appPath])
                return
            }
        }
        log(
            "no agent binary found (set MACMCP_AGENT_BIN, build macmcp-agent, or install macMCP.app)"
        )
    }

    private func spawn(executable: String, args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        // Detach: the agent outlives this shim and serves every session.
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            log("launched agent: \(executable) \(args.joined(separator: " "))")
        } catch {
            log("failed to launch agent \(executable): \(error)")
        }
    }
}
