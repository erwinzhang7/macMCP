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

All shipped (14 tools), each verified live:

- **Phase 1 ✅** — shim + agent + unix-socket IPC + default-tier tools (`mac_list_apps`,
  `mac_app_info`, `mac_list_windows`, `mac_permissions`, `mac_network_status`).
- **Phase 2 ✅** — screenshot (ScreenCaptureKit) + AX read + permission gate + menu-bar UI
  (`mac_screenshot`, `mac_read_ui`, `mac_find_element`).
- **Phase 3 ✅** — input/control via CGEvent + screenshot-coordinate fallback
  (`mac_click`, `mac_type`, `mac_scroll`, `mac_key`, `mac_computer`).
- **Phase 4 ✅** — per-app network **metadata** via `lsof` (`mac_read_network`): remote
  host/port/state, works on every app including cert-pinned ones.

Network **body** capture (decrypting request/response payloads) is intentionally out of scope:
it would require a transparent-proxy system extension + a trusted root CA, which needs a paid
Apple Developer Network Extension provision and still fails against cert-pinned apps. macMCP
stops at connection metadata.

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

## Security model

The agent gates every Full-tier capability per app (bundle id), fails closed on identity
mismatch (signing Team ID, or canonical path for unsigned apps), and only ever screenshots a
granted app's *own* windows. Grants happen solely via the native prompt or the menu bar —
Claude can never self-grant. The agent socket and allowlist live in an owner-only (`0700`)
directory; note that, as with any same-user agent, another process running **as you** can use
the socket, so treat the granted set like any local capability you hold.

## Requirements

macOS 14+. No third-party dependencies; no paid Apple Developer account required.

## License

Licensed under the Apache License, Version 2.0 — see [LICENSE](LICENSE).

Copyright © 2026 Erwin Zhang.
