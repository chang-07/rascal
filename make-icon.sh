#!/usr/bin/env bash
# Regenerate Resources/AppIcon.icns from Resources/AppIcon.svg.
# Rasterizes the SVG at every required size with a TRANSPARENT background
# (AppKit/NSImage), assembles an .iconset, then packs it with iconutil.
#
# Why this exists: the original .icns was flattened onto a white square, so
# macOS drew a white tile with the squircle shrunk inside it. Rendering onto a
# clear context keeps the area outside the rounded-rect transparent.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SVG="$ROOT/Resources/AppIcon.svg"
ICNS="$ROOT/Resources/AppIcon.icns"
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"

RENDER="$(mktemp -t rendericon).swift"
cat > "$RENDER" <<'SWIFT'
import AppKit
let a = CommandLine.arguments
guard a.count == 4, let size = Int(a[2]) else { exit(2) }
guard let img = NSImage(contentsOf: URL(fileURLWithPath: a[1])), img.isValid else {
    fputs("NSImage failed to load SVG\n", stderr); exit(3)
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
ctx.imageInterpolation = .high
NSGraphicsContext.current = ctx
NSColor.clear.set()
NSRect(x: 0, y: 0, width: size, height: size).fill()
img.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
         from: NSRect(origin: .zero, size: img.size),
         operation: .sourceOver, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[3]))
SWIFT

render() { swift "$RENDER" "$SVG" "$1" "$2"; }

render 16   "$SET/icon_16x16.png"
render 32   "$SET/icon_16x16@2x.png"
render 32   "$SET/icon_32x32.png"
render 64   "$SET/icon_32x32@2x.png"
render 128  "$SET/icon_128x128.png"
render 256  "$SET/icon_128x128@2x.png"
render 256  "$SET/icon_256x256.png"
render 512  "$SET/icon_256x256@2x.png"
render 512  "$SET/icon_512x512.png"
render 1024 "$SET/icon_512x512@2x.png"

iconutil -c icns "$SET" -o "$ICNS"
echo "✓ wrote $ICNS ($(stat -f%z "$ICNS") bytes)"
