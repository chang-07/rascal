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
    private let savedPopup = NSPopUpButton()
    private let spinner = NSProgressIndicator()
    private let testBtn = NSButton()
    private let connectBtn = NSButton()
    /// Backing list for `savedPopup` (index 0 is the "New connection…" item).
    private var saved: [SFTPClient.Connection] = []
    private let removeBtn = NSButton()
    /// Shared width for every leading label, so "Saved:" lines up with the
    /// User/Host/Port/Path column.
    private static let labelColumnWidth: CGFloat = 52

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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 430),
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
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        // Pin the label column to a fixed narrow width and let the FIELD column
        // absorb the slack. Previously column 1 was fixed at 300 while the grid
        // stretched, so all the extra width piled into the label column and
        // pushed the whole form off to the right.
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = Self.labelColumnWidth
        grid.column(at: 1).xPlacement = .fill

        status.font = NSFont.systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.tag = 101
        status.lineBreakMode = .byTruncatingTail
        status.translatesAutoresizingMaskIntoConstraints = false

        // ---- Header: icon + title + one line explaining what this does ----
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)
        iconView.symbolConfiguration = .init(pointSize: 26, weight: .regular)
        iconView.contentTintColor = .controlAccentColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: "Connect to Server")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.tag = 101
        let blurb = NSTextField(labelWithString:
            "Browse a remote machine over SFTP. Uses your existing SSH keys and agent — no password is stored.")
        blurb.font = .systemFont(ofSize: 11)
        blurb.textColor = .secondaryLabelColor
        blurb.tag = 101
        blurb.lineBreakMode = .byWordWrapping
        blurb.maximumNumberOfLines = 2
        let headingStack = NSStackView(views: [heading, blurb])
        headingStack.orientation = .vertical
        headingStack.alignment = .leading
        headingStack.spacing = 2
        let header = NSStackView(views: [iconView, headingStack])
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false

        // ---- Saved servers: bookmarks were being stored but never surfaced ----
        savedPopup.target = self
        savedPopup.action = #selector(savedServerChanged)
        savedPopup.translatesAutoresizingMaskIntoConstraints = false
        removeBtn.title = "Remove"
        removeBtn.bezelStyle = .rounded
        removeBtn.controlSize = .small
        removeBtn.target = self
        removeBtn.action = #selector(removeSavedServer)
        let savedLabel = makeLabel("Saved:")
        let savedRow = NSStackView(views: [savedLabel, savedPopup, removeBtn])
        savedRow.orientation = .horizontal
        savedRow.spacing = 8
        savedRow.translatesAutoresizingMaskIntoConstraints = false
        reloadSavedServers()

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        // One-liner on how to actually connect — the fields alone don't say what
        // has to be true on the other machine.
        let hint = NSTextField(labelWithString:
            "Use the same user@host you'd type with ssh. The remote Mac needs Remote Login on "
            + "(System Settings → General → Sharing), and your key in its ~/.ssh/authorized_keys.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.tag = 101
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 3
        hint.translatesAutoresizingMaskIntoConstraints = false

        let statusRow = NSStackView(views: [spinner, status])
        statusRow.orientation = .horizontal
        statusRow.spacing = 6
        statusRow.translatesAutoresizingMaskIntoConstraints = false

        testBtn.title = "Test"
        testBtn.target = self; testBtn.action = #selector(testConnection)
        let saveBtn = NSButton(title: "Save", target: self, action: #selector(saveBookmark))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(closeSheet))
        connectBtn.title = "Connect"
        connectBtn.target = self; connectBtn.action = #selector(connect)
        connectBtn.keyEquivalent = "\r"
        cancel.keyEquivalent = "\u{1b}"

        let buttonRow = NSStackView(views: [testBtn, saveBtn, cancel, connectBtn])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        for b in [testBtn, saveBtn, cancel, connectBtn] { b.bezelStyle = .rounded }

        for v in [header, savedRow, separator, grid, hint, statusRow, buttonRow] { cv.addSubview(v) }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: cv.topAnchor, constant: 20),
            header.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            iconView.widthAnchor.constraint(equalToConstant: 32),

            savedRow.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            savedRow.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            savedRow.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            savedLabel.widthAnchor.constraint(equalToConstant: Self.labelColumnWidth),

            separator.topAnchor.constraint(equalTo: savedRow.bottomAnchor, constant: 14),
            separator.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            separator.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),

            grid.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 14),
            grid.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),

            hint.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 14),
            hint.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),

            statusRow.topAnchor.constraint(greaterThanOrEqualTo: hint.bottomAnchor, constant: 12),
            statusRow.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            statusRow.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -20),

            buttonRow.topAnchor.constraint(equalTo: statusRow.bottomAnchor, constant: 12),
            buttonRow.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            buttonRow.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -20),
        ])
    }

    /// Rebuild the saved-servers menu from `SFTPBookmarks`.
    private func reloadSavedServers() {
        saved = SFTPBookmarks.all()
        savedPopup.removeAllItems()
        savedPopup.addItem(withTitle: saved.isEmpty ? "No saved servers" : "New connection…")
        for c in saved {
            savedPopup.addItem(withTitle: c.displayName)
        }
        savedPopup.isEnabled = !saved.isEmpty
        savedPopup.selectItem(at: 0)
        removeBtn.isEnabled = false        // nothing selected but the placeholder
    }

    /// Delete the selected bookmark. `SFTPBookmarks.remove` already existed but
    /// nothing ever called it, so a mistyped host stayed in the list forever.
    @objc private func removeSavedServer() {
        let index = savedPopup.indexOfSelectedItem - 1
        guard saved.indices.contains(index) else { NSSound.beep(); return }
        let c = saved[index]
        SFTPBookmarks.remove(user: c.user, host: c.host, port: c.port)
        reloadSavedServers()
        status.stringValue = "Removed “\(c.sshTarget)”"
        status.textColor = .secondaryLabelColor
    }

    /// Fill the fields in from the chosen bookmark.
    @objc private func savedServerChanged() {
        let index = savedPopup.indexOfSelectedItem - 1     // 0 is the placeholder
        removeBtn.isEnabled = saved.indices.contains(index)
        guard saved.indices.contains(index) else { return }
        let c = saved[index]
        userField.stringValue = c.user
        hostField.stringValue = c.host
        portField.stringValue = "\(c.port)"
        pathField.stringValue = c.remotePath.isEmpty ? "~" : c.remotePath
        status.stringValue = ""
    }

    /// Show/hide the spinner and lock the action buttons during a round trip, so
    /// it's obvious the app is working rather than wedged.
    private func setBusy(_ busy: Bool, _ message: String = "") {
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        testBtn.isEnabled = !busy
        connectBtn.isEnabled = !busy
        if !message.isEmpty {
            status.stringValue = message
            status.textColor = .secondaryLabelColor
        }
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
        setBusy(true, "Testing \(c.sshTarget)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let err = SFTPClient.ping(c)
            DispatchQueue.main.async {
                guard let self else { return }
                self.setBusy(false)
                self.status.stringValue = err ?? "✓ Connected to \(c.sshTarget)"
                self.status.textColor = err == nil ? .systemGreen : .systemRed
            }
        }
    }

    @objc private func saveBookmark() {
        let c = currentConnection()
        guard !c.host.isEmpty, !c.user.isEmpty else { NSSound.beep(); return }
        SFTPBookmarks.add(c)
        reloadSavedServers()
        status.stringValue = "Saved “\(c.sshTarget)”"
        status.textColor = .secondaryLabelColor
    }

    @objc private func connect() {
        let c = currentConnection()
        guard !c.host.isEmpty, !c.user.isEmpty else {
            status.stringValue = "user + host required"; return
        }
        guard let wc = target else { closeSheet(); return }
        SFTPBookmarks.add(c)
        setBusy(true, "Connecting to \(c.sshTarget)…")
        // Resolve ~ / relative starting path to an absolute one off-main, then
        // open the location in the ACTIVE PANE — first-class remote browsing in
        // the normal file list, rather than the standalone modal browser.
        let typed = c.remotePath
        DispatchQueue.global(qos: .userInitiated).async {
            let abs = SFTPClient.realpath(c, path: typed.isEmpty ? "~" : typed)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.setBusy(false)
                guard let abs else {
                    // Don't dump the user into an empty pane on a bad host/creds.
                    self.status.stringValue = "Could not connect to \(c.sshTarget)"
                    self.status.textColor = .systemRed
                    return
                }
                self.closeSheet()
                wc.navigateActivePane(to: SFTPLocation.url(c, path: abs))
            }
        }
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
