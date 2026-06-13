import AppKit
import CoreGraphics
import Foundation
import MacMCPCore
import Security

/// A running application, identified for gating by bundle id.
struct AppRecord {
    let bundleId: String?
    let name: String
    let pid: Int
    let isActive: Bool
    let isHidden: Bool
    let activationPolicy: String  // "regular" | "accessory" | "prohibited"
    let bundlePath: String?

    /// The key the permission model gates on. Falls back to the bundle path when an app has
    /// no bundle id (CLI tools, some Electron helpers) so such apps are still gateable.
    var gateKey: String { bundleId ?? bundlePath.map { "path:" + $0 } ?? "pid:\(pid)" }

    func toJSON(extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = [
            "name": .string(name),
            "pid": .int(pid),
            "isActive": .bool(isActive),
            "isHidden": .bool(isHidden),
            "activationPolicy": .string(activationPolicy),
        ]
        if let bundleId { o["bundleId"] = .string(bundleId) }
        if let bundlePath { o["bundlePath"] = .string(bundlePath) }
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }
}

/// One on-screen (or off-screen) window owned by some app. Title + geometry are exposed at
/// the default permission tier; pixels are not.
struct WindowRecord {
    let windowId: Int
    let title: String
    let ownerPID: Int
    let bounds: CGRect
    let isOnscreen: Bool
    let layer: Int

    func toJSON() -> JSONValue {
        [
            "windowId": .int(windowId),
            "title": .string(title),
            "ownerPID": .int(ownerPID),
            "bounds": [
                "x": .double(bounds.origin.x), "y": .double(bounds.origin.y),
                "width": .double(bounds.size.width), "height": .double(bounds.size.height),
            ],
            "isOnscreen": .bool(isOnscreen),
            "layer": .int(layer),
        ]
    }
}

/// Enumerates running apps (NSWorkspace) and their windows (CGWindowList). Needs no TCC
/// permission — this is the data the default ("none") tier is allowed to expose. NSWorkspace
/// is AppKit, so the agent runs as a real app process (not a launchd daemon).
final class AppInventory {
    func runningApps(includeBackground: Bool = false) -> [AppRecord] {
        NSWorkspace.shared.runningApplications.compactMap { app -> AppRecord? in
            let policy = policyString(app.activationPolicy)
            if !includeBackground && app.activationPolicy != .regular { return nil }
            return AppRecord(
                bundleId: app.bundleIdentifier,
                name: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)",
                pid: Int(app.processIdentifier),
                isActive: app.isActive,
                isHidden: app.isHidden,
                activationPolicy: policy,
                bundlePath: app.bundleURL?.path)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func frontmostBundleId() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    func frontmostPID() -> Int? {
        NSWorkspace.shared.frontmostApplication.map { Int($0.processIdentifier) }
    }

    /// Resolve a tool's target app from `bundleId` (preferred) or `pid`. For multi-process
    /// (Electron) apps, prefer the regular-activation-policy instance that owns the UI.
    func resolve(_ args: Args) throws -> AppRecord {
        if let bundleId = args.string("bundleId") {
            let matches = NSWorkspace.shared.runningApplications.filter {
                $0.bundleIdentifier == bundleId
            }
            guard !matches.isEmpty else {
                throw ToolError("No running app with bundle id '\(bundleId)'.")
            }
            let chosen = matches.first(where: { $0.activationPolicy == .regular }) ?? matches[0]
            return record(for: chosen)
        }
        if let pid = args.int("pid") {
            guard let app = NSRunningApplication(processIdentifier: pid_t(pid)) else {
                throw ToolError("No running app with pid \(pid).")
            }
            return record(for: app)
        }
        throw ToolError("Specify a target app via 'bundleId' or 'pid'.")
    }

    func windows(forPID pid: Int) -> [WindowRecord] {
        allWindows().filter { $0.ownerPID == pid }
    }

    func allWindows() -> [WindowRecord] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard
            let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return raw.compactMap { info -> WindowRecord? in
            guard let number = info[kCGWindowNumber as String] as? Int,
                let pid = info[kCGWindowOwnerPID as String] as? Int
            else { return nil }
            let title = (info[kCGWindowName as String] as? String) ?? ""
            let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
            let onscreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
            var rect = CGRect.zero
            if let b = info[kCGWindowBounds as String] as? [String: Any] {
                rect = CGRect(
                    x: (b["X"] as? Double) ?? 0, y: (b["Y"] as? Double) ?? 0,
                    width: (b["Width"] as? Double) ?? 0, height: (b["Height"] as? Double) ?? 0)
            }
            return WindowRecord(
                windowId: number, title: title, ownerPID: pid,
                bounds: rect, isOnscreen: onscreen, layer: layer)
        }
    }

    /// The signing Team ID of an app bundle, used by the permission gate to detect bundle-id
    /// squatting (a stored grant is invalidated if the running app's Team ID no longer matches).
    func teamID(forBundlePath path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
            let code = staticCode
        else { return nil }
        var info: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
            let dict = info as? [String: Any]
        else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    // MARK: - Internals

    private func record(for app: NSRunningApplication) -> AppRecord {
        AppRecord(
            bundleId: app.bundleIdentifier,
            name: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)",
            pid: Int(app.processIdentifier),
            isActive: app.isActive,
            isHidden: app.isHidden,
            activationPolicy: policyString(app.activationPolicy),
            bundlePath: app.bundleURL?.path)
    }

    private func policyString(_ p: NSApplication.ActivationPolicy) -> String {
        switch p {
        case .regular: return "regular"
        case .accessory: return "accessory"
        case .prohibited: return "prohibited"
        @unknown default: return "unknown"
        }
    }
}
