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
                + "click / type / scroll, and capture its network traffic.\n\n"
                + "App: \(app.bundleId ?? app.name)"
            if let teamID { info += "\nSigned by Team ID: \(teamID)" }
            info += "\n\nYou can revoke this anytime from the macMCP menu bar."
            alert.informativeText = info
            alert.addButton(withTitle: "Allow")  // .alertFirstButtonReturn
            alert.addButton(withTitle: "Deny")
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
