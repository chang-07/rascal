#!/usr/bin/env bash
# Builds Rascal and assembles a runnable .app bundle.
# Usage: ./build.sh [debug|release]   (default: debug)
set -euo pipefail

CONFIG=${1:-debug}
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT/build/Rascal.app"
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

# Sign the bundle. Prefer a STABLE self-signed identity so macOS remembers the
# privacy permissions you grant (Full Disk Access, Desktop/Documents/Downloads,
# volumes) across rebuilds — ad-hoc signing changes identity every build, which
# makes macOS re-ask every time. Run ./setup-signing.sh once to create it.
SIGN_CN="FinderTwo Local Signing"
SIGN_HASH=$(security find-certificate -c "$SIGN_CN" -Z "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null \
    | awk '/SHA-1 hash:/{print $NF; exit}')
if [[ -n "${SIGN_HASH:-}" ]] && codesign --force --deep --sign "$SIGN_HASH" "$APP_DIR" >/dev/null 2>&1; then
    echo "  signed with stable identity ($SIGN_CN) — permissions persist across rebuilds"
else
    codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
    echo "  ad-hoc signed"
fi

echo "✓ Built $APP_DIR"
