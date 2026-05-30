import AppKit
import UniformTypeIdentifiers

/// Sheet that shows the contents of a `.zip`/`.tar*` archive as an outline.
/// Lets the user extract a single entry or the whole archive.
final class ArchiveSheetController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate, ThemeObserving {

    private let archive: URL
    private weak var target: BrowserWindowController?
    private let outline = NSOutlineView()
    private let scroll = NSScrollView()

    private final class Node {
        let name: String
        let entry: Archive.Entry?
        var children: [Node] = []
        init(name: String, entry: Archive.Entry?) {
            self.name = name; self.entry = entry
        }
    }
    private let root = Node(name: "", entry: nil)

    static func show(for wc: BrowserWindowController, archive: URL) {
        guard let parent = wc.window else { return }
        let sc = ArchiveSheetController(archive: archive, target: wc)
        guard let sheet = sc.window else { return }
        PresentedControllers.retain(sc)
        parent.beginSheet(sheet, completionHandler: { _ in })
    }

    init(archive: URL, target: BrowserWindowController) {
        self.archive = archive
        self.target = target
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered, defer: false
        )
        win.title = "Archive — \(archive.lastPathComponent)"
        super.init(window: win)
        ThemeChrome.apply(to: window)
        buildTree()
        layout()
        subscribeToTheme(self)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildTree() {
        let entries = Archive.list(archive)
        for e in entries {
            insert(entry: e)
        }
        // Recursively sort: folders first, then alphabetical.
        sort(root)
    }

    private func insert(entry: Archive.Entry) {
        let parts = entry.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return }
        var node = root
        for (i, p) in parts.enumerated() {
            let isLeaf = i == parts.count - 1
            if let existing = node.children.first(where: { $0.name == p }) {
                node = existing
            } else {
                let child = Node(name: p, entry: isLeaf ? entry : nil)
                node.children.append(child)
                node = child
            }
        }
    }

    private func sort(_ n: Node) {
        n.children.sort { a, b in
            let aIsDir = !a.children.isEmpty || (a.entry?.isDirectory == true)
            let bIsDir = !b.children.isEmpty || (b.entry?.isDirectory == true)
            if aIsDir != bIsDir { return aIsDir }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        n.children.forEach(sort)
    }

    private func layout() {
        guard let cv = window?.contentView else { return }

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder

        outline.headerView = nil
        outline.style = .inset
        outline.rowHeight = 22
        outline.indentationPerLevel = 16
        outline.dataSource = self
        outline.delegate = self
        outline.allowsMultipleSelection = true
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        col.title = ""
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        scroll.documentView = outline

        let extractSel = NSButton(title: "Extract Selected", target: self, action: #selector(extractSelected))
        let extractAll = NSButton(title: "Extract All…", target: self, action: #selector(extractEverything))
        let close = NSButton(title: "Close", target: self, action: #selector(closeSheet))
        for b in [extractSel, extractAll, close] {
            b.bezelStyle = .rounded
            b.translatesAutoresizingMaskIntoConstraints = false
        }
        close.keyEquivalent = "\u{1b}"

        cv.addSubview(scroll)
        cv.addSubview(extractSel)
        cv.addSubview(extractAll)
        cv.addSubview(close)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: cv.topAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: close.topAnchor, constant: -12),
            close.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -14),
            close.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -14),
            extractAll.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -8),
            extractAll.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            extractSel.trailingAnchor.constraint(equalTo: extractAll.leadingAnchor, constant: -8),
            extractSel.centerYAnchor.constraint(equalTo: close.centerYAnchor),
        ])
    }

    // MARK: NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        let node = (item as? Node) ?? root
        return node.children.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let node = (item as? Node) ?? root
        return node.children[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        ((item as? Node)?.children.isEmpty == false)
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        let id = NSUserInterfaceItemIdentifier("ArchiveCell")
        let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let v = NSTableCellView()
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(icon)
            v.imageView = icon
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.font = NSFont.systemFont(ofSize: 12)
            tf.lineBreakMode = .byTruncatingMiddle
            v.addSubview(tf); v.textField = tf
            let size = NSTextField(labelWithString: "")
            size.translatesAutoresizingMaskIntoConstraints = false
            size.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            size.textColor = .secondaryLabelColor
            size.alignment = .right
            v.addSubview(size)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                tf.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                tf.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                size.leadingAnchor.constraint(equalTo: tf.trailingAnchor, constant: 8),
                size.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4),
                size.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            ])
            v.identifier = id
            return v
        }()
        let isDir = !node.children.isEmpty || node.entry?.isDirectory == true
        cell.textField?.stringValue = node.name
        cell.textField?.textColor = ThemeChrome.primary
        let sub = cell.subviews.compactMap { $0 as? NSTextField }
            .first { $0 !== cell.textField }
        sub?.stringValue = isDir ? "" : SizeFormatter.string(node.entry?.size ?? 0)
        sub?.textColor = ThemeChrome.secondary
        if isDir {
            cell.imageView?.image = NSImage(systemSymbolName: "folder",
                                            accessibilityDescription: nil)
        } else {
            let ext = (node.name as NSString).pathExtension
            let type = UTType(filenameExtension: ext) ?? .data
            cell.imageView?.image = NSWorkspace.shared.icon(for: type)
        }
        cell.imageView?.contentTintColor = isDir ? ThemeChrome.secondary : nil
        return cell
    }

    // MARK: Actions

    /// Extraction shells out to unzip/tar; keep it off the main thread so a
    /// large archive doesn't beachball the UI.
    private static let extractQueue = DispatchQueue(label: "FinderTwo.archiveExtract", qos: .userInitiated)

    @objc private func extractSelected() {
        let indexes = outline.selectedRowIndexes
        let nodes = indexes.compactMap { outline.item(atRow: $0) as? Node }
        let entries = nodes.compactMap { $0.entry }
        guard !entries.isEmpty else { NSSound.beep(); return }
        chooseExtractDestination { [weak self] dst in
            guard let self, let dst else { return }
            let archive = self.archive
            ArchiveSheetController.extractQueue.async {
                var failures = 0
                for e in entries where Archive.extract(e, from: archive, to: dst) == nil { failures += 1 }
                DispatchQueue.main.async { [weak self] in
                    self?.target?.testActivePane?.navigate(to: dst)
                    if failures > 0 { NSSound.beep() }
                }
            }
        }
    }

    @objc private func extractEverything() {
        chooseExtractDestination { [weak self] dst in
            guard let self, let dst else { return }
            let archive = self.archive
            ArchiveSheetController.extractQueue.async {
                let ok = Archive.extractAll(archive, to: dst)
                DispatchQueue.main.async { [weak self] in
                    self?.target?.testActivePane?.navigate(to: dst)
                    if !ok { NSSound.beep() }   // refused (zip-slip) or tool failure
                }
            }
        }
    }

    private func chooseExtractDestination(_ completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Choose a destination folder"
        panel.beginSheetModal(for: window!) { resp in
            if resp == .OK, let dst = panel.url { completion(dst) }
            else { completion(nil) }
        }
    }

    @objc private func closeSheet() {
        if let w = window, let parent = w.sheetParent {
            parent.endSheet(w)
        } else {
            window?.close()
        }
    }

    @objc func applyTheme() {
        ThemeChrome.apply(to: window)
        let t = ThemeManager.shared.current
        let custom = t.id != "system"
        let bg = custom ? t.background : .controlBackgroundColor
        outline.backgroundColor = bg
        scroll.drawsBackground = true
        scroll.backgroundColor = bg
        outline.reloadData()
    }
}
