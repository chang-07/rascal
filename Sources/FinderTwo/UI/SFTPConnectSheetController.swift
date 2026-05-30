import AppKit

/// Sheet that prompts for SFTP connection info, tests the connection, and
/// either lists the remote folder or saves a bookmark.
final class SFTPConnectSheetController: NSWindowController, ThemeObserving {

    private weak var target: BrowserWindowController?
    private let userField = NSTextField()
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let pathField = NSTextField()
    private let status = NSTextField(labelWithString: "")

    static func show(for wc: BrowserWindowController) {
        guard let parent = wc.window else { return }
        let s = SFTPConnectSheetController(target: wc)
        guard let sheet = s.window else { return }
        PresentedControllers.retain(s)
        parent.beginSheet(sheet, completionHandler: { _ in })
    }

    init(target: BrowserWindowController) {
        self.target = target
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 280),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered, defer: false
        )
        win.title = "Connect to SFTP Server"
        super.init(window: win)
        ThemeChrome.apply(to: window)
        layout()
        subscribeToTheme(self)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func layout() {
        guard let cv = window?.contentView else { return }

        userField.placeholderString = "username"; userField.stringValue = NSUserName()
        hostField.placeholderString = "host.example.com"
        portField.placeholderString = "22"; portField.stringValue = "22"
        pathField.placeholderString = "/home/user (defaults to ~)"; pathField.stringValue = "~"
        for f in [userField, hostField, portField, pathField] {
            f.bezelStyle = .roundedBezel
            f.font = NSFont.systemFont(ofSize: 12)
        }

        func makeLabel(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.alignment = .right
            l.font = NSFont.systemFont(ofSize: 12)
            l.textColor = .secondaryLabelColor
            l.tag = 101
            return l
        }

        // NSGridView guarantees a clean, non-conflicting row/column layout.
        let grid = NSGridView(views: [
            [makeLabel("User:"), userField],
            [makeLabel("Host:"), hostField],
            [makeLabel("Port:"), portField],
            [makeLabel("Path:"), pathField],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 300

        status.font = NSFont.systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.tag = 101
        status.lineBreakMode = .byTruncatingTail
        status.translatesAutoresizingMaskIntoConstraints = false

        let testBtn = NSButton(title: "Test", target: self, action: #selector(testConnection))
        let saveBtn = NSButton(title: "Save Bookmark", target: self, action: #selector(saveBookmark))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(closeSheet))
        let connect = NSButton(title: "Connect", target: self, action: #selector(connect))
        connect.keyEquivalent = "\r"
        cancel.keyEquivalent = "\u{1b}"

        let buttonRow = NSStackView(views: [testBtn, saveBtn, cancel, connect])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        for b in [testBtn, saveBtn, cancel, connect] { b.bezelStyle = .rounded }

        cv.addSubview(grid)
        cv.addSubview(status)
        cv.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: cv.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),

            status.topAnchor.constraint(greaterThanOrEqualTo: grid.bottomAnchor, constant: 12),
            status.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            status.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),

            buttonRow.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 10),
            buttonRow.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            buttonRow.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -20),
        ])
    }

    private func currentConnection() -> SFTPClient.Connection {
        let port = Int(portField.stringValue) ?? 22
        return SFTPClient.Connection(user: userField.stringValue.trimmingCharacters(in: .whitespaces),
                                     host: hostField.stringValue.trimmingCharacters(in: .whitespaces),
                                     port: port,
                                     remotePath: pathField.stringValue.trimmingCharacters(in: .whitespaces))
    }

    @objc private func testConnection() {
        let c = currentConnection()
        guard !c.host.isEmpty, !c.user.isEmpty else {
            status.stringValue = "user + host required"; return
        }
        status.stringValue = "Testing…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let err = SFTPClient.ping(c)
            DispatchQueue.main.async {
                self?.status.stringValue = err ?? "✓ Connection successful"
                self?.status.textColor = err == nil ? .systemGreen : .systemRed
            }
        }
    }

    @objc private func saveBookmark() {
        let c = currentConnection()
        guard !c.host.isEmpty, !c.user.isEmpty else { return }
        SFTPBookmarks.add(c)
        status.stringValue = "Saved to sidebar"
    }

    @objc private func connect() {
        let c = currentConnection()
        guard !c.host.isEmpty, !c.user.isEmpty else {
            status.stringValue = "user + host required"; return
        }
        guard let wc = target else { closeSheet(); return }
        SFTPBookmarks.add(c)
        closeSheet()
        SFTPBrowserController.show(for: wc, connection: c)
    }

    @objc private func closeSheet() {
        if let w = window, let parent = w.sheetParent { parent.endSheet(w) }
        else { window?.close() }
    }

    @objc func applyTheme() {
        ThemeChrome.apply(to: window)
        if let cv = window?.contentView {
            ThemeChrome.updateColors(in: cv)
        }
    }
}

/// Simple read-only SFTP browser — shows entries at a remote path with
/// up-button and a download action.
final class SFTPBrowserController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, ThemeObserving {

    private let connection: SFTPClient.Connection
    private var path: String
    private var entries: [SFTPClient.Entry] = []
    private weak var target: BrowserWindowController?
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private let pathLabel = NSTextField(labelWithString: "")

    static func show(for wc: BrowserWindowController, connection: SFTPClient.Connection) {
        let c = SFTPBrowserController(target: wc, connection: connection)
        PresentedControllers.retain(c)
        c.window?.center()
        c.window?.makeKeyAndOrderFront(nil)
        c.reload()
    }

    init(target: BrowserWindowController, connection: SFTPClient.Connection) {
        self.connection = connection
        self.path = connection.remotePath.isEmpty ? "." : connection.remotePath
        self.target = target
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .resizable, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        win.title = "SFTP — \(connection.sshTarget)"
        super.init(window: win)
        ThemeChrome.apply(to: window)
        layout()
        subscribeToTheme(self)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func layout() {
        guard let cv = window?.contentView else { return }
        let up = NSButton(title: "Up", target: self, action: #selector(goUp))
        up.bezelStyle = .rounded
        up.translatesAutoresizingMaskIntoConstraints = false

        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = NSFont.systemFont(ofSize: 12)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.tag = 101
        pathLabel.lineBreakMode = .byTruncatingMiddle

        let download = NSButton(title: "Download…", target: self, action: #selector(downloadSelected))
        download.bezelStyle = .rounded
        download.translatesAutoresizingMaskIntoConstraints = false

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        table.style = .inset
        table.rowHeight = 22
        table.headerView = NSTableHeaderView()
        let c1 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        c1.title = "Name"; c1.width = 340
        let c2 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        c2.title = "Size"; c2.width = 100
        for c in [c1, c2] { table.addTableColumn(c) }
        table.dataSource = self; table.delegate = self
        table.target = self
        table.doubleAction = #selector(activate)
        scroll.documentView = table

        for v in [up, pathLabel, download, scroll] { cv.addSubview(v) }
        NSLayoutConstraint.activate([
            up.topAnchor.constraint(equalTo: cv.topAnchor, constant: 14),
            up.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 14),
            pathLabel.centerYAnchor.constraint(equalTo: up.centerYAnchor),
            pathLabel.leadingAnchor.constraint(equalTo: up.trailingAnchor, constant: 10),
            pathLabel.trailingAnchor.constraint(equalTo: download.leadingAnchor, constant: -10),
            download.centerYAnchor.constraint(equalTo: up.centerYAnchor),
            download.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: up.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -14),
        ])
    }

    private func reload() {
        pathLabel.stringValue = "Loading…"
        let p = path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let list = SFTPClient.list(self.connection, path: p)
            DispatchQueue.main.async {
                self.entries = list
                self.pathLabel.stringValue = "\(self.connection.sshTarget):\(p)"
                self.table.reloadData()
            }
        }
    }

    @objc private func goUp() {
        path = (path as NSString).deletingLastPathComponent.ifEmpty(or: "/")
        reload()
    }

    @objc private func activate() {
        let row = table.clickedRow
        guard entries.indices.contains(row) else { return }
        let e = entries[row]
        if e.isDirectory {
            path = (path as NSString).appendingPathComponent(e.name)
            reload()
        } else {
            downloadSelected()
        }
    }

    @objc private func downloadSelected() {
        guard let row = table.selectedRowIndexes.first ?? (table.selectedRow >= 0 ? table.selectedRow : nil),
              entries.indices.contains(row) else { NSSound.beep(); return }
        let entry = entries[row]
        guard !entry.isDirectory else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        panel.beginSheetModal(for: window!) { [weak self] resp in
            guard resp == .OK, let self, let url = panel.url else { return }
            // Capture the connection/paths as values and self weakly, so closing
            // the SFTP browser mid-transfer can't extend its lifetime (self is
            // not retained during the blocking download).
            let remote = (self.path as NSString).appendingPathComponent(entry.name)
            let connection = self.connection
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let ok = SFTPClient.download(connection, remotePath: remote, to: url)
                DispatchQueue.main.async {
                    guard ok else { NSSound.beep(); return }
                    self?.target?.testActivePane?.navigate(to: url.deletingLastPathComponent())
                    DispatchQueue.main.async { self?.target?.testActivePane?.select(url: url) }
                }
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = entries[row]
        let id = tableColumn?.identifier.rawValue ?? ""
        let cellId = NSUserInterfaceItemIdentifier("S-\(id)")
        let cell = (tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTableCellView) ?? {
            let v = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingMiddle
            tf.font = NSFont.systemFont(ofSize: 12)
            v.addSubview(tf); v.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            ])
            v.identifier = cellId
            return v
        }()
        switch id {
        case "name":
            cell.textField?.stringValue = (e.isDirectory ? "📁 " : "") + e.name
            cell.textField?.textColor = ThemeChrome.primary
        case "size":
            cell.textField?.stringValue = e.isDirectory ? "" : SizeFormatter.string(e.size)
            cell.textField?.textColor = ThemeChrome.secondary
        default: break
        }
        return cell
    }

    @objc func applyTheme() {
        ThemeChrome.apply(to: window)
        if let cv = window?.contentView {
            ThemeChrome.updateColors(in: cv)
        }
        let t = ThemeManager.shared.current
        let custom = t.id != "system"
        let bg = custom ? t.background : .controlBackgroundColor
        table.backgroundColor = bg
        scroll.drawsBackground = true
        scroll.backgroundColor = bg
        table.reloadData()
    }
}

private extension String {
    func ifEmpty(or fallback: String) -> String { isEmpty ? fallback : self }
}
