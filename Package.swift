// swift-tools-version: 6.0
import PackageDescription

// Native, dependency-free MCP for controlling any macOS app. Sister project to safari-mcp.
// Only macOS system frameworks (Foundation, AppKit, CoreGraphics, ApplicationServices,
// ScreenCaptureKit, Network). Two executables share one core library:
//   • macmcp        — the thin stdio MCP shim Claude Code launches (forwards to the agent)
//   • macmcp-agent  — the persistent menu-bar agent that holds permissions and does the work
let package = Package(
    name: "macMCP",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "macmcp", targets: ["MacMCPShim"]),
        .executable(name: "macmcp-agent", targets: ["MacMCPAgent"]),
    ],
    targets: [
        // Shared, framework-light core: JSON-RPC/MCP types + IPC primitives.
        // Foundation-only on purpose so the shim never pulls AppKit/ScreenCaptureKit.
        .target(
            name: "MacMCPCore",
            path: "Sources/MacMCPCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The shim: MCP over stdio → forwards tool calls to the agent over a unix socket.
        .executableTarget(
            name: "MacMCPShim",
            dependencies: ["MacMCPCore"],
            path: "Sources/MacMCPShim",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The agent: unix-socket server + the actual macOS work layer + menu-bar UI.
        .executableTarget(
            name: "MacMCPAgent",
            dependencies: ["MacMCPCore"],
            path: "Sources/MacMCPAgent",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
