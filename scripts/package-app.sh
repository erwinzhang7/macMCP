#!/usr/bin/env bash
# Build, assemble, and code-sign the macMCP menu-bar app bundle.
#
# Signing matters here: macOS TCC ties Accessibility/Screen Recording grants to the app's
# code signature. Set MACMCP_SIGN_IDENTITY to a STABLE identity (e.g. an Apple Development or
# Developer ID cert) so you approve permissions ONCE; the ad-hoc default ("-") gets a
# fresh identity each rebuild and can require re-approval.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/macMCP.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
INFO="$ROOT/Packaging/Info.plist"
IDENTITY="${MACMCP_SIGN_IDENTITY:--}"
SWIFT_BUILD_FLAGS=(
	--disable-sandbox
	--cache-path "$ROOT/.build/swiftpm-cache"
	--config-path "$ROOT/.build/swiftpm-config"
	--security-path "$ROOT/.build/swiftpm-security"
	--manifest-cache local
)
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/module-cache}"

cd "$ROOT"

echo "==> Building macMCP release binaries..."
swift build "${SWIFT_BUILD_FLAGS[@]}" -c release
BIN_DIR="$(swift build "${SWIFT_BUILD_FLAGS[@]}" -c release --show-bin-path)"
AGENT="$BIN_DIR/macmcp-agent"

if [[ ! -x "$AGENT" ]]; then
	echo "error: missing built agent binary: $AGENT" >&2
	exit 1
fi

echo "==> Assembling macMCP.app..."
rm -rf "$APP"
install -d "$MACOS"
install -m 755 "$AGENT" "$MACOS/macmcp-agent"
install -m 644 "$INFO" "$CONTENTS/Info.plist"

echo "==> Signing macMCP.app with '$IDENTITY' (hardened runtime)..."
codesign --force --options runtime \
	--sign "$IDENTITY" \
	--entitlements Packaging/macMCP.entitlements \
	macMCP.app
codesign --display --verbose=2 macMCP.app 2>&1 | sed -n '1,4p' || true

echo
echo "==> Built: $APP"
