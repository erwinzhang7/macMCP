import Foundation
import MacMCPCore

/// Enumerates internet sockets owned by a process using system networking tools.
enum NetworkMonitor {
    /// Return active internet connections for `pid`, de-duplicated by protocol, endpoints, and state.
    static func connections(pid: Int) throws -> JSONValue {
        let output = try run(
            "/usr/sbin/lsof",
            arguments: ["-nP", "-i", "-a", "-p", String(pid)],
            allowEmptyFailure: true)
        let rows = parseLsof(output.stdout)
        let connections = rows.map { $0.toJSON() }
        return [
            "pid": .int(pid),
            "count": .int(connections.count),
            "connections": .array(connections),
        ]
    }

    // MARK: - Internals

    private struct CommandOutput {
        let stdout: String
        let stderr: String
    }

    private struct Connection: Hashable {
        let proto: String
        let local: String
        let remote: String?
        let remoteHost: String?
        let remotePort: Int?
        let state: String

        func toJSON() -> JSONValue {
            var o: [String: JSONValue] = [
                "proto": .string(proto),
                "local": .string(local),
                "state": .string(state),
            ]
            if let remote { o["remote"] = .string(remote) }
            if let remoteHost { o["remoteHost"] = .string(remoteHost) }
            if let remotePort { o["remotePort"] = .int(remotePort) }
            return .object(o)
        }
    }

    private static func run(
        _ executable: String,
        arguments: [String],
        allowEmptyFailure: Bool = false
    ) throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw ToolError("Could not run \(executable): \(error)")
        }

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let out = String(data: stdoutData, encoding: .utf8) ?? ""
        let err = String(data: stderrData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            let message = err.trimmingCharacters(in: .whitespacesAndNewlines)
            if allowEmptyFailure && out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && message.isEmpty
            {
                return CommandOutput(stdout: "", stderr: err)
            }
            throw ToolError(message.isEmpty ? "\(executable) exited with status \(process.terminationStatus)." : message)
        }

        return CommandOutput(stdout: out, stderr: err)
    }

    private static func parseLsof(_ output: String) -> [Connection] {
        var seen = Set<Connection>()
        var rows: [Connection] = []

        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("COMMAND") { continue }

            let columns = line.split(maxSplits: 8, whereSeparator: \.isWhitespace).map(String.init)
            guard columns.count >= 9 else { continue }

            let type = columns[4]
            let node = columns[7]
            let name = columns[8]
            guard type == "IPv4" || type == "IPv6", node == "TCP" || node == "UDP" else { continue }

            guard let connection = parseConnection(type: type, node: node, name: name) else { continue }
            if seen.insert(connection).inserted {
                rows.append(connection)
            }
        }

        return rows
    }

    private static func parseConnection(type: String, node: String, name: String) -> Connection? {
        let parsedName = splitState(from: name)
        let endpoints = parsedName.endpoint.split(separator: "->", maxSplits: 1).map(String.init)
        guard let local = endpoints.first, !local.isEmpty else { return nil }

        let remote = endpoints.count == 2 ? endpoints[1] : nil
        let remoteEndpoint = remote.flatMap(splitHostPort)
        return Connection(
            proto: node.lowercased() + (type == "IPv6" ? "6" : "4"),
            local: local,
            remote: remote,
            remoteHost: remoteEndpoint?.host,
            remotePort: remoteEndpoint?.port,
            state: parsedName.state)
    }

    private static func splitState(from name: String) -> (endpoint: String, state: String) {
        guard name.hasSuffix(")"), let openParen = name.lastIndex(of: "(") else {
            return (name.trimmingCharacters(in: .whitespaces), "")
        }

        let stateStart = name.index(after: openParen)
        let stateEnd = name.index(before: name.endIndex)
        let endpoint = name[..<openParen].trimmingCharacters(in: .whitespaces)
        let state = String(name[stateStart..<stateEnd])
        return (endpoint, state)
    }

    private static func splitHostPort(_ endpoint: String) -> (host: String, port: Int?)? {
        if endpoint.hasPrefix("[") {
            guard let closeBracket = endpoint.firstIndex(of: "]") else { return (endpoint, nil) }
            let hostStart = endpoint.index(after: endpoint.startIndex)
            let host = String(endpoint[hostStart..<closeBracket])
            let afterBracket = endpoint.index(after: closeBracket)
            guard afterBracket < endpoint.endIndex, endpoint[afterBracket] == ":" else {
                return (host, nil)
            }
            let portStart = endpoint.index(after: afterBracket)
            return (host, Int(endpoint[portStart...]))
        }

        guard let colon = endpoint.lastIndex(of: ":") else { return (endpoint, nil) }
        let host = String(endpoint[..<colon])
        let portStart = endpoint.index(after: colon)
        return (host, Int(endpoint[portStart...]))
    }
}
