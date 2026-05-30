import AppKit

/// Shows a unified diff of two files with +/- line coloring.
final class FileDiffWindowController: NSWindowController {

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

    init(a: URL, b: URL) {
        self.a = a; self.b = b
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "\(a.lastPathComponent) ↔ \(b.lastPathComponent)"
        win.minSize = NSSize(width: 420, height: 300)
        super.init(window: win)
        ThemeChrome.apply(to: window)
        win.contentView = buildContent()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildContent() -> NSView {
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isRichText = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        textView.autoresizingMask = [.width]
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        let root = NSView()
        root.addSubview(status); root.addSubview(scroll)
        NSLayoutConstraint.activate([
            status.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    private func run() {
        let a = self.a, b = self.b
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let diff = FileDiff.unified(a, b)
            DispatchQueue.main.async { self?.render(diff) }
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
            .foregroundColor: NSColor.labelColor,
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
                attrs[.foregroundColor] = NSColor.secondaryLabelColor
            }
            out.append(NSAttributedString(string: line + "\n", attributes: attrs))
        }
        textView.textStorage?.setAttributedString(out)
    }
}
