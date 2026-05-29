import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Headless capture harness for the landing-page media. Renders real Rascal
/// scenes OFF-SCREEN (parks an OffscreenSafeWindow far off every display and
/// captures it with CGWindowListCreateImage — an app may snapshot its OWN
/// windows with no Screen-Recording permission, and that composites vibrancy +
/// live text, unlike cacheDisplay). Nothing ever appears on the user's screens.
///
/// Light mode only, curated to a few pretty shots. Driven by
/// `FT_HEADLESS_TESTING=1 FT_DEMO=<outdir>` (see AppDelegate).
enum DemoShot {

    static func renderAll(to outDir: String) {
        let out = URL(fileURLWithPath: outDir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let sample = makeSampleTree()
        defer { try? FileManager.default.removeItem(at: sample) }

        setTheme("rascal-light")
        // Force a light appearance for the whole capture run so system controls
        // (search fields, scrollers) render light even if the Mac is in dark mode.
        // setTheme can early-return when already on the theme, so set it directly.
        NSApp.appearance = NSAppearance(named: .aqua)

        // ── Main browser window (light) ──────────────────────────────────
        let wc = BrowserWindowController(rootURL: sample)
        guard let win = wc.window, let content = win.contentView else { return }
        win.setContentSize(NSSize(width: 1200, height: 800))
        win.setFrameOrigin(NSPoint(x: -60000, y: -60000))
        win.makeKeyAndOrderFront(nil)
        spin(2.2)
        if let split = win.contentViewController as? NSSplitViewController, split.splitViewItems.count > 1 {
            split.splitViewItems[0].isCollapsed = false
            split.splitView.setPosition(214, ofDividerAt: 0)
        }
        spin(0.5)
        wc.testActivePane?.select(url: sample.appendingPathComponent("Q3-report.pdf")); spin(0.6)
        let appRep = windowShot(win, content)
        if let r = appRep { writePNG(r, out.appendingPathComponent("hero.png")) }

        // ── Command palette + fuzzy finder, composited over the app ──────
        if let appRep {
            let palette = CommandPaletteController(target: wc)
            palette.demoSetQuery("new")
            if let pc = palette.window?.contentView,
               let pr = panelShot(pc, size: NSSize(width: 720, height: 432)) {
                writePNG(overlayPanel(appRep, pr), out.appendingPathComponent("palette.png"))
            }

            let finder = SearchSheetController(target: wc, mode: .fuzzyFilenames, rootURL: sample)
            finder.demoPopulate(query: "re")
            if let fc = finder.window?.contentView,
               let fr = panelShot(fc, size: NSSize(width: 720, height: 432)) {
                writePNG(overlayPanel(appRep, fr), out.appendingPathComponent("fuzzyfind.png"))
            }
        }

        // ── Walkthrough clips ────────────────────────────────────────────
        func frame(_ into: inout [NSBitmapImageRep], hold: Int = 2) {
            if let r = windowShot(win, content) { for _ in 0..<hold { into.append(r) } }
        }

        // nav.gif — browsing + switching view modes.
        wc.testActivePane?.navigate(to: sample); spin(0.8)
        var nav: [NSBitmapImageRep] = []; frame(&nav)
        wc.testActivePane?.select(url: sample.appendingPathComponent("budget.xlsx")); spin(0.4); frame(&nav)
        wc.testActivePane?.setViewMode(.icon); spin(0.9); frame(&nav, hold: 3)
        wc.testActivePane?.setViewMode(.columns); spin(0.9); frame(&nav, hold: 3)
        wc.testActivePane?.setViewMode(.list); spin(0.5)
        wc.testActivePane?.navigate(to: sample.appendingPathComponent("Projects")); spin(0.9); frame(&nav, hold: 3)
        wc.testActivePane?.navigate(to: sample); spin(0.7); frame(&nav)
        writeGIF(nav.map { scaled($0, toWidth: 1100) }, out.appendingPathComponent("nav.gif"), delay: 1.0)

        // panels.gif — opening the preview side panel + a second pane.
        wc.testActivePane?.setViewMode(.list); spin(0.3)
        wc.testActivePane?.select(url: sample.appendingPathComponent("Q3-report.pdf")); spin(0.4)
        var panels: [NSBitmapImageRep] = []; frame(&panels)
        wc.testActivePane?.togglePreviewDrawer(); spin(1.3); frame(&panels, hold: 3)
        wc.testActivePane?.togglePreviewDrawer(); spin(0.5); frame(&panels)
        wc.testToggleExtraPane(); spin(1.2); frame(&panels, hold: 2)
        wc.testActivePane?.navigate(to: sample.appendingPathComponent("Projects")); spin(1.0); frame(&panels, hold: 3)
        writeGIF(panels.map { scaled($0, toWidth: 1100) }, out.appendingPathComponent("panels.gif"), delay: 1.0)
        win.orderOut(nil)

        // ── Treemap (light) — still + drill GIF ──────────────────────────
        setTheme("rascal-light"); spin(0.3)
        let scanned = DiskScan(root: sample).runSync()
        let tm = TreemapView(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))
        let tmHost = hostWindow(tm)
        tm.setRoot(scanned); tm.layoutSubtreeIfNeeded(); spin(0.3)
        if let rep = snapshot(tm) { writePNG(rep, out.appendingPathComponent("treemap.png")) }
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
    private static func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }

    /// Park a view in an off-screen window so it lays out / loads like it's real.
    @discardableResult
    private static func hostWindow(_ view: NSView) -> NSWindow {
        let w = OffscreenSafeWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = view
        w.setFrameOrigin(NSPoint(x: -60000, y: -60000))
        w.makeKeyAndOrderFront(nil)
        return w
    }

    /// Re-host an overlay finder's content in an OffscreenSafeWindow (which can't
    /// be yanked on-screen) under a dark appearance, then window-capture it — so
    /// the HUD's text composites correctly with no on-screen flash.
    private static func panelShot(_ content: NSView, size: NSSize) -> NSBitmapImageRep? {
        content.frame = NSRect(origin: .zero, size: size)
        let host = OffscreenSafeWindow(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        host.appearance = NSApp.appearance     // follow the active (light) theme
        host.isOpaque = false
        host.backgroundColor = .clear           // the panel's own rounded themed bg shows; corners stay transparent
        host.hasShadow = false                  // we draw the float shadow in the composite
        host.contentView = content
        host.setFrameOrigin(NSPoint(x: -60000, y: -60000))
        host.makeKeyAndOrderFront(nil)
        content.layoutSubtreeIfNeeded()
        spin(0.5)
        let rep = windowShot(host, content)
        host.orderOut(nil)
        return rep
    }

    private static func snapshot(_ view: NSView) -> NSBitmapImageRep? {
        guard view.bounds.width > 1, view.bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Capture a whole window (titlebar + vibrant sidebar) via the WindowServer.
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

    /// Draw `panel` as a floating, rounded, shadowed HUD over a dimmed `base`.
    private static func overlayPanel(_ base: NSBitmapImageRep, _ panel: NSBitmapImageRep) -> NSBitmapImageRep {
        let W = CGFloat(base.pixelsWide), H = CGFloat(base.pixelsHigh)
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return base }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        base.draw(in: NSRect(x: 0, y: 0, width: W, height: H))
        NSColor.black.withAlphaComponent(0.28).setFill()
        NSRect(x: 0, y: 0, width: W, height: H).fill()

        let pw = min(CGFloat(panel.pixelsWide), W * 0.58)
        let scale = pw / CGFloat(panel.pixelsWide)
        let ph = CGFloat(panel.pixelsHigh) * scale
        let px = (W - pw) / 2
        let py = H - ph - H * 0.12     // ~12% down from the top (bottom-left origin)
        let rect = NSRect(x: px, y: py, width: pw, height: ph)

        // The panel rep already carries its own rounded, themed background with
        // transparent corners — so drawing it under a shadow yields a rounded
        // float shadow automatically.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
        shadow.shadowBlurRadius = 55
        shadow.shadowOffset = NSSize(width: 0, height: -14)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        panel.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    // MARK: - sample content

    private static func makeSampleTree() -> URL {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent("Rascal", isDirectory: true)
        try? fm.removeItem(at: root)
        for d in ["Documents", "Projects", "Photos", "Music", "Downloads"] {
            try? fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        func write(_ name: String, _ kb: Int, in dir: URL = root) {
            try? Data(repeating: 0x52, count: max(1, kb) * 1024).write(to: dir.appendingPathComponent(name))
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
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 800,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(starting: colors.0, ending: colors.1)?.draw(in: NSRect(x: 0, y: 0, width: 1200, height: 800), angle: 35)
        NSColor.white.withAlphaComponent(0.18).setFill()
        NSBezierPath(ovalIn: NSRect(x: 760, y: 460, width: 360, height: 360)).fill()
        NSGraphicsContext.restoreGraphicsState()
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: url) }
    }
}
