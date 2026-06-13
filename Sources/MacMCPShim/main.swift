import Foundation
import MacMCPCore

// The macMCP shim: a thin MCP server over stdio that forwards every tool call to the
// persistent agent over a unix-domain socket. It holds no permissions and does no real
// work — the agent owns all of that. Claude Code launches one shim per session; many
// shims share the one agent.

logPrefix = "[macmcp]"

let client = AgentClient()

// Build the local tool registry by asking the agent what it exposes, then register a proxy
// handler per tool that forwards the call. This way the shim never hardcodes the tool list —
// it always mirrors whatever the agent currently offers.
let registry = ToolRegistry()
do {
    let toolsList = try client.call(method: "tools/list", name: nil, arguments: nil)
    let tools = toolsList["tools"]?.arrayValue ?? []
    for t in tools {
        guard let name = t["name"]?.stringValue else { continue }
        let desc = t["description"]?.stringValue ?? ""
        let schema = t["inputSchema"] ?? ["type": "object", "properties": .object([:])]
        registry.register(
            ToolSpec(name: name, description: desc, inputSchema: schema) { args in
                let result = try client.call(method: "tools/call", name: name, arguments: args)
                return ToolResult.fromJSON(result)
            })
    }
    log("mirrored \(tools.count) tools from the agent")
} catch {
    // Degrade gracefully: still speak MCP so Claude can initialize; report the problem when
    // a tool is actually called.
    log("could not reach the agent for tools/list (\(error)) — serving a diagnostic tool")
    registry.register(
        ToolSpec(
            name: "mac_agent_status",
            description: "Report whether the macMCP agent is reachable.",
            inputSchema: ["type": "object", "properties": .object([:])]
        ) { _ in
            ToolResult.failure(
                "The macMCP agent isn't reachable. Make sure macMCP.app is installed/running "
                    + "(or build & run the agent in development).")
        })
}

let server = MCPServer(name: "macmcp", version: "0.1.0", registry: registry)
server.run()
