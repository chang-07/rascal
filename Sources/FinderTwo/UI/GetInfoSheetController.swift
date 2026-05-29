import AppKit

/// Native "Get Info" window: icon, name, kind, size (folders computed async),
/// location, dates, owner, and POSIX permissions for one item. Replaces the old
/// AppleScript delegation to Finder.
final class GetInfoSheetController: NSWindowController {

    static func show(for url: URL, parent: NSWindow?) {
        let c = GetInfoSheetController(url: url)
        c.window?.center()
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        PresentedControllers.retain(c)
    }

    private let url: URL
    private let sizeLabel = NSTextField(labelWithString: "Calculating…")

    init(url: URL) {
        self.url = url
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 380),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "\(url.lastPathComponent) Info"
        win.minSize = NSSize(width: 300, height: 280)
        super.init(window: win)
        win.contentView = buildContent()
        computeSizeIfFolder()
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

        let header = NSStackView(views: [icon, name])
        header.orientation = .horizontal
        header.spacing = 10
        header.alignment = .centerY

        func valueField(_ s: String) -> NSTextField {
            let f = NSTextField(labelWithString: s)
            f.font = .systemFont(ofSize: 11)
            f.lineBreakMode = .byTruncatingMiddle
            f.isSelectable = true
            return f
        }
        func keyField(_ s: String) -> NSTextField {
            let f = NSTextField(labelWithString: s)
            f.font = .systemFont(ofSize: 11)
            f.alignment = .right
            f.textColor = .secondaryLabelColor
            return f
        }

        let kind = isDir ? "Folder" : (rv?.localizedTypeDescription
            ?? (url.pathExtension.isEmpty ? "Document" : url.pathExtension.uppercased() + " file"))
        let created = (rv?.creationDate).map { DateFormatterCache.string($0) } ?? "—"
        let modified = (rv?.contentModificationDate).map { DateFormatterCache.string($0) } ?? "—"
        let owner = (attrs?[.ownerAccountName] as? String) ?? "—"
        let perm = (attrs?[.posixPermissions] as? NSNumber).map { Self.permString($0.uint16Value) } ?? "—"
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
        grid.addRow(with: [keyField("Permissions:"), valueField(perm)])
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
