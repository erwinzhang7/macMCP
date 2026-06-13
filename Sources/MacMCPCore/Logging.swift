import Foundation

/// Process-wide log prefix. The shim sets "[macmcp]", the agent "[macmcp-agent]".
public var logPrefix = "[macmcp]"

/// Log to stderr. stdout is reserved for the JSON-RPC channel — never write logs there.
public func log(_ message: String) {
    FileHandle.standardError.write(Data((logPrefix + " " + message + "\n").utf8))
}
