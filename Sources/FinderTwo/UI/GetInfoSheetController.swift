import AppKit

/// Native "Get Info" window: icon, name, kind, size (folders computed async),
/// location, dates, owner, and POSIX permissions for one item. Replaces the old
/// AppleScript delegation to Finder.
final class GetInfoSheetController: NSWindowController, ThemeObserving {

    static func show(for url: URL, parent: NSWindow?) {
        let c = GetInfoSheetController(url: url)
        c.window?.center()
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        PresentedControllers.retain(c)
    }

    private let url: URL
    private let sizeLabel: NSTextField = {
        let f = NSTextField(labelWithString: "Calculating…")
        f.tag = 100
        return f
    }()
    /// 9 permission checkboxes in order: owner r,w,x · group r,w,x · other r,w,x.
    private var permBoxes: [NSButton] = []

    init(url: URL) {
        self.url = url
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 380),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "\(url.lastPathComponent) Info"
        win.minSize = NSSize(width: 300, height: 280)
        super.init(window: win)
        ThemeChrome.apply(to: window)
        win.contentView = buildContent()
        computeSizeIfFolder()
        subscribeToTheme(self)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildContent() -> NSView {
        let fm = FileManager.default
        let rv = try? url.resourceValues(forKeys: [
            .localizedTypeDescriptionKey, .fileSizeKey, .creationDateKey,
            .contentModificationDateKey, .isDirectoryKey])
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let isDir = rv?.isDirectory == true
        if !isDir { sizeLabel.stringValue = SizeFormatter.string(Int64(rv?.fileSize ?? 0)) }

        let icon = NSImageView()
        icon.image = NSWorkspace.shared.icon(forFile: url.path)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 48).isActive = true

        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.font = .boldSystemFont(ofSize: 14)
        name.lineBreakMode = .byTruncatingMiddle
        name.isSelectable = true
        name.tag = 100
 
        let header = NSStackView(views: [icon, name])
        header.orientation = .horizontal
        header.spacing = 10
        header.alignment = .centerY

        func valueField(_ s: String) -> NSTextField {
            let f = NSTextField(labelWithString: s)
            f.font = .systemFont(ofSize: 11)
            f.lineBreakMode = .byTruncatingMiddle
            f.isSelectable = true
            f.tag = 100
            return f
        }
        func keyField(_ s: String) -> NSTextField {
            let f = NSTextField(labelWithString: s)
            f.font = .systemFont(ofSize: 11)
            f.alignment = .right
            f.textColor = .secondaryLabelColor
            f.tag = 101
            return f
        }

        let kind = isDir ? "Folder" : (rv?.localizedTypeDescription
            ?? (url.pathExtension.isEmpty ? "Document" : url.pathExtension.uppercased() + " file"))
        let created = (rv?.creationDate).map { DateFormatterCache.string($0) } ?? "—"
        let modified = (rv?.contentModificationDate).map { DateFormatterCache.string($0) } ?? "—"
        let owner = (attrs?[.ownerAccountName] as? String) ?? "—"
        let group = (attrs?[.groupOwnerAccountName] as? String) ?? "—"
        let mode = (attrs?[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        originalSpecialBits = mode & 0o7000   // keep setuid/setgid/sticky when editing the 9 perm bits
        let whereStr = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath

        let grid = NSGridView()
        grid.rowSpacing = 6
        grid.columnSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.addRow(with: [keyField("Kind:"), valueField(kind)])
        grid.addRow(with: [keyField("Size:"), sizeLabel])
        grid.addRow(with: [keyField("Where:"), valueField(whereStr)])
        grid.addRow(with: [keyField("Created:"), valueField(created)])
        grid.addRow(with: [keyField("Modified:"), valueField(modified)])
        grid.addRow(with: [keyField("Owner:"), valueField(owner)])
        grid.addRow(with: [keyField("Group:"), valueField(group)])
        grid.addRow(with: [keyField("Permissions:"), permEditorView(mode: mode)])
        grid.addRow(with: [keyField("Path:"), valueField(url.path)])

        let root = NSStackView(views: [header, NSBox.divider, grid])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])
        return container
    }

    private func computeSizeIfFolder() {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let bytes = FileListController.recursiveSize(self.url)
            DispatchQueue.main.async { self.sizeLabel.stringValue = SizeFormatter.string(bytes) }
        }
    }

    /// "rwxr-xr-x" from a POSIX mode.
    static func permString(_ mode: UInt16) -> String {
        let parts = ["---", "--x", "-w-", "-wx", "r--", "r-x", "rw-", "rwx"]
        return parts[Int((mode >> 6) & 7)] + parts[Int((mode >> 3) & 7)] + parts[Int(mode & 7)]
    }

    // MARK: Editable permissions

    /// A 3×3 grid of checkboxes (Owner / Group / Everyone × Read / Write / Exec).
    /// Toggling any box re-chmods the item and re-reads the on-disk mode so the
    /// UI stays truthful even if the change is rejected (e.g. not the owner).
    private func permEditorView(mode: UInt16) -> NSView {
        let scopes = ["Owner", "Group", "Everyone"]
        let cols = ["R", "W", "X"]
        let g = NSGridView()
        g.rowSpacing = 2; g.columnSpacing = 6
        g.translatesAutoresizingMaskIntoConstraints = false
        // header
        var header: [NSView] = [NSGridCell.emptyContentView]
        for c in cols {
            let l = NSTextField(labelWithString: c)
            l.font = .systemFont(ofSize: 9); l.textColor = .tertiaryLabelColor; l.alignment = .center
            l.tag = 102
            header.append(l)
        }
        g.addRow(with: header)
        permBoxes.removeAll()
        for (si, scope) in scopes.enumerated() {
            let l = NSTextField(labelWithString: scope)
            l.font = .systemFont(ofSize: 10); l.textColor = .secondaryLabelColor; l.alignment = .right
            l.tag = 101
            var row: [NSView] = [l]
            for bit in 0..<3 {
                let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(permsChanged))
                let shift = UInt16((2 - si) * 3 + (2 - bit))   // owner=bits6-8, R is high bit
                box.state = (mode >> shift) & 1 == 1 ? .on : .off
                box.tag = Int(shift)
                permBoxes.append(box)
                row.append(box)
            }
            g.addRow(with: row)
        }
        return g
    }

    private var originalSpecialBits: UInt16 = 0   // setuid/setgid/sticky, preserved across edits

    private func currentMode() -> UInt16 {
        var m: UInt16 = 0
        for box in permBoxes where box.state == .on { m |= (1 << UInt16(box.tag)) }
        return m
    }

    // Test hooks (headless): inspect/drive the permission editor without UI.
    var testPermBoxCount: Int { permBoxes.count }
    var testCurrentMode: UInt16 { currentMode() }
    func testApplyMode(_ m: UInt16) {
        for box in permBoxes { box.state = (m >> UInt16(box.tag)) & 1 == 1 ? .on : .off }
        permsChanged()
    }

    @objc private func permsChanged() {
        let m = currentMode() | originalSpecialBits   // don't drop setuid/setgid/sticky
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: m)], ofItemAtPath: url.path)
        // Re-read truth and resync (a rejected chmod leaves the old mode).
        let actual = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]
            as? NSNumber)?.uint16Value ?? m
        if actual != m { NSSound.beep() }
        for box in permBoxes { box.state = (actual >> UInt16(box.tag)) & 1 == 1 ? .on : .off }
    }

    @objc func applyTheme() {
        ThemeChrome.apply(to: window)
        if let cv = window?.contentView {
            ThemeChrome.updateColors(in: cv)
        }
    }
}

private extension NSBox {
    /// A thin horizontal separator for stack views.
    static var divider: NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        return b
    }
}
