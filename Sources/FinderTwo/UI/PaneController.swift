import AppKit

enum ViewMode { case list, columns }

final class PaneController: NSViewController, DirectoryModelDelegate, FileListDelegate, TabStripDelegate {

    var onURLChange: ((URL) -> Void)?
    var onBecomeActive: (() -> Void)?

    private var tabs: [TabState] = []
    private var activeTabIndex: Int = 0
    private var activeTab: TabState { tabs[activeTabIndex] }

    var currentURL: URL { activeTab.currentURL }

    private let fileList: FileListController
    private let pathBar = PathBarView()
    private let toolbar = ToolbarView()
    private let statusBar = StatusBarView()
    private let tabStrip = TabStripView()
    private let hotbar = HotbarView()
    private let emptyState = EmptyStateView()
    private let notesView = FolderNoteView()
    private var notesWidthConstraint: NSLayoutConstraint!
    private var notesVisible = false
    private let terminalView = TerminalDrawerView()
    private var terminalHeightConstraint: NSLayoutConstraint!
    private var terminalVisible = false

    private(set) var viewMode: ViewMode = .list
    private var isActive: Bool = false

    /// Free-space is queried via a kernel call (volumeAvailableCapacityForImportantUsageKey).
    /// Caching it for a few seconds keeps the status bar smooth during keyboard arrow
    /// navigation, which would otherwise fire that lookup on every selection change.
    private var cachedFreeBytesString: String = ""
    private var cachedFreeBytesAt: TimeInterval = 0
    private static let freeBytesTTL: TimeInterval = 5.0

    private var tabStripHeightConstraint: NSLayoutConstraint!

    init(url: URL) {
        let initialTab = TabState(url: url)
        // Honor the user's "show hidden by default" preference for new panes.
        initialTab.model.showHidden = Settings.showHiddenByDefault
        self.tabs = [initialTab]
        self.fileList = FileListController(model: initialTab.model)
        super.init(nibName: nil, bundle: nil)
        initialTab.model.delegate = self
        self.fileList.delegate = self
    }

    func focusFilterFromVim() {
        toolbar.focusSearchField()
    }

    /// Briefly show a message in the status bar, then restore the normal
    /// item/selection summary. Used for transient feedback (e.g. plugin notify).
    func flashStatus(_ message: String) {
        statusBar.setSegments([.init(message, isMuted: false)])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.updateStatus()
        }
    }

    /// Toggle the bottom terminal drawer.
    func toggleTerminalDrawer() {
        terminalVisible.toggle()
        if terminalVisible {
            terminalView.isHidden = false
            terminalView.cwd = activeTab.currentURL
            terminalHeightConstraint.constant = 220
            DispatchQueue.main.async { [weak self] in self?.terminalView.focusInput() }
        } else {
            terminalHeightConstraint.constant = 0
            terminalView.isHidden = true
        }
    }

    /// Toggle the right-side notes drawer.
    func toggleNotesDrawer() {
        notesVisible.toggle()
        if notesVisible {
            notesView.isHidden = false
            notesView.folderURL = activeTab.currentURL
            notesWidthConstraint.constant = 280
        } else {
            notesView.saveNow()
            notesWidthConstraint.constant = 0
            notesView.isHidden = true
        }
    }

    private func currentFreeBytesString() -> String {
        let now = ProcessInfo.processInfo.systemUptime
        if now - cachedFreeBytesAt < PaneController.freeBytesTTL, !cachedFreeBytesString.isEmpty {
            return cachedFreeBytesString
        }
        let freeBytes = (try? URL(fileURLWithPath: "/").resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ))?.volumeAvailableCapacityForImportantUsage ?? 0
        let s = SizeFormatter.string(Int64(freeBytes))
        cachedFreeBytesString = s
        cachedFreeBytesAt = now
        return s
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = PaneRootView()
        root.onMouseDown = { [weak self] in self?.becomeActive() }

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        pathBar.translatesAutoresizingMaskIntoConstraints = false
        hotbar.translatesAutoresizingMaskIntoConstraints = false
        fileList.view.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        tabStrip.delegate = self

        root.addSubview(toolbar)
        root.addSubview(tabStrip)
        root.addSubview(pathBar)
        root.addSubview(hotbar)
        root.addSubview(fileList.view)
        root.addSubview(emptyState)
        root.addSubview(notesView)
        root.addSubview(terminalView)
        root.addSubview(statusBar)
        addChild(fileList)
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        notesView.isHidden = true
        notesWidthConstraint = notesView.widthAnchor.constraint(equalToConstant: 0)
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.isHidden = true
        terminalHeightConstraint = terminalView.heightAnchor.constraint(equalToConstant: 0)

        tabStripHeightConstraint = tabStrip.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 36),

            tabStrip.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabStripHeightConstraint,

            pathBar.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            pathBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pathBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pathBar.heightAnchor.constraint(equalToConstant: 26),

            hotbar.topAnchor.constraint(equalTo: pathBar.bottomAnchor),
            hotbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            hotbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            hotbar.heightAnchor.constraint(equalToConstant: 32),

            fileList.view.topAnchor.constraint(equalTo: hotbar.bottomAnchor),
            fileList.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            fileList.view.trailingAnchor.constraint(equalTo: notesView.leadingAnchor),
            fileList.view.bottomAnchor.constraint(equalTo: terminalView.topAnchor),

            notesView.topAnchor.constraint(equalTo: hotbar.bottomAnchor),
            notesView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            notesView.bottomAnchor.constraint(equalTo: terminalView.topAnchor),
            notesWidthConstraint,

            terminalView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            terminalHeightConstraint,

            emptyState.topAnchor.constraint(equalTo: fileList.view.topAnchor),
            emptyState.leadingAnchor.constraint(equalTo: fileList.view.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: fileList.view.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: fileList.view.bottomAnchor),

            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 22),
        ])

        toolbar.onBack = { [weak self] in self?.goBack() }
        toolbar.onForward = { [weak self] in self?.goForward() }
        toolbar.onUp = { [weak self] in self?.goUp() }
        toolbar.onCommit = { [weak self] text in self?.commitTypedPath(text) }
        toolbar.onSearchChanged = { [weak self] q in self?.applyFilter(q) }

        pathBar.onSelectSegment = { [weak self] url in self?.navigate(to: url) }

        self.view = root
        updateAfterNavigate(announce: true)
        updateTabStripVisibility()
        // Honor the default-view preference now that the view hierarchy exists.
        if Settings.defaultView == .columns { setViewMode(.columns) }
        DispatchQueue.main.async { [weak self] in
            self?.hotbar.target = self?.view.window?.windowController as? BrowserWindowController
        }
    }

    func setActive(_ active: Bool) {
        isActive = active
        view.layer?.borderColor = (active ? ThemeManager.shared.effectiveAccent.withAlphaComponent(0.45) : NSColor.clear).cgColor
        view.wantsLayer = true
        view.layer?.borderWidth = active ? 1 : 0
        if active { view.window?.makeFirstResponder(fileList.tableView) }
    }

    func becomeActive() {
        if !isActive { onBecomeActive?() }
    }

    // MARK: Navigation

    func navigate(to url: URL) {
        guard url != activeTab.currentURL else { return }
        activeTab.navigate(to: url)
        updateAfterNavigate(announce: true)
    }

    func goBack() {
        if !activeTab.goBack() { NSSound.beep(); return }
        updateAfterNavigate(announce: true)
    }

    func goForward() {
        if !activeTab.goForward() { NSSound.beep(); return }
        updateAfterNavigate(announce: true)
    }

    func goUp() {
        let parent = activeTab.currentURL.deletingLastPathComponent()
        guard parent.path != activeTab.currentURL.path else { NSSound.beep(); return }
        let childName = activeTab.currentURL.lastPathComponent
        navigate(to: parent)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let item = self.activeTab.model.items.first(where: { $0.name == childName }) {
                self.fileList.select(item: item, scroll: true)
            }
        }
    }

    func openSelection() {
        let sel = fileList.selectedItems()
        if sel.isEmpty { NSSound.beep(); return }
        for item in sel {
            if item.isDirectory {
                navigate(to: item.url)
                return
            } else {
                NSWorkspace.shared.open(item.url)
            }
        }
    }

    func beginRenameSelection() {
        fileList.beginRenameSelection()
    }

    func commitInlineRename(to newName: String) {
        fileList.commitInlineRename(to: newName)
    }

    // MARK: Tabs

    func newTab(at url: URL?) {
        let target = url ?? activeTab.currentURL
        let newTab = TabState(url: target)
        newTab.model.delegate = self
        tabs.append(newTab)
        activeTabIndex = tabs.count - 1
        switchToActiveTabModel()
        updateAfterNavigate(announce: true)
        updateTabStripVisibility()
    }

    /// Snapshot for state-persistence.
    func sessionSnapshot() -> [String: Any] {
        let urls = tabs.map { $0.currentURL.path }
        return ["urls": urls, "active": activeTabIndex]
    }

    /// Replaces the pane's tabs from a snapshot (called during launch restore).
    /// The first tab is the one created in init; we navigate it to the first
    /// saved URL and append the rest.
    func restoreFromSnapshot(_ snap: [String: Any]) {
        guard let urls = snap["urls"] as? [String], !urls.isEmpty else { return }
        let fm = FileManager.default
        let valid = urls.filter { fm.fileExists(atPath: $0) }
        guard !valid.isEmpty else { return }
        // Replace the single initial tab with the first saved URL
        tabs[0].navigate(to: URL(fileURLWithPath: valid[0]))
        for path in valid.dropFirst() {
            let t = TabState(url: URL(fileURLWithPath: path))
            t.model.delegate = self
            tabs.append(t)
        }
        let activeRaw = snap["active"] as? Int ?? 0
        activeTabIndex = max(0, min(activeRaw, tabs.count - 1))
        switchToActiveTabModel()
        updateAfterNavigate(announce: true)
        updateTabStripVisibility()
    }

    func closeActiveTab() {
        guard tabs.count > 1 else {
            view.window?.performClose(nil)
            return
        }
        tabs.remove(at: activeTabIndex)
        if activeTabIndex >= tabs.count { activeTabIndex = tabs.count - 1 }
        switchToActiveTabModel()
        updateAfterNavigate(announce: true)
        updateTabStripVisibility()
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index), index != activeTabIndex else { return }
        activeTabIndex = index
        switchToActiveTabModel()
        updateAfterNavigate(announce: true)
        updateTabStripVisibility()
    }

    private func switchToActiveTabModel() {
        fileList.setModel(activeTab.model)
    }

    private func updateTabStripVisibility() {
        let titles = tabs.map { $0.currentURL.lastPathComponent.isEmpty ? "/" : $0.currentURL.lastPathComponent }
        let tooltips = tabs.map { $0.currentURL.path }
        tabStrip.setTabs(titles, activeIndex: activeTabIndex, tooltips: tooltips)
        tabStripHeightConstraint.constant = tabs.count > 1 ? 26 : 0
    }

    // TabStripDelegate
    func tabStripDidSelect(index: Int) { selectTab(at: index) }
    func tabStripDidRequestClose(index: Int) {
        guard tabs.indices.contains(index) else { return }
        if tabs.count == 1 { view.window?.performClose(nil); return }
        let wasActive = (index == activeTabIndex)
        tabs.remove(at: index)
        if activeTabIndex >= tabs.count { activeTabIndex = tabs.count - 1 }
        else if index < activeTabIndex { activeTabIndex -= 1 }
        if wasActive { switchToActiveTabModel() }
        updateAfterNavigate(announce: true)
        updateTabStripVisibility()
    }
    func tabStripDidRequestNew() { newTab(at: activeTab.currentURL) }

    // MARK: Pane ops

    func toggleHidden() {
        activeTab.model.showHidden.toggle()
    }

    func setViewMode(_ mode: ViewMode) {
        guard mode != viewMode else { return }
        viewMode = mode
        if mode == .columns {
            installColumnsView()
        } else {
            installListView()
        }
    }

    private var columnVC: ColumnViewController?

    private func installColumnsView() {
        guard let host = view as? PaneRootView else { return }
        let col = ColumnViewController(pane: self)
        addChild(col)
        col.view.translatesAutoresizingMaskIntoConstraints = false
        fileList.view.removeFromSuperview()
        host.addSubview(col.view)
        NSLayoutConstraint.activate([
            col.view.topAnchor.constraint(equalTo: hotbar.bottomAnchor),
            col.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            col.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            col.view.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
        ])
        columnVC = col
    }

    private func installListView() {
        guard let host = view as? PaneRootView else { return }
        columnVC?.view.removeFromSuperview()
        columnVC?.removeFromParent()
        columnVC = nil
        host.addSubview(fileList.view)
        NSLayoutConstraint.activate([
            fileList.view.topAnchor.constraint(equalTo: hotbar.bottomAnchor),
            fileList.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            fileList.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            fileList.view.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
        ])
    }

    func reload() {
        activeTab.model.reload()
    }

    func select(url: URL) {
        if let item = activeTab.model.items.first(where: { $0.url == url }) {
            fileList.select(item: item, scroll: true)
        }
    }

    func selectedURLs() -> [URL] {
        fileList.selectedItems().map { $0.url }
    }

    /// Copy currently selected files to the general pasteboard as file URLs.
    func copySelection() {
        let urls = selectedURLs()
        guard !urls.isEmpty else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
    }

    /// Paste file URLs from pasteboard into current directory (copy semantics).
    func pasteHere() {
        FileOps.paste(NSPasteboard.general, into: currentURL, move: false)
    }

    /// Paste file URLs from pasteboard into current directory (move semantics).
    func pasteMoveHere() {
        FileOps.paste(NSPasteboard.general, into: currentURL, move: true)
    }

    /// Duplicate currently selected files in the current directory (Finder Cmd+D).
    func duplicateSelection() {
        let urls = selectedURLs()
        guard !urls.isEmpty else { NSSound.beep(); return }
        for u in urls {
            let dir = u.deletingLastPathComponent()
            let base = u.deletingPathExtension().lastPathComponent
            let ext = u.pathExtension
            var i = 1
            while true {
                let suffix = i == 1 ? " copy" : " copy \(i)"
                let candidate: URL
                if ext.isEmpty {
                    candidate = dir.appendingPathComponent(base + suffix)
                } else {
                    candidate = dir.appendingPathComponent(base + suffix).appendingPathExtension(ext)
                }
                if !FileManager.default.fileExists(atPath: candidate.path) {
                    do {
                        try FileManager.default.copyItem(at: u, to: candidate)
                    } catch {
                        NSSound.beep()
                    }
                    break
                }
                i += 1
                if i > 999 { NSSound.beep(); break }
            }
        }
    }

    func showGoToFolderSheet() {
        guard let win = view.window else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = "Go to Folder"
        alert.informativeText = "Type a path. Use ~ for home."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "/path/to/folder"
        field.stringValue = activeTab.currentURL.path
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: win) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            self?.commitTypedPath(field.stringValue)
        }
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
    }

    func commitTypedPath(_ text: String) {
        var expanded = (text as NSString).expandingTildeInPath
        if expanded.isEmpty { return }
        if !expanded.hasPrefix("/") {
            expanded = (activeTab.currentURL.path as NSString).appendingPathComponent(expanded)
        }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir)
        if exists && isDir.boolValue {
            navigate(to: URL(fileURLWithPath: expanded))
        } else if exists {
            let url = URL(fileURLWithPath: expanded)
            navigate(to: url.deletingLastPathComponent())
            DispatchQueue.main.async { [weak self] in
                self?.select(url: url)
            }
        } else {
            NSSound.beep()
        }
    }

    private func applyFilter(_ text: String) {
        activeTab.model.filterText = text
    }

    private func updateAfterNavigate(announce: Bool) {
        pathBar.url = activeTab.currentURL
        toolbar.canGoBack = activeTab.canGoBack
        toolbar.canGoForward = activeTab.canGoForward
        toolbar.pathText = activeTab.currentURL.path
        if announce { onURLChange?(activeTab.currentURL) }
        if notesVisible { notesView.folderURL = activeTab.currentURL }
        if terminalVisible { terminalView.cwd = activeTab.currentURL }
        updateStatus()
        updateTabStripVisibility()
    }

    private func updateStatus() {
        let total = activeTab.model.items.count
        let selected = fileList.selectedItems()
        let freeStr = currentFreeBytesString()

        var segments: [StatusBarView.Segment] = []
        if selected.isEmpty {
            segments.append(.init("\(total) item\(total == 1 ? "" : "s")"))
        } else {
            segments.append(.init("\(selected.count) of \(total) selected"))
            let sumBytes = selected.reduce(Int64(0)) { $0 + max($1.size, 0) }
            if sumBytes > 0 {
                segments.append(.init(SizeFormatter.string(sumBytes), isMonospaced: true))
            }
            if selected.count == 1, let only = selected.first {
                segments.append(.init(only.url.deletingLastPathComponent().lastPathComponent + "/" + only.name,
                                      isMonospaced: true))
            }
        }
        segments.append(.init("\(freeStr) free", isMuted: true))
        statusBar.setSegments(segments)

        // Empty state placeholder
        let filterIsActive = !activeTab.model.filterText.isEmpty
        if total == 0 {
            if filterIsActive {
                emptyState.configureNoMatches(query: activeTab.model.filterText)
            } else {
                emptyState.configureEmpty()
            }
            emptyState.isHidden = false
        } else {
            emptyState.isHidden = true
        }
    }

    // MARK: DirectoryModelDelegate

    func directoryModelDidUpdate(_ model: DirectoryModel) {
        // Only update UI if the changed model belongs to the active tab.
        if model === activeTab.model {
            fileList.reload()
            updateStatus()
        }
    }

    // MARK: FileListDelegate

    func fileListSelectionChanged() { updateStatus() }
    func fileListOpenItem(_ item: FileItem) {
        if item.isDirectory {
            navigate(to: item.url)
        } else if Archive.isArchive(item.url) {
            if let wc = view.window?.windowController as? BrowserWindowController {
                ArchiveSheetController.show(for: wc, archive: item.url)
            }
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }
    func fileListEnterParent() { goUp() }
    func fileListBecameActive() { becomeActive() }
    func fileListBeginTypeAhead(initial: String) {
        toolbar.focusSearchField(insert: initial)
    }

    func clearFilter() {
        toolbar.clearSearchField()
        view.window?.makeFirstResponder(fileList.tableView)
    }

    // MARK: Test accessors

    var testCurrentItems: [FileItem] { activeTab.model.items }
    var testTabCount: Int { tabs.count }
    var testActiveTabIndex: Int { activeTabIndex }
    var testModel: DirectoryModel { activeTab.model }
    func testSetFilter(_ s: String) { activeTab.model.filterText = s }
    func testSetSort(_ s: SortDescriptor) { activeTab.model.sort = s }
    func testSelectItem(_ item: FileItem) {
        fileList.select(item: item, scroll: false)
    }
    func testReloadSync() {
        activeTab.model.reload(sync: true)
    }
    var testFileList: FileListController { fileList }
    func testToolbarHasFocusAPI() -> Bool {
        // Compile-time presence — calling shouldn't crash.
        toolbar.focusSearchField()
        return true
    }
}

/// Root view that reports mouse-down so we can mark a pane active on click.
private final class PaneRootView: NSView {
    var onMouseDown: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
    }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
