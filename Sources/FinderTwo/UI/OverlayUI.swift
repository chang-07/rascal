import AppKit

/// Shared look for the overlay finders — Command Palette, Find Files, and
/// Search File Contents — so they feel like one coherent control: the same
/// floating panel, the same big rounded search field, and the same
/// icon + title + subtitle result row. The panel adopts the active theme, so
/// in Rascal Light it's a warm light card, in Rascal Dark a deep one.
enum OverlayUI {
    static let panelWidth: CGFloat = 640
    static let panelHeight: CGFloat = 440
    static let rowHeight: CGFloat = 36

    private static var isDark: Bool {
        let t = ThemeManager.shared.current
        if t.id == "system" { return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
        return t.appearance == .dark
    }

    /// A floating, themed panel with a hidden title bar and rounded corners.
    static func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.level = .modalPanel
        p.becomesKeyOnlyIfNeeded = false
        p.hidesOnDeactivate = true
        p.isMovableByWindowBackground = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        for b: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            p.standardWindowButton(b)?.isHidden = true
        }
        let t = ThemeManager.shared.current
        switch t.appearance {
        case .light: p.appearance = NSAppearance(named: .aqua)
        case .dark:  p.appearance = NSAppearance(named: .darkAqua)
        case .automatic: p.appearance = nil
        }
        p.contentView = OverlayPanelBackground()
        return p
    }

    /// Position a floating finder over its parent window instead of the screen,
    /// so the palette / Find Files / Search Contents appear on the window the
    /// user is actually using (matters most with multiple windows or displays).
    /// Sits a little above the parent's vertical centre — the conventional spot
    /// for a launcher overlay — and stays fully on the parent's screen. Falls
    /// back to screen-centring when there's no parent window.
    static func center(_ panel: NSWindow, over parent: NSWindow?) {
        guard let parent, let screen = parent.screen ?? NSScreen.main else {
            panel.center(); return
        }
        let p = parent.frame
        let size = panel.frame.size
        var origin = NSPoint(
            x: p.midX - size.width / 2,
            y: p.midY - size.height / 2 + p.height * 0.12   // nudge above centre
        )
        let vf = screen.visibleFrame
        origin.x = min(max(origin.x, vf.minX), max(vf.minX, vf.maxX - size.width))
        origin.y = min(max(origin.y, vf.minY), max(vf.minY, vf.maxY - size.height))
        panel.setFrameOrigin(origin)
    }

    /// The big rounded search field used at the top of every overlay finder.
    static func makeSearchField(placeholder: String) -> NSTextField {
        let f = NSTextField()
        f.translatesAutoresizingMaskIntoConstraints = false
        f.placeholderString = placeholder
        f.font = .systemFont(ofSize: 16)
        f.bezelStyle = .roundedBezel
        f.focusRingType = .none
        return f
    }

    /// Apply the shared inset, clear-backed, single-column look to a results
    /// table (adds one autosizing column).
    static func configureResultsTable(_ table: NSTableView) {
        table.style = .inset
        table.rowHeight = rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.headerView = nil
        table.backgroundColor = .clear
        table.allowsMultipleSelection = false
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
    }

    /// Apply the shared borderless, clear-backed scroll look.
    static func configureResultsScroll(_ scroll: NSScrollView, documentView table: NSTableView) {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = table
    }

    /// Shared selection row — the theme's selectionBackground, so every finder
    /// highlights in Rascal's orange (system theme → native highlight).
    static func makeRowView() -> NSTableRowView { ThemedRowView() }
}

/// Rounded, themed background that fills an overlay panel's content view.
final class OverlayPanelBackground: NSView {
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); wantsLayer = true; apply() }
    required init?(coder: NSCoder) { super.init(coder: coder); wantsLayer = true; apply() }
    override var isFlipped: Bool { true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); apply() }

    private func apply() {
        let t = ThemeManager.shared.current
        let bg = t.id == "system" ? NSColor.windowBackgroundColor : t.background
        let border = t.id == "system" ? NSColor.separatorColor : t.labelTertiary.withAlphaComponent(0.35)
        layer?.backgroundColor = bg.cgColor
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = border.cgColor
    }
}

/// One result row: icon + title over a muted subtitle, themed. Used by the
/// palette and both search modes.
final class OverlayResultRow: NSTableCellView, ThemeObserving {
    let iconView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")

    override var canBecomeKeyView: Bool { return false }
    override var acceptsFirstResponder: Bool { return false }

    /// Grep snippets read better monospaced; filenames/commands don't.
    var monospacedSubtitle: Bool = false {
        didSet {
            subtitleLabel.font = monospacedSubtitle
                ? .monospacedSystemFont(ofSize: 11, weight: .regular)
                : .systemFont(ofSize: 11)
        }
    }

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        subtitleLabel.font = .systemFont(ofSize: 11)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.lineBreakMode = .byTruncatingTail
        addSubview(iconView); addSubview(titleLabel); addSubview(subtitleLabel)
        imageView = iconView
        textField = titleLabel
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
        ])
        subscribeToTheme(self)
    }

    @objc func applyTheme() {
        let t = ThemeManager.shared.current
        titleLabel.textColor = t.id == "system" ? .labelColor : t.labelPrimary
        subtitleLabel.textColor = t.id == "system" ? .secondaryLabelColor : t.labelSecondary
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
