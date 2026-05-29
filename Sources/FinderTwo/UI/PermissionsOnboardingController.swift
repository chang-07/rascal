import AppKit

/// One-time, on-brand window that asks for Full Disk Access so Rascal can
/// reach every file with no per-folder prompts — and, with a stable signature,
/// never has to ask again. Presented at most once (see PermissionsManager).
final class PermissionsOnboardingController: NSWindowController, ThemeObserving {

    private let card = NSView()
    private let iconView = NSImageView()
    private let eyebrow = NSTextField(labelWithString: "ONE-TIME SETUP")
    private let titleLabel = NSTextField(labelWithString: "Give Rascal full access")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let bulletStack = NSStackView()
    private let warningLabel = NSTextField(wrappingLabelWithString: "")
    private let grantButton = NSButton(title: "Open System Settings", target: nil, action: nil)
    private let laterButton = NSButton(title: "Maybe Later", target: nil, action: nil)

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.center()
        self.init(window: w)
        buildUI()
        subscribeToTheme(self)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        content.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: content.topAnchor),
            card.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        eyebrow.font = .systemFont(ofSize: 11, weight: .heavy)
        eyebrow.alignment = .center

        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.alignment = .center

        bodyLabel.stringValue = "Rascal is a file manager — it works best when it can see all your files. Grant Full Disk Access once and macOS will remember it. No per-folder pop-ups, ever again."
        bodyLabel.font = .systemFont(ofSize: 13)
        bodyLabel.alignment = .center
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false

        bulletStack.orientation = .vertical
        bulletStack.alignment = .leading
        bulletStack.spacing = 8
        bulletStack.translatesAutoresizingMaskIntoConstraints = false
        for (symbol, text) in [
            ("externaldrive", "Browse external & network drives"),
            ("folder", "Open Desktop, Documents & Downloads instantly"),
            ("lock.open", "Skip the repeated permission prompts"),
        ] {
            bulletStack.addArrangedSubview(makeBullet(symbol: symbol, text: text))
        }

        warningLabel.font = .systemFont(ofSize: 11)
        warningLabel.alignment = .center
        warningLabel.translatesAutoresizingMaskIntoConstraints = false
        warningLabel.isHidden = !PermissionsManager.isAdHocSigned
        warningLabel.stringValue = "⚠︎ This build is ad-hoc signed, so grants won't persist across rebuilds. Run ./setup-signing.sh once to fix that."

        grantButton.target = self
        grantButton.action = #selector(grant)
        grantButton.bezelStyle = .rounded
        grantButton.keyEquivalent = "\r"          // default button → accent-tinted
        grantButton.translatesAutoresizingMaskIntoConstraints = false

        laterButton.target = self
        laterButton.action = #selector(later)
        laterButton.bezelStyle = .rounded
        laterButton.keyEquivalent = "\u{1b}"       // Esc
        laterButton.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [laterButton, grantButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false

        for v in [iconView, eyebrow, titleLabel, bodyLabel, bulletStack, warningLabel, buttons] {
            v.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(v)
        }
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: card.topAnchor, constant: 28),
            iconView.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 72),
            iconView.heightAnchor.constraint(equalToConstant: 72),

            eyebrow.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 12),
            eyebrow.centerXAnchor.constraint(equalTo: card.centerXAnchor),

            titleLabel.topAnchor.constraint(equalTo: eyebrow.bottomAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 32),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -32),

            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            bodyLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 36),
            bodyLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -36),

            bulletStack.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 18),
            bulletStack.centerXAnchor.constraint(equalTo: card.centerXAnchor),

            warningLabel.topAnchor.constraint(equalTo: bulletStack.bottomAnchor, constant: 16),
            warningLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 32),
            warningLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -32),

            buttons.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
            buttons.centerXAnchor.constraint(equalTo: card.centerXAnchor),
        ])
    }

    private func makeBullet(symbol: String, text: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        let img = NSImageView()
        img.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        img.translatesAutoresizingMaskIntoConstraints = false
        img.widthAnchor.constraint(equalToConstant: 18).isActive = true
        img.contentTintColor = ThemeManager.shared.effectiveAccent
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.tag = 0xB117   // marker so applyTheme can recolor bullet labels
        row.addArrangedSubview(img)
        row.addArrangedSubview(label)
        return row
    }

    @objc func applyTheme() {
        let t = ThemeManager.shared.current
        let isSystem = t.id == "system"
        card.layer?.backgroundColor = (isSystem ? NSColor.windowBackgroundColor : t.background).cgColor
        eyebrow.textColor = ThemeManager.shared.effectiveAccent
        titleLabel.textColor = isSystem ? .labelColor : t.labelPrimary
        bodyLabel.textColor = isSystem ? .secondaryLabelColor : t.labelSecondary
        warningLabel.textColor = .systemOrange
        for row in bulletStack.arrangedSubviews {
            for sub in (row as? NSStackView)?.arrangedSubviews ?? [] {
                if let iv = sub as? NSImageView { iv.contentTintColor = ThemeManager.shared.effectiveAccent }
                if let tf = sub as? NSTextField, tf.tag == 0xB117 {
                    tf.textColor = isSystem ? .labelColor : t.labelPrimary
                }
            }
        }
    }

    @objc private func grant() {
        PermissionsManager.openFullDiskAccessSettings()
        close()
    }

    @objc private func later() { close() }

    // MARK: Test hooks
    var testTitle: String { titleLabel.stringValue }
    var testShowsAdHocWarning: Bool { !warningLabel.isHidden }
    var testBulletCount: Int { bulletStack.arrangedSubviews.count }
}
