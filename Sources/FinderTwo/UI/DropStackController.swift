import AppKit
import UniformTypeIdentifiers

/// The Drop Stack panel: a small floating shelf that collects files (drop onto
/// it, or "Add to Drop Stack" from the context menu) and lets you drag them
/// back out — or copy/move the whole stack into the frontmost window's folder.
final class DropStackController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = DropStackController()

    private let table = NSTableView()
    private let countLabel = NSTextField(labelWithString: "")
    private var items: [URL] = []

    private init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 360),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Drop Stack"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 200, height: 200)
        super.init(window: panel)
        panel.contentView = buildContent()
        reload()
        NotificationCenter.default.addObserver(self, selector: #selector(reload),
                                               name: DropStack.didChange, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    func present() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    /// Toggle visibility (View ▸ Drop Stack).
    func toggle() {
        if window?.isVisible == true { window?.orderOut(nil) } else { present() }
    }

    private func buildContent() -> NSView {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        col.title = "Items"
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: false)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor

        let clear = NSButton(title: "Clear", target: self, action: #selector(clearAll))
        clear.bezelStyle = .rounded
        let header = NSStackView(views: [countLabel, NSView(), clear])
        header.orientation = .horizontal
        header.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)

        let copyBtn = NSButton(title: "Copy Here", target: self, action: #selector(copyAllHere))
        let moveBtn = NSButton(title: "Move Here", target: self, action: #selector(moveAllHere))
        for b in [copyBtn, moveBtn] { b.bezelStyle = .rounded }
        let footer = NSStackView(views: [copyBtn, moveBtn])
        footer.orientation = .horizontal
        footer.distribution = .fillEqually
        footer.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 8, right: 10)

        let root = NSView()
        for v in [header, scroll, footer] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    @objc func reload() {
        items = DropStack.all()
        countLabel.stringValue = items.isEmpty ? "Empty" : "\(items.count) item\(items.count == 1 ? "" : "s")"
        table.reloadData()
    }

    @objc private func clearAll() { DropStack.clear() }

    private var frontFolder: URL? {
        BrowserWindowController.frontmost?.activePaneURL
    }
    @objc private func copyAllHere() { transferAll(move: false) }
    @objc private func moveAllHere() { transferAll(move: true) }
    private func transferAll(move: Bool) {
        guard !items.isEmpty, let dest = frontFolder else { NSSound.beep(); return }
        FileOps.transfer(items, into: dest, move: move, from: BrowserWindowController.frontmost?.window)
        if move { DropStack.clear() }
    }

    // MARK: Table data / drag

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let url = items[row]
        let id = NSUserInterfaceItemIdentifier("shelfCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let v = NSTableCellView()
            let icon = NSImageView(); icon.translatesAutoresizingMaskIntoConstraints = false
            let tf = NSTextField(labelWithString: ""); tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingMiddle; tf.font = .systemFont(ofSize: 12)
            v.addSubview(icon); v.addSubview(tf); v.imageView = icon; v.textField = tf
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4),
                icon.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                tf.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                tf.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            ])
            v.identifier = id
            return v
        }()
        cell.textField?.stringValue = url.lastPathComponent
        let icon = NSWorkspace.shared.icon(forFile: url.path); icon.size = NSSize(width: 16, height: 16)
        cell.imageView?.image = icon
        return cell
    }

    // Drag rows OUT (to a folder / Finder).
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        items.indices.contains(row) ? items[row] as NSURL : nil
    }

    // Accept files dropped ONTO the shelf.
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        // Don't accept our own rows being dragged within the shelf.
        if info.draggingSource as? NSTableView === tableView { return [] }
        tableView.setDropRow(-1, dropOperation: .above)
        return .copy
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else { return false }
        return DropStack.add(urls) > 0
    }
}
