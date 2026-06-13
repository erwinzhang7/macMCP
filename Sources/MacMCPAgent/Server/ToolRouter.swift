import AppKit
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
        registerFullTier()
    }

    // MARK: - Permission gate

    /// Resolve the target app and ensure it's at Full tier, prompting if needed. Mirrors
    /// safari-mcp's `requireAuth` (Tools/Registry.swift) but keyed on bundle id with a
    /// two-tier model. Granting only happens via the native dialog (or the menu bar) — Claude
    /// can never self-authorize. Returns the resolved app on success; throws otherwise.
    @discardableResult
    private func requireFull(_ args: Args) throws -> AppRecord {
        let app = try inventory.resolve(args)
        let key = app.gateKey
        let liveTeamID = app.bundlePath.flatMap { inventory.teamID(forBundlePath: $0) }

        if permissions.tier(for: key) == .full {
            // Anti-squatting: a stored grant is invalidated if the running app's signing
            // identity no longer matches what was granted.
            if let stored = permissions.grant(for: key)?.signingTeamID, let live = liveTeamID,
                stored != live
            {
                permissions.revoke(key: key)
                log("revoked \(key): signing Team ID changed (\(stored) → \(live))")
            } else {
                return app
            }
        }

        if GrantDialog.prompt(app: app, teamID: liveTeamID) {
            permissions.grantFull(key: key, name: app.name, teamID: liveTeamID)
            return app
        }
        throw ToolError(
            "Not authorized to act on \(app.name) (\(key)) at Full tier — the prompt was denied "
                + "or dismissed. Default-tier info (mac_list_apps, mac_app_info, window titles, "
                + "frontmost) still works; grant Full from the macMCP menu bar, or approve the "
                + "prompt next time.")
    }

    private func ensureAXTrust() throws {
        guard AXController.isTrusted() else {
            AXController.requestTrust()
            throw ToolError(
                "Accessibility permission is required to read or drive app UIs, and it isn't "
                    + "granted to the macMCP agent. A system prompt may have appeared — otherwise "
                    + "enable it in System Settings ▸ Privacy & Security ▸ Accessibility (turn on "
                    + "“macMCP”), then retry. The grant persists afterward.")
        }
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

    // MARK: - Full tier (per-app grant via requireFull)

    private func registerFullTier() {
        registry.register(
            ToolSpec(
                name: "mac_screenshot",
                description:
                    "Screenshot one window of a granted app (PNG), occlusion-safe — the window "
                    + "need not be frontmost. Full-tier: prompts for access on first use.",
                inputSchema: schema([
                    "bundleId": prop("string", "Target app bundle id (preferred)."),
                    "pid": prop("integer", "Target app process id."),
                    "windowId": prop(
                        "integer", "Specific window id (from mac_list_windows). Default: the "
                            + "app's largest on-screen window."),
                    "bringToFront": prop(
                        "boolean", "Activate the app before capturing. Default false."),
                ])
            ) { [self] raw in
                let a = Args(raw)
                let app = try requireFull(a)
                if a.bool("bringToFront") == true { activate(pid: app.pid) }
                let png: Data
                if let windowId = a.int("windowId") {
                    png = try ScreenCapture.capturePNG(windowID: windowId)
                } else {
                    png = try ScreenCapture.capturePNG(pid: app.pid)
                }
                return .image(
                    base64: png.base64EncodedString(),
                    caption: "Screenshot of \(app.name) (\(png.count) bytes PNG).")
            })

        registry.register(
            ToolSpec(
                name: "mac_read_ui",
                description:
                    "Accessibility-tree snapshot of a granted app: interactive/labeled elements "
                    + "with stable refs, roles, titles, values, and geometry. Enables a11y for "
                    + "Electron/Chromium apps automatically. Full-tier.",
                inputSchema: schema([
                    "bundleId": prop("string", "Target app bundle id."),
                    "pid": prop("integer", "Target app process id."),
                    "maxElements": prop("integer", "Cap on elements returned. Default 200."),
                ])
            ) { [self] raw in
                let a = Args(raw)
                let app = try requireFull(a)
                try ensureAXTrust()
                let snapshot = try AXController.snapshot(
                    pid: app.pid, maxElements: a.int("maxElements") ?? 200)
                return .text(jsonText(snapshot))
            })

        registry.register(
            ToolSpec(
                name: "mac_find_element",
                description:
                    "Find elements in a granted app by role/title/value/description substring "
                    + "(case-insensitive). Returns refs usable for later actions. Full-tier.",
                inputSchema: schema([
                    "bundleId": prop("string", "Target app bundle id."),
                    "pid": prop("integer", "Target app process id."),
                    "query": prop("string", "Substring to match (required)."),
                    "role": prop("string", "Restrict to an AX role (e.g. AXButton)."),
                    "max": prop("integer", "Max matches. Default 25."),
                ])
            ) { [self] raw in
                let a = Args(raw)
                let app = try requireFull(a)
                try ensureAXTrust()
                let query = try a.requiredString("query")
                let found = try AXController.find(
                    pid: app.pid, query: query, role: a.string("role"), max: a.int("max") ?? 25)
                return .text(jsonText(found))
            })
    }

    /// Bring an app to the front (used by mac_screenshot's bringToFront). Hops to main.
    private func activate(pid: Int) {
        let work: () -> Void = {
            _ = NSRunningApplication(processIdentifier: pid_t(pid))?
                .activate(options: [.activateAllWindows])
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
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
