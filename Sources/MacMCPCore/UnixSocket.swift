import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// A socket-layer error carrying the failing operation and errno.
public struct SocketError: Error, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { self.description = message }
}

private func socketErr(_ op: String) -> SocketError {
    SocketError("\(op): \(String(cString: strerror(errno))) (errno \(errno))")
}

/// Thin, dependency-free POSIX unix-domain-socket helpers. We use raw sockets (not
/// Network.framework) because NWListener has no public way to bind a UDS path, and a UDS is
/// the right transport here: filesystem permissions scope it to the user, so screenshots and
/// (at Full tier) network bodies never cross to another local process.
public enum UnixSocket {
    /// Connect to a listening UDS at `path`. Returns a connected fd (caller closes it).
    public static func connect(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw socketErr("socket") }
        setNoSigPipe(fd)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        try setPath(&addr, path)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, len)
            }
        }
        guard r == 0 else {
            let e = socketErr("connect")
            close(fd)
            throw e
        }
        return fd
    }

    /// Bind + listen a UDS at `path` (unlinking any stale socket first). Returns the server fd.
    public static func listen(path: String, backlog: Int32 = 64) throws -> Int32 {
        unlink(path)  // remove a stale socket from a previous run
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw socketErr("socket") }
        setNoSigPipe(fd)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        try setPath(&addr, path)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        var r = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, len)
            }
        }
        guard r == 0 else {
            let e = socketErr("bind")
            close(fd)
            throw e
        }
        r = Darwin.listen(fd, backlog)
        guard r == 0 else {
            let e = socketErr("listen")
            close(fd)
            throw e
        }
        // Only the owner may connect (the path is also inside the user's app-support dir).
        chmod(path, 0o600)
        return fd
    }

    /// Accept one inbound connection. Returns the accepted fd, or nil on a retryable interrupt.
    public static func accept(_ serverFD: Int32) throws -> Int32? {
        let fd = Darwin.accept(serverFD, nil, nil)
        if fd >= 0 {
            setNoSigPipe(fd)
            return fd
        }
        if errno == EINTR || errno == ECONNABORTED { return nil }
        throw socketErr("accept")
    }

    /// Write all bytes, looping over partial writes and EINTR.
    public static func writeAll(_ fd: Int32, _ data: Data) throws {
        if data.isEmpty { return }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var off = 0
            let total = raw.count
            while off < total {
                let n = Darwin.write(fd, base.advanced(by: off), total - off)
                if n > 0 {
                    off += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    throw socketErr("write")
                }
            }
        }
    }

    /// Read whatever is available (up to `max`). Returns nil on EOF, empty Data on EINTR.
    public static func readAvailable(_ fd: Int32, max: Int = 65536) throws -> Data? {
        var buf = [UInt8](repeating: 0, count: max)
        let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, max) }
        if n > 0 { return Data(buf[0..<n]) }
        if n == 0 { return nil }  // EOF
        if errno == EINTR { return Data() }
        throw socketErr("read")
    }

    /// Bound blocking reads so a hung agent can't hang the shim (and Claude) forever.
    public static func setReceiveTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    // MARK: - Internals

    private static func setNoSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func setPath(_ addr: inout sockaddr_un, _ path: String) throws {
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)  // 104 on Darwin
        guard bytes.count < cap else {
            throw SocketError("unix socket path too long (\(bytes.count) ≥ \(cap)): \(path)")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: cap) { dst in
                for i in 0..<bytes.count { dst[i] = bytes[i] }
                dst[bytes.count] = 0
            }
        }
    }
}
