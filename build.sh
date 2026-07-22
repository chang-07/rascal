#!/usr/bin/env bash
# Builds Rascal and assembles a runnable .app bundle.
# Usage: ./build.sh [debug|release]   (default: debug)
set -euo pipefail

CONFIG=${1:-debug}
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT/build/Rascal.app"
SWIFT_SCRATCH_PATH="${SWIFT_SCRATCH_PATH:-$ROOT/.build}"

cd "$ROOT"

# Optional ARCH env selects a target architecture (e.g. ARCH=arm64 or
# ARCH=x86_64); unset builds for the host. Used by make-dmg.sh to cut per-arch
# disk images. Branch explicitly so an empty array never trips `set -u` on
# macOS's stock bash 3.2.
if [[ -n "${ARCH:-}" ]]; then
    echo "→ Building Swift package ($CONFIG, arch=$ARCH)..."
    swift build --disable-sandbox -c "$CONFIG" --product FinderTwo --scratch-path "$SWIFT_SCRATCH_PATH" --arch "$ARCH"
    BIN="$(swift build --disable-sandbox -c "$CONFIG" --product FinderTwo --scratch-path "$SWIFT_SCRATCH_PATH" --arch "$ARCH" --show-bin-path)/FinderTwo"
else
    echo "→ Building Swift package ($CONFIG)..."
    swift build --disable-sandbox -c "$CONFIG" --product FinderTwo --scratch-path "$SWIFT_SCRATCH_PATH"
    BIN="$(swift build --disable-sandbox -c "$CONFIG" --product FinderTwo --scratch-path "$SWIFT_SCRATCH_PATH" --show-bin-path)/FinderTwo"
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
SECURITY_TOOL="${RASCAL_SECURITY_TOOL:-security}"
CERT_OUTPUT=""
if CERT_OUTPUT=$("$SECURITY_TOOL" find-certificate -c "$SIGN_CN" -Z "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null); then
    SIGN_HASH=$(awk '/SHA-1 hash:/{print $NF; exit}' <<<"$CERT_OUTPUT")
else
    SIGN_HASH=""
fi
if [[ -n "$SIGN_HASH" ]]; then
    codesign --force --deep --sign "$SIGN_HASH" "$APP_DIR"
    echo "  signed with stable identity ($SIGN_CN) — permissions persist across rebuilds"
else
    codesign --force --deep --sign - "$APP_DIR"
    echo "  ad-hoc signed"
fi

# Signing is a build invariant, not a best-effort decoration. Keep verbose
# identity details in lane evidence while verifying the assembled bundle.
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
codesign --display --verbose=4 "$APP_DIR"

echo "✓ Built $APP_DIR"
