import AppKit

protocol TabStripDelegate: AnyObject {
    func tabStripDidSelect(index: Int)
    func tabStripDidRequestClose(index: Int)
    func tabStripDidRequestNew()
}

final class TabStripView: NSView {
    weak var delegate: TabStripDelegate?

    private let stack = NSStackView()
    private let newButton = NSButton(title: "+", target: nil, action: nil)
    private(set) var titles: [String] = []
    private(set) var activeIndex: Int = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.6).cgColor

        stack.orientation = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        newButton.translatesAutoresizingMaskIntoConstraints = false
        newButton.bezelStyle = .recessed
        newButton.isBordered = false
        newButton.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        newButton.target = self
        newButton.action = #selector(handleNew)
        addSubview(newButton)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            newButton.leadingAnchor.constraint(equalTo: stack.trailingAnchor, constant: 4),
            newButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            newButton.widthAnchor.constraint(equalToConstant: 22),
            newButton.heightAnchor.constraint(equalToConstant: 22),
        ])

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

    private var tooltips: [String] = []

    func setTabs(_ titles: [String], activeIndex: Int, tooltips: [String] = []) {
        self.titles = titles
        self.activeIndex = activeIndex
        self.tooltips = tooltips
        rebuild()
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, t) in titles.enumerated() {
            let tab = TabButton(title: t, isActive: i == activeIndex, index: i)
            if tooltips.indices.contains(i) { tab.toolTip = tooltips[i] }
            tab.onClick = { [weak self] idx in self?.delegate?.tabStripDidSelect(index: idx) }
            tab.onClose = { [weak self] idx in self?.delegate?.tabStripDidRequestClose(index: idx) }
            stack.addArrangedSubview(tab)
        }
    }

    @objc private func handleNew() {
        delegate?.tabStripDidRequestNew()
    }
}

private final class TabButton: NSView {
    let index: Int
    var onClick: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let close = NSButton(title: "×", target: nil, action: nil)
    private let isActive: Bool
    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    init(title: String, isActive: Bool, index: Int) {
        self.index = index
        self.isActive = isActive
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous

        label.stringValue = title
        label.font = NSFont.systemFont(ofSize: 12, weight: isActive ? .medium : .regular)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false

        close.bezelStyle = .recessed
        close.isBordered = false
        close.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        close.contentTintColor = .tertiaryLabelColor
        close.target = self
        close.action = #selector(handleClose)
        close.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(close)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
            close.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 16),
            close.heightAnchor.constraint(equalToConstant: 16),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        applyAppearance()
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
    override func mouseEntered(with event: NSEvent) { isHovering = true; applyAppearance() }
    override func mouseExited(with event: NSEvent)  { isHovering = false; applyAppearance() }

    override func mouseDown(with event: NSEvent) {
        // Single-click selects the tab. Click-on-close uses NSButton path.
        onClick?(index)
    }
    @objc private func handleClose() { onClose?(index) }

    private func applyAppearance() {
        let accent = ThemeManager.shared.effectiveAccent
        if isActive {
            layer?.backgroundColor = accent.withAlphaComponent(0.20).cgColor
            label.textColor = .labelColor
        } else if isHovering {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
            label.textColor = .labelColor
        } else {
            layer?.backgroundColor = .clear
            label.textColor = .secondaryLabelColor
        }
    }
}
