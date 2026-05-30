import AppKit

final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, ThemeObserving, NSMenuDelegate {

    var onSelect: ((URL) -> Void)?
    var onOpenInNewTab: ((URL) -> Void)?
    var onOpenInNewWindow: ((URL) -> Void)?

    private let outline = NSOutlineView()
    private let scrollView = NSScrollView()

    private final class Section {
        let title: String
        var items: [Entry]
        init(title: String, items: [Entry]) { self.title = title; self.items = items }
    }
    private final class Entry {
        let title: String
        let url: URL
        let icon: NSImage
        init(title: String, url: URL, icon: NSImage) {
            self.title = title; self.url = url; self.icon = icon
        }
    }

    private var sections: [Section] = []
    private var selectedURL: URL?

    var testEntryTitles: [String] {
        sections.flatMap { $0.items.map { $0.title } }
    }

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
        outline.backgroundColor = .clear
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
    }

    @objc private func bookmarksChanged() {
        buildSections()
        outline.reloadData()
        for s in sections { outline.expandItem(s) }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Context menu (built per right-click for the clicked row)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        guard row >= 0, let entry = outline.item(atRow: row) as? Entry,
              !SidebarController.isTagURL(entry.url) else { return }
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
        for s in sections {
            if let e = s.items.first(where: { $0.url == url }) {
                let row = outline.row(forItem: e)
                if row >= 0 {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    return
                }
            }
        }
        outline.deselectAll(nil)
    }

    @objc private func handleClick() {
        let row = outline.selectedRow
        guard row >= 0, let entry = outline.item(atRow: row) as? Entry else { return }
        onSelect?(entry.url)
    }

    private func buildSections() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default
        func makeEntry(_ title: String, _ path: String, fallback: NSImage.Name) -> Entry? {
            let url = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: url.path) else { return nil }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
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
            let icon = NSWorkspace.shared.icon(forFile: url.path)
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
                let icon = NSWorkspace.shared.icon(forFile: v.path)
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

        sections = [
            Section(title: "Favorites", items: favs),
            Section(title: "Locations", items: locations),
            Section(title: "Smart Folders", items: smartItems),
        ].filter { !$0.items.isEmpty }

        // Populate Tags section asynchronously — Spotlight call.
        TagIndex.allTagSummaries { [weak self] summaries in
            guard let self else { return }
            guard !summaries.isEmpty else { return }
            let tagItems = summaries.map { s -> Entry in
                let img = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
                let tinted = img?.tinted(s.tag.color.nsColor) ?? img ?? NSImage()
                tinted.size = NSSize(width: 12, height: 12)
                let label = s.count > 0 ? "\(s.tag.name)  ·  \(s.count)" : s.tag.name
                return Entry(title: label, url: URL(fileURLWithPath: "/tag/\(s.tag.name)"),
                             icon: tinted)
            }
            self.sections.append(Section(title: "Tags", items: tagItems))
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
        if let s = item as? Section { return s.items.count }
        return 0
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return sections.indices.contains(index) ? sections[index] : Section(title: "", items: [])
        }
        guard let section = item as? Section, section.items.indices.contains(index) else {
            return Section(title: "", items: [])
        }
        return section.items[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is Section
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
        let row = outline.selectedRow
        guard row >= 0, let entry = outline.item(atRow: row) as? Entry else { return }
        if selectedURL != entry.url {
            onSelect?(entry.url)
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
        if let e = item as? Entry {
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
            let cellIcon = e.icon
            if cellIcon.isTemplate {
                view.imageView?.image = cellIcon.tinted(sidebarPrimaryColor)
            } else {
                view.imageView?.image = cellIcon
            }
            view.textField?.stringValue = e.title
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
