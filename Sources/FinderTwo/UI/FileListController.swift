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

    // MARK: Spring-loaded folders
    /// The folder row a drag is currently hovering (-1 = none), plus the timer
    /// that fires `springLoadDelay` after the hover settles. When it fires we
    /// navigate into that folder so the user can drop deeper (Finder behavior).
    private var springRow = -1
    private var springTimer: Timer?

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
        // Context menu is built fresh per right-click (see FileListTableView.menu(for:))
        // so it reflects the current selection, clipboard, and clicked row.
        tableView.autosaveName = "FinderTwo.FileList"
        tableView.autosaveTableColumns = true

        // Columns
        addColumn(id: "name", title: "Name", width: 340, minWidth: 120, sortKey: SortKey.name.rawValue)
        addColumn(id: "modified", title: "Date Modified", width: 170, minWidth: 110, sortKey: SortKey.dateModified.rawValue)
        addColumn(id: "size", title: "Size", width: 90, minWidth: 60, sortKey: SortKey.size.rawValue, alignment: .right)
        addColumn(id: "kind", title: "Kind", width: 130, minWidth: 70, sortKey: SortKey.kind.rawValue)
        tableView.sortDescriptors = [NSSortDescriptor(key: SortKey.name.rawValue, ascending: true)]

        // Column chooser: right-click the header to show/hide columns (Name stays).
        let headerMenu = NSMenu()
        for col in tableView.tableColumns where col.identifier.rawValue != "name" {
            let it = NSMenuItem(title: col.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            it.representedObject = col.identifier.rawValue
            it.target = self
            it.state = col.isHidden ? .off : .on
            headerMenu.addItem(it)
        }
        tableView.headerView?.menu = headerMenu

        scrollView.documentView = tableView
        scrollView.focusRingType = .none   // no blue focus outline around the list
        tableView.focusRingType = .none

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

    /// Apply density (row height) + font + accent + themed background live when
    /// appearance settings or theme change, then re-render rows.
    @objc func applyTheme() {
        let t = ThemeManager.shared.current
        tableView.rowHeight = ThemeManager.shared.effectiveRowHeight
        // Non-"System" themes paint a solid themed background; System keeps the
        // native look (and native alternating rows).
        let custom = t.id != "system"
        tableView.backgroundColor = custom ? t.background : .controlBackgroundColor
        tableView.usesAlternatingRowBackgroundColors = !custom
        scrollView.drawsBackground = true
        scrollView.backgroundColor = custom ? t.background : .controlBackgroundColor
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

    /// Repaint rows in place when only git badges changed — no map rebuild, no
    /// selection/scroll reset (unlike full `reload()`). AppKit clips the redraw
    /// to visible rows.
    func refreshGitBadges() {
        let n = tableView.numberOfRows
        guard n > 0, tableView.numberOfColumns > 0 else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<n),
                             columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
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

    /// Secondary-column text color: theme label for custom themes, semantic
    /// (light/dark-adapting) for System.
    private var secondaryTextColor: NSColor {
        let t = ThemeManager.shared.current
        return t.id == "system" ? .secondaryLabelColor : t.labelSecondary
    }

    // Folder-size cache for "Calculate all sizes". Computed off-main per visible
    // folder and the row repainted when the result lands (like git badges).
    private static let folderSizeQueue = DispatchQueue(label: "FinderTwo.folderSize", qos: .utility)
    private var folderSizeCache: [URL: Int64] = [:]
    private var folderSizeInFlight: Set<URL> = []

    private func folderSizeText(for url: URL) -> String {
        if let bytes = folderSizeCache[url] { return SizeFormatter.string(bytes) }
        if !folderSizeInFlight.contains(url) {
            folderSizeInFlight.insert(url)
            FileListController.folderSizeQueue.async { [weak self] in
                let bytes = FileListController.recursiveSize(url)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.folderSizeCache[url] = bytes
                    self.folderSizeInFlight.remove(url)
                    if let idx = self.urlToRowIndex[url], idx < self.tableView.numberOfRows {
                        self.tableView.reloadData(forRowIndexes: IndexSet(integer: idx),
                                                  columnIndexes: IndexSet(integersIn: 0..<self.tableView.numberOfColumns))
                    }
                }
            }
        }
        return "…"   // computing
    }

    static func recursiveSize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        if let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                   options: [.skipsPackageDescendants]) {
            while let f = en.nextObject() as? URL {
                let v = try? f.resourceValues(forKeys: Set(keys))
                total += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
            }
        }
        return total
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let col = tableView.tableColumns.first(where: { $0.identifier.rawValue == id }) else { return }
        col.isHidden.toggle()
        sender.state = col.isHidden ? .off : .on
    }

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
            cell.configure(with: item, gitState: model.gitStates[item.name])
            cell.imageView?.image = thumbnail(for: item, indexPath: row)
            return cell
        case "modified":
            return makeTextCell(text: DateFormatterCache.string(item.modified), color: secondaryTextColor)
        case "size":
            let sizeText: String
            if item.isDirectory {
                sizeText = Settings.calculateFolderSizes ? folderSizeText(for: item.url) : "—"
            } else {
                sizeText = SizeFormatter.string(item.size)
            }
            return makeTextCell(text: sizeText, color: secondaryTextColor, alignment: .right)
        case "kind":
            return makeTextCell(text: item.kindDescription, color: secondaryTextColor)
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
            armSpring(forRow: row)
            return modifierIsOption(info) ? .copy : .move
        }
        cancelSpring()
        if dropOperation == .above {
            tableView.setDropRow(-1, dropOperation: .on)  // map to current directory
        }
        return modifierIsOption(info) ? .copy : .move
    }

    /// Start (or keep) the spring-load timer for `row`. Hovering a *different*
    /// folder restarts the countdown; hovering the same one leaves it running.
    private func armSpring(forRow row: Int) {
        guard Settings.springLoadedFolders else { return }
        if row == springRow, springTimer != nil { return }
        cancelSpring()
        springRow = row
        let t = Timer(timeInterval: Settings.springLoadDelay, repeats: false) { [weak self] _ in
            self?.springFire()
        }
        // .eventTracking so it still fires while the drag loop is spinning.
        RunLoop.current.add(t, forMode: .eventTracking)
        RunLoop.current.add(t, forMode: .default)
        springTimer = t
    }

    /// Cancel any pending spring-load (drag left the folder, dropped, or ended).
    func cancelSpring() {
        springTimer?.invalidate()
        springTimer = nil
        springRow = -1
    }

    private func springFire() {
        let row = springRow
        cancelSpring()
        guard model.items.indices.contains(row), model.items[row].isDirectory else { return }
        delegate?.fileListOpenItem(model.items[row])
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        cancelSpring()
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
        FileOps.transfer(urls, into: target, move: !isCopy, from: view.window)
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
        // When "type to select" is on, fall through so NSTableView's built-in
        // type-select (move the selection to the next matching name) takes over.
        if Settings.typeAheadEnabled, !Settings.typeToSelect,
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

    // Context menu — built fresh on each right-click so it reflects the current
    // selection / clipboard / clicked row.
    func contextMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(NSMenuItem(title: "Open", action: #selector(menuOpen), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "Open With…", action: #selector(menuOpenWith), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "Quick Look", action: #selector(menuQuickLook), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "Reveal in Finder", action: #selector(menuReveal), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "Open in Terminal", action: #selector(menuOpenTerm), keyEquivalent: ""))
        // "Open in Editor" → submenu of installed editors (built lazily so newly
        // installed editors appear without relaunch).
        let editorItem = NSMenuItem(title: "Open in Editor", action: nil, keyEquivalent: "")
        let editorMenu = NSMenu()
        let installed = Editor.installed
        if installed.isEmpty {
            let none = NSMenuItem(title: "No editor found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            editorMenu.addItem(none)
        } else {
            for ed in installed {
                let it = NSMenuItem(title: ed.displayName, action: #selector(menuOpenInEditor(_:)), keyEquivalent: "")
                it.representedObject = ed.rawValue
                it.target = self
                editorMenu.addItem(it)
            }
        }
        editorItem.submenu = editorMenu
        m.addItem(editorItem)
        m.addItem(NSMenuItem.separator())
        m.addItem(NSMenuItem(title: "Get Info", action: #selector(menuGetInfo), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "Copy", action: #selector(menuCopy), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "Copy Path", action: #selector(menuCopyPath), keyEquivalent: ""))
        if NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: nil) {
            m.addItem(NSMenuItem(title: "Paste", action: #selector(menuPaste), keyEquivalent: ""))
        }
        m.addItem(NSMenuItem(title: "Duplicate", action: #selector(menuDuplicate), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "Rename", action: #selector(menuRename), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "Make Alias", action: #selector(menuMakeAlias), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "New Folder with Selection", action: #selector(menuNewFolderWithSelection), keyEquivalent: ""))
        m.addItem(NSMenuItem.separator())
        let compressTitle = selectedItems().count == 1 ? "Compress “\(selectedItems()[0].name)”" : "Compress \(selectedItems().count) Items"
        m.addItem(NSMenuItem(title: compressTitle, action: #selector(menuCompress), keyEquivalent: ""))
        if selectedItems().contains(where: { Archive.isArchive($0.url) }) {
            m.addItem(NSMenuItem(title: "Extract", action: #selector(menuExtract), keyEquivalent: ""))
        }
        m.addItem(tagsSubmenuItem())
        if selectedItems().count == 1,
           (try? selectedItems()[0].url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            m.addItem(NSMenuItem(title: "Add to Sidebar", action: #selector(menuAddToSidebar), keyEquivalent: ""))
        }
        if selectedItems().count == 1,
           FileOps.imageExtensions.contains(selectedItems()[0].url.pathExtension.lowercased()) {
            m.addItem(NSMenuItem(title: "Set Desktop Picture", action: #selector(menuSetDesktop), keyEquivalent: ""))
        }
        m.addItem(NSMenuItem.separator())
        m.addItem(NSMenuItem(title: "Move to Trash", action: #selector(menuTrash), keyEquivalent: ""))
        for it in m.items { it.target = self }
        return m
    }

    /// Tags ▸ submenu: the 7 Finder colors (toggle on the whole selection) + Clear.
    private func tagsSubmenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        let sel = selectedItems().map { $0.url }
        // A color is "on" only when every selected item carries it.
        var common: Set<Tags.Color> = []
        if let first = sel.first {
            common = Set(Tags.read(first).map { $0.color })
            for u in sel.dropFirst() {
                common.formIntersection(Set(Tags.read(u).map { $0.color }))
            }
        }
        for color in [Tags.Color.red, .orange, .yellow, .green, .blue, .purple, .gray] {
            let it = NSMenuItem(title: color.label, action: #selector(menuToggleTag(_:)), keyEquivalent: "")
            it.representedObject = color.rawValue
            it.target = self
            it.state = common.contains(color) ? .on : .off
            it.image = NameCell.tagDotImage(color.nsColor)
            menu.addItem(it)
        }
        menu.addItem(NSMenuItem.separator())
        let clear = NSMenuItem(title: "Clear Tags", action: #selector(menuClearTags), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        item.submenu = menu
        return item
    }

    /// Menu shown when right-clicking empty space in the list (no row).
    func backgroundContextMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(NSMenuItem(title: "New Folder", action: #selector(menuBgNewFolder), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "New File", action: #selector(menuBgNewFile), keyEquivalent: ""))
        if NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: nil) {
            m.addItem(NSMenuItem(title: "Paste", action: #selector(menuPaste), keyEquivalent: ""))
        }
        m.addItem(NSMenuItem.separator())
        m.addItem(NSMenuItem(title: "Get Info", action: #selector(menuBgGetInfo), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "Add to Sidebar", action: #selector(menuBgAddToSidebar), keyEquivalent: ""))
        for it in m.items { it.target = self }
        return m
    }
    @objc private func menuBgNewFolder() { _ = FileOps.newFolder(in: model.url); model.reload() }
    @objc private func menuBgNewFile() { _ = FileOps.newFile(in: model.url); model.reload() }
    @objc private func menuBgGetInfo() { GetInfoSheetController.show(for: model.url, parent: view.window) }
    @objc private func menuBgAddToSidebar() { SidebarBookmarks.add(model.url) }
    @objc private func menuSetDesktop() {
        if let u = selectedItems().first?.url { FileOps.setDesktopPicture(u) }
    }
    @objc private func menuAddToSidebar() {
        for u in selectedItems().map({ $0.url }) where (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            SidebarBookmarks.add(u)
        }
    }

    /// Re-render visible rows (cheap, preserves selection/scroll) — used after a
    /// tag change so the color dots update.
    func reloadVisibleRows() {
        let n = tableView.numberOfRows
        guard n > 0, tableView.numberOfColumns > 0 else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<n),
                             columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
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
    @objc private func menuOpenInEditor(_ sender: NSMenuItem) {
        guard let wc = view.window?.windowController as? BrowserWindowController else { return }
        wc.openInEditor(sender)   // sender.representedObject carries the chosen editor
    }
    @objc private func menuGetInfo() {
        if let u = selectedItems().first?.url { GetInfoSheetController.show(for: u, parent: view.window) }
    }
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
    @objc private func menuQuickLook() { toggleQuickLook() }
    @objc private func menuMakeAlias() {
        let urls = selectedItems().map { $0.url }
        guard !urls.isEmpty else { return }
        FileOps.makeAliases(for: urls)
        model.reload()
    }
    @objc private func menuCompress() {
        let urls = selectedItems().map { $0.url }
        guard !urls.isEmpty else { NSSound.beep(); return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = Archive.compress(urls) != nil
            DispatchQueue.main.async { if !ok { NSSound.beep() }; self?.model.reload() }
        }
    }
    @objc private func menuExtract() {
        let archives = selectedItems().map { $0.url }.filter { Archive.isArchive($0) }
        guard !archives.isEmpty else { NSSound.beep(); return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let allOK = archives.allSatisfy { Archive.extractInPlace($0) != nil }
            DispatchQueue.main.async { if !allOK { NSSound.beep() }; self?.model.reload() }
        }
    }
    @objc private func menuToggleTag(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int,
              let color = Tags.Color(rawValue: raw) else { return }
        let urls = selectedItems().map { $0.url }
        guard !urls.isEmpty else { return }
        // Toggle across the whole selection: if every item already has the color,
        // remove it from all; otherwise add it to all.
        let allHave = urls.allSatisfy { Tags.read($0).contains { $0.color == color } }
        for url in urls {
            if allHave {
                Tags.write(Tags.read(url).filter { $0.color != color }, to: url)
            } else {
                Tags.addTag(Tags.Tag(name: color.label, color: color), to: url)
            }
        }
        reloadVisibleRows()
    }
    @objc private func menuClearTags() {
        for url in selectedItems().map({ $0.url }) { Tags.write([], to: url) }
        reloadVisibleRows()
    }

    /// Entry points usable from menus & the command palette.
    @objc private func menuPaste() {
        FileOps.paste(NSPasteboard.general, into: model.url, move: false, from: view.window)
    }
    @objc private func menuNewFolderWithSelection() {
        let sel = selectedItems().map { $0.url }
        guard !sel.isEmpty else { return }
        _ = FileOps.newFolderWithItems(sel, in: model.url)
        model.reload()
    }

    func compressSelection() { menuCompress() }
    func extractSelection() { menuExtract() }
    func makeAliasSelection() { menuMakeAlias() }

    /// Arrange By <key>: set the sort, updating both the model and the column
    /// header's sort indicator. The model's recompute cascades to the icon view.
    func setSortKey(_ key: SortKey) {
        tableView.sortDescriptors = [NSSortDescriptor(key: key.rawValue, ascending: true)]
        model.sort = SortDescriptor(key: key, ascending: true, foldersFirst: model.sort.foldersFirst)
    }
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

    // Spring-loaded folders: kill the pending hover-open when the drag leaves
    // the table or finishes, so we never navigate after the user moves on.
    override func draggingExited(_ sender: NSDraggingInfo?) {
        listController?.cancelSpring()
        super.draggingExited(sender)
    }
    override func draggingEnded(_ sender: NSDraggingInfo) {
        listController?.cancelSpring()
        super.draggingEnded(sender)
    }

    /// Build the context menu fresh per right-click. On a row: select it first
    /// (if not already selected) and show the item menu. On empty space: the
    /// background menu (New Folder / New File / Paste / …).
    override func menu(for event: NSEvent) -> NSMenu? {
        let pt = convert(event.locationInWindow, from: nil)
        let row = self.row(at: pt)
        if row >= 0 {
            if !selectedRowIndexes.contains(row) {
                selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            return listController?.contextMenu()
        }
        deselectAll(nil)
        return listController?.backgroundContextMenu()
    }

    private var lastPrefetchAt: TimeInterval = 0
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Drop any prior registration before re-adding so re-parenting (e.g.
        // list↔columns toggles, which move this view in/out of a window) can't
        // stack duplicate observers that fire boundsChanged N× per scroll.
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        guard let cv = enclosingScrollView?.contentView else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsChanged),
            name: NSView.boundsDidChangeNotification, object: cv
        )
        cv.postsBoundsChangedNotifications = true
    }

    deinit { NotificationCenter.default.removeObserver(self) }

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
    private let gitBadge = NSTextField(labelWithString: "")
    private let tagDots = NSTextField(labelWithString: "")
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

        gitBadge.translatesAutoresizingMaskIntoConstraints = false
        gitBadge.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        gitBadge.alignment = .center
        gitBadge.setContentHuggingPriority(.required, for: .horizontal)
        gitBadge.setContentCompressionResistancePriority(.required, for: .horizontal)

        tagDots.translatesAutoresizingMaskIntoConstraints = false
        tagDots.setContentHuggingPriority(.required, for: .horizontal)
        tagDots.setContentCompressionResistancePriority(.required, for: .horizontal)
        // Let the name truncate instead of shoving the dots/badge off the edge.
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(icon)
        addSubview(name)
        addSubview(tagDots)
        addSubview(gitBadge)
        self.imageView = icon
        self.textField = name
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            tagDots.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
            tagDots.centerYAnchor.constraint(equalTo: centerYAnchor),
            gitBadge.leadingAnchor.constraint(equalTo: tagDots.trailingAnchor, constant: 4),
            gitBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            gitBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    func configure(with item: FileItem, gitState: GitStatus.FileState? = nil) {
        currentItem = item
        if !isEditing {
            name.stringValue = item.name
        }
        // Honor the active theme's label palette for custom themes; the System
        // theme keeps the semantic colors so it adapts to light/dark.
        let t = ThemeManager.shared.current
        if t.id == "system" {
            name.textColor = item.isHidden ? .tertiaryLabelColor : .labelColor
        } else {
            name.textColor = item.isHidden ? t.labelTertiary : t.labelPrimary
        }
        name.font = ThemeManager.shared.font()   // live font size + monospaced themes
        applyGitState(gitState)
        applyTagDots(for: item.url)
    }

    /// Show up to 3 colored dots for the file's color tags (Finder-style).
    private func applyTagDots(for url: URL) {
        let colors = Tags.read(url).map { $0.color }.filter { $0 != .none }
        guard !colors.isEmpty else { tagDots.attributedStringValue = NSAttributedString(string: ""); return }
        let s = NSMutableAttributedString()
        for c in colors.prefix(3) {
            s.append(NSAttributedString(string: "●",
                attributes: [.foregroundColor: c.nsColor, .font: NSFont.systemFont(ofSize: 9)]))
        }
        tagDots.attributedStringValue = s
    }

    /// Small filled circle for the Tags ▸ menu items.
    static func tagDotImage(_ color: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 12, height: 12))
        img.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 8, height: 8)).fill()
        img.unlockFocus()
        return img
    }

    private func applyGitState(_ state: GitStatus.FileState?) {
        guard let state else { gitBadge.stringValue = ""; return }
        gitBadge.stringValue = state.letter
        gitBadge.textColor = NameCell.color(for: state)
    }

    static func color(for state: GitStatus.FileState) -> NSColor {
        switch state {
        case .modified, .modifiedFolder, .renamed: return .systemOrange
        case .added, .untracked: return .systemGreen
        case .deleted: return .systemRed
        case .conflicted: return .systemRed
        case .ignored: return .tertiaryLabelColor
        }
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
