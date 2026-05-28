import AppKit

final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {

    var onSelect: ((URL) -> Void)?

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

    override func loadView() {
        // Use a sidebar-style NSVisualEffectView so the sidebar gets the
        // standard macOS sidebar translucency in System / Sepia themes.
        let v = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: v.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        self.view = v

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        col.title = ""
        col.resizingMask = [.autoresizingMask]
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .sourceList
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
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.rowHeight = 22

        buildSections()
        outline.reloadData()
        for s in sections { outline.expandItem(s) }
    }

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
        sections = [
            Section(title: "Favorites", items: favs),
            Section(title: "Locations", items: locations),
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
    static func isTagURL(_ url: URL) -> Bool { url.path.hasPrefix("/tag/") }
    static func tagName(from url: URL) -> String? {
        guard url.path.hasPrefix("/tag/") else { return nil }
        return String(url.path.dropFirst("/tag/".count))
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
            view.imageView?.image = e.icon
            view.textField?.stringValue = e.title
            return view
        }
        return nil
    }
}
