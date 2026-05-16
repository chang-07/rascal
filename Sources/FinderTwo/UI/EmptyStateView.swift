import AppKit

/// Centered placeholder shown over the file list when there are no items
/// (either because the folder is empty or the active filter matches nothing).
final class EmptyStateView: NSView, ThemeObserving {

    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")
    let icon = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 36, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = .tertiaryLabelColor
        subtitleLabel.alignment = .center

        addSubview(icon)
        addSubview(titleLabel)
        addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -24),
            icon.widthAnchor.constraint(equalToConstant: 44),
            icon.heightAnchor.constraint(equalToConstant: 44),
            titleLabel.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 10),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
        subscribeToTheme(self)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Configure for "folder is empty".
    func configureEmpty() {
        icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        titleLabel.stringValue = "This folder is empty"
        subtitleLabel.stringValue = "Drag files here or press ⌘⇧N for a new folder."
    }

    /// Configure for "no items match the current filter".
    func configureNoMatches(query: String) {
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        titleLabel.stringValue = "No matches for “\(query)”"
        subtitleLabel.stringValue = "Press Esc to clear the filter."
    }

    @objc func applyTheme() {
        let t = ThemeManager.shared.current
        layer?.backgroundColor = t.background.cgColor
        titleLabel.textColor = t.labelSecondary
        subtitleLabel.textColor = t.labelTertiary
    }
}
