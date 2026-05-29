import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Headless capture harness for the landing-page media. Renders real Rascal
/// scenes into PNGs (stills) and GIFs (motion) entirely OFF-SCREEN — it parks
/// an OffscreenSafeWindow far off every display and snapshots the view tree via
/// cacheDisplay, so nothing ever appears on the user's screens.
///
/// Only NON-vibrant, synchronously-rendering scenes are captured (the file
/// browser with the opaque Rascal themes, and the treemap) — vibrancy and
/// QuickLook don't survive an off-screen cacheDisplay.
///
/// Driven by `FT_HEADLESS_TESTING=1 FT_DEMO=<outdir>` (see AppDelegate).
enum DemoShot {

    static func renderAll(to outDir: String) {
        let out = URL(fileURLWithPath: outDir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let sample = makeSampleTree()
        defer { try? FileManager.default.removeItem(at: sample) }

        // ── Main browser window ──────────────────────────────────────────
        let wc = BrowserWindowController(rootURL: sample)
        guard let win = wc.window, let content = win.contentView else { return }
        win.setContentSize(NSSize(width: 1200, height: 780))
        win.setFrameOrigin(NSPoint(x: -60000, y: -60000))
        win.makeKeyAndOrderFront(nil)
        setTheme("rascal-light"); spin(2.2)

        // Make sure the sidebar is expanded to a readable width for the shots.
        if let split = win.contentViewController as? NSSplitViewController, split.splitViewItems.count > 1 {
            split.splitViewItems[0].isCollapsed = false
            split.splitView.setPosition(214, ofDividerAt: 0)
        }
        spin(0.5)

        // Select a file so the orange selection accent shows in the stills.
        wc.testActivePane?.select(url: sample.appendingPathComponent("Q3-report.pdf"))
        spin(0.6)

        if let rep = windowShot(win, content) { writePNG(rep, out.appendingPathComponent("hero.png")) }

        // Dark-mode still (same window, Rascal Dark).
        setTheme("rascal-dark"); spin(0.7)
        if let rep = windowShot(win, content) { writePNG(rep, out.appendingPathComponent("dark.png")) }

        // themes.png — Rascal Light beside Rascal Dark.
        setTheme("rascal-light"); spin(0.6); let lightRep = windowShot(win, content)
        setTheme("rascal-dark");  spin(0.6); let darkRep  = windowShot(win, content)
        if let l = lightRep, let d = darkRep {
            writePNG(sideBySide(l, d, gap: 26), out.appendingPathComponent("themes.png"))
        }

        // themes.gif — the whole window re-themes live (hero motion).
        var themeFrames: [NSBitmapImageRep] = []
        for id in ["rascal-light", "rascal-dark", "nord", "dracula", "solarized-light", "ocean"] {
            setTheme(id); spin(0.7)
            if let rep = windowShot(win, content) { themeFrames.append(rep) }
        }
        writeGIF(themeFrames.map { scaled($0, toWidth: 1040) },
                 out.appendingPathComponent("themes.gif"), delay: 1.1)

        // vim.gif — selection walks down the list (j j j …), Rascal Dark.
        setTheme("rascal-dark"); spin(0.5)
        let listing = ((try? FileManager.default.contentsOfDirectory(at: sample, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var vimFrames: [NSBitmapImageRep] = []
        for url in listing.prefix(8) {
            wc.testActivePane?.select(url: url); spin(0.35)
            if let rep = windowShot(win, content) { vimFrames.append(rep) }
        }
        writeGIF(vimFrames.map { scaled($0, toWidth: 1040) },
                 out.appendingPathComponent("vim.gif"), delay: 0.6)

        // dualpane.png — open a second pane, Rascal Light.
        setTheme("rascal-light"); spin(0.4)
        wc.testToggleExtraPane(); spin(1.2)
        wc.testActivePane?.navigate(to: sample.appendingPathComponent("Projects")); spin(1.2)
        if let rep = windowShot(win, content) { writePNG(rep, out.appendingPathComponent("dualpane.png")) }
        win.orderOut(nil)

        // ── Treemap (Rascal Dark — dramatic) ─────────────────────────────
        setTheme("rascal-dark"); spin(0.3)
        let scanned = DiskScan(root: sample).runSync()
        let tm = TreemapView(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))
        let tmHost = hostWindow(tm)
        tm.setRoot(scanned); tm.layoutSubtreeIfNeeded(); spin(0.3)
        if let rep = snapshot(tm) { writePNG(rep, out.appendingPathComponent("treemap.png")) }
        // treemap.gif — drill into the largest nested directories.
        var tmFrames: [NSBitmapImageRep] = []
        if let rep = snapshot(tm) { tmFrames += [rep, rep] }
        var node = scanned
        for _ in 0..<3 {
            guard let bigDir = node.children.first(where: { $0.isDirectory && !$0.children.isEmpty }) else { break }
            tm.testDrill(into: bigDir); tm.layoutSubtreeIfNeeded(); spin(0.25)
            if let rep = snapshot(tm) { tmFrames += [rep, rep] }
            node = bigDir
        }
        writeGIF(tmFrames.map { scaled($0, toWidth: 1040) },
                 out.appendingPathComponent("treemap.gif"), delay: 0.9)
        tmHost.orderOut(nil)
    }

    // MARK: - infrastructure

    private static func setTheme(_ id: String) { ThemeManager.shared.setTheme(id: id) }

    private static func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// Park a view in an off-screen window so it lays out / loads like it's real.
    @discardableResult
    private static func hostWindow(_ view: NSView) -> NSWindow {
        let w = OffscreenSafeWindow(contentRect: view.bounds,
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = view
        w.setFrameOrigin(NSPoint(x: -60000, y: -60000))
        w.makeKeyAndOrderFront(nil)
        return w
    }

    private static func snapshot(_ view: NSView) -> NSBitmapImageRep? {
        guard view.bounds.width > 1, view.bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Capture a whole window (including its titlebar + vibrant sidebar) via the
    /// WindowServer. An app may capture ITS OWN windows with no Screen-Recording
    /// permission, even while parked off-screen — and unlike cacheDisplay this
    /// composites vibrancy and live text correctly. Falls back to cacheDisplay.
    private static func windowShot(_ win: NSWindow, _ content: NSView) -> NSBitmapImageRep? {
        if win.windowNumber > 0,
           let cg = CGWindowListCreateImage(.null, [.optionIncludingWindow],
                                            CGWindowID(win.windowNumber), [.bestResolution, .boundsIgnoreFraming]) {
            return NSBitmapImageRep(cgImage: cg)
        }
        return snapshot(content)
    }

    private static func writePNG(_ rep: NSBitmapImageRep, _ url: URL) {
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: url) }
    }

    private static func writeGIF(_ reps: [NSBitmapImageRep], _ url: URL, delay: Double) {
        let cgs = reps.compactMap { $0.cgImage }
        guard !cgs.isEmpty,
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, cgs.count, nil)
        else { return }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
        for cg in cgs { CGImageDestinationAddImage(dest, cg, frameProps) }
        CGImageDestinationFinalize(dest)
    }

    /// Downscale a (possibly @2x) rep to a target logical width — keeps GIFs small.
    private static func scaled(_ rep: NSBitmapImageRep, toWidth w: CGFloat) -> NSBitmapImageRep {
        let aspect = CGFloat(rep.pixelsHigh) / CGFloat(max(rep.pixelsWide, 1))
        let h = (w * aspect).rounded()
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w), pixelsHigh: Int(h),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return rep }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        rep.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    /// Compose two snapshots side by side (themes.png).
    private static func sideBySide(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, gap: CGFloat) -> NSBitmapImageRep {
        let h = max(CGFloat(a.pixelsHigh), CGFloat(b.pixelsHigh))
        let w = CGFloat(a.pixelsWide) + CGFloat(b.pixelsWide) + gap
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w), pixelsHigh: Int(h),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return a }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSColor.clear.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
        a.draw(in: NSRect(x: 0, y: 0, width: CGFloat(a.pixelsWide), height: CGFloat(a.pixelsHigh)))
        b.draw(in: NSRect(x: CGFloat(a.pixelsWide) + gap, y: 0, width: CGFloat(b.pixelsWide), height: CGFloat(b.pixelsHigh)))
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    // MARK: - sample content

    /// Build a curated folder of real files (with synthesized images so icon /
    /// gallery thumbnails look genuine) under ~/Rascal for a clean breadcrumb.
    /// Removed by the caller's `defer` after rendering.
    private static func makeSampleTree() -> URL {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent("Rascal", isDirectory: true)
        try? fm.removeItem(at: root)
        for d in ["Documents", "Projects", "Photos", "Music", "Downloads"] {
            try? fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        func write(_ name: String, _ kb: Int, in dir: URL = root) {
            let data = Data(repeating: 0x52, count: max(1, kb) * 1024)
            try? data.write(to: dir.appendingPathComponent(name))
        }
        write("Welcome.md", 3);     write("budget.xlsx", 48);   write("Q3-report.pdf", 220)
        write("resume.docx", 36);   write("archive.zip", 540);  write("notes.txt", 2)
        write("config.json", 5);    write("trailer.mov", 1800); write("podcast.mp3", 900)
        write("App.swift", 14, in: root.appendingPathComponent("Projects"))
        write("server.ts", 9, in: root.appendingPathComponent("Projects"))
        write("index.html", 6, in: root.appendingPathComponent("Projects"))
        write("README.md", 4, in: root.appendingPathComponent("Projects"))
        write("invoice.pdf", 120, in: root.appendingPathComponent("Documents"))
        write("contract.pdf", 84, in: root.appendingPathComponent("Documents"))
        write("set.list", 1, in: root.appendingPathComponent("Music"))
        let photos = root.appendingPathComponent("Photos")
        let palettes: [(NSColor, NSColor)] = [
            (NSColor(srgbRed: 1.0, green: 0.55, blue: 0.2, alpha: 1), NSColor(srgbRed: 0.95, green: 0.27, blue: 0.4, alpha: 1)),
            (NSColor(srgbRed: 0.27, green: 0.6, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.3, green: 0.85, blue: 0.78, alpha: 1)),
            (NSColor(srgbRed: 0.61, green: 0.36, blue: 0.9, alpha: 1),  NSColor(srgbRed: 0.95, green: 0.55, blue: 0.2, alpha: 1)),
            (NSColor(srgbRed: 0.2, green: 0.78, blue: 0.5, alpha: 1),   NSColor(srgbRed: 0.95, green: 0.85, blue: 0.3, alpha: 1)),
            (NSColor(srgbRed: 0.95, green: 0.4, blue: 0.55, alpha: 1),  NSColor(srgbRed: 0.4, green: 0.4, blue: 0.95, alpha: 1)),
        ]
        for (i, pair) in palettes.enumerated() {
            writeGradientPNG(pair, to: photos.appendingPathComponent(String(format: "photo-%02d.png", i + 1)))
        }
        return root
    }

    private static func writeGradientPNG(_ colors: (NSColor, NSColor), to url: URL) {
        let size = NSSize(width: 1200, height: 800)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 800,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(starting: colors.0, ending: colors.1)?.draw(in: NSRect(origin: .zero, size: size), angle: 35)
        NSColor.white.withAlphaComponent(0.18).setFill()
        NSBezierPath(ovalIn: NSRect(x: 760, y: 460, width: 360, height: 360)).fill()
        NSGraphicsContext.restoreGraphicsState()
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: url) }
    }
}
