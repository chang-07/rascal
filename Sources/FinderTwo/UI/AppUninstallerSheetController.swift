import AppKit

/// Confirmation sheet for uninstalling a .app: shows the app + every leftover
/// found in ~/Library, with sizes. User can uncheck items they want to keep.
final class AppUninstallerSheetController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    private let appURL: URL
    private weak var target: BrowserWindowController?
    private var leftovers: [AppUninstaller.Leftover] = []
    private var checked: [Bool] = []
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let summary = NSTextField(labelWithString: "")

    static func show(for wc: BrowserWindowController, appURL: URL) {
        guard let parent = wc.window else { return }
        let c = AppUninstallerSheetController(appURL: appURL, target: wc)
        guard let sheet = c.window else { return }
        PresentedControllers.retain(c)
        parent.beginSheet(sheet, completionHandler: { _ in })
    }

    init(appURL: URL, target: BrowserWindowController) {
        self.appURL = appURL
        self.target = target
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered, defer: false
        )
        win.title = "Uninstall \(appURL.lastPathComponent)"
        super.init(window: win)
        ThemeChrome.apply(to: window)
        layout()
        scan()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func layout() {
        guard let cv = window?.contentView else { return }

        let header = NSTextField(labelWithString:
            "Move \(appURL.lastPathComponent) and its supporting files to Trash. " +
            "Uncheck anything you want to keep.")
        header.font = NSFont.systemFont(ofSize: 12)
        header.textColor = .secondaryLabelColor
        header.translatesAutoresizingMaskIntoConstraints = false
        header.lineBreakMode = .byWordWrapping
        header.maximumNumberOfLines = 2

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        table.style = .inset
        table.rowHeight = 22
        table.headerView = NSTableHeaderView()
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self

        let c1 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("on"))
        c1.title = ""
        c1.width = 22
        let c2 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("kind"))
        c2.title = "Kind"
        c2.width = 140
        let c3 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        c3.title = "Path"
        c3.width = 360
        let c4 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        c4.title = "Size"
        c4.width = 80
        for c in [c1, c2, c3, c4] { table.addTableColumn(c) }
        scroll.documentView = table

        summary.translatesAutoresizingMaskIntoConstraints = false
        summary.font = NSFont.systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(closeSheet))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.translatesAutoresizingMaskIntoConstraints = false
        let trash = NSButton(title: "Move All to Trash", target: self, action: #selector(performUninstall))
        trash.bezelStyle = .rounded
        trash.keyEquivalent = "\r"
        trash.translatesAutoresizingMaskIntoConstraints = false

        for v in [header, scroll, summary, cancel, trash] { cv.addSubview(v) }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: cv.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: summary.topAnchor, constant: -10),
            summary.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 14),
            summary.bottomAnchor.constraint(equalTo: trash.topAnchor, constant: -8),
            trash.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -14),
            trash.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -14),
            cancel.trailingAnchor.constraint(equalTo: trash.leadingAnchor, constant: -8),
            cancel.centerYAnchor.constraint(equalTo: trash.centerYAnchor),
        ])
    }

    private func scan() {
        let appBid = AppUninstaller.bundleId(for: appURL) ?? ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = appBid.isEmpty ? [] : AppUninstaller.scanLeftovers(bundleId: appBid)
            DispatchQueue.main.async {
                self?.leftovers = found
                self?.checked = Array(repeating: true, count: found.count)
                self?.refreshSummary()
                self?.table.reloadData()
            }
        }
    }

    private func refreshSummary() {
        let bytes = zip(leftovers, checked).reduce(Int64(0)) { acc, pair in
            acc + (pair.1 ? pair.0.size : 0)
        }
        summary.stringValue = "\(checked.filter { $0 }.count) supporting items · \(SizeFormatter.string(bytes)) reclaimable + the .app itself"
    }

    @objc private func performUninstall() {
        let selected = zip(leftovers, checked).compactMap { (l, on) in on ? l : nil }
        let ok = AppUninstaller.uninstall(app: appURL, leftovers: selected)
        if !ok { NSSound.beep() }
        target?.testActivePane?.reload()
        closeSheet()
    }

    @objc private func closeSheet() {
        if let w = window, let parent = w.sheetParent {
            parent.endSheet(w)
        } else {
            window?.close()
        }
    }

    // MARK: NSTableViewDataSource
    func numberOfRows(in tableView: NSTableView) -> Int { leftovers.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let l = leftovers[row]
        let id = tableColumn?.identifier.rawValue ?? ""
        let cellId = NSUserInterfaceItemIdentifier("AUcell-\(id)")
        switch id {
        case "on":
            let cell = (tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTableCellView) ?? {
                let v = NSTableCellView()
                let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle(_:)))
                box.translatesAutoresizingMaskIntoConstraints = false
                v.addSubview(box)
                NSLayoutConstraint.activate([
                    box.centerXAnchor.constraint(equalTo: v.centerXAnchor),
                    box.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                ])
                v.identifier = cellId
                return v
            }()
            if let box = cell.subviews.compactMap({ $0 as? NSButton }).first {
                box.state = checked[row] ? .on : .off
                box.tag = row
            }
            return cell
        case "kind":
            return textCell(text: l.kind, color: .secondaryLabelColor, id: cellId, in: tableView)
        case "name":
            return textCell(text: l.url.path, color: .labelColor, id: cellId, in: tableView)
        case "size":
            return textCell(text: SizeFormatter.string(l.size),
                            color: .secondaryLabelColor, id: cellId, in: tableView, alignment: .right)
        default: return nil
        }
    }

    @objc private func toggle(_ sender: NSButton) {
        let row = sender.tag
        if checked.indices.contains(row) {
            checked[row].toggle()
            refreshSummary()
        }
    }

    private func textCell(text: String, color: NSColor, id: NSUserInterfaceItemIdentifier,
                          in tv: NSTableView, alignment: NSTextAlignment = .left) -> NSView {
        let cell = (tv.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let v = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.font = NSFont.systemFont(ofSize: 12)
            tf.lineBreakMode = .byTruncatingMiddle
            v.addSubview(tf); v.textField = tf
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
        return cell
    }
}
