import Foundation
import MacMCPCore

#if canImport(Darwin)
    import Darwin
#endif

/// Unix-domain-socket server that accepts shim connections and answers request envelopes.
/// One accept loop thread; one reader thread per connection. Each request envelope
/// `{id, method, name?, arguments?}` is mapped to a response envelope by `dispatch`.
///
/// This is macMCP's analogue of safari-mcp's `BridgeServer`, but it carries MCP tool calls
/// (not just telemetry) over a UDS instead of a loopback WebSocket.
final class AgentServer {
    private let socketPath: String
    private let dispatch: (JSONValue) -> JSONValue
    private var serverFD: Int32 = -1
    private let lock = NSLock()
    private var connectionFDs: Set<Int32> = []
    /// Cap concurrent shim connections so a flood of same-user connections can't exhaust
    /// threads/fds. Real use is a handful of sessions.
    private let maxConnections = 32

    init(socketPath: String, dispatch: @escaping (JSONValue) -> JSONValue) {
        self.socketPath = socketPath
        self.dispatch = dispatch
    }

    /// Number of currently-connected shims (for status reporting).
    var connectionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return connectionFDs.count
    }

    func start() throws {
        AgentPaths.ensureSupportDir()
        serverFD = try UnixSocket.listen(path: socketPath)
        log("listening on \(socketPath)")
        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "macmcp.agent.accept"
        t.stackSize = 1 << 20
        t.start()
    }

    private func acceptLoop() {
        while true {
            do {
                guard let fd = try UnixSocket.accept(serverFD) else { continue }
                lock.lock()
                let atCapacity = connectionFDs.count >= maxConnections
                if !atCapacity { connectionFDs.insert(fd) }
                lock.unlock()
                if atCapacity {
                    log("rejecting connection: at capacity (\(maxConnections))")
                    close(fd)
                    continue
                }
                let t = Thread { [weak self] in self?.serve(fd) }
                t.name = "macmcp.agent.conn"
                t.stackSize = 1 << 20
                t.start()
            } catch {
                log("accept failed: \(error)")
                // Brief pause to avoid a hot spin if the listener is wedged.
                usleep(50_000)
            }
        }
    }

    private func serve(_ fd: Int32) {
        log("shim connected (fd \(fd))")
        let lineBuf = LineBuffer()
        defer {
            close(fd)
            lock.lock(); connectionFDs.remove(fd); lock.unlock()
            log("shim disconnected (fd \(fd))")
        }
        while true {
            let chunk: Data?
            do { chunk = try UnixSocket.readAvailable(fd) } catch {
                log("read error on fd \(fd): \(error)")
                return
            }
            guard let chunk else { return }  // EOF
            if chunk.isEmpty { continue }  // EINTR
            let requests: [JSONValue]
            do {
                requests = try lineBuf.append(chunk)
            } catch {
                log("framing error on fd \(fd): \(error) — closing")
                return
            }
            for request in requests {
                let response = dispatch(request)
                do {
                    try UnixSocket.writeAll(fd, Wire.frame(response))
                } catch {
                    log("write error on fd \(fd): \(error)")
                    return
                }
            }
        }
    }
}
