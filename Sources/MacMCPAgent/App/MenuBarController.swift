import AppKit
import MacMCPCore

/// The menu-bar UI: a status item whose menu lists running apps with a per-app None/Full
/// toggle, the set of granted apps (with revoke), and the macOS permission status. This is
/// the control center the user manages access from — the locked design's "lives in the menu
/// bar for perms per app".
///
/// Toggling an app to Full *from the menu* is a legitimate user grant (no dialog needed,
/// since the click itself is the consent). The native dialog only appears when Claude tries
/// to act on a not-yet-granted app.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let core: AgentCore
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    init(core: AgentCore) {
        self.core = core
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "macwindow.on.rectangle",
                accessibilityDescription: "macMCP")
            button.toolTip = "macMCP — app control permissions"
        }
        menu.delegate = self
        statusItem.menu = menu
    }

    // Rebuild the menu each time it opens so app lists / tiers / permission status are live.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        addHeader("macMCP")

        // macOS permission status.
        addStatus(
            "Accessibility", granted: AXController.isTrusted(),
            action: #selector(openAccessibilitySettings))
        addStatus(
            "Screen Recording", granted: ScreenCapture.hasPermission(),
            action: #selector(openScreenRecordingSettings))

        menu.addItem(.separator())

        // Granted apps (Full tier), with revoke.
        let grants = core.permissions.allJSON().objectValue ?? [:]
        if grants.isEmpty {
            addDisabled("No apps granted")
        } else {
            addDisabled("Granted apps (click to revoke)")
            for (key, rec) in grants.sorted(by: { ($0.value["name"]?.stringValue ?? $0.key) < ($1.value["name"]?.stringValue ?? $1.key) }) {
                let name = rec["name"]?.stringValue ?? key
                let item = NSMenuItem(
                    title: "✓ \(name)", action: #selector(revokeApp(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = key
                item.toolTip = key
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        // Running apps with a None/Full toggle (checkmark = Full).
        addDisabled("Running apps (click to toggle Full)")
        for app in core.inventory.runningApps(includeBackground: false) {
            let item = NSMenuItem(
                title: app.name, action: #selector(toggleApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app.gateKey
            item.state = core.permissions.tier(for: app.gateKey) == .full ? .on : .off
            item.toolTip = app.bundleId ?? app.gateKey
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit macMCP", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func toggleApp(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        if core.permissions.tier(for: key) == .full {
            core.permissions.revoke(key: key)
        } else {
            // Resolve the live app for name + Team ID so a menu grant matches a dialog grant.
            let app = core.inventory.runningApps(includeBackground: true).first { $0.gateKey == key }
            let teamID = app?.bundlePath.flatMap { core.inventory.teamID(forBundlePath: $0) }
            core.permissions.grantFull(
                key: key, name: app?.name ?? key, teamID: teamID, bundlePath: app?.bundlePath)
        }
    }

    @objc private func revokeApp(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        core.permissions.revoke(key: key)
    }

    @objc private func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @objc private func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Builders

    private func addHeader(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        let font = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        item.attributedTitle = NSAttributedString(string: title, attributes: [.font: font])
        menu.addItem(item)
    }

    private func addDisabled(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addStatus(_ name: String, granted: Bool, action: Selector) {
        let item = NSMenuItem(
            title: "\(granted ? "🟢" : "🔴") \(name): \(granted ? "granted" : "not granted — open settings")",
            action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }
}
