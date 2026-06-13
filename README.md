# macMCP

Control **any macOS app** from Claude over MCP — enumerate apps, screenshot a window, read
its UI (accessibility tree), click/type/scroll, and watch its network. Sister project to
[safari-mcp](../safari-mcp): same idea, but for native apps (e.g. Lark, Slack) instead of
Safari.

Access is gated by a **per-app, two-level permission model** managed from a menu-bar app:

- **Default ("none")** — Claude may only learn that an app exists, is running, and its window
  titles / frontmost state. No screenshots, no UI content, no input, no network bodies.
- **Full** — everything: screenshot, accessibility tree, click/type/scroll, network capture.

Granting is one click (a native Allow/Deny prompt the first time Claude acts on an app, or a
toggle in the menu bar). Revoking is one click. Claude can never grant itself access.

## Architecture

Two binaries, mirroring safari-mcp's zero-dependency Swift / hand-rolled-JSON-RPC stack:

- **`macmcp`** (shim) — the thin stdio MCP server Claude Code launches per session. Holds no
  permissions; forwards every tool call to the agent over a unix-domain socket.
- **`macmcp-agent`** (agent) — the persistent, signed menu-bar app that owns the macOS TCC
  grants (Accessibility, Screen Recording), the per-app allowlist, the network system
  extension, and the work layer (AX / ScreenCaptureKit / CGEvent). Many shims → one agent.

`MacMCPCore` is the shared, Foundation-only library (MCP types + IPC primitives) so the shim
never pulls AppKit.

## Status

Built in phases (see `PLAN`):

- **Phase 1 ✅** — shim + agent + unix-socket IPC + default-tier tools (`mac_list_apps`,
  `mac_app_info`, `mac_list_windows`, `mac_permissions`, `mac_network_status`).
- **Phase 2** — screenshot (ScreenCaptureKit) + AX read + permission gate + menu-bar UI.
- **Phase 3** — input/control (CGEvent) + coordinate fallback.
- **Phase 4** — network capture via an `NETransparentProxyProvider` system extension.

## Develop

```sh
make build      # swift build (macmcp + macmcp-agent)
make test       # protocol self-test (shim ⇄ agent over the socket)
make package    # release build + signed ./macMCP.app bundle
make install    # install /Applications/macMCP.app + register the release shim with Claude Code
```

The installed app owns macOS TCC grants for Accessibility and Screen Recording. By default
the bundle is ad-hoc signed; set `MACMCP_SIGN_IDENTITY` to a stable code-signing identity
before `make package` or `make install` if you want to grant those permissions once and keep
them across rebuilds.

## Requirements

macOS 14+. Building the network system extension (Phase 4) needs a paid Apple Developer team
with the Network Extension capability.
