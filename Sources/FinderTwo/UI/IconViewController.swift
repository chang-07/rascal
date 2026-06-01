import AppKit

/// Icon (grid) view — the Finder default view. Backed by NSCollectionView,
/// driven by the pane's current item list. Double-click opens; selection is
/// reported back so the pane can act on it.
final class IconViewController: NSViewController, NSCollectionViewDataSource,
                                NSCollectionViewDelegate, ThemeObserving {

    private(set) var items: [FileItem] = []
    var onOpen: ((FileItem) -> Void)?
    var onSelectionChange: (([FileItem]) -> Void)?
    /// Files were dropped: (urls, the folder item dropped onto or nil for the
    /// current directory, isCopy). The pane performs the transfer.
    var onDrop: (([URL], FileItem?, Bool) -> Void)?

    private let scroll = NSScrollView()
    private let collection = NSCollectionView()
    private static let itemId = NSUserInterfaceItemIdentifier("IconGridItem")

    override func loadView() {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 100, height: 88)
        layout.sectionInset = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 14
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.allowsEmptySelection = true
        collection.backgroundColors = [.clear]
        collection.register(IconGridItem.self, forItemWithIdentifier: IconViewController.itemId)
        // Drag files out to Finder/other apps, and accept drops into the folder
        // (or onto a subfolder item) — parity with the list view.
        collection.registerForDraggedTypes([.fileURL])
        collection.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        collection.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: true)

        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.focusRingType = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let host = NSView()
        host.wantsLayer = true
        host.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: host.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        self.view = host

        let dbl = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
        dbl.numberOfClicksRequired = 2
        dbl.delaysPrimaryMouseButtonEvents = false
        collection.addGestureRecognizer(dbl)

        applyTheme()
        subscribeToTheme(self)
    }

    func reload(_ items: [FileItem]) {
        self.items = items
        collection.reloadData()
    }

    // MARK: Keyboard navigation (vim j/k/gg/G + open)

    /// Move the single selection by `delta` items, clamped, scrolling to it.
    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let cur = collection.selectionIndexPaths.first?.item ?? (delta >= 0 ? -1 : items.count)
        select(index: max(0, min(items.count - 1, cur + delta)))
    }
    func selectFirst() { guard !items.isEmpty else { return }; select(index: 0) }
    func selectLast() { guard !items.isEmpty else { return }; select(index: items.count - 1) }

    /// Test hook: the currently-selected item(s).
    var testSelectedItems: [FileItem] {
        collection.selectionIndexPaths.compactMap { items.indices.contains($0.item) ? items[$0.item] : nil }
    }

    private func select(index: Int) {
        let ip = IndexPath(item: index, section: 0)
        collection.deselectAll(nil)
        collection.selectItems(at: [ip], scrollPosition: .nearestHorizontalEdge)
        reportSelection()
    }

    /// Open the focused (selected) item, if any.
    func openSelected() {
        if let ip = collection.selectionIndexPaths.first, items.indices.contains(ip.item) {
            onOpen?(items[ip.item])
        }
    }

    @objc func applyTheme() {
        let t = ThemeManager.shared.current
        let bg: NSColor = t.id == "system" ? .controlBackgroundColor : t.background
        scroll.backgroundColor = bg
        view.layer?.backgroundColor = bg.cgColor
    }

    @objc private func handleDoubleClick(_ g: NSClickGestureRecognizer) {
        let pt = g.location(in: collection)
        guard let ip = collection.indexPathForItem(at: pt), items.indices.contains(ip.item) else { return }
        onOpen?(items[ip.item])
    }

    // MARK: NSCollectionViewDataSource
    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt ip: IndexPath) -> NSCollectionViewItem {
        let item = cv.makeItem(withIdentifier: IconViewController.itemId, for: ip)
        if let grid = item as? IconGridItem, items.indices.contains(ip.item) {
            grid.configure(with: items[ip.item], labelColor: labelColor)
        }
        return item
    }

    private var labelColor: NSColor {
        let t = ThemeManager.shared.current
        return t.id == "system" ? .labelColor : t.labelPrimary
    }

    // MARK: NSCollectionViewDelegate
    func collectionView(_ cv: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { reportSelection() }
    func collectionView(_ cv: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { reportSelection() }

    // MARK: Drag & drop
    func collectionView(_ cv: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>,
                        with event: NSEvent) -> Bool { !indexPaths.isEmpty }

    func collectionView(_ cv: NSCollectionView, pasteboardWriterForItemAt ip: IndexPath) -> NSPasteboardWriting? {
        items.indices.contains(ip.item) ? (items[ip.item].url as NSURL) : nil
    }

    func collectionView(_ cv: NSCollectionView, validateDrop info: NSDraggingInfo,
                        proposedIndexPath ip: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        // Drop ON a folder item → into it; otherwise into the current directory.
        if proposedDropOperation.pointee == .on, items.indices.contains(ip.pointee.item),
           items[ip.pointee.item].isDirectory {
            return FileOps.dropIsCopy(info) ? .copy : .move
        }
        proposedDropOperation.pointee = .before   // "between items" → current dir
        return FileOps.dropIsCopy(info) ? .copy : .move
    }

    func collectionView(_ cv: NSCollectionView, acceptDrop info: NSDraggingInfo,
                        indexPath ip: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else { return false }
        let folder: FileItem? = (dropOperation == .on && items.indices.contains(ip.item)
                                 && items[ip.item].isDirectory) ? items[ip.item] : nil
        onDrop?(urls, folder, FileOps.dropIsCopy(info))
        return true
    }
    private func reportSelection() {
        let sel = collection.selectionIndexPaths.compactMap { items.indices.contains($0.item) ? items[$0.item] : nil }
        onSelectionChange?(sel)
    }
}

/// One icon-grid cell: a 48pt icon above a centered, two-line name label.
final class IconGridItem: NSCollectionViewItem {
    private let img = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        img.translatesAutoresizingMaskIntoConstraints = false
        img.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 2
        nameLabel.font = NSFont.systemFont(ofSize: 11)
        nameLabel.cell?.wraps = true
        nameLabel.drawsBackground = false
        nameLabel.isBordered = false
        v.addSubview(img)
        v.addSubview(nameLabel)
        NSLayoutConstraint.activate([
            img.topAnchor.constraint(equalTo: v.topAnchor, constant: 4),
            img.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            img.widthAnchor.constraint(equalToConstant: 48),
            img.heightAnchor.constraint(equalToConstant: 48),
            nameLabel.topAnchor.constraint(equalTo: img.bottomAnchor, constant: 3),
            nameLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -2),
        ])
        self.view = v
        self.imageView = img
        self.textField = nameLabel
    }

    func configure(with item: FileItem, labelColor: NSColor) {
        nameLabel.stringValue = item.name
        nameLabel.textColor = item.isHidden ? ThemeChrome.tertiary : labelColor
        img.image = IconCache.shared.icon(for: item)   // cached per-extension, not a LaunchServices hit per cell
    }

    override var isSelected: Bool {
        didSet { applySelection() }
    }
    private func applySelection() {
        view.layer?.cornerRadius = 6
        let t = ThemeManager.shared.current
        let sel = t.id == "system" ? ThemeManager.shared.effectiveAccent.withAlphaComponent(0.25)
                                    : t.selectionBackground
        view.layer?.backgroundColor = isSelected ? sel.cgColor : NSColor.clear.cgColor
    }
}
