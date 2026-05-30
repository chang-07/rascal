import AppKit

/// "Analyze Disk Usage" window. Background scan + interactive, animated treemap
/// with drill-in zoom, type-colored tiles, nested folders, and hover read-outs.
final class DiskAnalyzerWindowController: NSWindowController, NSWindowDelegate {

    private weak var target: BrowserWindowController?
    private let rootURL: URL
    private var scan: DiskScan?
    private var focusedNode: DiskScan.Node?
    private let treemap = TreemapView()
    private let pathBar = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var nav: NSSegmentedControl!   // ← / → back-forward through the drill history

    static func show(for wc: BrowserWindowController, rootURL: URL) {
        let c = DiskAnalyzerWindowController(target: wc, rootURL: rootURL)
        PresentedControllers.retain(c)
        c.window?.center()
        c.window?.makeKeyAndOrderFront(nil)
        c.startScan()
    }

    init(target: BrowserWindowController, rootURL: URL) {
        self.target = target
        self.rootURL = rootURL
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
            styleMask: [.titled, .resizable, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        win.title = "Disk Usage — \(rootURL.lastPathComponent)"
        super.init(window: win)
        ThemeChrome.apply(to: window)
        win.delegate = self
        layout()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func layout() {
        guard let cv = window?.contentView else { return }
        treemap.translatesAutoresizingMaskIntoConstraints = false
        treemap.onDrill = { [weak self] node in self?.focus(node) }
        treemap.onOpenFile = { [weak self] node in
            guard let self else { return }
            self.target?.testActivePane?.navigate(to: node.url.deletingLastPathComponent())
            DispatchQueue.main.async { self.target?.testActivePane?.select(url: node.url) }
        }

        let chevL = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back") ?? NSImage()
        let chevR = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward") ?? NSImage()
        nav = NSSegmentedControl(images: [chevL, chevR], trackingMode: .momentary,
                                 target: self, action: #selector(navSegment(_:)))
        nav.segmentStyle = .rounded
        nav.setEnabled(false, forSegment: 0)
        nav.setEnabled(false, forSegment: 1)
        nav.translatesAutoresizingMaskIntoConstraints = false

        pathBar.translatesAutoresizingMaskIntoConstraints = false
        pathBar.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        pathBar.textColor = .secondaryLabelColor
        pathBar.lineBreakMode = .byTruncatingMiddle

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false
        spinner.controlSize = .small

        let reveal = NSButton(title: "Reveal in Rascal", target: self, action: #selector(revealInPane))
        reveal.bezelStyle = .rounded
        reveal.translatesAutoresizingMaskIntoConstraints = false

        let legend = makeLegend()
        legend.translatesAutoresizingMaskIntoConstraints = false

        for v in [nav!, pathBar, statusLabel, spinner, treemap, reveal, legend] { cv.addSubview(v) }

        NSLayoutConstraint.activate([
            nav.topAnchor.constraint(equalTo: cv.topAnchor, constant: 12),
            nav.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 12),
            pathBar.centerYAnchor.constraint(equalTo: nav.centerYAnchor),
            pathBar.leadingAnchor.constraint(equalTo: nav.trailingAnchor, constant: 10),
            pathBar.trailingAnchor.constraint(equalTo: statusLabel.leadingAnchor, constant: -10),
            spinner.centerYAnchor.constraint(equalTo: nav.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: statusLabel.leadingAnchor, constant: -6),
            statusLabel.centerYAnchor.constraint(equalTo: nav.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -12),
            statusLabel.widthAnchor.constraint(equalToConstant: 220),
            treemap.topAnchor.constraint(equalTo: nav.bottomAnchor, constant: 12),
            treemap.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 12),
            treemap.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -12),
            treemap.bottomAnchor.constraint(equalTo: legend.topAnchor, constant: -10),
            legend.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 12),
            legend.trailingAnchor.constraint(lessThanOrEqualTo: reveal.leadingAnchor, constant: -12),
            legend.centerYAnchor.constraint(equalTo: reveal.centerYAnchor),
            reveal.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -12),
            reveal.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -12),
        ])
    }

    private func makeLegend() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 12
        for cat in FileTypePalette.Category.allCases {
            let chip = NSStackView()
            chip.orientation = .horizontal
            chip.spacing = 4
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.backgroundColor = cat.color.cgColor
            dot.layer?.cornerRadius = 4
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
            let label = NSTextField(labelWithString: cat.label)
            label.font = .systemFont(ofSize: 10)
            label.textColor = .secondaryLabelColor
            chip.addArrangedSubview(dot)
            chip.addArrangedSubview(label)
            stack.addArrangedSubview(chip)
        }
        return stack
    }

    private func startScan() {
        let s = DiskScan(root: rootURL)
        scan = s
        spinner.startAnimation(nil)
        statusLabel.stringValue = "Scanning…"
        s.run(onUpdate: { [weak self] count, size in
            self?.statusLabel.stringValue = "\(count) files · \(SizeFormatter.string(size))"
        }, onFinish: { [weak self] root in
            self?.spinner.stopAnimation(nil)
            self?.treemap.setRoot(root)   // initializes history before focus() reads it
            self?.focus(root)
        })
    }

    /// Update the chrome to reflect a newly focused node (called by the treemap
    /// when it drills in/out, and once when the scan finishes).
    private func focus(_ node: DiskScan.Node) {
        focusedNode = node
        pathBar.stringValue = relativePath(of: node)
        statusLabel.stringValue = "\(node.fileCount) files · \(SizeFormatter.string(node.size))"
        nav.setEnabled(treemap.canGoBack, forSegment: 0)
        nav.setEnabled(treemap.canGoForward, forSegment: 1)
    }

    @objc private func navSegment(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { treemap.goBack() } else { treemap.goForward() }
    }

    @objc private func revealInPane() {
        guard let n = focusedNode else { return }
        target?.testActivePane?.navigate(to: n.url)
    }

    private func relativePath(of node: DiskScan.Node) -> String {
        let rootPath = rootURL.path
        let path = node.url.path
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)).replacingOccurrences(of: "^/", with: "", options: .regularExpression).ifEmpty(or: "(root)") : path
    }

    func windowWillClose(_ notification: Notification) {
        scan?.cancel()
    }
}

// MARK: - Squarified treemap layout (Bruls/Huijing/van Wijk)

enum TreemapLayout {
    /// Pack `nodes` into `rect` as rectangles whose areas are proportional to
    /// each node's size, minimizing aspect-ratio distortion (squarified).
    static func squarify(_ nodes: [DiskScan.Node], total: Int64, in rect: CGRect) -> [(DiskScan.Node, CGRect)] {
        let items = nodes.filter { $0.size > 0 }.sorted { $0.size > $1.size }
        guard total > 0, !items.isEmpty, rect.width > 0.5, rect.height > 0.5 else { return [] }
        let area = Double(rect.width) * Double(rect.height)
        let scale = area / Double(total)
        let areas = items.map { Double($0.size) * scale }

        var result: [(DiskScan.Node, CGRect)] = []
        var remaining = rect
        var row: [Int] = []
        var i = 0

        func worst(_ idxs: [Int], _ w: Double) -> Double {
            guard !idxs.isEmpty, w > 0 else { return .greatestFiniteMagnitude }
            let s = idxs.reduce(0.0) { $0 + areas[$1] }
            let rmax = idxs.map { areas[$0] }.max() ?? 0
            let rmin = idxs.map { areas[$0] }.min() ?? 0
            guard s > 0, rmin > 0 else { return .greatestFiniteMagnitude }
            let w2 = w * w, s2 = s * s
            return max(w2 * rmax / s2, s2 / (w2 * rmin))
        }
        func layoutRow(_ idxs: [Int]) {
            let s = idxs.reduce(0.0) { $0 + areas[$1] }
            guard s > 0 else { return }
            let wide = remaining.width >= remaining.height
            if wide {
                let stripW = CGFloat(s) / remaining.height
                var y = remaining.minY
                for idx in idxs {
                    let h = CGFloat(areas[idx]) / CGFloat(s) * remaining.height
                    result.append((items[idx], CGRect(x: remaining.minX, y: y, width: stripW, height: h)))
                    y += h
                }
                remaining = CGRect(x: remaining.minX + stripW, y: remaining.minY,
                                   width: remaining.width - stripW, height: remaining.height)
            } else {
                let stripH = CGFloat(s) / remaining.width
                var x = remaining.minX
                for idx in idxs {
                    let w = CGFloat(areas[idx]) / CGFloat(s) * remaining.width
                    result.append((items[idx], CGRect(x: x, y: remaining.minY, width: w, height: stripH)))
                    x += w
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + stripH,
                                   width: remaining.width, height: remaining.height - stripH)
            }
        }

        while i < items.count {
            let w = Double(min(remaining.width, remaining.height))
            if row.isEmpty || worst(row, w) >= worst(row + [i], w) {
                row.append(i); i += 1
            } else {
                layoutRow(row); row = []
            }
        }
        if !row.isEmpty { layoutRow(row) }
        return result
    }
}

// MARK: - The view

/// Animated, type-colored treemap. Draws nested folders to a capped depth, with
/// a hover read-out and a zoom transition when drilling in/out.
final class TreemapView: NSView {

    var onDrill: ((DiskScan.Node) -> Void)?
    var onOpenFile: ((DiskScan.Node) -> Void)?

    private(set) var currentRoot: DiskScan.Node?
    private var tiles: [Tile] = []
    private var hovered: DiskScan.Node?
    private var hoverPoint: CGPoint = .zero
    private var tracking: NSTrackingArea?

    /// Browser-style drill history: `history[historyIndex]` is the current view.
    private var history: [DiskScan.Node] = []
    private var historyIndex = -1
    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex >= 0 && historyIndex < history.count - 1 }

    private let maxDepth = 3
    private let headerH: CGFloat = 16

    private struct Tile {
        let node: DiskScan.Node
        let rect: CGRect
        let depth: Int
        let isContainer: Bool
    }

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Set the starting root and reset history (called once after the scan).
    func setRoot(_ node: DiskScan.Node) {
        currentRoot = node
        history = [node]
        historyIndex = 0
        hovered = nil
        rebuild()
    }

    /// ← Go back one step in the drill history (zooms back out).
    func goBack() {
        guard canGoBack else { NSSound.beep(); return }
        let leaving = currentRoot
        historyIndex -= 1
        let snap = snapshotOverlay()
        showRoot(history[historyIndex])
        if let snap {
            addSubview(snap)
            // Shrink the old (deeper) view down into the tile it now occupies.
            let target = tiles.first(where: { $0.node === leaving })?.rect
                ?? bounds.insetBy(dx: bounds.width * 0.4, dy: bounds.height * 0.4)
            animate(snap, to: target)
        }
    }

    /// → Go forward one step in the drill history (zooms back in).
    func goForward() {
        guard canGoForward else { NSSound.beep(); return }
        let node = history[historyIndex + 1]
        let fromRect = tiles.first(where: { $0.node === node })?.rect ?? bounds
        historyIndex += 1
        zoomIn(to: node, from: fromRect)
    }

    /// Record a freshly drilled-into node, discarding any forward history.
    private func pushHistory(_ node: DiskScan.Node) {
        if historyIndex < history.count - 1 { history.removeSubrange((historyIndex + 1)...) }
        history.append(node)
        historyIndex = history.count - 1
    }

    /// Swap the displayed root without touching history.
    private func showRoot(_ node: DiskScan.Node) {
        currentRoot = node
        hovered = nil
        rebuild()
        onDrill?(node)
    }

    // MARK: layout

    override func resizeSubviews(withOldSize oldSize: NSSize) { super.resizeSubviews(withOldSize: oldSize); rebuild() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); rebuild() }

    private func rebuild() {
        tiles.removeAll()
        if let root = currentRoot {
            layoutChildren(of: root, in: bounds.insetBy(dx: 2, dy: 2), depth: 0)
        }
        needsDisplay = true
    }

    private func layoutChildren(of node: DiskScan.Node, in rect: CGRect, depth: Int) {
        guard rect.width > 4, rect.height > 4 else { return }
        let placed = TreemapLayout.squarify(node.children, total: node.size, in: rect)
        for (child, r) in placed {
            let canRecurse = child.isDirectory && depth < maxDepth
                && r.width > 60 && r.height > 60 && !child.children.isEmpty
            tiles.append(Tile(node: child, rect: r, depth: depth, isContainer: canRecurse))
            if canRecurse {
                let inner = CGRect(x: r.minX + 3, y: r.minY + headerH,
                                   width: r.width - 6, height: r.height - headerH - 3)
                layoutChildren(of: child, in: inner, depth: depth + 1)
            }
        }
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeManager.shared.current
        let backdrop = theme.id == "system" ? NSColor.windowBackgroundColor : theme.background
        backdrop.setFill()
        bounds.fill()

        guard !tiles.isEmpty else {
            let msg = currentRoot == nil ? "Analyzing…" : "Empty"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let s = NSAttributedString(string: msg, attributes: attrs)
            let sz = s.size()
            s.draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2))
            return
        }

        // shallow→deep order means parents paint first, children land on top.
        for t in tiles { drawTile(t) }
        if let h = hovered { drawHoverChip(for: h) }
    }

    private func drawTile(_ t: Tile) {
        let r = t.rect.insetBy(dx: 1, dy: 1)
        guard r.width > 1.5, r.height > 1.5 else { return }
        let base = FileTypePalette.color(for: t.node)
        let radius = min(5, r.width / 2, r.height / 2)
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)

        if t.isContainer {
            (base.blended(withFraction: 0.62, of: .black) ?? base).withAlphaComponent(0.92).setFill()
            path.fill()
            drawLabel(t.node, in: CGRect(x: r.minX + 6, y: r.minY, width: r.width - 12, height: headerH),
                      twoLine: false, on: base)
        } else {
            let top = base.blended(withFraction: 0.18, of: .white) ?? base
            let bottom = base.blended(withFraction: 0.22, of: .black) ?? base
            (NSGradient(starting: top, ending: bottom))?.draw(in: path, angle: -90)
            NSColor.white.withAlphaComponent(0.07).setStroke()
            path.lineWidth = 1; path.stroke()
            if r.width > 34, r.height > 20 {
                drawLabel(t.node, in: r.insetBy(dx: 5, dy: 3), twoLine: r.height > 32, on: base)
            }
        }

        if hovered === t.node {
            NSColor.white.withAlphaComponent(0.16).setFill(); path.fill()
            ThemeManager.shared.effectiveAccent.setStroke()
            let hp = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: radius, yRadius: radius)
            hp.lineWidth = 2; hp.stroke()
        }
    }

    private func drawLabel(_ node: DiskScan.Node, in rect: CGRect, twoLine: Bool, on base: NSColor) {
        guard rect.width > 10, rect.height > 9 else { return }
        let srgb = base.usingColorSpace(.sRGB)
        let lum = srgb.map { 0.299 * $0.redComponent + 0.587 * $0.greenComponent + 0.114 * $0.blueComponent } ?? 0.5
        let textColor = lum > 0.62 ? NSColor.black.withAlphaComponent(0.82) : NSColor.white.withAlphaComponent(0.96)
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: textColor, .paragraphStyle: para,
        ]
        (node.name as NSString).draw(in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 15),
                                     withAttributes: nameAttrs)
        if twoLine {
            let sizeAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9.5),
                .foregroundColor: textColor.withAlphaComponent(0.75), .paragraphStyle: para,
            ]
            (SizeFormatter.string(node.size) as NSString)
                .draw(in: CGRect(x: rect.minX, y: rect.minY + 14, width: rect.width, height: 13),
                      withAttributes: sizeAttrs)
        }
    }

    private func drawHoverChip(for node: DiskScan.Node) {
        let pct = currentRoot.map { $0.size > 0 ? Double(node.size) / Double($0.size) * 100 : 0 } ?? 0
        let line1 = node.name
        let line2 = "\(SizeFormatter.string(node.size))  ·  \(String(format: "%.1f", pct))%"
        let f1 = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let f2 = NSFont.systemFont(ofSize: 11)
        let a1: [NSAttributedString.Key: Any] = [.font: f1, .foregroundColor: NSColor.white]
        let a2: [NSAttributedString.Key: Any] = [.font: f2, .foregroundColor: NSColor.white.withAlphaComponent(0.75)]
        let s1 = NSAttributedString(string: line1, attributes: a1)
        let s2 = NSAttributedString(string: line2, attributes: a2)
        let w = max(s1.size().width, s2.size().width) + 20
        let h: CGFloat = 42
        var x = hoverPoint.x + 14
        var y = hoverPoint.y + 14
        if x + w > bounds.maxX - 4 { x = hoverPoint.x - w - 14 }
        if y + h > bounds.maxY - 4 { y = hoverPoint.y - h - 14 }
        x = max(bounds.minX + 4, x); y = max(bounds.minY + 4, y)
        let chip = CGRect(x: x, y: y, width: w, height: h)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: chip, xRadius: 7, yRadius: 7).fill()
        s1.draw(at: NSPoint(x: x + 10, y: y + 6))
        s2.draw(at: NSPoint(x: x + 10, y: y + 23))
    }

    // MARK: zoom transition

    private func snapshotOverlay() -> NSImageView? {
        guard bounds.width > 1, bounds.height > 1,
              let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let img = NSImage(size: bounds.size)
        img.addRepresentation(rep)
        let iv = NSImageView(frame: bounds)
        iv.image = img
        iv.imageScaling = .scaleAxesIndependently
        iv.wantsLayer = true
        return iv
    }

    private func animate(_ snap: NSImageView, to target: CGRect) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.34
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            snap.animator().frame = target
            snap.animator().alphaValue = 0
        }, completionHandler: { snap.removeFromSuperview() })
    }

    /// Visually zoom into `node`, expanding its tile (`rect`) to fill the view.
    /// History is the caller's responsibility.
    private func zoomIn(to node: DiskScan.Node, from rect: CGRect) {
        let snap = snapshotOverlay()
        showRoot(node)
        guard let snap, rect.width > 1, rect.height > 1 else { return }
        addSubview(snap)
        let b = bounds
        let sx = b.width / rect.width, sy = b.height / rect.height
        let target = CGRect(x: -rect.minX * sx, y: -rect.minY * sy, width: b.width * sx, height: b.height * sy)
        animate(snap, to: target)
    }

    // MARK: interaction

    private func deepestTile(at p: CGPoint) -> Tile? {
        for t in tiles.reversed() where t.rect.contains(p) { return t }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let hit = deepestTile(at: p) else { return }
        if hit.node.isDirectory && !hit.node.children.isEmpty {
            pushHistory(hit.node)
            zoomIn(to: hit.node, from: hit.rect)
        } else {
            onOpenFile?(hit.node)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: goBack()        // ←
        case 124: goForward()     // →
        default:   super.keyDown(with: event)
        }
    }

    /// Test hook: drill into a node as if its tile were clicked (no animation
    /// dependency on a live run loop).
    func testDrill(into node: DiskScan.Node) {
        pushHistory(node)
        showRoot(node)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hoverPoint = p
        let node = deepestTile(at: p)?.node
        // Always redraw (the chip follows the cursor); cheap for bounded tile counts.
        hovered = node
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    // MARK: test hooks
    var testTileCount: Int { tiles.count }
    var testHasNestedTiles: Bool { tiles.contains { $0.depth > 0 } }
}

private extension String {
    /// Returns self if non-empty, otherwise the fallback.
    func ifEmpty(or fallback: String) -> String { isEmpty ? fallback : self }
}

/// Off-screen treemap renderer: scans a folder synchronously, lays out the
/// treemap, and writes a PNG — no window, no display. Used for demo assets and
/// headless visual verification (FT_TREEMAP_SHOT).
enum TreemapShot {
    static func render(rootPath: String, size: NSSize, to outPath: String) {
        let root = DiskScan(root: URL(fileURLWithPath: rootPath)).runSync()
        let view = TreemapView(frame: NSRect(origin: .zero, size: size))
        view.setRoot(root)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: outPath))
    }
}
