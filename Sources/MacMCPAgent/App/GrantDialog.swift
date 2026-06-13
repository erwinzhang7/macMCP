import AppKit
import MacMCPCore

/// The native Allow/Deny prompt shown the first time Claude tries a Full-tier action on an
/// app that hasn't been granted. Because the agent is a real GUI app we use a plain `NSAlert`
/// (cleaner than safari-mcp's AppleScript `display dialog`, which had to borrow Safari's UI).
///
/// Called from the work queue (background); the alert must run modally on the main thread.
enum GrantDialog {
    static func prompt(app: AppRecord, teamID: String?) -> Bool {
        var allow = false
        let show = {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Allow Claude to fully control “\(app.name)”?"
            var info =
                "This lets macMCP screenshot the app, read its accessibility tree, "
                + "click / type / scroll, and read its network connections.\n\n"
                + "App: \(app.bundleId ?? app.name)"
            if let bundlePath = app.bundlePath { info += "\nPath: \(bundlePath)" }
            if let teamID {
                info += "\nSigned by Team ID: \(teamID)"
            } else {
                // No verifiable developer identity — make the human pause.
                info +=
                    "\n\n⚠️ This app has NO verifiable developer signature (Team ID). "
                    + "Only allow it if you are certain you trust this exact app."
            }
            info += "\n\nYou can revoke this anytime from the macMCP menu bar."
            alert.informativeText = info
            alert.addButton(withTitle: "Allow")  // .alertFirstButtonReturn
            let deny = alert.addButton(withTitle: "Deny")
            deny.keyEquivalent = "\u{1b}"  // Esc → Deny
            // Don't let a stray Return auto-grant: clear Allow's default key equivalent.
            alert.buttons.first?.keyEquivalent = ""
            allow = alert.runModal() == .alertFirstButtonReturn
        }
        if Thread.isMainThread {
            show()
        } else {
            DispatchQueue.main.sync(execute: show)
        }
        return allow
    }
}
