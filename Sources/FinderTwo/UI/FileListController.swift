import AppKit
import QuickLookUI

protocol FileListDelegate: AnyObject {
    func fileListSelectionChanged()
    func fileListOpenItem(_ item: FileItem)
    func fileListEnterParent()
    func fileListBecameActive()
    func fileListBeginTypeAhead(initial: String)
}

final class FileListController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate, NameCellDelegate, ThemeObserving {

    weak var delegate: FileListDelegate?

    let tableView = FileListTableView()
    private let scrollView = NSScrollView()
    private(set) var model: DirectoryModel

    /// Move selection by delta rows, clamped to bounds.
    func moveSelection(by delta: Int) {
        let n = model.items.count
        guard n > 0 else { return }
        let current = tableView.selectedRow
        let target = max(0, min(n - 1, (current < 0 ? 0 : current) + delta))
        tableView.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        tableView.scrollRowToVisible(target)
    }

    func selectRow(_ row: Int) {
        let n = model.items.count
        guard n > 0 else { return }
        let r = max(0, min(n - 1, row))
        tableView.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
        tableView.scrollRowToVisible(r)
    }

    var lastRowIndex: Int { max(0, model.items.count - 1) }

    func setModel(_ newModel: DirectoryModel) {
        self.model = newModel
        // Sort descriptors stay; new model picks up its own sort.
        reload()
    }

    /// URL → row index for the currently-displayed items. Rebuilt on every
    /// `reload()` and used to make async thumbnail callbacks O(1) instead of
    /// O(n) (matters once items.count gets into the tens of thousands).
    private var urlToRowIndex: [URL: Int] = [:]

    init(model: DirectoryModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        tableView.listController = self
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.gridStyleMask = []
        tableView.rowHeight = ThemeManager.shared.effectiveRowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsColumnSelection = false
        tableView.usesAutomaticRowHeights = false
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick)
        tableView.action = #selector(handleClick)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        tableView.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: true)
        tableView.draggingDestinationFeedbackStyle = .gap
        tableView.menu = makeContextMenu()
        tableView.autosaveName = "FinderTwo.FileList"
        tableView.autosaveTableColumns = true

        // Columns
        addColumn(id: "name", title: "Name", width: 340, minWidth: 120, sortKey: SortKey.name.rawValue)
        addColumn(id: "modified", title: "Date Modified", width: 170, minWidth: 110, sortKey: SortKey.dateModified.rawValue)
        addColumn(id: "size", title: "Size", width: 90, minWidth: 60, sortKey: SortKey.size.rawValue, alignment: .right)
        addColumn(id: "kind", title: "Kind", width: 130, minWidth: 70, sortKey: SortKey.kind.rawValue)
        tableView.sortDescriptors = [NSSortDescriptor(key: SortKey.name.rawValue, ascending: true)]

        scrollView.documentView = tableView

        let host = ListHostView()
        host.onKeyDown = { [weak self] event in
            self?.handleKey(event) ?? false
        }
        host.onActivate = { [weak self] in self?.delegate?.fileListBecameActive() }
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: host.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        self.view = host
        subscribeToTheme(self)
    }

    /// Apply density (row height) + font + accent live when appearance settings
    /// or theme change, then re-render rows.
    @objc func applyTheme() {
        tableView.rowHeight = ThemeManager.shared.effectiveRowHeight
        tableView.reloadData()
    }

    private func addColumn(id: String, title: String, width: CGFloat, minWidth: CGFloat, sortKey: String, alignment: NSTextAlignment = .left) {
        let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        c.title = title
        c.width = width
        c.minWidth = minWidth
        c.sortDescriptorPrototype = NSSortDescriptor(key: sortKey, ascending: true)
        c.headerCell.alignment = alignment == .right ? .right : .left
        tableView.addTableColumn(c)
    }

    func reload() {
        // Preserve selection by URL
        let prevSel = selectedItems().map { $0.url }
        // Rebuild the URL→row map in one pass (much cheaper than firstIndex
        // lookups when async thumbnail callbacks arrive).
        var newMap: [URL: Int] = [:]
        newMap.reserveCapacity(model.items.count)
        for (i, item) in model.items.enumerated() {
            newMap[item.url] = i
        }
        urlToRowIndex = newMap
        tableView.reloadData()
        if !prevSel.isEmpty {
            var indexes = IndexSet()
            let prevSelSet = Set(prevSel)
            for (i, item) in model.items.enumerated() where prevSelSet.contains(item.url) {
                indexes.insert(i)
            }
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        }
    }

    func select(item: FileItem, scroll: Bool) {
        if let idx = model.items.firstIndex(of: item) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            if scroll { tableView.scrollRowToVisible(idx) }
        }
    }

    func selectedItems() -> [FileItem] {
        tableView.selectedRowIndexes.compactMap { model.items.indices.contains($0) ? model.items[$0] : nil }
    }

    // MARK: NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { model.items.count }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let key = d.key, let k = SortKey(rawValue: key) else { return }
        var sd = model.sort
        sd.key = k
        sd.ascending = d.ascending
        model.sort = sd
    }

    // MARK: NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, model.items.indices.contains(row) else { return nil }
        let item = model.items[row]
        let id = col.identifier.rawValue

        switch id {
        case "name":
            let cellId = NSUserInterfaceItemIdentifier("NameCell")
            let cell = (tableView.makeView(withIdentifier: cellId, owner: nil) as? NameCell) ?? NameCell()
            cell.identifier = cellId
            cell.renameDelegate = self
            cell.configure(with: item)
            cell.imageView?.image = thumbnail(for: item, indexPath: row)
            return cell
        case "modified":
            return makeTextCell(text: DateFormatterCache.string(item.modified), color: .secondaryLabelColor)
        case "size":
            return makeTextCell(text: SizeFormatter.string(item.size), color: .secondaryLabelColor, alignment: .right)
        case "kind":
            return makeTextCell(text: item.kindDescription, color: .secondaryLabelColor)
        default:
            return nil
        }
    }

    private var lastSelectionNotify: TimeInterval = 0
    func tableViewSelectionDidChange(_ notification: Notification) {
        // Throttle to ~60 Hz — keyboard repeat with arrow keys can fire 4× per
        // frame which thrashes the status bar formatter for big selections.
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastSelectionNotify > 1.0 / 60.0 {
            lastSelectionNotify = now
            delegate?.fileListSelectionChanged()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.020) { [weak self] in
                guard let self else { return }
                self.delegate?.fileListSelectionChanged()
            }
        }
        if QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().reloadData()
        }
    }

    private var lastPrefetchedCenter: Int = -100
    /// Prefetch a few rows ahead/behind so thumbnails are cached before they
    /// scroll into view. Triggered by FileListTableView on bounds-did-change.
    /// Skips work if the visible center has barely moved, and only asks QL
    /// for files that are actually thumbnailable (images / PDFs / video).
    fileprivate func prefetchThumbnails(around visibleRange: NSRange) {
        let center = visibleRange.location + visibleRange.length / 2
        if abs(center - lastPrefetchedCenter) < 3 { return }
        lastPrefetchedCenter = center
        let lo = max(0, visibleRange.location - 20)
        let hi = min(model.items.count, NSMaxRange(visibleRange) + 20)
        guard lo < hi else { return }
        for i in lo..<hi {
            let item = model.items[i]
            guard !item.isDirectory else { continue }
            guard ThumbnailService.shared.isThumbnailable(item.url) else { continue }
            let url = item.url
            _ = ThumbnailService.shared.thumbnail(
                for: url, size: NSSize(width: 32, height: 32)
            ) { [weak self] img in
                guard let self else { return }
                IconCache.shared.putThumbnail(img, for: url)
                if let idx = self.urlToRowIndex[url] {
                    self.tableView.reloadData(forRowIndexes: IndexSet(integer: idx),
                                              columnIndexes: IndexSet(integer: 0))
                }
            }
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = NSTableRowView()
        v.isEmphasized = true
        return v
    }

    // Drag source
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard model.items.indices.contains(row) else { return nil }
        return model.items[row].url as NSURL
    }

    // Drop validation
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        // Drop on a folder row → "on"; otherwise treat as drop into current dir
        if dropOperation == .on, model.items.indices.contains(row), model.items[row].isDirectory {
            return modifierIsOption(info) ? .copy : .move
        }
        if dropOperation == .above {
            tableView.setDropRow(-1, dropOperation: .on)  // map to current directory
        }
        return modifierIsOption(info) ? .copy : .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty else {
            return false
        }
        let target: URL
        if dropOperation == .on, model.items.indices.contains(row), model.items[row].isDirectory {
            target = model.items[row].url
        } else {
            target = model.url
        }
        let isCopy = modifierIsOption(info)
        let fm = FileManager.default
        for src in urls {
            guard src != target else { continue }
            let dst = target.appendingPathComponent(src.lastPathComponent)
            do {
                if isCopy {
                    try fm.copyItem(at: src, to: dst)
                } else {
                    try fm.moveItem(at: src, to: dst)
                }
            } catch {
                NSSound.beep()
            }
        }
        return true
    }

    private func modifierIsOption(_ info: NSDraggingInfo) -> Bool {
        NSEvent.modifierFlags.contains(.option)
    }

    // MARK: Cell helpers

    private func makeTextCell(text: String, color: NSColor = .labelColor, alignment: NSTextAlignment = .left) -> NSView {
        let id = NSUserInterfaceItemIdentifier("TextCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let v = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            tf.font = NSFont.systemFont(ofSize: 12)
            v.addSubview(tf)
            v.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            ])
            v.identifier = id
            return v
        }()
        cell.textField?.stringValue = text
        cell.textField?.textColor = color
        cell.textField?.alignment = alignment
        // Honor the live font size (theme base + density delta) — secondary
        // columns sit one point smaller than the name column.
        cell.textField?.font = NSFont.systemFont(ofSize: max(9, ThemeManager.shared.effectiveFontSize - 1))
        return cell
    }

    private func thumbnail(for item: FileItem, indexPath row: Int) -> NSImage {
        // Fast path — cached (real thumb or generic-by-extension icon).
        let placeholder = IconCache.shared.icon(for: item)
        // For thumbnailable file types, kick off async QL thumbnail; cell will
        // be reloaded when it arrives.
        if !item.isDirectory, ThumbnailService.shared.isThumbnailable(item.url) {
            let url = item.url
            _ = ThumbnailService.shared.thumbnail(
                for: url, size: NSSize(width: 32, height: 32)
            ) { [weak self] img in
                guard let self else { return }
                IconCache.shared.putThumbnail(img, for: url)
                // O(1) lookup via the URL→row map maintained in reload().
                if let idx = self.urlToRowIndex[url] {
                    self.tableView.reloadData(forRowIndexes: IndexSet(integer: idx),
                                              columnIndexes: IndexSet(integer: 0))
                }
            }
        }
        return placeholder
    }

    // MARK: Click / keyboard handling

    @objc private func handleClick() {
        delegate?.fileListBecameActive()
    }

    @objc private func handleDoubleClick() {
        let row = tableView.clickedRow
        guard model.items.indices.contains(row) else { return }
        delegate?.fileListOpenItem(model.items[row])
    }

    fileprivate func handleKey(_ event: NSEvent) -> Bool {
        guard let chars = event.charactersIgnoringModifiers else { return false }
        // NOTE: vim keys are intercepted at the window level (see
        // BrowserWindowController.installVimKeyMonitor) so they work from any
        // focus, not just the table. By the time a key reaches here, it's a
        // non-vim key (or vim is disabled).
        // QuickLook on Space
        if chars == " " && event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            toggleQuickLook()
            return true
        }
        // Return — Finder parity: rename the selected item.
        if chars == "\r" || chars == "\n" {
            beginRenameSelection()
            return true
        }
        // Type-ahead → live filter: alphanumeric + a few punctuation, no Cmd/Opt/Ctrl.
        if Settings.typeAheadEnabled,
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           chars.count == 1,
           let ch = chars.unicodeScalars.first,
           (CharacterSet.alphanumerics.contains(ch) || "._- ".unicodeScalars.contains(ch)) {
            delegate?.fileListBeginTypeAhead(initial: chars)
            return true
        }
        return false
    }

    func beginRenameSelection() {
        let row = tableView.selectedRow
        guard row >= 0 else { NSSound.beep(); return }
        guard let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NameCell else {
            NSSound.beep(); return
        }
        view.beginEditing()
    }

    /// Programmatic rename without requiring keyboard focus — useful for tests and
    /// future automation. Renames the currently selected item to `newName`.
    func commitInlineRename(to newName: String) {
        let row = tableView.selectedRow
        guard row >= 0, model.items.indices.contains(row) else { NSSound.beep(); return }
        let item = model.items[row]
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { NSSound.beep(); return }
        let newURL = item.url.deletingLastPathComponent().appendingPathComponent(trimmed)
        if newURL == item.url { return }
        if FileManager.default.fileExists(atPath: newURL.path) { NSSound.beep(); return }
        do {
            try FileManager.default.moveItem(at: item.url, to: newURL)
        } catch {
            NSSound.beep()
        }
    }

    // MARK: NameCellDelegate

    func nameCellDidCommit(_ cell: NameCell, newName: String) {
        guard let item = cell.currentItem else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            NSSound.beep()
            cell.name.stringValue = item.name
            return
        }
        let newURL = item.url.deletingLastPathComponent().appendingPathComponent(trimmed)
        if newURL == item.url { return }
        if FileManager.default.fileExists(atPath: newURL.path) {
            NSSound.beep()
            cell.name.stringValue = item.name
            return
        }
        do {
            try FileManager.default.moveItem(at: item.url, to: newURL)
            // The FSEvents watcher will pick up the change and trigger a reload.
        } catch {
            NSSound.beep()
            cell.name.stringValue = item.name
        }
    }
    func nameCellDidCancel(_ cell: NameCell) { /* no-op */ }

    private func toggleQuickLook() {
        let panel = QLPreviewPanel.shared()!
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: QuickLook

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.delegate = self
        panel.dataSource = self
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.delegate = nil
        panel.dataSource = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedItems().count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let items = selectedItems()
        guard items.indices.contains(index) else { return nil }
        return items[index].url as NSURL
    }

    // Context menu
    private func makeContextMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(NSMenuItem(title: "Open", action: #selector(menuOpen), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "Open With…", action: #selector(menuOpenWith), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "Reveal in Finder", action: #selector(menuReveal), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "Open in Terminal", action: #selector(menuOpenTerm), keyEquivalent: ""))
        m.addItem(NSMenuItem.separator())
        m.addItem(NSMenuItem(title: "Get Info", action: #selector(menuGetInfo), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "Copy", action: #selector(menuCopy), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "Copy Path", action: #selector(menuCopyPath), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "Duplicate", action: #selector(menuDuplicate), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "Rename", action: #selector(menuRename), keyEquivalent: ""))
        m.addItem(NSMenuItem.separator())
        m.addItem(NSMenuItem(title: "Move to Trash", action: #selector(menuTrash), keyEquivalent: ""))
        for it in m.items { it.target = self }
        return m
    }

    @objc private func menuOpen() {
        for it in selectedItems() { delegate?.fileListOpenItem(it); break }
    }
    @objc private func menuOpenWith() {
        let urls = selectedItems().map { $0.url }
        guard !urls.isEmpty else { NSSound.beep(); return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose an application to open the selected item(s)"
        let appWindow = view.window
        let complete: (NSApplication.ModalResponse) -> Void = { resp in
            guard resp == .OK, let appURL = panel.url else { return }
            let cfg = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open(urls, withApplicationAt: appURL,
                                    configuration: cfg, completionHandler: nil)
        }
        if let w = appWindow {
            panel.beginSheetModal(for: w, completionHandler: complete)
        } else {
            complete(panel.runModal())
        }
    }
    @objc private func menuReveal() { FileOps.revealInFinder(selectedItems().map { $0.url }) }
    @objc private func menuOpenTerm() {
        guard let wc = view.window?.windowController as? BrowserWindowController else { return }
        wc.openInTerminal(nil)
    }
    @objc private func menuGetInfo() { FileOps.getInfo(selectedItems().map { $0.url }) }
    @objc private func menuCopy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(selectedItems().map { $0.url as NSURL })
    }
    @objc private func menuCopyPath() {
        let paths = selectedItems().map { $0.url.path }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(paths.joined(separator: "\n"), forType: .string)
    }
    @objc private func menuDuplicate() {
        guard let wc = view.window?.windowController as? BrowserWindowController else { return }
        wc.duplicate(nil)
    }
    @objc private func menuRename() { beginRenameSelection() }
    @objc private func menuTrash() { FileOps.moveToTrash(selectedItems().map { $0.url }) }
}

/// NSTableView subclass that routes alphanumeric keys to type-ahead filtering and
/// preserves arrow-key / Cmd handling. Also drives thumbnail prefetch when the
/// visible range changes.
final class FileListTableView: NSTableView {
    weak var listController: FileListController?

    override func keyDown(with event: NSEvent) {
        if let lc = listController, lc.handleKey(event) {
            return
        }
        super.keyDown(with: event)
    }

    private var lastPrefetchAt: TimeInterval = 0
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let cv = enclosingScrollView?.contentView else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsChanged),
            name: NSView.boundsDidChangeNotification, object: cv
        )
        cv.postsBoundsChangedNotifications = true
    }

    @objc private func boundsChanged() {
        guard let lc = listController else { return }
        // Throttle to once per frame at 60Hz — keeps scroll handlers light.
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastPrefetchAt < 1.0 / 60.0 { return }
        lastPrefetchAt = now
        let visible = rows(in: visibleRect)
        if visible.length > 0 {
            lc.prefetchThumbnails(around: visible)
        }
    }
}

/// Container that captures unhandled keyDown events for shortcuts the table doesn't natively support.
private final class ListHostView: NSView {
    var onKeyDown: ((NSEvent) -> Bool)?
    var onActivate: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func mouseDown(with event: NSEvent) {
        onActivate?()
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}

protocol NameCellDelegate: AnyObject {
    func nameCellDidCommit(_ cell: NameCell, newName: String)
    func nameCellDidCancel(_ cell: NameCell)
}

/// Custom name cell with icon + text. Text is normally a label; on demand we
/// flip it to editable for in-place rename.
final class NameCell: NSTableCellView, NSTextFieldDelegate {
    weak var renameDelegate: NameCellDelegate?
    private let icon = NSImageView()
    let name = NSTextField()
    private(set) var currentItem: FileItem?
    private var isEditing = false
    private var originalNameBeforeEdit: String = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    private func setup() {
        icon.translatesAutoresizingMaskIntoConstraints = false
        name.translatesAutoresizingMaskIntoConstraints = false
        name.lineBreakMode = .byTruncatingMiddle
        name.font = NSFont.systemFont(ofSize: 13)
        name.textColor = .labelColor
        name.isBordered = false
        name.drawsBackground = false
        name.isEditable = false
        name.isSelectable = false
        name.usesSingleLineMode = true
        name.cell?.usesSingleLineMode = true
        name.cell?.wraps = false
        name.delegate = self
        addSubview(icon)
        addSubview(name)
        self.imageView = icon
        self.textField = name
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    func configure(with item: FileItem) {
        currentItem = item
        if !isEditing {
            name.stringValue = item.name
        }
        name.textColor = item.isHidden ? .tertiaryLabelColor : .labelColor
        name.font = ThemeManager.shared.font()   // live font size + monospaced themes
    }

    func beginEditing() {
        guard let item = currentItem, !isEditing else { return }
        isEditing = true
        originalNameBeforeEdit = item.name
        name.isEditable = true
        name.isSelectable = true
        name.isBordered = true
        name.drawsBackground = true
        name.backgroundColor = NSColor.textBackgroundColor
        window?.makeFirstResponder(name)
        // Select the base name (everything before extension) — Finder behavior.
        if let editor = name.currentEditor() {
            let s = name.stringValue as NSString
            let dot = s.range(of: ".", options: .backwards).location
            if dot != NSNotFound && dot > 0 {
                editor.selectedRange = NSRange(location: 0, length: dot)
            } else {
                editor.selectAll(nil)
            }
        }
    }

    private func endEditing(commit: Bool) {
        guard isEditing else { return }
        isEditing = false
        let final = name.stringValue
        name.isEditable = false
        name.isSelectable = false
        name.isBordered = false
        name.drawsBackground = false
        if commit, final != originalNameBeforeEdit, !final.isEmpty {
            renameDelegate?.nameCellDidCommit(self, newName: final)
        } else {
            name.stringValue = originalNameBeforeEdit
            renameDelegate?.nameCellDidCancel(self)
        }
    }

    // NSTextFieldDelegate
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === name else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            endEditing(commit: true); return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endEditing(commit: false); return true
        }
        return false
    }
}
