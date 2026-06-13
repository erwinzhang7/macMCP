import AppKit
import CoreGraphics
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
        registerInputTier()
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

    // MARK: - Input / control tier (Full)

    private func registerInputTier() {
        registry.register(
            ToolSpec(
                name: "mac_click",
                description:
                    "Click an element in a granted app. Prefer 'ref' (from mac_read_ui / "
                    + "mac_find_element): it presses semantically via Accessibility, falling back "
                    + "to a synthetic click at the element's center. Or pass global screen point "
                    + "x,y (points, top-left). Full-tier.",
                inputSchema: schema([
                    "bundleId": prop("string", "Target app bundle id."),
                    "pid": prop("integer", "Target app process id."),
                    "ref": prop("string", "Element ref from mac_read_ui/mac_find_element (preferred)."),
                    "x": prop("number", "Global screen X (points, top-left) — used if no ref."),
                    "y": prop("number", "Global screen Y (points, top-left)."),
                    "button": prop("string", "left|right|center. Default left."),
                    "clicks": prop("integer", "1=single, 2=double. Default 1."),
                ])
            ) { [self] raw in
                let a = Args(raw)
                let app = try requireFull(a)
                try ensureAXTrust()
                let button = mouseButton(a.string("button"))
                let clicks = a.int("clicks") ?? 1
                if let ref = a.string("ref") {
                    // Tier A: semantic AX press (single left-click only).
                    if case .left = button, clicks == 1,
                        (try? AXController.press(ref: ref, pid: app.pid)) == true
                    {
                        return .text("Pressed \(ref) on \(app.name).")
                    }
                    // Tier B: synthetic click at the element's center.
                    guard let frame = AXController.frame(ref: ref, pid: app.pid) else {
                        throw ToolError(
                            "Ref \(ref) has no press action and no resolvable frame — re-run "
                                + "mac_read_ui for fresh refs.")
                    }
                    let c = CGPoint(x: frame.midX, y: frame.midY)
                    try InputControl.click(
                        pid: app.pid, at: c, button: button, clicks: clicks, flags: [])
                    return .text("Clicked \(ref) at (\(Int(c.x)),\(Int(c.y))) on \(app.name).")
                }
                if let x = a.double("x"), let y = a.double("y") {
                    try InputControl.click(
                        pid: app.pid, at: CGPoint(x: x, y: y), button: button, clicks: clicks,
                        flags: [])
                    return .text("Clicked (\(Int(x)),\(Int(y))) on \(app.name).")
                }
                throw ToolError("Provide 'ref' (preferred) or both 'x' and 'y' (global points).")
            })

        registry.register(
            ToolSpec(
                name: "mac_type",
                description:
                    "Type text into a granted app. With 'ref', sets the field value via "
                    + "Accessibility (falling back to focus + synthetic keystrokes); without, "
                    + "types into the focused field. submit=true presses Return after. Full-tier.",
                inputSchema: schema([
                    "bundleId": prop("string", "Target app bundle id."),
                    "pid": prop("integer", "Target app process id."),
                    "text": prop("string", "Text to type (required)."),
                    "ref": prop("string", "Field element ref (optional)."),
                    "submit": prop("boolean", "Press Return after typing. Default false."),
                ])
            ) { [self] raw in
                let a = Args(raw)
                let app = try requireFull(a)
                try ensureAXTrust()
                let text = try a.requiredString("text")
                if let ref = a.string("ref") {
                    if (try? AXController.setValue(ref: ref, pid: app.pid, text)) == true {
                        if a.bool("submit") == true {
                            try InputControl.pressKey(pid: app.pid, combo: "return")
                        }
                        return .text("Set value of \(ref) on \(app.name).")
                    }
                    try? AXController.focus(ref: ref, pid: app.pid)
                }
                try InputControl.typeText(pid: app.pid, text)
                if a.bool("submit") == true {
                    try InputControl.pressKey(pid: app.pid, combo: "return")
                }
                return .text("Typed \(text.count) chars into \(app.name).")
            })

        registry.register(
            ToolSpec(
                name: "mac_key",
                description:
                    "Press a key chord in a granted app, e.g. 'cmd+s', 'return', 'cmd+shift+t', "
                    + "'escape', 'down', 'f5'. Full-tier.",
                inputSchema: schema([
                    "bundleId": prop("string", "Target app bundle id."),
                    "pid": prop("integer", "Target app process id."),
                    "combo": prop("string", "Key chord (required), e.g. 'cmd+s'."),
                    "repeat": prop("integer", "Times to press. Default 1."),
                ])
            ) { [self] raw in
                let a = Args(raw)
                let app = try requireFull(a)
                try ensureAXTrust()
                let combo = try a.requiredString("combo")
                let n = max(1, a.int("repeat") ?? 1)
                for _ in 0..<n { try InputControl.pressKey(pid: app.pid, combo: combo) }
                return .text("Pressed \(combo)\(n > 1 ? " ×\(n)" : "") on \(app.name).")
            })

        registry.register(
            ToolSpec(
                name: "mac_scroll",
                description:
                    "Scroll within a granted app. direction up|down|left|right, amount in lines. "
                    + "Scrolls at element 'ref' center, else the app's main window center. Full-tier.",
                inputSchema: schema([
                    "bundleId": prop("string", "Target app bundle id."),
                    "pid": prop("integer", "Target app process id."),
                    "direction": prop("string", "up|down|left|right (required)."),
                    "amount": prop("integer", "Lines to scroll. Default 5."),
                    "ref": prop("string", "Scroll at this element's center (optional)."),
                ])
            ) { [self] raw in
                let a = Args(raw)
                let app = try requireFull(a)
                try ensureAXTrust()
                let dir = try a.requiredString("direction").lowercased()
                let amount = Int32(a.int("amount") ?? 5)
                var dx: Int32 = 0
                var dy: Int32 = 0
                switch dir {
                case "up": dy = amount
                case "down": dy = -amount
                case "left": dx = amount
                case "right": dx = -amount
                default: throw ToolError("direction must be up|down|left|right")
                }
                let point: CGPoint
                if let ref = a.string("ref"), let f = AXController.frame(ref: ref, pid: app.pid) {
                    point = CGPoint(x: f.midX, y: f.midY)
                } else {
                    let map = try windowMapping(pid: app.pid, windowId: nil)
                    point = CGPoint(x: map.bounds.midX, y: map.bounds.midY)
                }
                try InputControl.scroll(pid: app.pid, at: point, dx: dx, dy: dy)
                return .text("Scrolled \(dir) \(amount) on \(app.name).")
            })

        registry.register(
            ToolSpec(
                name: "mac_computer",
                description:
                    "Screenshot-driven control of a granted app window — the coordinate fallback "
                    + "for apps with no usable accessibility tree (games, custom UIs). action: "
                    + "screenshot|left_click|right_click|double_click|type|key|scroll. Click "
                    + "coordinates are PIXELS within the window screenshot (top-left). Full-tier.",
                inputSchema: schema([
                    "bundleId": prop("string", "Target app bundle id."),
                    "pid": prop("integer", "Target app process id."),
                    "windowId": prop("integer", "Specific window (default: largest on-screen)."),
                    "action": prop(
                        "string",
                        "screenshot|left_click|right_click|double_click|type|key|scroll (required)."),
                    "x": prop("integer", "Pixel X within the window screenshot."),
                    "y": prop("integer", "Pixel Y within the window screenshot."),
                    "text": prop("string", "Text for action=type."),
                    "combo": prop("string", "Key chord for action=key."),
                    "direction": prop("string", "up|down|left|right for action=scroll."),
                    "amount": prop("integer", "Lines for action=scroll. Default 5."),
                ])
            ) { [self] raw in
                let a = Args(raw)
                let app = try requireFull(a)
                let action = try a.requiredString("action").lowercased()
                let map = try windowMapping(pid: app.pid, windowId: a.int("windowId"))
                func globalPoint() throws -> CGPoint {
                    guard let px = a.int("x"), let py = a.int("y") else {
                        throw ToolError("action '\(action)' needs x,y pixel coordinates.")
                    }
                    return CGPoint(
                        x: map.origin.x + CGFloat(px) / map.scale,
                        y: map.origin.y + CGFloat(py) / map.scale)
                }
                switch action {
                case "screenshot":
                    let png = try ScreenCapture.capturePNG(windowID: map.windowId)
                    let caption =
                        "Window \(map.windowId) of \(app.name): "
                        + "\(Int(map.bounds.width))×\(Int(map.bounds.height)) pt at "
                        + "(\(Int(map.origin.x)),\(Int(map.origin.y))), scale \(map.scale). "
                        + "Click coordinates are PIXELS within this image."
                    return .image(base64: png.base64EncodedString(), caption: caption)
                case "left_click", "right_click", "double_click":
                    try ensureAXTrust()
                    let p = try globalPoint()
                    let button: MouseButton = action == "right_click" ? .right : .left
                    let clicks = action == "double_click" ? 2 : 1
                    try InputControl.click(
                        pid: app.pid, at: p, button: button, clicks: clicks, flags: [])
                    return .text("\(action) at pixel (\(a.int("x") ?? 0),\(a.int("y") ?? 0)).")
                case "type":
                    try ensureAXTrust()
                    try InputControl.typeText(pid: app.pid, try a.requiredString("text"))
                    return .text("Typed into \(app.name).")
                case "key":
                    try ensureAXTrust()
                    try InputControl.pressKey(pid: app.pid, combo: try a.requiredString("combo"))
                    return .text("Pressed key on \(app.name).")
                case "scroll":
                    try ensureAXTrust()
                    let p =
                        (a.int("x") != nil && a.int("y") != nil)
                        ? try globalPoint() : CGPoint(x: map.bounds.midX, y: map.bounds.midY)
                    let amount = Int32(a.int("amount") ?? 5)
                    var dx: Int32 = 0
                    var dy: Int32 = 0
                    switch (a.string("direction") ?? "down").lowercased() {
                    case "up": dy = amount
                    case "left": dx = amount
                    case "right": dx = -amount
                    default: dy = -amount
                    }
                    try InputControl.scroll(pid: app.pid, at: p, dx: dx, dy: dy)
                    return .text("Scrolled on \(app.name).")
                default:
                    throw ToolError("Unknown action '\(action)'.")
                }
            })
    }

    private func mouseButton(_ s: String?) -> MouseButton {
        switch (s ?? "left").lowercased() {
        case "right": return .right
        case "center", "middle": return .center
        default: return .left
        }
    }

    /// Resolve the target window's screen origin (points, top-left), backing scale, and bounds,
    /// for mapping mac_computer screenshot pixels → global screen points.
    /// NB: scale uses the main display; multi-display mixed-scale setups are a known v1 limitation.
    private func windowMapping(pid: Int, windowId: Int?)
        throws -> (origin: CGPoint, scale: CGFloat, windowId: Int, bounds: CGRect)
    {
        let wins = inventory.windows(forPID: pid)
        let win: WindowRecord
        if let windowId {
            guard let w = wins.first(where: { $0.windowId == windowId }) else {
                throw ToolError("Window \(windowId) not found for pid \(pid).")
            }
            win = w
        } else {
            guard
                let w = wins.filter({
                    $0.isOnscreen && $0.layer == 0 && $0.bounds.width > 1 && $0.bounds.height > 1
                }).max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
            else {
                throw ToolError("No on-screen window for pid \(pid).")
            }
            win = w
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        return (win.bounds.origin, scale, win.windowId, win.bounds)
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
