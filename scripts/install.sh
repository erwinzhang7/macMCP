#!/usr/bin/env bash
# Install macMCP.app and register the release shim with Claude Code.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/macMCP.app"
DEST="/Applications/macMCP.app"
SWIFT_BUILD_FLAGS=(
	--disable-sandbox
	--cache-path "$ROOT/.build/swiftpm-cache"
	--config-path "$ROOT/.build/swiftpm-config"
	--security-path "$ROOT/.build/swiftpm-security"
	--manifest-cache local
)
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/module-cache}"

cd "$ROOT"

"$ROOT/scripts/package-app.sh"

echo "==> Installing macMCP.app to /Applications..."
rm -rf "$DEST"
ditto "$APP" "$DEST"

echo "==> Building release shim..."
swift build "${SWIFT_BUILD_FLAGS[@]}" -c release
BIN_DIR="$(swift build "${SWIFT_BUILD_FLAGS[@]}" -c release --show-bin-path)"
SHIM="$BIN_DIR/macmcp"

if [[ ! -x "$SHIM" ]]; then
	echo "error: missing built shim binary: $SHIM" >&2
	exit 1
fi

echo "==> Ad-hoc signing shim..."
codesign --force --options runtime --sign - "$SHIM"

echo "==> Registering macmcp MCP server with Claude Code..."
claude mcp add macmcp --scope user -- "$SHIM"

cat <<EOF

Installed:
  App:  $DEST
  Shim: $SHIM

Next:
  1. Grant Accessibility to "macMCP" in System Settings.
  2. Grant Screen Recording to "macMCP" in System Settings.
  3. Restart your MCP client.
EOF
