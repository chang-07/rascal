import AppKit
import AVFoundation
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

        // ── Feature stills (rascal-light, off-screen) ────────────────────
        while wc.testPaneCount > 1 { wc.testCloseActivePane() }
        let pane = wc.testActivePane
        pane?.setViewMode(.list); pane?.navigate(to: sample); spin(0.4)

        // icons.png — root folder as an icon grid. File-type icons render
        // crisply off-screen; QuickLook image thumbnails do not, so we use a
        // varied folder (not an image-only one) to keep the shot flicker-free.
        pane?.navigate(to: sample); spin(0.4)
        pane?.setViewMode(.icon); spin(1.3)
        if let r = windowShot(win, content) { writePNG(r, out.appendingPathComponent("icons.png")) }

        // columns.png — Miller columns, drilled one level in.
        pane?.setViewMode(.list); pane?.navigate(to: sample); spin(0.3)
        pane?.setViewMode(.columns); spin(0.6)
        pane?.testColumnVC?.testDrillIntoFirstFolder(); spin(0.9)
        if let r = windowShot(win, content) { writePNG(r, out.appendingPathComponent("columns.png")) }

        // multipane.png — three independent panes (up to four).
        pane?.setViewMode(.list); pane?.navigate(to: sample); spin(0.3)
        wc.testAddPane(); wc.testAddPane(); spin(0.4)
        let mp = wc.testAllPanes
        if mp.count >= 3 {
            mp[1].navigate(to: sample.appendingPathComponent("Documents"))
            mp[2].navigate(to: sample.appendingPathComponent("Projects")); mp[2].setViewMode(.icon)
            spin(1.3)
        }
        if let r = windowShot(win, content) { writePNG(r, out.appendingPathComponent("multipane.png")) }
        while wc.testPaneCount > 1 { wc.testCloseActivePane() }; spin(0.3)

        // cut.png — true Cut (⌘X): cut files render dimmed until pasted.
        pane?.setViewMode(.list); pane?.navigate(to: sample); spin(0.5)
        pane?.testFileList.tableView.selectRowIndexes(IndexSet([1, 3, 5]), byExtendingSelection: false)
        pane?.cutSelection(); spin(0.6)
        if let r = windowShot(win, content) { writePNG(r, out.appendingPathComponent("cut.png")) }
        FileOps.clearCut(); spin(0.2)

        // tags.png — Finder-compatible color tags shown as dots; reuse this
        // clean base for the Get Info overlay too.
        Tags.write([Tags.Tag(name: "Important", color: .red)],  to: sample.appendingPathComponent("Q3-report.pdf"))
        Tags.write([Tags.Tag(name: "Work", color: .blue)],      to: sample.appendingPathComponent("budget.xlsx"))
        Tags.write([Tags.Tag(name: "Personal", color: .green)], to: sample.appendingPathComponent("resume.docx"))
        Tags.write([Tags.Tag(name: "Review", color: .orange)],  to: sample.appendingPathComponent("config.json"))
        pane?.navigate(to: sample.appendingPathComponent("Projects")); spin(0.3)
        pane?.navigate(to: sample); spin(0.7)
        pane?.select(url: sample.appendingPathComponent("Q3-report.pdf")); spin(0.3)
        if let base = windowShot(win, content) {
            writePNG(base, out.appendingPathComponent("tags.png"))
            // getinfo.png — native Get Info floated over the dimmed window.
            let gi = GetInfoSheetController(url: sample.appendingPathComponent("Q3-report.pdf"))
            if let gc = gi.window?.contentView,
               let gr = panelShot(gc, size: NSSize(width: 380, height: 560)) {
                writePNG(overlayPanel(base, gr), out.appendingPathComponent("getinfo.png"))
            }
        }

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

    // MARK: - demo video (short guided walkthrough → .mp4)

    /// Render a short, simple product walkthrough as an .mp4 — entirely off-screen.
    /// Each "beat" is a real captured Rascal state, composited onto a warm ivory
    /// canvas with a caption, then cross-faded and encoded with AVAssetWriter.
    static func renderWalkthrough(to outPath: String) {
        let sample = makeSampleTree()
        defer { try? FileManager.default.removeItem(at: sample) }
        setTheme("rascal-light"); NSApp.appearance = NSAppearance(named: .aqua)

        let wc = BrowserWindowController(rootURL: sample)
        guard let win = wc.window, let content = win.contentView else { return }
        win.setContentSize(NSSize(width: 1280, height: 800))
        win.setFrameOrigin(NSPoint(x: -60000, y: -60000))
        win.makeKeyAndOrderFront(nil)
        spin(2.2)
        if let split = win.contentViewController as? NSSplitViewController, split.splitViewItems.count > 1 {
            split.splitViewItems[0].isCollapsed = false
            split.splitView.setPosition(214, ofDividerAt: 0)
        }
        spin(0.4)

        var keys: [NSBitmapImageRep] = []
        func beat(_ caption: String?) { if let r = windowShot(win, content) { keys.append(composeFrame(r, caption: caption)) } }

        // 1 — browse
        wc.testActivePane?.setViewMode(.list)
        wc.testActivePane?.select(url: sample.appendingPathComponent("Q3-report.pdf")); spin(0.6)
        beat("Browse your files")
        // 2 — view modes
        wc.testActivePane?.setViewMode(.icon); spin(0.8); beat("Four built-in views")
        wc.testActivePane?.setViewMode(.columns); spin(0.8); beat("List · Icon · Column · Gallery")
        wc.testActivePane?.setViewMode(.list); spin(0.4)

        // 3 + 4 — command palette and fuzzy finder, composited over the window
        let base = windowShot(win, content)
        if let base {
            let palette = CommandPaletteController(target: wc); palette.demoSetQuery("new")
            if let pc = palette.window?.contentView, let pr = panelShot(pc, size: NSSize(width: 720, height: 432)) {
                keys.append(composeFrame(overlayPanel(base, pr), caption: "Command palette · ⌘⇧P"))
            }
            let finder = SearchSheetController(target: wc, mode: .fuzzyFilenames, rootURL: sample); finder.demoPopulate(query: "re")
            if let fc = finder.window?.contentView, let fr = panelShot(fc, size: NSSize(width: 720, height: 432)) {
                keys.append(composeFrame(overlayPanel(base, fr), caption: "Fuzzy file finder · ⌘F"))
            }
        }

        // 5 — preview pane
        wc.testActivePane?.select(url: sample.appendingPathComponent("Q3-report.pdf")); spin(0.3)
        wc.testActivePane?.togglePreviewDrawer(); spin(1.2); beat("Preview anything inline")
        wc.testActivePane?.togglePreviewDrawer(); spin(0.3)
        win.orderOut(nil)

        // 6 — disk-usage treemap
        let scanned = DiskScan(root: sample).runSync()
        let tm = TreemapView(frame: NSRect(x: 0, y: 0, width: 1180, height: 740))
        let tmHost = hostWindow(tm)
        tm.setRoot(scanned); tm.layoutSubtreeIfNeeded(); spin(0.4)
        if let r = snapshot(tm) { keys.append(composeFrame(r, caption: "See where your space goes")) }
        tmHost.orderOut(nil)

        // end card
        keys.append(endCard(1280, 800))
        guard keys.count > 1 else { return }

        // ── assemble timeline: hold each key state, cross-fade between them ──
        let fps = 30, hold = 42, fade = 9
        var frames: [NSBitmapImageRep] = []
        for (i, k) in keys.enumerated() {
            if i > 0 { frames += crossfade(keys[i - 1], k, count: fade) }
            for _ in 0..<hold { frames.append(k) }
        }
        for _ in 0..<24 { frames.append(keys[keys.count - 1]) }   // linger on the end card
        writeVideo(frames, to: URL(fileURLWithPath: outPath), fps: fps)
    }

    /// Compose one captured rep onto a 1280×800 ivory canvas: the app window
    /// floats with a soft shadow, a caption pill sits at the bottom.
    private static func composeFrame(_ src: NSBitmapImageRep, caption: String?, w: Int = 1280, h: Int = 800) -> NSBitmapImageRep {
        let canvas = newRep(w, h)
        drawInto(canvas) {
            NSColor(srgbRed: 0.984, green: 0.965, blue: 0.933, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: w, height: h).fill()
            let topInset: CGFloat = 30, bottomInset: CGFloat = 96, side: CGFloat = 34
            let availW = CGFloat(w) - 2 * side, availH = CGFloat(h) - topInset - bottomInset
            let aspect = CGFloat(src.pixelsHigh) / CGFloat(max(src.pixelsWide, 1))
            var dw = availW, dh = availW * aspect
            if dh > availH { dh = availH; dw = availH / aspect }
            let rect = NSRect(x: (CGFloat(w) - dw) / 2, y: CGFloat(h) - topInset - dh, width: dw, height: dh)
            let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.22); sh.shadowBlurRadius = 42; sh.shadowOffset = NSSize(width: 0, height: -14)
            NSGraphicsContext.saveGraphicsState(); sh.set(); src.draw(in: rect); NSGraphicsContext.restoreGraphicsState()
            if let caption { drawCaption(caption, canvasW: w, bottomY: 30) }
        }
        return canvas
    }

    private static func drawCaption(_ text: String, canvasW: Int, bottomY: CGFloat) {
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 25, weight: .semibold),
            .foregroundColor: NSColor(srgbRed: 0.14, green: 0.10, blue: 0.07, alpha: 1),
            .paragraphStyle: para,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let ts = s.size()
        let padX: CGFloat = 28, padY: CGFloat = 13
        let pw = ts.width + padX * 2, ph = ts.height + padY * 2
        let pill = NSRect(x: (CGFloat(canvasW) - pw) / 2, y: bottomY, width: pw, height: ph)
        let path = NSBezierPath(roundedRect: pill, xRadius: ph / 2, yRadius: ph / 2)
        let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.16); sh.shadowBlurRadius = 22; sh.shadowOffset = NSSize(width: 0, height: -6)
        NSGraphicsContext.saveGraphicsState(); sh.set()
        NSColor.white.withAlphaComponent(0.94).setFill(); path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(srgbRed: 0.91, green: 0.86, blue: 0.79, alpha: 1).setStroke(); path.lineWidth = 1; path.stroke()
        s.draw(in: NSRect(x: pill.minX + padX, y: bottomY + padY - 1, width: ts.width, height: ts.height))
    }

    private static func endCard(_ w: Int, _ h: Int) -> NSBitmapImageRep {
        let canvas = newRep(w, h)
        drawInto(canvas) {
            NSColor(srgbRed: 0.984, green: 0.965, blue: 0.933, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: w, height: h).fill()
            let cx = CGFloat(w) / 2
            if let icon = NSApp.applicationIconImage {
                icon.draw(in: NSRect(x: cx - 64, y: CGFloat(h) * 0.56, width: 128, height: 128))
            }
            func center(_ str: String, font: NSFont, color: NSColor, y: CGFloat) {
                let p = NSMutableParagraphStyle(); p.alignment = .center
                let a = NSAttributedString(string: str, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
                a.draw(in: NSRect(x: 0, y: y, width: CGFloat(w), height: font.pointSize * 1.5))
            }
            let serif = NSFont(name: "Georgia-Bold", size: 70) ?? NSFont.systemFont(ofSize: 70, weight: .bold)
            center("Rascal", font: serif, color: NSColor(srgbRed: 0.14, green: 0.10, blue: 0.07, alpha: 1), y: CGFloat(h) * 0.40)
            let ital = NSFont(name: "Georgia-Italic", size: 27) ?? NSFont.systemFont(ofSize: 27)
            center("your files, finally yours.", font: ital, color: NSColor(srgbRed: 0.54, green: 0.47, blue: 0.40, alpha: 1), y: CGFloat(h) * 0.32)
            center("github.com/chang-07/finder-2", font: NSFont.monospacedSystemFont(ofSize: 18, weight: .medium), color: NSColor(srgbRed: 0.75, green: 0.27, blue: 0.05, alpha: 1), y: CGFloat(h) * 0.22)
        }
        return canvas
    }

    private static func crossfade(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, count: Int) -> [NSBitmapImageRep] {
        var out: [NSBitmapImageRep] = []
        let rect = NSRect(x: 0, y: 0, width: a.pixelsWide, height: a.pixelsHigh)
        for i in 1...count {
            let t = CGFloat(i) / CGFloat(count + 1)
            let f = newRep(a.pixelsWide, a.pixelsHigh)
            drawInto(f) {
                a.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
                b.draw(in: rect, from: .zero, operation: .sourceOver, fraction: t, respectFlipped: false, hints: nil)
            }
            out.append(f)
        }
        return out
    }

    private static func newRep(_ w: Int, _ h: Int) -> NSBitmapImageRep {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    }
    private static func drawInto(_ rep: NSBitmapImageRep, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func writeVideo(_ frames: [NSBitmapImageRep], to url: URL, fps: Int) {
        guard let first = frames.first else { return }
        let w = first.pixelsWide, h = first.pixelsHigh
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 9_000_000,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        guard writer.canAdd(input) else { return }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let dur = CMTime(value: 1, timescale: CMTimeScale(fps))
        var t = CMTime.zero
        for rep in frames {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.004) }
            if let pb = pixelBuffer(rep, w, h) { adaptor.append(pb, withPresentationTime: t) }
            t = CMTimeAdd(t, dur)
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
    }

    private static func pixelBuffer(_ rep: NSBitmapImageRep, _ w: Int, _ h: Int) -> CVPixelBuffer? {
        guard let cg = rep.cgImage else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferCGImageCompatibilityKey: true,
                             kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb)
        guard let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buffer
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
