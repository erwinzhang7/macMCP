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
        registerNetworkTier()
        registerFlowTier()
        registerWindowTier()
    }

    // MARK: - Window + drag tier (Full)

    private func registerWindowTier() {
        registry.register(
            ToolSpec(
                name: "mac_drag",
                description:
                    "Press-drag-release in a granted app between two global screen points "
                    + "(points, top-left) — for sliders, canvas drawing, reordering, resize "
                    + "handles, drag-and-drop. NOTE: a drag uses a real mouse-down, so it WILL "
                    + "raise the window (unavoidable). Full-tier.",
                inputSchema: schema([
                    "bundleId": prop("string", "Target app bundle id."),
                    "pid": prop("integer", "Target app process id."),
                    "fromX": prop("number", "Start X (global points)."),
                    "fromY": prop("number", "Start Y (global points)."),
                    "toX": prop("number", "End X (global points)."),
                    "toY": prop("number", "End Y (global points)."),
                    "button": prop("string", "left|right|center. Default left."),
                    "steps": prop("integer", "Interpolation steps. Default 20."),
                ])
            ) { [self] raw in
                let a = Args(raw)
                let app = try requireFull(a)
                try ensureAXTrust()
                guard let fx = a.double("fromX"), let fy = a.double("fromY"),
                    let tx = a.double("toX"), let ty = a.double("toY")
                else {
                    throw ToolError("mac_drag needs fromX, fromY, toX, toY (global screen points).")
                }
                try InputControl.drag(
                    pid: app.pid, from: CGPoint(x: fx, y: fy), to: CGPoint(x: tx, y: ty),
                    steps: clampInt(a.int("steps"), default: 20, min: 1, max: 200),
                    button: mouseButton(a.string("button")), flags: [])
                return .text(
                    "Dragged (\(Int(fx)),\(Int(fy))) → (\(Int(tx)),\(Int(ty))) on \(app.name).")
            })

        registry.register(
            ToolSpec(
                name: "mac_window",
                description:
                    "Manage a granted app's window via Accessibility. action: "
                    + "move|resize|minimize|unminimize|close|raise|list. Target by 'title' "
                    + "substring, else the focused/main window. move/resize/minimize do NOT raise "
                    + "or steal focus; only 'raise' brings the window forward. Full-tier.",
                inputSchema: schema([
                    "bundleId": prop("string", "Target app bundle id."),
                    "pid": prop("integer", "Target app process id."),
                    "action": prop(
                        "string", "move|resize|minimize|unminimize|close|raise|list (required)."),
                    "title": prop("string", "Match a window by title substring (optional)."),
                    "x": prop("number", "move: new X (global points, top-left)."),
                    "y": prop("number", "move: new Y (global points, top-left)."),
                    "width": prop("number", "resize: new width (points)."),
                    "height": prop("number", "resize: new height (points)."),
                ])
            ) { [self] raw in
                let a = Args(raw)
                let app = try requireFull(a)
                try ensureAXTrust()
                let title = a.string("title")
                switch try a.requiredString("action").lowercased() {
                case "list":
                    return .text(jsonText(["windows": WindowControl.list(pid: app.pid)]))
                case "move":
                    guard let x = a.double("x"), let y = a.double("y") else {
                        throw ToolError("move needs x,y (global points).")
                    }
                    return .text(
                        try WindowControl.move(pid: app.pid, title: title, to: CGPoint(x: x, y: y)))
                case "resize":
                    guard let w = a.double("width"), let h = a.double("height") else {
                        throw ToolError("resize needs width,height (points).")
                    }
                    return .text(
                        try WindowControl.resize(
                            pid: app.pid, title: title, to: CGSize(width: w, height: h)))
                case "minimize":
                    return .text(try WindowControl.setMinimized(pid: app.pid, title: title, true))
                case "unminimize":
                    return .text(try WindowControl.setMinimized(pid: app.pid, title: title, false))
                case "close":
                    return .text(try WindowControl.close(pid: app.pid, title: title))
                case "raise":
                    return .text(try WindowControl.raise(pid: app.pid, title: title))
                case let other:
                    throw ToolError("Unknown window action '\(other)'.")
                }
            })
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

        if permissions.tier(for: key) == .full, let grant = permissions.grant(for: key) {
            // Fail CLOSED: only honor the grant if the running app's identity still verifies.
            if identityMatches(grant: grant, app: app, liveTeamID: liveTeamID) {
                return app
            }
            permissions.revoke(key: key)  // identity changed or unverifiable → re-prompt
            log("revoked \(key): identity no longer verifies")
        }

        if GrantDialog.prompt(app: app, teamID: liveTeamID) {
            // Never persist a pure-pid grant: a PID is reusable by a different app later.
            if !key.hasPrefix("pid:") {
                permissions.grantFull(
                    key: key, name: app.name, teamID: liveTeamID, bundlePath: app.bundlePath)
            }
            return app
        }
        throw ToolError(
            "Not authorized to act on \(app.name) (\(key)) at Full tier — the prompt was denied "
                + "or dismissed. Default-tier info (mac_list_apps, mac_app_info, window titles, "
                + "frontmost) still works; grant Full from the macMCP menu bar, or approve the "
                + "prompt next time.")
    }

    /// Fail-closed identity check for a stored Full grant. Signed grants require the live app to
    /// present the SAME Team ID (a nil live Team ID — couldn't verify — fails). Unsigned/system
    /// grants bind to the canonical bundle path. A grant with neither identity re-prompts.
    private func identityMatches(grant g: Grant, app: AppRecord, liveTeamID: String?) -> Bool {
        if let storedTeam = g.signingTeamID {
            return liveTeamID == storedTeam
        }
        if let storedPath = g.bundlePath {
            return app.bundlePath == storedPath
        }
        return false
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
                        "metadataMode": .bool(true),
                        "metadataSource": .string(
                            "lsof (per-app connection metadata: remote host/port/state). No "
                                + "entitlement or root required; works on every app incl. pinned."),
                        "bodyCaptureSupported": .bool(false),
                        "bodyCaptureNote": .string(
                            "Request/response BODY capture is out of scope — it would need a "
                                + "transparent-proxy system extension + a trusted root CA (and "
                                + "still fails on cert-pinned apps). macMCP provides connection "
                                + "metadata only."),
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
                    "maxWidth": prop(
                        "integer", "Downscale so the image is at most this many pixels wide "
                            + "(default 1400). Smaller = faster + cheaper to process."),
                    "format": prop("string", "png (default, crisp text) or jpeg (smaller/faster)."),
                ])
            ) { [self] raw in
                let a = Args(raw)
                let app = try requireFull(a)
                // No activation: ScreenCaptureKit captures occluded/background windows, so a
                // screenshot never needs to raise or focus the app (won't interrupt the user).
                // windowMapping is pid-scoped, so a foreign windowId can't be captured (ownership)
                // and it computes the downscaled capture dimensions.
                let jpeg = isJPEG(a.string("format"))
                let map = try windowMapping(
                    pid: app.pid, windowId: a.int("windowId"),
                    maxWidth: a.int("maxWidth") ?? defaultMaxWidth)
                let data = try ScreenCapture.capturePNG(
                    windowID: map.windowId, pixelWidth: map.pixelWidth,
                    pixelHeight: map.pixelHeight, jpeg: jpeg)
                return .image(
                    base64: data.base64EncodedString(),
                    mimeType: jpeg ? "image/jpeg" : "image/png",
                    caption: "Screenshot of \(app.name) — window \(map.windowId), "
                        + "\(map.pixelWidth)×\(map.pixelHeight)px, \(data.count) bytes.")
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
                    pid: app.pid,
                    maxElements: clampInt(a.int("maxElements"), default: 200, min: 1, max: 5000))
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
                    pid: app.pid, query: query, role: a.string("role"),
                    max: clampInt(a.int("max"), default: 25, min: 1, max: 1000))
                return .text(jsonText(found))
            })
    }

    // MARK: - Input / control tier (Full)

    private func registerInputTier() {
        registry.register(
            ToolSpec(
                name: "mac_click",
                description:
                    "Click an element in a granted app. Easiest: pass 'query' to find-and-click a "
                    + "control by its label in one call. Or 'ref' (from mac_read_ui/mac_find_element), "
                    + "or global screen point 'x','y' (points, top-left). Single left-clicks invoke "
                    + "the control via Accessibility (no app activation / focus steal). Full-tier.",
                inputSchema: schema([
                    "bundleId": prop("string", "Target app bundle id."),
                    "pid": prop("integer", "Target app process id."),
                    "query": prop(
                        "string",
                        "Find-and-click the first element whose label/role/value contains this "
                            + "(one-shot — no prior read needed)."),
                    "role": prop("string", "Restrict 'query' to an AX role (e.g. AXButton)."),
                    "ref": prop("string", "Element ref from mac_read_ui/mac_find_element."),
                    "x": prop("number", "Global screen X (points, top-left)."),
                    "y": prop("number", "Global screen Y (points, top-left)."),
                    "button": prop("string", "left|right|center. Default left."),
                    "clicks": prop("integer", "1=single, 2=double. Default 1."),
                ])
            ) { [self] raw in
                let a = Args(raw)
                let app = try requireFull(a)
                try ensureAXTrust()
                return .text(try doClick(app: app, a: a) + " on \(app.name).")
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
                let text = try checkedText(a.requiredString("text"))
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
                let n = clampInt(a.int("repeat"), default: 1, min: 1, max: 1000)
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
                let amount = Int32(clampInt(a.int("amount"), default: 5, min: 0, max: 10000))
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
                    let map = try windowMapping(pid: app.pid, windowId: nil, maxWidth: nil)
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
                    "format": prop("string", "Screenshot format: png (default) or jpeg (smaller)."),
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
                // Fixed maxWidth (not caller-tunable) so a screenshot and its follow-up clicks
                // always share the same pixel→point scale.
                let map = try windowMapping(
                    pid: app.pid, windowId: a.int("windowId"), maxWidth: defaultMaxWidth)
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
                    let jpeg = isJPEG(a.string("format"))
                    let png = try ScreenCapture.capturePNG(
                        windowID: map.windowId, pixelWidth: map.pixelWidth,
                        pixelHeight: map.pixelHeight, jpeg: jpeg)
                    let caption =
                        "Window \(map.windowId) of \(app.name): image is "
                        + "\(map.pixelWidth)×\(map.pixelHeight)px (window "
                        + "\(Int(map.bounds.width))×\(Int(map.bounds.height))pt at "
                        + "(\(Int(map.origin.x)),\(Int(map.origin.y)))). "
                        + "Click coordinates are PIXELS within this image."
                    return .image(
                        base64: png.base64EncodedString(),
                        mimeType: jpeg ? "image/jpeg" : "image/png", caption: caption)
                case "left_click", "right_click", "double_click":
                    try ensureAXTrust()
                    let p = try globalPoint()
                    // Single left-click: prefer a semantic AXPress at the point (no app
                    // activation / focus steal); fall back to a synthetic click otherwise.
                    if action == "left_click", AXController.pressElementAt(p) {
                        return .text(
                            "Pressed element at pixel (\(a.int("x") ?? 0),\(a.int("y") ?? 0)) "
                                + "(no focus change).")
                    }
                    let button: MouseButton = action == "right_click" ? .right : .left
                    let clicks = action == "double_click" ? 2 : 1
                    try InputControl.click(
                        pid: app.pid, at: p, button: button, clicks: clicks, flags: [])
                    return .text("\(action) at pixel (\(a.int("x") ?? 0),\(a.int("y") ?? 0)).")
                case "type":
                    try ensureAXTrust()
                    try InputControl.typeText(pid: app.pid, try checkedText(a.requiredString("text")))
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
                    let amount = Int32(clampInt(a.int("amount"), default: 5, min: 0, max: 10000))
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

        registry.register(
            ToolSpec(
                name: "mac_menu",
                description:
                    "Invoke a granted app's menu-bar item by title path, e.g. path "
                    + "[\"Playback\",\"Next\"]. WORKS IN THE BACKGROUND — an app's menu bar stays "
                    + "accessible while it isn't focused, so this is the reliable way to control a "
                    + "backgrounded Electron app (Spotify, Lark) whose in-window UI is hidden. Omit "
                    + "'path' to list top-level menus; pass one title to list that menu's items; "
                    + "pass the full path to invoke it. Full-tier.",
                inputSchema: schema([
                    "bundleId": prop("string", "Target app bundle id."),
                    "pid": prop("integer", "Target app process id."),
                    "path": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": .string(
                            "Menu title path, e.g. [\"Playback\",\"Next\"]. Omit to list top "
                                + "menus; one title lists that menu's items; full path invokes it."),
                    ],
                ])
            ) { [self] raw in
                let a = Args(raw)
                let app = try requireFull(a)
                try ensureAXTrust()
                let path = (a.array("path") ?? []).compactMap { $0.stringValue }
                switch path.count {
                case 0:
                    return .text(jsonText(try MenuControl.list(pid: app.pid, under: nil)))
                case 1:
                    return .text(jsonText(try MenuControl.list(pid: app.pid, under: path[0])))
                default:
                    return .text(try MenuControl.select(pid: app.pid, path: path))
                }
            })
    }

    // MARK: - Network tier (Full) — metadata only (Phase 4a)

    private func registerNetworkTier() {
        registry.register(
            ToolSpec(
                name: "mac_read_network",
                description:
                    "Current network connections of a granted app (remote host/port/state) via "
                    + "lsof — the 'what is this app talking to' view. Works on every app including "
                    + "cert-pinned ones (Lark/Slack). Connection metadata only — request/response "
                    + "BODIES are out of scope (would need a transparent-proxy system extension + "
                    + "trusted CA). Full-tier.",
                inputSchema: schema([
                    "bundleId": prop("string", "Target app bundle id."),
                    "pid": prop("integer", "Target app process id."),
                    "remoteHostContains": prop(
                        "string", "Only connections whose remote host contains this substring."),
                    "limit": prop("integer", "Max connections returned. Default 100."),
                ])
            ) { [self] raw in
                let a = Args(raw)
                let app = try requireFull(a)
                let result = try NetworkMonitor.connections(pid: app.pid)
                var conns = result["connections"]?.arrayValue ?? []
                if let needle = a.string("remoteHostContains")?.lowercased(), !needle.isEmpty {
                    conns = conns.filter {
                        ($0["remoteHost"]?.stringValue ?? "").lowercased().contains(needle)
                    }
                }
                let limit = clampInt(a.int("limit"), default: 100, min: 0, max: 5000)
                if conns.count > limit { conns = Array(conns.prefix(limit)) }
                return .text(
                    jsonText([
                        "app": .string(app.bundleId ?? app.name),
                        "pid": .int(app.pid),
                        "mode": .string("metadata"),
                        "note": .string(
                            "Connection metadata only (no bodies). Body capture is out of scope "
                                + "(would need a transparent-proxy system extension + trusted CA)."),
                        "count": .int(conns.count),
                        "connections": .array(conns),
                    ]))
            })
    }

    /// Clamp an optional Int argument into a safe range — defends against hostile/out-of-range
    /// values arriving over the IPC (negative limits, huge counts) that could crash the agent
    /// (e.g. Array.prefix(-1), Int32 overflow) or starve the work queue.
    private func clampInt(_ v: Int?, default d: Int, min lo: Int, max hi: Int) -> Int {
        Swift.max(lo, Swift.min(hi, v ?? d))
    }

    private static let maxTextLength = 100_000
    private func checkedText(_ s: String) throws -> String {
        guard s.count <= Self.maxTextLength else {
            throw ToolError("text too long (max \(Self.maxTextLength) characters).")
        }
        return s
    }

    // MARK: - Flow tier (Full): wait + batch

    private func registerFlowTier() {
        registry.register(
            ToolSpec(
                name: "mac_wait_for",
                description:
                    "Wait until an element matching 'query' (and optional 'role') appears in a "
                    + "granted app, then return it. Set absent=true to wait until it DISAPPEARS. "
                    + "Polls up to 'timeout' seconds (default 10, max 60). Full-tier.",
                inputSchema: schema([
                    "bundleId": prop("string", "Target app bundle id."),
                    "pid": prop("integer", "Target app process id."),
                    "query": prop("string", "Substring to wait for (required)."),
                    "role": prop("string", "Restrict to an AX role (e.g. AXButton)."),
                    "timeout": prop("number", "Max seconds to wait. Default 10, max 60."),
                    "absent": prop("boolean", "Wait until it disappears instead. Default false."),
                ])
            ) { [self] raw in
                let a = Args(raw)
                let app = try requireFull(a)
                try ensureAXTrust()
                let query = try a.requiredString("query")
                let absent = a.bool("absent") ?? false
                let timeout = min(60.0, max(0.5, a.double("timeout") ?? 10.0))
                if waitFor(
                    pid: app.pid, query: query, role: a.string("role"), absent: absent,
                    timeout: timeout)
                {
                    return .text("\(absent ? "Gone" : "Found"): \"\(query)\" in \(app.name).")
                }
                return .failure(
                    "Timed out after \(Int(timeout))s waiting for \"\(query)\" to "
                        + "\(absent ? "disappear" : "appear") in \(app.name).")
            })

        registry.register(
            ToolSpec(
                name: "mac_do",
                description:
                    "Run a sequence of UI steps on a granted app in ONE call (fewer round-trips). "
                    + "'steps' is an array; each item has a 'do': click {query|ref|x,y}, type "
                    + "{text, ref?, submit?}, key {combo}, scroll {direction, amount?}, wait "
                    + "{query, timeout?, absent?}, delay {ms}. Stops at the first failing step. "
                    + "Full-tier.",
                inputSchema: schema([
                    "bundleId": prop("string", "Target app bundle id."),
                    "pid": prop("integer", "Target app process id."),
                    "steps": [
                        "type": "array", "items": ["type": "object"],
                        "description": .string(
                            "Ordered step objects, e.g. [{\"do\":\"click\",\"query\":\"File\"},"
                                + "{\"do\":\"wait\",\"query\":\"Save\"},{\"do\":\"click\",\"query\":"
                                + "\"Save\"}]."),
                    ],
                ])
            ) { [self] raw in
                let a = Args(raw)
                let app = try requireFull(a)
                try ensureAXTrust()
                let steps = a.array("steps") ?? []
                var results: [String] = []
                for (i, stepV) in steps.enumerated() {
                    let s = Args(stepV)
                    let kind = s.string("do") ?? "?"
                    do {
                        results.append("[\(i)] \(kind): \(try performStep(app: app, s: s))")
                    } catch {
                        results.append("[\(i)] \(kind): FAILED — \(String(describing: error))")
                        return .text(
                            "Ran \(i)/\(steps.count) steps on \(app.name):\n"
                                + results.joined(separator: "\n"))
                    }
                }
                return .text(
                    "Ran all \(steps.count) steps on \(app.name):\n"
                        + results.joined(separator: "\n"))
            })
    }

    /// Shared click logic (mac_click + mac_do 'click' step): resolve the target from query / ref /
    /// coordinate; single left-clicks invoke via Accessibility (no activation), else synthetic.
    private func doClick(app: AppRecord, a: Args) throws -> String {
        let button = mouseButton(a.string("button"))
        let clicks = clampInt(a.int("clicks"), default: 1, min: 1, max: 3)
        var ref = a.string("ref")
        if (ref?.isEmpty ?? true), let query = a.string("query"), !query.isEmpty {
            ref = try AXController.firstMatchRef(pid: app.pid, query: query, role: a.string("role"))
            if ref == nil { throw ToolError("No element matching \"\(query)\" in \(app.name).") }
        }
        if let ref, !ref.isEmpty {
            if case .left = button, clicks == 1,
                (try? AXController.press(ref: ref, pid: app.pid)) == true
            {
                return "pressed \(ref)"
            }
            guard let frame = AXController.frame(ref: ref, pid: app.pid) else {
                throw ToolError("Ref \(ref) has no press action and no frame — re-read the UI.")
            }
            let c = CGPoint(x: frame.midX, y: frame.midY)
            if case .left = button, clicks == 1, AXController.pressElementAt(c) {
                return "pressed \(ref) (no focus change)"
            }
            try InputControl.click(pid: app.pid, at: c, button: button, clicks: clicks, flags: [])
            return "clicked \(ref)"
        }
        if let x = a.double("x"), let y = a.double("y") {
            let p = CGPoint(x: x, y: y)
            if case .left = button, clicks == 1, AXController.pressElementAt(p) {
                return "pressed (\(Int(x)),\(Int(y))) (no focus change)"
            }
            try InputControl.click(pid: app.pid, at: p, button: button, clicks: clicks, flags: [])
            return "clicked (\(Int(x)),\(Int(y)))"
        }
        throw ToolError("Provide 'query', 'ref', or both 'x' and 'y'.")
    }

    /// Poll until `query` (optionally filtered by `role`) is present (or absent) in `pid`, or
    /// the timeout elapses.
    private func waitFor(pid: Int, query: String, role: String?, absent: Bool, timeout: Double)
        -> Bool
    {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let present =
                ((try? AXController.firstMatchRef(pid: pid, query: query, role: role)) ?? nil)
                != nil
            if present != absent { return true }
            usleep(300_000)
        } while Date() < deadline
        return false
    }

    /// Execute one mac_do step against `app`.
    private func performStep(app: AppRecord, s: Args) throws -> String {
        switch (s.string("do") ?? "").lowercased() {
        case "click":
            return try doClick(app: app, a: s)
        case "type":
            let text = try checkedText(s.requiredString("text"))
            if let ref = s.string("ref"),
                (try? AXController.setValue(ref: ref, pid: app.pid, text)) == true
            {
                // value set directly via Accessibility
            } else {
                if let ref = s.string("ref") { try? AXController.focus(ref: ref, pid: app.pid) }
                try InputControl.typeText(pid: app.pid, text)
            }
            if s.bool("submit") == true { try InputControl.pressKey(pid: app.pid, combo: "return") }
            return "typed \(text.count) chars"
        case "key":
            let combo = try s.requiredString("combo")
            try InputControl.pressKey(pid: app.pid, combo: combo)
            return "pressed \(combo)"
        case "scroll":
            let amount = Int32(clampInt(s.int("amount"), default: 5, min: 0, max: 10000))
            var dx: Int32 = 0
            var dy: Int32 = 0
            switch (s.string("direction") ?? "down").lowercased() {
            case "up": dy = amount
            case "left": dx = amount
            case "right": dx = -amount
            default: dy = -amount
            }
            let map = try windowMapping(pid: app.pid, windowId: nil, maxWidth: nil)
            try InputControl.scroll(
                pid: app.pid, at: CGPoint(x: map.bounds.midX, y: map.bounds.midY), dx: dx, dy: dy)
            return "scrolled"
        case "wait":
            let query = try s.requiredString("query")
            let absent = s.bool("absent") ?? false
            let timeout = min(60.0, max(0.5, s.double("timeout") ?? 10.0))
            if waitFor(
                pid: app.pid, query: query, role: s.string("role"), absent: absent, timeout: timeout)
            {
                return "\(absent ? "gone" : "found") \"\(query)\""
            }
            throw ToolError("wait timed out for \"\(query)\"")
        case "delay":
            let ms = clampInt(s.int("ms"), default: 200, min: 0, max: 10000)
            usleep(useconds_t(ms) * 1000)
            return "delayed \(ms)ms"
        case let other:
            throw ToolError("unknown step '\(other)' — use click/type/key/scroll/wait/delay")
        }
    }

    private func mouseButton(_ s: String?) -> MouseButton {
        switch (s ?? "left").lowercased() {
        case "right": return .right
        case "center", "middle": return .center
        default: return .left
        }
    }

    private let defaultMaxWidth = 1400

    private func isJPEG(_ format: String?) -> Bool {
        let f = (format ?? "png").lowercased()
        return f == "jpeg" || f == "jpg"
    }

    /// Resolve the target window plus the capture geometry. `scale` is the effective
    /// pixels-per-point of the returned image (= min(backingScale, maxWidth/pointWidth) when a
    /// `maxWidth` is given), and `pixelWidth/Height` are the exact capture dimensions. The SAME
    /// `scale` is used to map mac_computer screenshot pixels → global points, so downscaling
    /// stays click-accurate. Selecting by `windowId` is pid-scoped (only the app's own windows),
    /// which also enforces the screenshot-ownership rule.
    /// NB: backing scale uses the main display; multi-display mixed-scale is a known v1 limit.
    private func windowMapping(pid: Int, windowId: Int?, maxWidth: Int?)
        throws -> (
            origin: CGPoint, scale: CGFloat, windowId: Int, bounds: CGRect, pixelWidth: Int,
            pixelHeight: Int
        )
    {
        let wins = inventory.windows(forPID: pid)
        let win: WindowRecord
        if let windowId {
            guard let w = wins.first(where: { $0.windowId == windowId }) else {
                throw ToolError(
                    "Window \(windowId) isn't an on-screen window of pid \(pid). It may belong to "
                        + "another app, or be minimized / on another Space — bring the app forward "
                        + "or switch to its Space, then retry.")
            }
            win = w
        } else {
            guard
                let w = wins.filter({
                    $0.isOnscreen && $0.layer == 0 && $0.bounds.width > 1 && $0.bounds.height > 1
                }).max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
            else {
                throw ToolError(
                    "No on-screen window for pid \(pid) — the app may be minimized or on another "
                        + "Space (bring it forward / switch Spaces). Note Electron apps also drop "
                        + "their window content when not focused.")
            }
            win = w
        }
        let backing = backingScale(forWindowBounds: win.bounds)
        let pointW = max(1, win.bounds.width)
        let scale: CGFloat = maxWidth.map { min(backing, CGFloat($0) / pointW) } ?? backing
        let pw = max(1, Int((win.bounds.width * scale).rounded()))
        let ph = max(1, Int((win.bounds.height * scale).rounded()))
        return (win.bounds.origin, scale, win.windowId, win.bounds, pw, ph)
    }

    /// Backing scale of the display the window actually sits on. CGWindowList bounds are global
    /// top-left points; NSScreen frames are bottom-left, so flip through the primary screen's
    /// height to find the containing screen (fixes click/scale accuracy on multi-monitor setups).
    private func backingScale(forWindowBounds bounds: CGRect) -> CGFloat {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return 2.0 }
        let primaryHeight = primary.frame.height
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        for screen in screens {
            let f = screen.frame
            let topLeft = CGRect(
                x: f.origin.x, y: primaryHeight - (f.origin.y + f.height),
                width: f.width, height: f.height)
            if topLeft.contains(center) { return screen.backingScaleFactor }
        }
        return primary.backingScaleFactor
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
