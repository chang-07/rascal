import AppKit

/// "Analyze Disk Usage" window. Background scan + interactive treemap +
/// breadcrumb drill-in.
final class DiskAnalyzerWindowController: NSWindowController, NSWindowDelegate {

    private weak var target: BrowserWindowController?
    private let rootURL: URL
    private var scan: DiskScan?
    private var focusedNode: DiskScan.Node?
    private let treemap = TreemapView()
    private let pathBar = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

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
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
            styleMask: [.titled, .resizable, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        win.title = "Disk Usage — \(rootURL.lastPathComponent)"
        super.init(window: win)
        win.delegate = self
        layout()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func layout() {
        guard let cv = window?.contentView else { return }
        treemap.translatesAutoresizingMaskIntoConstraints = false
        treemap.onClick = { [weak self] node in
            guard let self else { return }
            if node.isDirectory {
                self.focusedNode = node
                self.pathBar.stringValue = self.relativePath(of: node)
                self.treemap.setRoot(node)
            } else {
                self.target?.testActivePane?.navigate(to: node.url.deletingLastPathComponent())
                DispatchQueue.main.async { self.target?.testActivePane?.select(url: node.url) }
            }
        }

        let up = NSButton(title: "Up", target: self, action: #selector(focusUp))
        up.bezelStyle = .rounded
        up.translatesAutoresizingMaskIntoConstraints = false

        pathBar.translatesAutoresizingMaskIntoConstraints = false
        pathBar.font = NSFont.systemFont(ofSize: 12)
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

        let reveal = NSButton(title: "Reveal in FinderTwo", target: self, action: #selector(revealInPane))
        reveal.bezelStyle = .rounded
        reveal.translatesAutoresizingMaskIntoConstraints = false

        for v in [up, pathBar, statusLabel, spinner, treemap, reveal] { cv.addSubview(v) }

        NSLayoutConstraint.activate([
            up.topAnchor.constraint(equalTo: cv.topAnchor, constant: 12),
            up.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 12),
            pathBar.centerYAnchor.constraint(equalTo: up.centerYAnchor),
            pathBar.leadingAnchor.constraint(equalTo: up.trailingAnchor, constant: 10),
            pathBar.trailingAnchor.constraint(equalTo: statusLabel.leadingAnchor, constant: -10),
            spinner.centerYAnchor.constraint(equalTo: up.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: statusLabel.leadingAnchor, constant: -6),
            statusLabel.centerYAnchor.constraint(equalTo: up.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -12),
            statusLabel.widthAnchor.constraint(equalToConstant: 220),
            treemap.topAnchor.constraint(equalTo: up.bottomAnchor, constant: 12),
            treemap.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 12),
            treemap.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -12),
            treemap.bottomAnchor.constraint(equalTo: reveal.topAnchor, constant: -12),
            reveal.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -12),
            reveal.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -12),
        ])
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
            self?.focusedNode = root
            self?.pathBar.stringValue = root.url.path
            self?.statusLabel.stringValue = "\(root.fileCount) files · \(SizeFormatter.string(root.size))"
            self?.treemap.setRoot(root)
        })
    }

    @objc private func focusUp() {
        if let parent = focusedNode?.parent {
            focusedNode = parent
            pathBar.stringValue = relativePath(of: parent)
            treemap.setRoot(parent)
        }
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

/// Custom treemap drawing view. Draws each child of the root node as a rect
/// proportional to its size with a label.
final class TreemapView: NSView {

    var onClick: ((DiskScan.Node) -> Void)?
    private var rectsByNode: [(DiskScan.Node, CGRect)] = []
    private var root: DiskScan.Node?

    func setRoot(_ node: DiskScan.Node) {
        self.root = node
        recompute()
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        recompute()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        recompute()
    }

    private func recompute() {
        guard let root else { return }
        rectsByNode = DiskScan.squarify(root, in: bounds.insetBy(dx: 1, dy: 1))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        guard !rectsByNode.isEmpty else { return }
        let totalSize = root?.size ?? 1
        for (node, rect) in rectsByNode {
            let frac = Double(node.size) / Double(max(totalSize, 1))
            let color = colorFor(fraction: frac, isDir: node.isDirectory)
            color.setFill()
            rect.insetBy(dx: 1, dy: 1).fill()
            NSColor.black.withAlphaComponent(0.15).setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()

            // Label
            let nameSize = SizeFormatter.string(node.size)
            let label = "\(node.name)\n\(nameSize)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: rect.height < 30 ? 9 : 11, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.95),
            ]
            let attr = NSAttributedString(string: label, attributes: attrs)
            let padded = rect.insetBy(dx: 4, dy: 2)
            if padded.width > 20 && padded.height > 18 {
                attr.draw(in: padded)
            }
        }
    }

    private func colorFor(fraction: Double, isDir: Bool) -> NSColor {
        // Blue for files, orange-ish for folders, deepening with fraction
        let base = isDir
            ? NSColor(red: 0.95, green: 0.55, blue: 0.20, alpha: 1)
            : NSColor(red: 0.20, green: 0.55, blue: 0.95, alpha: 1)
        let alpha = 0.45 + min(0.55, fraction * 4)
        return base.withAlphaComponent(alpha)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for (node, rect) in rectsByNode where rect.contains(p) {
            onClick?(node)
            return
        }
    }
}

private extension String {
    /// Returns self if non-empty, otherwise the fallback.
    func ifEmpty(or fallback: String) -> String { isEmpty ? fallback : self }
}
