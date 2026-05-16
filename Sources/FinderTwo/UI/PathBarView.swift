import AppKit

/// Clickable breadcrumb-style path bar. Each path segment is a button.
final class PathBarView: NSView, ThemeObserving {
    var onSelectSegment: ((URL) -> Void)?
    var url: URL = URL(fileURLWithPath: "/") { didSet { rebuild() } }

    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        subscribeToTheme(self)

        stack.orientation = .horizontal
        stack.distribution = .gravityAreas
        stack.spacing = 0
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.documentView = stack
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.heightAnchor),
        ])
        // Bottom hairline
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Compute path segments from root to current by splitting the path string.
        let path = url.path
        var components: [String] = []
        if path.hasPrefix("/") {
            components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        } else {
            components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        }
        var segments: [URL] = [URL(fileURLWithPath: "/")]
        var cum = "/"
        for c in components {
            if cum.hasSuffix("/") {
                cum += c
            } else {
                cum += "/" + c
            }
            segments.append(URL(fileURLWithPath: cum))
        }

        for (idx, seg) in segments.enumerated() {
            let title: String
            if idx == 0 {
                title = seg.path == "/" ? "Macintosh HD" : seg.lastPathComponent
            } else {
                title = seg.lastPathComponent
            }
            let btn = NSButton(title: title, target: self, action: #selector(segmentClicked(_:)))
            btn.bezelStyle = .recessed
            btn.isBordered = false
            btn.setButtonType(.momentaryChange)
            btn.contentTintColor = .labelColor
            btn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            btn.tag = idx
            btn.translatesAutoresizingMaskIntoConstraints = false

            // Tiny folder icon
            let icon = NSWorkspace.shared.icon(forFile: seg.path)
            icon.size = NSSize(width: 14, height: 14)
            btn.image = icon
            btn.imagePosition = .imageLeading

            stack.addArrangedSubview(btn)

            if idx < segments.count - 1 {
                let chev = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) ?? NSImage())
                chev.contentTintColor = .tertiaryLabelColor
                chev.translatesAutoresizingMaskIntoConstraints = false
                chev.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
                stack.addArrangedSubview(chev)
            }
        }
        self.segments = segments
    }

    private var segments: [URL] = []

    @objc private func segmentClicked(_ sender: NSButton) {
        let idx = sender.tag
        guard segments.indices.contains(idx) else { return }
        onSelectSegment?(segments[idx])
    }

    @objc func applyTheme() {
        let t = ThemeManager.shared.current
        layer?.backgroundColor = t.pathBarBackground.cgColor
    }

    /// Pure helper — used by tests to verify segment computation without
    /// instantiating a view.
    static func testSegments(for url: URL) -> [URL] {
        let path = url.path
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var out: [URL] = [URL(fileURLWithPath: "/")]
        var cum = "/"
        for c in parts {
            if !cum.hasSuffix("/") { cum += "/" }
            cum += c
            out.append(URL(fileURLWithPath: cum))
        }
        return out
    }
}
