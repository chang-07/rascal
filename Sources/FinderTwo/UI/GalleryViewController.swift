import AppKit
import QuickLookUI

/// Gallery view: a large Quick Look preview of the focused item above a
/// horizontal filmstrip of thumbnails. Click a thumb to preview it,
/// double-click (or Return) to open.
final class GalleryViewController: NSViewController, ThemeObserving {
    var onOpen: ((FileItem) -> Void)?
    var onSelectionChange: (([FileItem]) -> Void)?

    private let ql = QLPreviewView(frame: .zero, style: .normal)
    private let nameLabel = NSTextField(labelWithString: "")
    private let strip = NSStackView()
    private var items: [FileItem] = []
    private(set) var focused: FileItem?
    private var stripButtons: [NSButton] = []

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        let previewHost = ql ?? QLPreviewView()
        previewHost.translatesAutoresizingMaskIntoConstraints = false
        previewHost.autostarts = true

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)

        strip.orientation = .horizontal
        strip.spacing = 8
        strip.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        strip.translatesAutoresizingMaskIntoConstraints = false
        let stripScroll = NSScrollView()
        stripScroll.hasHorizontalScroller = true
        stripScroll.hasVerticalScroller = false
        stripScroll.drawsBackground = false
        stripScroll.documentView = strip
        stripScroll.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(previewHost)
        root.addSubview(nameLabel)
        root.addSubview(stripScroll)
        NSLayoutConstraint.activate([
            previewHost.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            previewHost.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            previewHost.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            nameLabel.topAnchor.constraint(equalTo: previewHost.bottomAnchor, constant: 6),
            nameLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            stripScroll.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 6),
            stripScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stripScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stripScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stripScroll.heightAnchor.constraint(equalToConstant: 92),
            strip.heightAnchor.constraint(equalTo: stripScroll.heightAnchor),
        ])
        view = root
        subscribeToTheme(self)
    }

    @objc func applyTheme() {
        let t = ThemeManager.shared.current
        let bg: NSColor = t.id == "system" ? .controlBackgroundColor : t.background
        view.layer?.backgroundColor = bg.cgColor
        nameLabel.textColor = t.id == "system" ? .labelColor : t.labelPrimary
    }

    func reload(_ items: [FileItem]) {
        self.items = items
        rebuildStrip()
        focus(items.first)
    }

    private func rebuildStrip() {
        strip.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stripButtons.removeAll()
        for (i, item) in items.enumerated() {
            let b = NSButton(title: "", target: self, action: #selector(thumbClicked(_:)))
            b.tag = i
            b.imagePosition = .imageOnly
            b.bezelStyle = .smallSquare
            b.isBordered = true
            let icon = IconCache.shared.icon(for: item)
            icon.size = NSSize(width: 56, height: 56)
            b.image = icon
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 72).isActive = true
            b.toolTip = item.name
            let dbl = NSClickGestureRecognizer(target: self, action: #selector(thumbDoubleClicked(_:)))
            dbl.numberOfClicksRequired = 2
            b.addGestureRecognizer(dbl)
            strip.addArrangedSubview(b)
            stripButtons.append(b)
        }
    }

    private func focus(_ item: FileItem?) {
        focused = item
        ql?.previewItem = item?.url as NSURL?
        nameLabel.stringValue = item?.name ?? "No selection"
        for (i, b) in stripButtons.enumerated() {
            b.keyEquivalent = ""
            b.layer?.borderWidth = 0
            b.state = (items.indices.contains(i) && items[i] == item) ? .on : .off
        }
        onSelectionChange?(item.map { [$0] } ?? [])
    }

    // MARK: Keyboard navigation (vim j/k/gg/G + open)

    /// Move the focused item by `delta` (j/k map to ±1), clamped + scrolled.
    func moveFocus(by delta: Int) {
        guard !items.isEmpty else { return }
        let cur = focused.flatMap { items.firstIndex(of: $0) } ?? (delta >= 0 ? -1 : items.count)
        let next = max(0, min(items.count - 1, cur + delta))
        focus(items[next])
        if stripButtons.indices.contains(next) {
            stripButtons[next].scrollToVisible(stripButtons[next].bounds)
        }
    }
    func focusFirst() { guard let f = items.first else { return }; focus(f) }
    func focusLast() { guard let l = items.last else { return }; focus(l) }
    func openFocused() { if let f = focused { onOpen?(f) } }

    @objc private func thumbClicked(_ sender: NSButton) {
        guard items.indices.contains(sender.tag) else { return }
        focus(items[sender.tag])
    }
    @objc private func thumbDoubleClicked(_ g: NSClickGestureRecognizer) {
        guard let b = g.view as? NSButton, items.indices.contains(b.tag) else { return }
        onOpen?(items[b.tag])
    }
}
