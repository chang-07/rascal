import AppKit

/// Scans a folder for byte-identical files and lists the duplicate groups;
/// each file row reveals in Finder on click.
final class DuplicateFinderWindowController: NSWindowController, ThemeObserving {

    static func show(for root: URL, parent: NSWindow?) {
        let c = DuplicateFinderWindowController(root: root)
        c.window?.center()
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        PresentedControllers.retain(c)
        c.scan()
    }

    private let root: URL
    private let status = NSTextField(labelWithString: "Scanning…")
    private let stack = NSStackView()

    init(root: URL) {
        self.root = root
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "Duplicates in \(root.lastPathComponent)"
        win.minSize = NSSize(width: 380, height: 280)
        super.init(window: win)
        ThemeChrome.apply(to: window)
        win.contentView = buildContent()
        subscribeToTheme(self)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildContent() -> NSView {
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.tag = 101
        status.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = stack
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(status); root.addSubview(scroll)
        NSLayoutConstraint.activate([
            status.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        return root
    }

    private func scan() {
        DuplicateFinder.find(in: root) { [weak self] groups in
            self?.present(groups)
        }
    }

    private func present(_ groups: [DuplicateFinder.Group]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let wasted = groups.reduce(Int64(0)) { $0 + Int64($1.urls.count - 1) * $1.size }
        if groups.isEmpty {
            status.stringValue = "No duplicate files found."
            return
        }
        status.stringValue = "\(groups.count) duplicate group\(groups.count == 1 ? "" : "s") · \(SizeFormatter.string(wasted)) recoverable"
        for (i, g) in groups.enumerated() {
            let header = NSTextField(labelWithString: "\(g.urls.count) identical · \(SizeFormatter.string(g.size))")
            header.font = .systemFont(ofSize: 11, weight: .semibold)
            header.textColor = .secondaryLabelColor
            header.tag = 101
            stack.addArrangedSubview(header)
            for url in g.urls {
                let b = NSButton(title: (url.path as NSString).abbreviatingWithTildeInPath,
                                 target: self, action: #selector(reveal(_:)))
                b.bezelStyle = .inline
                b.alignment = .left
                b.isBordered = false
                b.contentTintColor = ThemeChrome.isSystem ? .linkColor : ThemeManager.shared.effectiveAccent
                b.toolTip = url.path
                b.identifier = NSUserInterfaceItemIdentifier(url.path)
                stack.addArrangedSubview(b)
            }
            if i < groups.count - 1 {
                let sep = NSBox(); sep.boxType = .separator
                sep.translatesAutoresizingMaskIntoConstraints = false
                sep.widthAnchor.constraint(equalToConstant: 480).isActive = true
                stack.addArrangedSubview(sep)
            }
        }
    }

    @objc private func reveal(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        FileOps.revealInFinder([URL(fileURLWithPath: path)])
    }

    @objc func applyTheme() {
        ThemeChrome.apply(to: window)
        if let cv = window?.contentView {
            ThemeChrome.updateColors(in: cv)
        }
        func updateButtons(in view: NSView) {
            if let b = view as? NSButton, b.bezelStyle == .inline {
                b.contentTintColor = ThemeChrome.isSystem ? .linkColor : ThemeManager.shared.effectiveAccent
            }
            for sub in view.subviews {
                updateButtons(in: sub)
            }
        }
        if let cv = window?.contentView {
            updateButtons(in: cv)
        }
    }
}
