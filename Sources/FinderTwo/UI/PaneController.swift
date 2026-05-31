import AppKit

enum ViewMode { case list, columns, icon, gallery }

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
    private let previewView = PreviewDrawerView()
    private var previewWidthConstraint: NSLayoutConstraint!
    private var previewVisible = false
    private let terminalView = TerminalDrawerView()
    private var terminalHeightConstraint: NSLayoutConstraint!
    private var terminalVisible = false
    var isTerminalVisible: Bool { terminalVisible }
    private let gitDiffView = GitDiffDrawerView()
    private var gitDiffWidthConstraint: NSLayoutConstraint!
    private var gitDiffVisible = false
    var isGitDiffVisible: Bool { gitDiffVisible }

    private(set) var viewMode: ViewMode = .list
    private var isActive: Bool = false

    /// Free-space is queried via a kernel call (volumeAvailableCapacityForImportantUsageKey).
    /// Caching it for a few seconds keeps the status bar smooth during keyboard arrow
    /// navigation, which would otherwise fire that lookup on every selection change.
    private var cachedFreeBytesString: String = ""
    private var cachedFreeBytesAt: TimeInterval = 0
    private static let freeBytesTTL: TimeInterval = 5.0

    private var tabStripHeightConstraint: NSLayoutConstraint!
    private var hotbarHeightConstraint: NSLayoutConstraint!
    private var pathBarHeightConstraint: NSLayoutConstraint!
    private var statusBarHeightConstraint: NSLayoutConstraint!
    /// Inset for the first row of pane content. Non-zero when the window title
    /// bar is hidden, so the toolbar clears the traffic-light strip and lines up
    /// with the (also-inset) sidebar.
    private var topInsetConstraint: NSLayoutConstraint!
    /// Top inset applied when the window title bar is hidden (matches the
    /// sidebar inset in BrowserWindowController so both edges align).
    static let hiddenTitleBarInset: CGFloat = 28
    /// Fixed chrome-row heights (named so the constraint and any toggle that
    /// collapses/expands the row stay in lockstep).
    static let toolbarHeight: CGFloat = 36
    static let hotbarHeight: CGFloat = 32

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

    func toggleGitDiffDrawer() {
        gitDiffVisible.toggle()
        if gitDiffVisible {
            gitDiffView.isHidden = false
            gitDiffWidthConstraint.constant = 400
            if let first = selectedURLs().first,
               (try? first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
                gitDiffView.fileURL = first
            } else {
                gitDiffView.fileURL = nil
            }
        } else {
            gitDiffWidthConstraint.constant = 0
            gitDiffView.isHidden = true
        }
    }

    func showGitDiffDrawer(for url: URL) {
        if !gitDiffVisible {
            gitDiffVisible = true
            gitDiffView.isHidden = false
            gitDiffWidthConstraint.constant = 400
        }
        gitDiffView.fileURL = url
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

    func togglePreviewDrawer() {
        previewVisible.toggle()
        previewView.isHidden = !previewVisible
        previewWidthConstraint.constant = previewVisible ? 260 : 0
        if previewVisible { updatePreviewContent() }
    }

    /// Update the preview drawer to the current selection (or the folder when
    /// nothing is selected). No-op while the drawer is closed.
    private func updatePreviewContent() {
        guard previewVisible else { return }
        previewView.url = selectedURLs().first ?? activeTab.currentURL
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
        root.addSubview(gitDiffView)
        root.addSubview(previewView)
        root.addSubview(notesView)
        root.addSubview(terminalView)
        root.addSubview(statusBar)
        addChild(fileList)
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        notesView.isHidden = true
        notesWidthConstraint = notesView.widthAnchor.constraint(equalToConstant: 0)
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.isHidden = true
        previewWidthConstraint = previewView.widthAnchor.constraint(equalToConstant: 0)
        gitDiffView.isHidden = true
        gitDiffWidthConstraint = gitDiffView.widthAnchor.constraint(equalToConstant: 0)
        gitDiffView.onClose = { [weak self] in self?.toggleGitDiffDrawer() }
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.isHidden = true
        terminalHeightConstraint = terminalView.heightAnchor.constraint(equalToConstant: 0)

        tabStripHeightConstraint = tabStrip.heightAnchor.constraint(equalToConstant: 0)
        hotbarHeightConstraint = hotbar.heightAnchor.constraint(equalToConstant: PaneController.hotbarHeight)
        pathBarHeightConstraint = pathBar.heightAnchor.constraint(equalToConstant: 26)
        statusBarHeightConstraint = statusBar.heightAnchor.constraint(equalToConstant: 22)
        topInsetConstraint = toolbar.topAnchor.constraint(equalTo: root.topAnchor)

        NSLayoutConstraint.activate([
            topInsetConstraint,
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: PaneController.toolbarHeight),

            tabStrip.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabStripHeightConstraint,

            pathBar.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            pathBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pathBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pathBarHeightConstraint,

            hotbar.topAnchor.constraint(equalTo: pathBar.bottomAnchor),
            hotbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            hotbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            hotbarHeightConstraint,

            fileList.view.topAnchor.constraint(equalTo: hotbar.bottomAnchor),
            fileList.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            fileList.view.trailingAnchor.constraint(equalTo: gitDiffView.leadingAnchor),
            fileList.view.bottomAnchor.constraint(equalTo: terminalView.topAnchor),

            // Git Diff drawer sits between content and preview drawer
            gitDiffView.topAnchor.constraint(equalTo: hotbar.bottomAnchor),
            gitDiffView.trailingAnchor.constraint(equalTo: previewView.leadingAnchor),
            gitDiffView.bottomAnchor.constraint(equalTo: terminalView.topAnchor),
            gitDiffWidthConstraint,

            // Preview drawer sits between git diff drawer and notes drawer.
            previewView.topAnchor.constraint(equalTo: hotbar.bottomAnchor),
            previewView.trailingAnchor.constraint(equalTo: notesView.leadingAnchor),
            previewView.bottomAnchor.constraint(equalTo: terminalView.topAnchor),
            previewWidthConstraint,

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
            statusBarHeightConstraint,
        ])

        toolbar.onBack = { [weak self] in self?.goBack() }
        toolbar.onForward = { [weak self] in self?.goForward() }
        toolbar.onUp = { [weak self] in self?.goUp() }
        toolbar.onCommit = { [weak self] text in self?.commitTypedPath(text) }
        toolbar.onSearchChanged = { [weak self] q in self?.applyFilter(q) }

        pathBar.onSelectSegment = { [weak self] url in self?.navigate(to: url) }

        self.view = root
        subscribeToTheme(root)   // paints the chrome strip behind the inset toolbar
        updateAfterNavigate(announce: true)
        updateTabStripVisibility()
        applyHotbarVisibility()
        applyChromeVisibility()
        applyTopInset()
        // Honor the default-view preference now that the view hierarchy exists.
        if Settings.defaultView == .columns { setViewMode(.columns) }
        DispatchQueue.main.async { [weak self] in
            self?.hotbar.target = self?.view.window?.windowController as? BrowserWindowController
        }
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: Settings.didChange, object: nil)
    }

    @objc private func settingsChanged() {
        applyHotbarVisibility()
        applyChromeVisibility()
        applyTopInset()
        fileList.settingsDidChange()   // Calculate-Sizes / type-to-select / Use Groups
    }

    /// Show or hide the customizable hotbar per the user setting. Hidden by
    /// default; collapses to zero height so the file list reclaims the space.
    private func applyHotbarVisibility() {
        hotbar.isHidden = !Settings.showHotbar
        hotbarHeightConstraint.constant = Settings.showHotbar ? PaneController.hotbarHeight : 0
    }

    /// Show/hide the breadcrumb path bar and the status bar per the user
    /// settings (both on by default), collapsing to zero height when hidden.
    private func applyChromeVisibility() {
        pathBar.isHidden = !Settings.showPathBar
        pathBarHeightConstraint.constant = Settings.showPathBar ? 26 : 0
        statusBar.isHidden = !Settings.showStatusBar
        statusBarHeightConstraint.constant = Settings.showStatusBar ? 22 : 0
    }

    /// When the window title bar is hidden, inset the toolbar from the top so it
    /// clears the traffic lights and lines up with the (also-inset) sidebar.
    private func applyTopInset() {
        topInsetConstraint.constant = Settings.showTitleBar ? 0 : PaneController.hiddenTitleBarInset
    }

    func setActive(_ active: Bool, showBorder: Bool = false) {
        isActive = active
        // The accent border only marks WHICH pane is active — it's meaningless
        // (and reads as a stray blue outline) with a single pane, so only draw
        // it when the window is actually split.
        let border = active && showBorder
        view.wantsLayer = true
        view.layer?.borderColor = (border ? ThemeManager.shared.effectiveAccent.withAlphaComponent(0.45) : NSColor.clear).cgColor
        view.layer?.borderWidth = border ? 1 : 0
        // Focus the file list on activation — but don't yank focus away from the
        // sidebar (so keyboard users can drive the source list), and don't focus
        // the hidden list while in columns mode.
        if active, viewMode == .list, !(view.window?.firstResponder is NSOutlineView) {
            view.window?.makeFirstResponder(fileList.tableView)
        }
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

    // MARK: View-aware keyboard navigation (used by Vim mode)

    /// Move selection/focus by `delta` in whichever view is active.
    func vimMove(by delta: Int) {
        switch viewMode {
        case .icon:    iconVC?.moveSelection(by: delta)
        case .gallery: galleryVC?.moveFocus(by: delta)
        default:       fileList.moveSelection(by: delta)
        }
    }
    func vimSelectFirst() {
        switch viewMode {
        case .icon:    iconVC?.selectFirst()
        case .gallery: galleryVC?.focusFirst()
        default:       fileList.selectRow(0)
        }
    }
    func vimSelectLast() {
        switch viewMode {
        case .icon:    iconVC?.selectLast()
        case .gallery: galleryVC?.focusLast()
        default:       fileList.selectRow(fileList.lastRowIndex)
        }
    }

    func openSelection() {
        // Icon/gallery keep their own selection; route those through the
        // alternate view so Enter / vim `l` open the focused item there too.
        if viewMode == .icon { iconVC?.openSelected(); return }
        if viewMode == .gallery { galleryVC?.openFocused(); return }
        let sel = fileList.selectedItems()
        if sel.isEmpty { NSSound.beep(); return }
        // Route through the same handler as double-click so folders enter,
        // archives open the browser, and files open in their default app.
        if let folder = sel.first(where: { $0.isDirectory }) {
            fileListOpenItem(folder)
        } else {
            for item in sel { fileListOpenItem(item) }
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

    /// Cycle to the next/previous tab (wraps around).
    func nextTab() { cycleTab(by: 1) }
    func prevTab() { cycleTab(by: -1) }
    private func cycleTab(by delta: Int) {
        guard tabs.count > 1 else { return }
        selectTab(at: (activeTabIndex + delta + tabs.count) % tabs.count)
    }

    /// Jump to the last tab (⌘9, browser convention).
    func selectLastTab() { selectTab(at: tabs.count - 1) }

    /// Move the active tab out into its own new window, then close it here.
    func moveActiveTabToNewWindow() {
        guard tabs.count > 1 else { return }
        let url = activeTab.currentURL
        (NSApp.delegate as? AppDelegate)?.openNewBrowserWindow(at: url)
        closeActiveTab()
    }

    /// Reorder the active tab left/right (no wrap); it stays active.
    func moveActiveTab(by delta: Int) {
        let dest = activeTabIndex + delta
        guard tabs.count > 1, tabs.indices.contains(dest) else { return }
        let t = tabs.remove(at: activeTabIndex)
        tabs.insert(t, at: dest)
        activeTabIndex = dest
        updateTabStripVisibility()
    }

    /// Put keyboard focus on this pane's file list (used by pane-switching).
    func focusFileList() {
        view.window?.makeFirstResponder(fileList.tableView)
    }

    func compressSelection() { fileList.compressSelection() }
    func extractSelection() { fileList.extractSelection() }
    func makeAliasSelection() { fileList.makeAliasSelection() }
    func selectByPattern() { fileList.selectByPatternPrompt() }
    /// Test hook: select by glob without the prompt; returns the match count.
    func testSelectMatching(_ glob: String) -> Int { fileList.selectMatching(glob: glob) }
    func arrangeBy(_ key: SortKey) { fileList.setSortKey(key) }

    private func switchToActiveTabModel() {
        fileList.setModel(activeTab.model)
    }

    private func updateTabStripVisibility() {
        let titles = tabs.map { $0.currentURL.lastPathComponent.isEmpty ? "/" : $0.currentURL.lastPathComponent }
        let tooltips = tabs.map { $0.currentURL.path }
        tabStrip.setTabs(titles, activeIndex: activeTabIndex, tooltips: tooltips)
        let multi = tabs.count > 1 || Settings.alwaysShowTabBar
        tabStrip.isHidden = !multi
        tabStripHeightConstraint.constant = multi ? 26 : 0
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
        switch mode {
        case .columns: installColumnsView()
        case .icon:    installIconView()
        case .gallery: installGalleryView()
        case .list:    installListView()
        }
    }

    private var columnVC: ColumnViewController?
    private var iconVC: IconViewController?
    private var galleryVC: GalleryViewController?
    private var iconSelection: [FileItem] = []

    /// Remove any installed alternate (columns/icon/gallery) view controller.
    private func teardownAlternateViews() {
        columnVC?.view.removeFromSuperview(); columnVC?.removeFromParent(); columnVC = nil
        iconVC?.view.removeFromSuperview(); iconVC?.removeFromParent(); iconVC = nil
        galleryVC?.view.removeFromSuperview(); galleryVC?.removeFromParent(); galleryVC = nil
        iconSelection = []
    }

    /// Pin an alternate view's edges into the content region (hotbar↓ to status,
    /// stopping at the notes drawer) — same frame the list view occupies.
    private func pinAlternate(_ v: NSView, in host: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: hotbar.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: previewView.leadingAnchor),
            v.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
        ])
    }

    private func installColumnsView() {
        guard let host = view as? PaneRootView else { return }
        teardownAlternateViews()
        // Hide the list rather than remove it — removing would deactivate the
        // empty-state and notes-drawer constraints that are pinned to it.
        fileList.view.isHidden = true
        emptyState.isHidden = true
        let col = ColumnViewController(pane: self)
        addChild(col)
        pinAlternate(col.view, in: host)
        columnVC = col
    }

    private func installIconView() {
        guard let host = view as? PaneRootView else { return }
        teardownAlternateViews()
        fileList.view.isHidden = true
        emptyState.isHidden = true
        let icon = IconViewController()
        addChild(icon)
        icon.onOpen = { [weak self] item in self?.fileListOpenItem(item) }
        icon.onSelectionChange = { [weak self] items in self?.iconSelection = items; self?.updateStatus() }
        pinAlternate(icon.view, in: host)
        iconVC = icon
        icon.reload(activeTab.model.items)
    }

    private func installGalleryView() {
        guard let host = view as? PaneRootView else { return }
        teardownAlternateViews()
        fileList.view.isHidden = true
        emptyState.isHidden = true
        let gallery = GalleryViewController()
        addChild(gallery)
        gallery.onOpen = { [weak self] item in self?.fileListOpenItem(item) }
        gallery.onSelectionChange = { [weak self] items in self?.iconSelection = items; self?.updateStatus() }
        pinAlternate(gallery.view, in: host)
        galleryVC = gallery
        gallery.reload(activeTab.model.items)
    }

    private func installListView() {
        teardownAlternateViews()
        fileList.view.isHidden = false
        // Re-evaluate the empty-state placeholder for the current contents.
        updateStatus()
    }

    func reload() {
        activeTab.model.reload()
    }

    func select(url: URL) {
        if let item = activeTab.model.items.first(where: { $0.url == url }) {
            fileList.select(item: item, scroll: true)
        }
    }

    /// Create-and-reveal helpers (New Folder / New File): make the item, then
    /// select + inline-rename it once the asynchronous directory reload lands.
    func createNewFolder() {
        guard let url = FileOps.newFolder(in: currentURL) else { NSSound.beep(); return }
        fileList.queueReveal(url, rename: true); reload()
    }

    /// Test hook: create a folder and reveal it via a SYNCHRONOUS reload, so the
    /// resulting selection is deterministic (the async scan queue is saturated
    /// during the full test run). Exercises the same queueReveal + consume path.
    @discardableResult
    func testNewFolderSyncReveal() -> URL? {
        guard let url = FileOps.newFolder(in: currentURL) else { return nil }
        fileList.queueReveal(url, rename: false)
        activeTab.model.reload(sync: true)
        return url
    }
    func createNewFile() {
        guard let url = FileOps.newFile(in: currentURL) else { NSSound.beep(); return }
        fileList.queueReveal(url, rename: true); reload()
    }
    func createNewFolderWithSelection() {
        let sel = selectedURLs()
        guard !sel.isEmpty, let url = FileOps.newFolderWithItems(sel, in: currentURL) else { NSSound.beep(); return }
        fileList.queueReveal(url, rename: true); reload()
    }

    func selectedURLs() -> [URL] {
        if viewMode == .icon || viewMode == .gallery { return iconSelection.map { $0.url } }
        return fileList.selectedItems().map { $0.url }
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
        FileOps.paste(NSPasteboard.general, into: currentURL, move: false, from: view.window)
    }

    /// Paste file URLs from pasteboard into current directory (move semantics).
    func pasteMoveHere() {
        FileOps.paste(NSPasteboard.general, into: currentURL, move: true, from: view.window)
    }

    /// Duplicate currently selected files in the current directory (Finder Cmd+D).
    func duplicateSelection() {
        let urls = selectedURLs()
        guard !urls.isEmpty else { NSSound.beep(); return }
        var lastCreated: URL?
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
                        FileActionLog.shared.recordCreate(candidate, name: "Duplicate")
                        lastCreated = candidate
                    } catch {
                        NSSound.beep()
                    }
                    break
                }
                i += 1
                if i > 999 { NSSound.beep(); break }
            }
        }
        // Select the duplicate once it lands (Finder selects the copy). No rename
        // (Cmd+D leaves the name as-is), and reveal the last one for a multi-select.
        if let created = lastCreated { fileList.queueReveal(created, rename: false); reload() }
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
        iconVC?.reload(activeTab.model.items)
        galleryVC?.reload(activeTab.model.items)
        updateStatus()
        updateTabStripVisibility()
    }

    private func updateGitDiffContent() {
        guard gitDiffVisible else { return }
        if let first = selectedURLs().first,
           (try? first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
            gitDiffView.fileURL = first
        } else {
            gitDiffView.fileURL = nil
        }
    }

    private func updateStatus() {
        updatePreviewContent()
        updateGitDiffContent()
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
        if Settings.gitIntegrationEnabled, Settings.showGitBranchInStatusBar, let git = activeTab.model.gitRepoInfo {
            segments.append(.init("git: \(git.label)", isMonospaced: true, isMuted: false))
        }
        segments.append(.init("\(freeStr) free", isMuted: true))
        statusBar.setSegments(segments)

        // Empty state placeholder (list view only — the column view fills the
        // same region and manages its own emptiness).
        let filterIsActive = !activeTab.model.filterText.isEmpty
        if total == 0 && viewMode == .list {
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
            iconVC?.reload(activeTab.model.items)
        galleryVC?.reload(activeTab.model.items)
            updateStatus()
        }
    }

    func directoryModelDidUpdateGitStatus(_ model: DirectoryModel) {
        // Items are unchanged — repaint badges in place, no full reload.
        if model === activeTab.model {
            fileList.refreshGitBadges()
        }
    }

    // MARK: FileListDelegate

    func fileListSelectionChanged() { updateStatus() }
    func fileListOpenItem(_ item: FileItem) {
        if item.isPackage {
            NSWorkspace.shared.open(item.url)   // launch the app/bundle
        } else if item.isDirectory {
            if Settings.doubleClickFolderOpensNewTab {
                newTab(at: item.url)
            } else {
                navigate(to: item.url)
            }
        } else if Archive.isArchive(item.url) {
            if let wc = view.window?.windowController as? BrowserWindowController {
                ArchiveSheetController.show(for: wc, archive: item.url)
            }
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }
    func fileListEnterParent() { goUp() }
    /// Browse inside a bundle (Show Package Contents) — navigate in, treating
    /// the package as an ordinary folder.
    func fileListShowPackageContents(_ url: URL) { navigate(to: url) }
    func fileListShowGitDiff(for url: URL) {
        showGitDiffDrawer(for: url)
    }
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
    var testToolbarVisible: Bool { !toolbar.isHidden }
    var testHotbarVisible: Bool { !hotbar.isHidden }
    var testTabStripVisible: Bool { !tabStrip.isHidden }
    var testTabStrip: TabStripView { tabStrip }
    var testPreviewVisible: Bool { previewVisible }
    var testHotbarHeight: CGFloat { hotbarHeightConstraint.constant }
    var testToolbarTopInset: CGFloat { topInsetConstraint.constant }
    func testToolbarHasFocusAPI() -> Bool {
        // Compile-time presence — calling shouldn't crash.
        toolbar.focusSearchField()
        return true
    }
}

/// Root view that reports mouse-down so we can mark a pane active on click.
private final class PaneRootView: NSView, ThemeObserving {
    var onMouseDown: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
    }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc func applyTheme() {
        wantsLayer = true
        // Match the toolbar so the inset strip above it (title-bar-hidden mode)
        // reads as one continuous top bar rather than a mismatched gap.
        layer?.backgroundColor = ThemeManager.shared.current.toolbarBackground.cgColor
    }
    deinit { NotificationCenter.default.removeObserver(self) }
}
