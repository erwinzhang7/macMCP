import AppKit
import MacMCPCore

// The macMCP agent: the persistent menu-bar process that owns the per-app permission
// allowlist, the macOS TCC grants, the work layer, and (Phase 4) the network extension. It
// serves tool calls to every shim over a unix-domain socket.
//
// Runs as an accessory app (menu bar only, no Dock icon). The socket server runs on its own
// background threads, so the AppKit run loop drives the menu bar while tools execute.

logPrefix = "[macmcp-agent]"
AgentPaths.ensureSupportDir()

let core = AgentCore()
core.start()  // single-instance guard + bind socket (exits if another agent is live)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // menu-bar only, no Dock icon
let menuBar = MenuBarController(core: core)
_ = menuBar  // retained for the process lifetime
app.run()
