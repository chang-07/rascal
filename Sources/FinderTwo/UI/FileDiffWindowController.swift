import AppKit

/// Shows a unified diff of two files with +/- line coloring.
final class FileDiffWindowController: NSWindowController, ThemeObserving {

    static func show(a: URL, b: URL, parent: NSWindow?) {
        let c = FileDiffWindowController(a: a, b: b)
        c.window?.center()
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        PresentedControllers.retain(c)
        c.run()
    }

    private let a: URL
    private let b: URL
    private let textView = NSTextView()
    private let status = NSTextField(labelWithString: "Comparing…")
    private let scrollView = NSScrollView()
    private var rawDiff: String?

    init(a: URL, b: URL) {
        self.a = a; self.b = b
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "\(a.lastPathComponent) ↔ \(b.lastPathComponent)"
        win.minSize = NSSize(width: 420, height: 300)
        super.init(window: win)
        ThemeChrome.apply(to: window)
        win.contentView = buildContent()
        subscribeToTheme(self)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildContent() -> NSView {
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.tag = 101
        status.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isRichText = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        textView.autoresizingMask = [.width]
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
 
        let root = NSView()
        root.addSubview(status); root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            status.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scrollView.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    private func run() {
        let a = self.a, b = self.b
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let diff = FileDiff.unified(a, b)
            DispatchQueue.main.async {
                self?.rawDiff = diff
                self?.render(diff)
            }
        }
    }

    private func render(_ diff: String?) {
        guard let diff else {
            status.stringValue = "Couldn't compare (one file may be binary)."
            return
        }
        if diff.isEmpty {
            status.stringValue = "The files are identical."
            return
        }
        status.stringValue = "Showing differences."
        let out = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: ThemeChrome.primary,
        ]
        for line in diff.components(separatedBy: "\n") {
            var attrs = base
            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                attrs[.foregroundColor] = NSColor.systemGreen
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                attrs[.foregroundColor] = NSColor.systemRed
            } else if line.hasPrefix("@@") {
                attrs[.foregroundColor] = NSColor.systemBlue
            } else if line.hasPrefix("+++") || line.hasPrefix("---") {
                attrs[.foregroundColor] = ThemeChrome.secondary
            }
            out.append(NSAttributedString(string: line + "\n", attributes: attrs))
        }
        textView.textStorage?.setAttributedString(out)
    }

    @objc func applyTheme() {
        ThemeChrome.apply(to: window)
        if let cv = window?.contentView {
            ThemeChrome.updateColors(in: cv)
        }
        let t = ThemeManager.shared.current
        let custom = t.id != "system"
        let bg = custom ? t.background : .controlBackgroundColor
        textView.backgroundColor = bg
        scrollView.drawsBackground = true
        scrollView.backgroundColor = bg
        render(rawDiff)
    }
}
