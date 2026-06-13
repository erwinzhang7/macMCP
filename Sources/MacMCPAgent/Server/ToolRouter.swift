import Foundation
import MacMCPCore

/// Builds the agent's `ToolRegistry`. Phase 1 registers the default ("none") tier — tools
/// that only reveal that an app exists/is running, plus its window titles and frontmost
/// state. Full-tier tools (screenshot, AX, input, network) and the `requireFull` gate are
/// layered on in later phases.
///
/// Mirrors safari-mcp/driver/.../Tools/Registry.swift's `makeRegistry`/`ToolSpec` pattern.
final class ToolRouter {
    let registry = ToolRegistry()
    private let inventory: AppInventory
    private let permissions: Permissions

    init(inventory: AppInventory, permissions: Permissions) {
        self.inventory = inventory
        self.permissions = permissions
        registerDefaultTier()
    }

    // MARK: - Default tier (no grant required)

    private func registerDefaultTier() {
        registry.register(
            ToolSpec(
                name: "mac_list_apps",
                description:
                    "List running macOS apps with bundle id, pid, frontmost/hidden state, and "
                    + "their current macMCP access tier (none|full). Default-tier: needs no grant.",
                inputSchema: schema([
                    "includeBackground": prop(
                        "boolean",
                        "Include accessory/background apps (no Dock icon). Default false.")
                ])
            ) { [self] raw in
                let a = Args(raw)
                let apps = inventory.runningApps(includeBackground: a.bool("includeBackground") ?? false)
                let front = inventory.frontmostBundleId()
                let arr = apps.map { app -> JSONValue in
                    app.toJSON(extra: [
                        "tier": .string(permissions.tier(for: app.gateKey).rawValue),
                        "isFrontmost": .bool(app.bundleId != nil && app.bundleId == front),
                    ])
                }
                return .text(jsonText(["count": .int(arr.count), "apps": .array(arr)]))
            })

        registry.register(
            ToolSpec(
                name: "mac_app_info",
                description:
                    "Details for one app (by bundleId or pid): identity, access tier, whether "
                    + "it's frontmost, and its window titles + geometry. Default-tier.",
                inputSchema: schema([
                    "bundleId": prop("string", "Target app bundle id (preferred)."),
                    "pid": prop("integer", "Target app process id (alternative to bundleId)."),
                ])
            ) { [self] raw in
                let a = Args(raw)
                let app = try inventory.resolve(a)
                let wins = inventory.windows(forPID: app.pid).map { $0.toJSON() }
                return .text(
                    jsonText(
                        app.toJSON(extra: [
                            "tier": .string(permissions.tier(for: app.gateKey).rawValue),
                            "isFrontmost": .bool(inventory.frontmostPID() == app.pid),
                            "windows": .array(wins),
                        ])))
            })

        registry.register(
            ToolSpec(
                name: "mac_list_windows",
                description:
                    "List an app's windows (windowId, title, bounds, on-screen). Titles + "
                    + "geometry only — no pixels (screenshots need Full tier). Default-tier.",
                inputSchema: schema([
                    "bundleId": prop("string", "Target app bundle id."),
                    "pid": prop("integer", "Target app process id."),
                ])
            ) { [self] raw in
                let app = try inventory.resolve(Args(raw))
                let wins = inventory.windows(forPID: app.pid).map { $0.toJSON() }
                return .text(
                    jsonText([
                        "app": .string(app.bundleId ?? app.name),
                        "count": .int(wins.count),
                        "windows": .array(wins),
                    ]))
            })

        registry.register(
            ToolSpec(
                name: "mac_permissions",
                description:
                    "List or revoke macMCP per-app grants. Actions: 'list' (default) shows all "
                    + "granted apps; 'revoke' removes a grant by bundleId. Claude cannot GRANT — "
                    + "granting happens via the native prompt or the menu bar. Default-tier.",
                inputSchema: schema([
                    "action": prop("string", "'list' or 'revoke'. Default 'list'."),
                    "bundleId": prop("string", "Bundle id to revoke (required for 'revoke')."),
                ])
            ) { [self] raw in
                let a = Args(raw)
                switch a.string("action") ?? "list" {
                case "revoke":
                    let key = try a.requiredString("bundleId")
                    permissions.revoke(key: key)
                    return .text("Revoked Full access for \(key).")
                case "list":
                    return .text(jsonText(["grants": permissions.allJSON()]))
                default:
                    throw ToolError("Unknown action; use 'list' or 'revoke'.")
                }
            })

        registry.register(
            ToolSpec(
                name: "mac_network_status",
                description:
                    "Report the network-capture subsystem status (extension active, buffered "
                    + "flow counts, CA installed). Default-tier (status only — bodies are gated).",
                inputSchema: schema([:])
            ) { _ in
                .text(
                    jsonText([
                        "provisioned": .bool(false),
                        "note": .string(
                            "Network capture lands in Phase 4 (NETransparentProxyProvider system "
                                + "extension). Not yet provisioned."),
                    ]))
            })
    }

    // MARK: - Schema helpers (mirror safari-mcp's inline JSON Schemas)

    func schema(_ properties: [String: JSONValue]) -> JSONValue {
        ["type": "object", "properties": .object(properties)]
    }
    func prop(_ type: String, _ description: String) -> JSONValue {
        ["type": .string(type), "description": .string(description)]
    }
}

/// Pretty-print a JSON value for a tool's text result (sorted keys, indented).
func jsonText(_ value: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(value), let s = String(data: data, encoding: .utf8) {
        return s
    }
    return "{}"
}
