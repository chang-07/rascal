import AppKit

/// Shared look for the overlay finders — Command Palette, Find Files, and
/// Search File Contents — so they feel like one coherent control: the same
/// floating HUD panel, the same big rounded search field, and the same
/// icon + title + subtitle result row.
enum OverlayUI {
    static let panelWidth: CGFloat = 640
    static let panelHeight: CGFloat = 440
    static let rowHeight: CGFloat = 36

    /// A floating, non-activating HUD panel with a hidden title bar.
    static func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.titled, .closable, .nonactivatingPanel, .hudWindow, .resizable],
            backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.level = .modalPanel
        p.becomesKeyOnlyIfNeeded = false
        p.hidesOnDeactivate = true
        return p
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
}

/// One result row: icon + bold-ish title over a muted subtitle. Used by the
/// palette and both search modes.
final class OverlayResultRow: NSTableCellView {
    let iconView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")

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
        subtitleLabel.textColor = .secondaryLabelColor
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
    }
}
