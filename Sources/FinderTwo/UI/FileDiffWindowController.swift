import AppKit

/// Shows a unified diff of two files with +/- line coloring.
final class FileDiffWindowController: NSWindowController, ThemeObserving {

    enum DiffMode {
        case fileCompare(a: URL, b: URL)
        case gitDiff(repoRoot: URL, fileURL: URL)
    }

    static func show(a: URL, b: URL, parent: NSWindow?) {
        let c = FileDiffWindowController(mode: .fileCompare(a: a, b: b))
        c.window?.center()
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        PresentedControllers.retain(c)
        c.run()
    }

    static func showGitDiff(repoRoot: URL, fileURL: URL, parent: NSWindow?) {
        let c = FileDiffWindowController(mode: .gitDiff(repoRoot: repoRoot, fileURL: fileURL))
        c.window?.center()
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        PresentedControllers.retain(c)
        c.run()
    }

    private let mode: DiffMode
    private let textView = NSTextView()
    private let status = NSTextField(labelWithString: "Comparing…")
    private let scrollView = NSScrollView()
    private var rawDiff: String?

    init(mode: DiffMode) {
        self.mode = mode
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        switch mode {
        case .fileCompare(let a, let b):
            win.title = "\(a.lastPathComponent) ↔ \(b.lastPathComponent)"
        case .gitDiff(_, let fileURL):
            win.title = "Git Diff: \(fileURL.lastPathComponent)"
        }
        win.minSize = NSSize(width: 420, height: 300)
        super.init(window: win)
        ThemeChrome.apply(to: window)
        win.contentView = buildContent()
        subscribeToTheme(self)
    }
    convenience init(a: URL, b: URL) {
        self.init(mode: .fileCompare(a: a, b: b))
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
        switch mode {
        case .fileCompare(let a, let b):
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let diff = FileDiff.unified(a, b)
                DispatchQueue.main.async {
                    self?.rawDiff = diff
                    self?.render(diff)
                }
            }
        case .gitDiff(let repoRoot, let fileURL):
            status.stringValue = "Fetching git diff…"
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let diff = GitStatus.gitDiff(repoRoot: repoRoot, fileURL: fileURL)
                DispatchQueue.main.async {
                    self?.rawDiff = diff
                    self?.render(diff)
                }
            }
        }
    }

    private func render(_ diff: String?) {
        guard let diff else {
            status.stringValue = "Couldn't compare (one file may be binary)."
            return
        }
        if diff.isEmpty {
            switch mode {
            case .fileCompare:
                status.stringValue = "The files are identical."
            case .gitDiff:
                status.stringValue = "No changes compared to Git HEAD."
            }
            textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
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
