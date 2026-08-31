import AppKit

final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, ThemeObserving, NSMenuDelegate {

    var onSelect: ((URL) -> Void)?
    var onOpenInNewTab: ((URL) -> Void)?
    var onOpenInNewWindow: ((URL) -> Void)?

    let outline = NSOutlineView()
    private let scrollView = NSScrollView()

    private final class Section {
        let title: String
        var items: [Entry]
        /// Non-nil for the folder-tree section, whose top-level rows are
        /// lazily-expandable `TreeNode`s rather than flat `Entry`s.
        var treeRoots: [TreeNode]?
        init(title: String, items: [Entry], treeRoots: [TreeNode]? = nil) {
            self.title = title; self.items = items; self.treeRoots = treeRoots
        }
        /// How many top-level rows this section shows.
        var childCount: Int { treeRoots?.count ?? items.count }
    }
    private final class Entry {
        let title: String
        let url: URL
        let icon: NSImage
        init(title: String, url: URL, icon: NSImage) {
            self.title = title; self.url = url; self.icon = icon
        }
    }

    /// A node in the Explorer-style folder tree. Children are loaded *lazily*
    /// (only when the node is expanded) via `FastDirScan`, so deep hierarchies
    /// are never pre-scanned — see `loadChildrenIfNeeded`. Reference type because
    /// `NSOutlineView` keys items by object identity.
    final class TreeNode {
        let url: URL
        let title: String
        let icon: NSImage
        let isDirectory: Bool
        /// Canonical (symlink-resolved) paths of this node and every ancestor,
        /// used to break symlink cycles when enumerating children.
        let ancestorRealPaths: Set<String>
        /// nil until the node is first expanded; non-nil (possibly empty) after.
        private(set) var children: [TreeNode]?
        var isLoaded: Bool { children != nil }

        init(url: URL, title: String, icon: NSImage, isDirectory: Bool,
             ancestorRealPaths: Set<String> = []) {
            self.url = url
            self.title = title
            self.icon = icon
            self.isDirectory = isDirectory
            self.ancestorRealPaths = ancestorRealPaths
        }

        /// Lazily enumerate this node's immediate subdirectories with the fast
        /// scanner, sorted case-insensitively. Hidden folders are skipped unless
        /// the user has "Show Hidden Files" on. Symlinked directories whose real
        /// path is already an ancestor are dropped to prevent infinite recursion.
        /// Idempotent: only the first call hits the disk.
        @discardableResult
        func loadChildrenIfNeeded() -> [TreeNode] {
            if let children { return children }
            guard isDirectory else { children = []; return [] }
            // The tree follows the user's global "show hidden" default; per-pane
            // toggles don't apply to the always-present sidebar.
            let showHidden = Settings.showHiddenByDefault
            let myReal = (url.resolvingSymlinksInPath().path as NSString).standardizingPath
            let inheritedReal = ancestorRealPaths.union([myReal])

            var dirs = FastDirScan.list(url).filter { $0.isDirectory }
            if !showHidden { dirs = dirs.filter { !$0.isHidden } }
            dirs.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            var built: [TreeNode] = []
            built.reserveCapacity(dirs.count)
            for e in dirs {
                let childReal = (e.url.resolvingSymlinksInPath().path as NSString).standardizingPath
                // Cycle guard: a symlink pointing back up the tree (or to itself)
                // would otherwise let the user expand forever.
                if e.isSymlink && inheritedReal.contains(childReal) { continue }
                built.append(TreeNode(
                    url: e.url, title: e.name,
                    icon: SidebarController.folderIcon(for: e.url),
                    isDirectory: true, ancestorRealPaths: inheritedReal))
            }
            children = built
            return built
        }

        /// Drop cached children so the next expansion re-scans (used when the
        /// "Show Hidden Files" setting flips, which changes what's visible).
        func invalidateChildren() { children = nil }
    }

    private var sections: [Section] = []
    /// Tags load asynchronously (Spotlight); cached here so section assembly stays
    /// driven by `canonicalRank`, never by completion-handler timing.
    private var tagsSection: Section?

    /// Fixed display order for sidebar sections. The visible array is always
    /// rebuilt from this rank, so two in-flight async loads (Tags vs the folder
    /// tree) can finish in any order without changing section order or flickering.
    private static func canonicalRank(of title: String) -> Int {
        switch title {
        case "Favorites":                           return 0
        case "Locations":                           return 1
        case "Smart Folders":                       return 2
        case "Tags":                                return 3
        case SidebarController.foldersSectionTitle: return 4   // "Folders" — always last
        default:                                    return 99
        }
    }

    /// Assemble `sections` in canonical order from the synchronous sections plus
    /// the (optional) cached async Tags section. Idempotent and order-stable; the
    /// Folders section is kept even though its `items` are empty (it carries the
    /// expandable `treeRoots`).
    private func applySections(base: [Section]) {
        var all = base
        if let tags = tagsSection { all.append(tags) }
        sections = all
            .filter { !$0.items.isEmpty || $0.title == SidebarController.foldersSectionTitle }
            .sorted { SidebarController.canonicalRank(of: $0.title)
                    < SidebarController.canonicalRank(of: $1.title) }
    }
    /// Top-level roots of the folder tree (Home + mounted volumes). Kept around
    /// so their lazily-built children survive `reloadData` across bookmark/theme
    /// changes (rebuilding them would collapse the user's expanded folders).
    private var treeRoots: [TreeNode] = []
    private var selectedURL: URL?

    var testEntryTitles: [String] {
        sections.flatMap { $0.items.map { $0.title } }
    }

    // MARK: Folder-tree test hooks (off-screen)

    /// Titles of the folder-tree's top-level roots (Home + volumes).
    var testTreeRootTitles: [String] { treeRoots.map { $0.title } }

    /// Whether the live sidebar exposes a "Folders" section.
    var testHasFoldersSection: Bool {
        sections.contains { $0.title == SidebarController.foldersSectionTitle }
    }

    /// Build a detached tree node rooted at `url` (used by tests to point the
    /// lazy-loader at a known temp directory without touching the live sidebar).
    static func testMakeTreeNode(url: URL) -> TreeNode {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? true
        return TreeNode(url: url, title: url.lastPathComponent,
                        icon: folderIcon(for: url), isDirectory: isDir)
    }

    /// Lazily load and return the immediate child folder nodes of `node`.
    static func testLoadChildren(of node: TreeNode) -> [TreeNode] {
        node.loadChildrenIfNeeded()
    }

    /// Lazily load and return the immediate child folder URLs of `node`.
    static func testLoadChildURLs(of node: TreeNode) -> [URL] {
        node.loadChildrenIfNeeded().map { $0.url }
    }

    /// Whether a node has already loaded its children (proves laziness).
    static func testIsLoaded(_ node: TreeNode) -> Bool { node.isLoaded }

    /// Themed tint that covers the vibrancy for non-System themes so the
    /// sidebar background matches the rest of the window.
    private let tintView = NSView()
    private var scrollTopConstraint: NSLayoutConstraint!

    /// Inset the source-list rows from the top (used to clear the traffic
    /// lights when the window title bar is hidden).
    func setTopInset(_ inset: CGFloat) {
        scrollTopConstraint?.constant = inset
    }
    var testTopInset: CGFloat { scrollTopConstraint?.constant ?? -1 }

    override func loadView() {
        // Sidebar-style NSVisualEffectView gives the native translucency for the
        // System theme; a themed tint overlay covers it for custom themes.
        let v = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 168, height: 400))
        v.wantsLayer = true
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState

        tintView.wantsLayer = true
        tintView.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(tintView)

        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        // The clip view defaults to drawing an OPAQUE system background, which
        // sits in front of the tint and is what made every theme look "system".
        // Turn it off so the outline's own background (set per-theme) shows.
        scrollView.contentView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(scrollView)
        scrollTopConstraint = scrollView.topAnchor.constraint(equalTo: v.topAnchor)
        NSLayoutConstraint.activate([
            tintView.topAnchor.constraint(equalTo: v.topAnchor),
            tintView.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            tintView.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            scrollTopConstraint,
            scrollView.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        self.view = v
        subscribeToTheme(self)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        col.title = ""
        col.resizingMask = [.autoresizingMask]
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        // `.inset` (not `.sourceList`): the source-list style draws its OWN
        // system vibrancy that ignores our theme tint, so every custom theme
        // looked identically "system". `.inset` is non-vibrant, so the tint
        // (clear for System → the visual-effect view shows; opaque theme color
        // otherwise) governs the sidebar background. Runtime style changes
        // don't reliably stick, so this is set once and never toggled.
        outline.style = .inset
        // selectionHighlightStyle = .sourceList is deprecated since macOS 12 because
        // setting the table style to .sourceList already provides the correct highlight.
        outline.indentationPerLevel = 16
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(handleClick)
        outline.autosaveExpandedItems = true
        outline.autosaveName = "FinderTwo.Sidebar"
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        outline.focusRingType = .none   // no blue focus outline around the sidebar
        outline.intercellSpacing = NSSize(width: 0, height: 3)
        outline.rowHeight = 28

        outline.menu = NSMenu()
        outline.menu?.delegate = self

        buildSections()
        outline.reloadData()
        for s in sections { outline.expandItem(s) }

        NotificationCenter.default.addObserver(self, selector: #selector(bookmarksChanged),
                                               name: SidebarBookmarks.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(bookmarksChanged),
                                               name: SmartFolders.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: Settings.didChange, object: nil)
        lastShowHiddenDefault = Settings.showHiddenByDefault
    }

    @objc private func bookmarksChanged() {
        buildSections()
        outline.reloadData()
        for s in sections { outline.expandItem(s) }
    }

    /// Tracks the global show-hidden default so we only rescan the tree when it
    /// actually flips (Settings.didChange also fires for theme/density/etc.).
    private var lastShowHiddenDefault = false

    @objc private func settingsChanged() {
        let now = Settings.showHiddenByDefault
        guard now != lastShowHiddenDefault else { return }
        lastShowHiddenDefault = now
        // The set of visible subfolders changed: drop every cached subtree so the
        // next expansion rescans with the new hidden-files rule.
        invalidateAllTreeChildren(treeRoots)
        outline.reloadData()
        for s in sections { outline.expandItem(s) }
    }

    private func invalidateAllTreeChildren(_ nodes: [TreeNode]) {
        for n in nodes {
            if let kids = n.children { invalidateAllTreeChildren(kids) }
            n.invalidateChildren()
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Context menu (built per right-click for the clicked row)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        guard row >= 0 else { return }
        let item = outline.item(atRow: row)
        // Folder-tree nodes get open-in-tab/window plus an Add to Sidebar shortcut.
        if let node = item as? TreeNode {
            let openTab = NSMenuItem(title: "Open in New Tab", action: #selector(ctxOpenNewTab(_:)), keyEquivalent: "")
            let openWin = NSMenuItem(title: "Open in New Window", action: #selector(ctxOpenNewWindow(_:)), keyEquivalent: "")
            for it in [openTab, openWin] { it.target = self; it.representedObject = node.url; menu.addItem(it) }
            menu.addItem(.separator())
            if SidebarBookmarks.contains(node.url) {
                let rm = NSMenuItem(title: "Remove from Sidebar", action: #selector(ctxRemoveBookmark(_:)), keyEquivalent: "")
                rm.target = self; rm.representedObject = node.url; menu.addItem(rm)
            } else {
                let add = NSMenuItem(title: "Add to Sidebar", action: #selector(ctxAddBookmark(_:)), keyEquivalent: "")
                add.target = self; add.representedObject = node.url; menu.addItem(add)
            }
            return
        }
        guard let entry = item as? Entry, !SidebarController.isTagURL(entry.url) else { return }
        let openTab = NSMenuItem(title: "Open in New Tab", action: #selector(ctxOpenNewTab(_:)), keyEquivalent: "")
        let openWin = NSMenuItem(title: "Open in New Window", action: #selector(ctxOpenNewWindow(_:)), keyEquivalent: "")
        for it in [openTab, openWin] { it.target = self; it.representedObject = entry.url; menu.addItem(it) }
        if SidebarController.isSmartFolderURL(entry.url) {
            menu.addItem(.separator())
            let del = NSMenuItem(title: "Delete Smart Folder", action: #selector(ctxDeleteSmartFolder(_:)), keyEquivalent: "")
            del.target = self; del.representedObject = entry.url; menu.addItem(del)
            return
        }
        if let rv = try? entry.url.resourceValues(forKeys: [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsRootFileSystemKey]),
           (rv.volumeIsEjectable == true || rv.volumeIsRemovable == true), rv.volumeIsRootFileSystem != true {
            menu.addItem(.separator())
            let eject = NSMenuItem(title: "Eject", action: #selector(ctxEject(_:)), keyEquivalent: "")
            eject.target = self; eject.representedObject = entry.url; menu.addItem(eject)
        }
        if SidebarBookmarks.contains(entry.url) {
            menu.addItem(.separator())
            let rm = NSMenuItem(title: "Remove from Sidebar", action: #selector(ctxRemoveBookmark(_:)), keyEquivalent: "")
            rm.target = self; rm.representedObject = entry.url; menu.addItem(rm)
        }
    }
    @objc private func ctxOpenNewTab(_ s: NSMenuItem) { if let u = s.representedObject as? URL { onOpenInNewTab?(u) } }
    @objc private func ctxOpenNewWindow(_ s: NSMenuItem) { if let u = s.representedObject as? URL { onOpenInNewWindow?(u) } }
    @objc private func ctxRemoveBookmark(_ s: NSMenuItem) { if let u = s.representedObject as? URL { SidebarBookmarks.remove(u) } }
    @objc private func ctxAddBookmark(_ s: NSMenuItem) { if let u = s.representedObject as? URL { SidebarBookmarks.add(u) } }
    @objc private func ctxDeleteSmartFolder(_ s: NSMenuItem) {
        if let u = s.representedObject as? URL, let id = SidebarController.smartFolderId(from: u) {
            SmartFolders.remove(id: id)
        }
    }
    @objc private func ctxEject(_ s: NSMenuItem) {
        guard let u = s.representedObject as? URL else { return }
        do { try NSWorkspace.shared.unmountAndEjectDevice(at: u) } catch { NSSound.beep() }
    }

    @objc func applyTheme() {
        let t = ThemeManager.shared.current
        let isSystem = t.id == "system"
        
        let view = self.view as? NSVisualEffectView
        if isSystem {
            view?.state = .followsWindowActiveState
            view?.material = .sidebar
        } else {
            view?.state = .inactive
            view?.material = .underWindowBackground
        }
        
        let bg: NSColor = isSystem ? .clear : t.sidebarBackground
        outline.backgroundColor = bg
        tintView.layer?.backgroundColor = bg.cgColor
        outline.reloadData()
    }

    /// Test hook: the surface the sidebar actually renders (the outline's own
    /// background). Clear / zero-alpha = native vibrancy.
    var testSidebarBackground: NSColor? { outline.backgroundColor }

    func highlight(url: URL) {
        selectedURL = url
        // Prefer a flat shortcut row (Favorites/Locations) for the active path.
        for s in sections {
            if let e = s.items.first(where: { $0.url == url }) {
                let row = outline.row(forItem: e)
                if row >= 0 {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    return
                }
            }
        }
        // Otherwise, if a matching folder-tree node is already on screen (we only
        // search ALREADY-LOADED nodes — never force a scan just to highlight),
        // select it so clicking a tree folder keeps its row highlighted.
        if let node = visibleTreeNode(matching: url) {
            let row = outline.row(forItem: node)
            if row >= 0 {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                return
            }
        }
        outline.deselectAll(nil)
    }

    /// Find an already-loaded tree node whose URL matches `url`, without
    /// triggering any lazy scan (we read cached children only).
    private func visibleTreeNode(matching url: URL) -> TreeNode? {
        func search(_ nodes: [TreeNode]) -> TreeNode? {
            for n in nodes {
                if n.url == url { return n }
                if let kids = n.children, let hit = search(kids) {
                    return hit
                }
            }
            return nil
        }
        return search(treeRoots)
    }

    /// The navigable URL for a clicked/selected sidebar row, if any.
    private func navigableURL(forRow row: Int) -> URL? {
        guard row >= 0 else { return nil }
        let item = outline.item(atRow: row)
        if let entry = item as? Entry { return entry.url }
        if let node = item as? TreeNode { return node.url }
        return nil
    }

    @objc private func handleClick() {
        if let url = navigableURL(forRow: outline.selectedRow) { onSelect?(url) }
    }

    /// Section title for the Explorer-style folder tree.
    static let foldersSectionTitle = "Folders"

    /// Icon for a folder/volume URL, falling back to the generic folder icon for
    /// TCC-protected paths we can't read without Full Disk Access (so we don't
    /// trip a permission prompt just to draw a sidebar row). Sized for the tree.
    static func folderIcon(for url: URL) -> NSImage {
        let icon: NSImage
        if !PermissionsManager.hasFullDiskAccess && PermissionsManager.isProtectedPath(url.path) {
            icon = NSWorkspace.shared.icon(for: .folder)
        } else {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        }
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    /// (Re)build the folder-tree roots: Home, then each browsable mounted
    /// volume. Only the *roots* are created here; their subfolders load lazily on
    /// expansion. Existing roots are reused so already-expanded subtrees aren't
    /// thrown away on a rebuild (e.g. when bookmarks or the theme change).
    private func buildTreeRoots() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var existing: [String: TreeNode] = [:]
        for r in treeRoots { existing[r.url.path] = r }

        func root(url: URL, title: String) -> TreeNode {
            if let r = existing[url.path] { return r }
            return TreeNode(url: url, title: title,
                            icon: SidebarController.folderIcon(for: url),
                            isDirectory: true)
        }

        var roots: [TreeNode] = [root(url: home, title: NSUserName())]
        let volKeys: [URLResourceKey] = [.volumeNameKey, .volumeIsBrowsableKey]
        if let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: volKeys,
                                              options: [.skipHiddenVolumes]) {
            for v in volumes {
                guard let rv = try? v.resourceValues(forKeys: Set(volKeys)),
                      rv.volumeIsBrowsable == true else { continue }
                let name = v.path == "/" ? (rv.volumeName ?? "Macintosh HD")
                                         : (rv.volumeName ?? v.lastPathComponent)
                roots.append(root(url: v, title: name))
            }
        }
        treeRoots = roots
    }

    private func buildSections() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default
        func makeEntry(_ title: String, _ path: String, fallback: NSImage.Name) -> Entry? {
            let url = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: url.path) else { return nil }
            let icon: NSImage
            if !PermissionsManager.hasFullDiskAccess && PermissionsManager.isProtectedPath(url.path) {
                icon = NSWorkspace.shared.icon(for: .folder)
            } else {
                icon = NSWorkspace.shared.icon(forFile: url.path)
            }
            icon.size = NSSize(width: 16, height: 16)
            return Entry(title: title, url: url, icon: icon)
        }

        var favs: [Entry] = []
        let clock = NSImage(systemSymbolName: "clock", accessibilityDescription: nil) ?? NSImage()
        clock.size = NSSize(width: 16, height: 16)
        favs.append(Entry(title: "Recents", url: SidebarController.recentsURL, icon: clock))
        for (title, sub) in [
            ("Applications", "/Applications"),
            ("Desktop", home.appendingPathComponent("Desktop").path),
            ("Documents", home.appendingPathComponent("Documents").path),
            ("Downloads", home.appendingPathComponent("Downloads").path),
            ("Movies", home.appendingPathComponent("Movies").path),
            ("Music", home.appendingPathComponent("Music").path),
            ("Pictures", home.appendingPathComponent("Pictures").path),
            (NSUserName(), home.path),
        ] {
            if let e = makeEntry(title, sub, fallback: NSImage.folderName) {
                favs.append(e)
            }
        }
        // User-added bookmarks live at the bottom of Favorites.
        for url in SidebarBookmarks.all() where fm.fileExists(atPath: url.path) {
            let icon: NSImage
            if !PermissionsManager.hasFullDiskAccess && PermissionsManager.isProtectedPath(url.path) {
                icon = NSWorkspace.shared.icon(for: .folder)
            } else {
                icon = NSWorkspace.shared.icon(forFile: url.path)
            }
            icon.size = NSSize(width: 16, height: 16)
            let name = url.path == "/" ? "Macintosh HD" : url.lastPathComponent
            favs.append(Entry(title: name, url: url, icon: icon))
        }

        var locations: [Entry] = []
        let volKeys: [URLResourceKey] = [
            .volumeNameKey, .volumeIsLocalKey, .volumeIsBrowsableKey,
            .volumeIsRootFileSystemKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
            .volumeIsInternalKey
        ]
        if let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: volKeys, options: [.skipHiddenVolumes]) {
            for v in volumes {
                guard let rv = try? v.resourceValues(forKeys: Set(volKeys)) else { continue }
                guard rv.volumeIsBrowsable == true else { continue }
                // Surface: root FS, ejectable, removable, or any non-system "Volumes" mount.
                let isRoot = rv.volumeIsRootFileSystem == true
                let isUserMount = rv.volumeIsEjectable == true || rv.volumeIsRemovable == true
                    || (!isRoot && v.path.hasPrefix("/Volumes/") && rv.volumeIsInternal != true)
                guard isRoot || isUserMount else { continue }
                let name = rv.volumeName ?? v.lastPathComponent
                let icon: NSImage
                if !PermissionsManager.hasFullDiskAccess && PermissionsManager.isProtectedPath(v.path) {
                    icon = NSWorkspace.shared.icon(for: .folder)
                } else {
                    icon = NSWorkspace.shared.icon(forFile: v.path)
                }
                icon.size = NSSize(width: 16, height: 16)
                locations.append(Entry(title: name, url: v, icon: icon))
            }
        }
        // Saved searches (smart folders) — synthetic `/smart/<id>` entries.
        let gear = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) ?? NSImage()
        gear.size = NSSize(width: 14, height: 14)
        let smartItems = SmartFolders.all().map { f in
            Entry(title: f.name, url: SidebarController.smartFolderURL(id: f.id), icon: gear)
        }

        // Explorer-style folder tree: Home + mounted volumes, each expandable
        // into its subfolders on demand. Built last so it sits beneath the flat
        // shortcut sections.
        buildTreeRoots()
        let foldersSection = Section(title: SidebarController.foldersSectionTitle,
                                     items: [], treeRoots: treeRoots)

        applySections(base: [
            Section(title: "Favorites", items: favs),
            Section(title: "Locations", items: locations),
            Section(title: "Smart Folders", items: smartItems),
            foldersSection,
        ])

        // Populate Tags section asynchronously — Spotlight call.
        TagIndex.allTagSummaries { [weak self] summaries in
            guard let self else { return }
            let tagItems = summaries.map { s -> Entry in
                let img = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
                let tinted = img?.tinted(s.tag.color.nsColor) ?? img ?? NSImage()
                tinted.size = NSSize(width: 12, height: 12)
                let label = s.count > 0 ? "\(s.tag.name)  ·  \(s.count)" : s.tag.name
                return Entry(title: label, url: URL(fileURLWithPath: "/tag/\(s.tag.name)"),
                             icon: tinted)
            }
            // Cache the Tags section (nil when there are no tags) and re-derive the
            // ordered list. Its slot is fixed by canonicalRank, so it's correct no
            // matter whether this Spotlight load or the folder-tree build finished
            // first — and a later rebuild keeps Tags rather than flickering it out.
            self.tagsSection = tagItems.isEmpty ? nil : Section(title: "Tags", items: tagItems)
            let base = self.sections.filter { $0.title != "Tags" }
            self.applySections(base: base)
            self.outline.reloadData()
            for s in self.sections { self.outline.expandItem(s) }
        }
    }

    /// Returns true if this URL is the synthetic `/tag/<name>` URL produced
    /// by the Tags section.
    static let recentsURL = URL(fileURLWithPath: "/recents")
    static func isRecentsURL(_ url: URL) -> Bool { url.path == "/recents" }
    static func isTagURL(_ url: URL) -> Bool { url.path.hasPrefix("/tag/") }
    static func tagName(from url: URL) -> String? {
        guard url.path.hasPrefix("/tag/") else { return nil }
        return String(url.path.dropFirst("/tag/".count))
    }

    /// Synthetic `/smart/<id>` URL for a saved search (smart folder).
    static func smartFolderURL(id: String) -> URL { URL(fileURLWithPath: "/smart/\(id)") }
    static func isSmartFolderURL(_ url: URL) -> Bool { url.path.hasPrefix("/smart/") }
    static func smartFolderId(from url: URL) -> String? {
        guard url.path.hasPrefix("/smart/") else { return nil }
        return String(url.path.dropFirst("/smart/".count))
    }

    // MARK: NSOutlineViewDataSource autosave

    func outlineView(_ outlineView: NSOutlineView, persistentObjectForItem item: Any?) -> Any? {
        if let s = item as? Section { return "section:\(s.title)" }
        if let e = item as? Entry { return "entry:\(e.url.path)" }
        // Folder-tree expansion is intentionally NOT persisted: restoring it
        // would force a scan of every saved path on launch, against the lazy
        // design. Sections (incl. "Folders") still persist their expanded state.
        return nil
    }
    func outlineView(_ outlineView: NSOutlineView, itemForPersistentObject object: Any) -> Any? {
        guard let s = object as? String else { return nil }
        if s.hasPrefix("section:") {
            let title = String(s.dropFirst("section:".count))
            return sections.first { $0.title == title }
        }
        if s.hasPrefix("entry:") {
            let path = String(s.dropFirst("entry:".count))
            for sec in sections {
                if let e = sec.items.first(where: { $0.url.path == path }) { return e }
            }
        }
        return nil
    }

    // MARK: NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return sections.count }
        if let s = item as? Section { return s.childCount }
        // A tree folder: lazily scan its subdirectories the first time its count
        // is requested (i.e. when it's being expanded), then serve the cache.
        // NSOutlineView only asks this for items it's about to display, so
        // collapsed/deep folders are never scanned — that's the lazy guarantee.
        if let node = item as? TreeNode { return node.loadChildrenIfNeeded().count }
        return 0
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return sections.indices.contains(index) ? sections[index] : Section(title: "", items: [])
        }
        if let section = item as? Section {
            if let roots = section.treeRoots {
                return roots.indices.contains(index) ? roots[index]
                    : Section(title: "", items: [])
            }
            return section.items.indices.contains(index) ? section.items[index]
                : Section(title: "", items: [])
        }
        if let node = item as? TreeNode {
            let kids = node.loadChildrenIfNeeded()
            return kids.indices.contains(index) ? kids[index] : Section(title: "", items: [])
        }
        return Section(title: "", items: [])
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if item is Section { return true }
        // Report directories as expandable WITHOUT scanning, so the disclosure
        // triangle appears immediately. If an expanded folder turns out to have
        // no subfolders, NSOutlineView removes the triangle on its own.
        if let node = item as? TreeNode { return node.isDirectory }
        return false
    }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is Section
    }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        !(item is Section)
    }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        ThemedRowView()   // theme-accent selection pill (system theme → native)
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let url = navigableURL(forRow: outline.selectedRow) else { return }
        if selectedURL != url {
            onSelect?(url)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let s = item as? Section {
            let id = NSUserInterfaceItemIdentifier("header")
            let view = (outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
                let v = NSTableCellView()
                let tf = NSTextField(labelWithString: "")
                tf.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
                tf.textColor = .secondaryLabelColor
                tf.translatesAutoresizingMaskIntoConstraints = false
                v.addSubview(tf)
                v.textField = tf
                NSLayoutConstraint.activate([
                    tf.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                    tf.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 0),
                    tf.trailingAnchor.constraint(equalTo: v.trailingAnchor),
                ])
                v.identifier = id
                return v
            }()
            view.textField?.stringValue = s.title.uppercased()
            view.textField?.textColor = sidebarSecondaryColor
            return view
        }
        // Both flat shortcut Entries and folder-tree TreeNodes render the same
        // icon + label row; pull the pair out so they share the cell.
        let leaf: (icon: NSImage, title: String)?
        if let e = item as? Entry { leaf = (e.icon, e.title) }
        else if let n = item as? TreeNode { leaf = (n.icon, n.title) }
        else { leaf = nil }
        if let leaf {
            let id = NSUserInterfaceItemIdentifier("entry")
            let view = (outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
                let v = NSTableCellView()
                let img = NSImageView()
                img.translatesAutoresizingMaskIntoConstraints = false
                v.addSubview(img)
                v.imageView = img
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.lineBreakMode = .byTruncatingTail
                tf.font = NSFont.systemFont(ofSize: 13)
                v.addSubview(tf)
                v.textField = tf
                NSLayoutConstraint.activate([
                    img.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                    img.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 0),
                    img.widthAnchor.constraint(equalToConstant: 16),
                    img.heightAnchor.constraint(equalToConstant: 16),
                    tf.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 6),
                    tf.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                    tf.trailingAnchor.constraint(equalTo: v.trailingAnchor),
                ])
                v.identifier = id
                return v
            }()
            let cellIcon = leaf.icon
            if cellIcon.isTemplate {
                view.imageView?.image = cellIcon.tinted(sidebarPrimaryColor)
            } else {
                view.imageView?.image = cellIcon
            }
            view.textField?.stringValue = leaf.title
            view.textField?.textColor = sidebarPrimaryColor
            return view
        }
        return nil
    }

    /// Sidebar text colors: theme palette for custom themes, semantic for System.
    private var sidebarPrimaryColor: NSColor {
        let t = ThemeManager.shared.current
        return t.id == "system" ? .labelColor : t.labelPrimary
    }
    private var sidebarSecondaryColor: NSColor {
        let t = ThemeManager.shared.current
        return t.id == "system" ? .secondaryLabelColor : t.labelSecondary
    }
}
