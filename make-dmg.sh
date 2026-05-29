#!/usr/bin/env bash
# make-dmg.sh — package Rascal.app into a distributable, drag-to-install .dmg.
#
# Usage:  ./make-dmg.sh
# Output: build/Rascal.dmg
#
# Then publish it so the landing page's "Download Rascal.dmg" button works:
#   gh release create v0.1.0 build/Rascal.dmg --title "Rascal 0.1.0" --notes "…"
#   # or upload to an existing release; the site points at
#   #   github.com/<you>/finder-2/releases/latest/download/Rascal.dmg
#
# Uses only hdiutil (ships with macOS) — no tools to install, no cost.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Rascal.app"
DMG="$ROOT/build/Rascal.dmg"
VOL="Rascal"

# Build a fresh release bundle if one isn't present.
if [[ ! -d "$APP" ]]; then
    echo "→ No build/Rascal.app yet — building release…"
    "$ROOT/build.sh" release >/dev/null
fi

echo "→ Staging disk image contents…"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/Rascal.app"
ln -s /Applications "$STAGE/Applications"          # drag Rascal → Applications

echo "→ Building $DMG…"
rm -f "$DMG"
hdiutil create \
    -volname "$VOL" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG" >/dev/null

SIZE=$(du -h "$DMG" | cut -f1)
echo "✓ Built $DMG ($SIZE)"
echo "  Publish it to a GitHub release named so the URL ends in /Rascal.dmg."
