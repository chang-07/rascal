import AppKit

/// A horizontal strip of buttons that invoke Actions. Configurable per-window
/// via UserDefaults. Default config: New Folder, Get Info, Trash, Copy, Paste,
/// Duplicate, Reveal in Finder, Toggle Hidden, Cycle Theme, Command Palette.
final class HotbarView: NSView, ThemeObserving {
    weak var target: BrowserWindowController?
    private let stack = NSStackView()
    private static let storageKey = "FinderTwo.hotbar.v1"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        subscribeToTheme(self)
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let line = SeparatorView()
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
        rebuild()
        NotificationCenter.default.addObserver(self, selector: #selector(rebuild),
                                               name: HotbarView.didChangeConfig, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    static let didChangeConfig = Notification.Name("FinderTwo.hotbar.configChanged")

    static func defaultIds() -> [String] {
        ["file.new-folder", "file.get-info", "file.trash",
         "edit.copy", "edit.paste", "edit.duplicate",
         "file.reveal-finder", "view.toggle-hidden",
         "view.cycle-theme", "search.palette"]
    }

    static func currentIds() -> [String] {
        (UserDefaults.standard.array(forKey: storageKey) as? [String]) ?? defaultIds()
    }

    static func setIds(_ ids: [String]) {
        UserDefaults.standard.set(ids, forKey: storageKey)
        NotificationCenter.default.post(name: didChangeConfig, object: nil)
    }

    @objc private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for id in HotbarView.currentIds() {
            guard let action = ActionRegistry.action(id: id) else { continue }
            let btn = HotbarButton(id: id, title: action.title)
            if let symbol = action.icon,
               let img = NSImage(systemSymbolName: symbol, accessibilityDescription: action.title) {
                let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                btn.image = img.withSymbolConfiguration(cfg) ?? img
                btn.imagePosition = .imageOnly
            } else {
                btn.title = action.title
            }
            btn.target = self
            btn.action = #selector(performHotbarAction(_:))
            btn.toolTip = action.title + (ActionRegistry.shortcut(for: id).map { "  \($0.displayLabel)" } ?? "")
            stack.addArrangedSubview(btn)
            btn.widthAnchor.constraint(equalToConstant: 28).isActive = true
            btn.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
    }

    @objc func applyTheme() {
        let t = ThemeManager.shared.current
        layer?.backgroundColor = t.toolbarBackground.cgColor
        for v in stack.arrangedSubviews { (v as? HotbarButton)?.refreshTheme() }
    }

    @objc private func performHotbarAction(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let action = ActionRegistry.action(id: id),
              let wc = target else { return }
        action.perform(wc)
    }
}

/// Borderless action button with manual hover/pressed styling so the hotbar
/// looks flat in all themes (instead of the OS default textured pill).
final class HotbarButton: NSButton {
    private let actionId: String
    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    init(id: String, title: String) {
        self.actionId = id
        super.init(frame: .zero)
        self.identifier = NSUserInterfaceItemIdentifier(id)
        self.title = title
        self.translatesAutoresizingMaskIntoConstraints = false
        self.isBordered = false
        self.bezelStyle = .recessed
        self.imagePosition = .imageOnly
        self.wantsLayer = true
        self.layer?.cornerRadius = 5
        self.layer?.cornerCurve = .continuous
        self.contentTintColor = ThemeManager.shared.current.labelSecondary
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds,
                                options: [.mouseEnteredAndExited, .activeInActiveApp],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }
    override func mouseEntered(with event: NSEvent) { isHovering = true; refreshTheme() }
    override func mouseExited(with event: NSEvent)  { isHovering = false; refreshTheme() }

    func refreshTheme() {
        let t = ThemeManager.shared.current
        if isHovering {
            layer?.backgroundColor = t.accent.withAlphaComponent(0.15).cgColor
            contentTintColor = t.labelPrimary
        } else {
            layer?.backgroundColor = .clear
            contentTintColor = t.labelSecondary
        }
    }
}
