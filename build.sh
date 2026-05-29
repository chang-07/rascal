#!/usr/bin/env bash
# Builds FinderTwo and assembles a runnable .app bundle.
# Usage: ./build.sh [debug|release]   (default: debug)
set -euo pipefail

CONFIG=${1:-debug}
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT/build/FinderTwo.app"
SWIFT_BUILD_DIR="$ROOT/.build/$CONFIG"

cd "$ROOT"

echo "→ Building Swift package ($CONFIG)..."
swift build -c "$CONFIG"

BIN="$SWIFT_BUILD_DIR/FinderTwo"
if [[ ! -x "$BIN" ]]; then
    # SwiftPM puts release binaries under .build/release, arch-specific subdirs sometimes:
    BIN=$(find "$ROOT/.build" -type f -name FinderTwo -perm +111 | head -n1)
fi
if [[ -z "${BIN:-}" || ! -x "$BIN" ]]; then
    echo "✗ Could not locate built FinderTwo binary"
    exit 1
fi

echo "→ Assembling .app bundle at $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/FinderTwo"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

# Ad-hoc sign so the binary can run from a bundle without quarantine pain
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "✓ Built $APP_DIR"
