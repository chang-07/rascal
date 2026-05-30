import AppKit

/// "Sync Folder…" — pick source + target, view a 3-state diff, mirror src→dst.
final class FolderSyncSheetController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, ThemeObserving {

    private weak var target: BrowserWindowController?
    private let sourceField = NSTextField()
    private let destField = NSTextField()
    private let mirrorPruneCheck = NSButton(checkboxWithTitle: "Also delete files missing from source (prune)",
                                            target: nil, action: nil)
    private let twoWayCheck = NSButton(checkboxWithTitle: "Two-way sync (newer file wins; nothing deleted)",
                                       target: nil, action: nil)
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private let summary = NSTextField(labelWithString: "")
    private var entries: [FolderSync.Entry] = []

    static func show(for wc: BrowserWindowController, source: URL?) {
        guard let parent = wc.window else { return }
        let c = FolderSyncSheetController(target: wc, source: source)
        guard let sheet = c.window else { return }
        PresentedControllers.retain(c)
        parent.beginSheet(sheet, completionHandler: { _ in })
    }

    init(target: BrowserWindowController, source: URL?) {
        self.target = target
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 540),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered, defer: false
        )
        win.title = "Sync Folder"
        super.init(window: win)
        ThemeChrome.apply(to: window)
        sourceField.stringValue = source?.path ?? ""
        layout()
        subscribeToTheme(self)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func layout() {
        guard let cv = window?.contentView else { return }

        let sLbl = NSTextField(labelWithString: "From:")
        sLbl.tag = 101
        let dLbl = NSTextField(labelWithString: "To:")
        dLbl.tag = 101
        let pickS = NSButton(title: "Choose…", target: self, action: #selector(pickSource))
        let pickD = NSButton(title: "Choose…", target: self, action: #selector(pickDest))
        let allViews: [NSView] = [sLbl, dLbl, sourceField, destField, pickS, pickD, mirrorPruneCheck, twoWayCheck]
        for v in allViews {
            v.translatesAutoresizingMaskIntoConstraints = false
            cv.addSubview(v)
        }
        for lbl in [sLbl, dLbl] {
            lbl.font = NSFont.systemFont(ofSize: 12)
        }
        for tf in [sourceField, destField] {
            tf.font = NSFont.systemFont(ofSize: 12)
            tf.bezelStyle = .roundedBezel
        }
        for b in [pickS, pickD] {
            b.bezelStyle = .rounded
        }

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        table.style = .inset
        table.rowHeight = 22
        table.headerView = NSTableHeaderView()
        let c1 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("st"))
        c1.title = "Status"; c1.width = 110
        let c2 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        c2.title = "Path"; c2.width = 380
        let c3 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        c3.title = "Size"; c3.width = 110
        for c in [c1, c2, c3] { table.addTableColumn(c) }
        table.dataSource = self; table.delegate = self
        scroll.documentView = table

        summary.translatesAutoresizingMaskIntoConstraints = false
        summary.font = NSFont.systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        summary.tag = 101

        let compare = NSButton(title: "Compare", target: self, action: #selector(doCompare))
        let apply = NSButton(title: "Apply →", target: self, action: #selector(doApply))
        let close = NSButton(title: "Close", target: self, action: #selector(closeSheet))
        compare.bezelStyle = .rounded
        apply.bezelStyle = .rounded
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        for b in [compare, apply, close] {
            b.translatesAutoresizingMaskIntoConstraints = false
            cv.addSubview(b)
        }
        cv.addSubview(scroll)
        cv.addSubview(summary)

        NSLayoutConstraint.activate([
            sLbl.topAnchor.constraint(equalTo: cv.topAnchor, constant: 14),
            sLbl.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 14),
            sLbl.widthAnchor.constraint(equalToConstant: 50),
            sourceField.centerYAnchor.constraint(equalTo: sLbl.centerYAnchor),
            sourceField.leadingAnchor.constraint(equalTo: sLbl.trailingAnchor, constant: 8),
            sourceField.trailingAnchor.constraint(equalTo: pickS.leadingAnchor, constant: -8),
            pickS.centerYAnchor.constraint(equalTo: sLbl.centerYAnchor),
            pickS.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -14),

            dLbl.topAnchor.constraint(equalTo: sLbl.bottomAnchor, constant: 10),
            dLbl.leadingAnchor.constraint(equalTo: sLbl.leadingAnchor),
            dLbl.widthAnchor.constraint(equalTo: sLbl.widthAnchor),
            destField.centerYAnchor.constraint(equalTo: dLbl.centerYAnchor),
            destField.leadingAnchor.constraint(equalTo: sourceField.leadingAnchor),
            destField.trailingAnchor.constraint(equalTo: pickD.leadingAnchor, constant: -8),
            pickD.centerYAnchor.constraint(equalTo: dLbl.centerYAnchor),
            pickD.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -14),

            mirrorPruneCheck.topAnchor.constraint(equalTo: dLbl.bottomAnchor, constant: 10),
            mirrorPruneCheck.leadingAnchor.constraint(equalTo: sourceField.leadingAnchor),

            twoWayCheck.topAnchor.constraint(equalTo: mirrorPruneCheck.bottomAnchor, constant: 6),
            twoWayCheck.leadingAnchor.constraint(equalTo: sourceField.leadingAnchor),

            scroll.topAnchor.constraint(equalTo: twoWayCheck.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: summary.topAnchor, constant: -8),

            summary.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 14),
            summary.bottomAnchor.constraint(equalTo: close.topAnchor, constant: -8),

            close.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -14),
            close.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -14),
            apply.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -8),
            apply.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            compare.trailingAnchor.constraint(equalTo: apply.leadingAnchor, constant: -8),
            compare.centerYAnchor.constraint(equalTo: close.centerYAnchor),
        ])
    }

    private func pickDir(into field: NSTextField) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.beginSheetModal(for: window!) { resp in
            if resp == .OK, let url = panel.url { field.stringValue = url.path }
        }
    }
    @objc private func pickSource() { pickDir(into: sourceField) }
    @objc private func pickDest() { pickDir(into: destField) }

    @objc private func doCompare() {
        let src = URL(fileURLWithPath: sourceField.stringValue)
        let dst = URL(fileURLWithPath: destField.stringValue)
        guard FileManager.default.fileExists(atPath: src.path),
              FileManager.default.fileExists(atPath: dst.path) else {
            NSSound.beep(); return
        }
        summary.stringValue = "Comparing…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = FolderSync.compare(source: src, destination: dst)
            DispatchQueue.main.async {
                self?.entries = result
                self?.table.reloadData()
                self?.updateSummary()
            }
        }
    }

    private func updateSummary() {
        let only = entries.filter { $0.status == .onlySource }.count
        let absent = entries.filter { $0.status == .onlyDestination }.count
        let diff = entries.filter { $0.status == .differs }.count
        let same = entries.filter { $0.status == .identical }.count
        summary.stringValue = "→ \(only) new, ≠ \(diff) modified, ← \(absent) only in destination, = \(same) identical"
    }

    @objc private func doApply() {
        let src = URL(fileURLWithPath: sourceField.stringValue)
        let dst = URL(fileURLWithPath: destField.stringValue)

        // Two-way: union both sides, newer wins, nothing deleted.
        if twoWayCheck.state == .on {
            let pending = entries.filter { $0.status != .identical }.count
            guard pending > 0 else { summary.stringValue = "Nothing to apply."; return }
            let alert = NSAlert()
            alert.messageText = "Two-way sync these folders?"
            alert.informativeText = "Each side gains the other's files; where both changed, the newer file wins. Nothing is deleted."
            alert.addButton(withTitle: "Sync"); alert.addButton(withTitle: "Cancel")
            let proceed: () -> Void = { [weak self] in
                guard let self else { return }
                self.summary.stringValue = "Syncing…"
                DispatchQueue.global(qos: .userInitiated).async {
                    let ops = FolderSync.syncBothWays(source: src, destination: dst)
                    DispatchQueue.main.async {
                        self.summary.stringValue = "Synced \(ops) file\(ops == 1 ? "" : "s") both ways."
                        self.target?.testActivePane?.reload()
                        self.doCompare()
                    }
                }
            }
            if let w = window {
                alert.beginSheetModal(for: w) { if $0 == .alertFirstButtonReturn { proceed() } }
            } else if alert.runModal() == .alertFirstButtonReturn { proceed() }
            return
        }

        let prune = mirrorPruneCheck.state == .on
        let copyCount = entries.filter { $0.status == .onlySource }.count
        let overwriteCount = entries.filter { $0.status == .differs }.count
        let deleteCount = prune ? entries.filter { $0.status == .onlyDestination }.count : 0
        guard copyCount + overwriteCount + deleteCount > 0 else {
            summary.stringValue = "Nothing to apply."
            return
        }
        // This mutates the destination — confirm before touching the user's
        // files, spelling out exactly what will be copied / overwritten / deleted.
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Apply sync to “\(dst.lastPathComponent)”?"
        var info = "\(copyCount) new file\(copyCount == 1 ? "" : "s") copied, \(overwriteCount) overwritten"
        if deleteCount > 0 {
            info += ", \(deleteCount) deleted from the destination (moved to Trash)"
        }
        info += "."
        alert.informativeText = info
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        let proceed: () -> Void = { [weak self] in
            guard let self else { return }
            let ops = FolderSync.mirrorSourceToDestination(self.entries, source: src,
                                                           destination: dst, prune: prune)
            self.summary.stringValue = "Applied \(ops) operation\(ops == 1 ? "" : "s")."
            self.target?.testActivePane?.reload()
        }
        if let w = window {
            alert.beginSheetModal(for: w) { resp in
                if resp == .alertFirstButtonReturn { proceed() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            proceed()
        }
    }

    @objc private func closeSheet() {
        if let w = window, let parent = w.sheetParent { parent.endSheet(w) }
        else { window?.close() }
    }

    // MARK: NSTableViewDataSource
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = entries[row]
        let id = tableColumn?.identifier.rawValue ?? ""
        let cellId = NSUserInterfaceItemIdentifier("FS-\(id)")
        let cell = (tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTableCellView) ?? {
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
            v.identifier = cellId
            return v
        }()
        let (text, color): (String, NSColor)
        switch id {
        case "st":
            switch e.status {
            case .onlySource:     text = "→ Will copy";       color = .systemGreen
            case .onlyDestination: text = "← Only in dest";    color = ThemeChrome.secondary
            case .differs:        text = "≠ Will overwrite";  color = .systemOrange
            case .identical:      text = "= Same";             color = ThemeChrome.tertiary
            }
        case "path":
            text = e.relPath
            color = ThemeChrome.primary
        case "size":
            text = SizeFormatter.string(max(e.srcSize, e.dstSize))
            color = ThemeChrome.secondary
        default:
            text = ""; color = ThemeChrome.primary
        }
        cell.textField?.stringValue = text
        cell.textField?.textColor = color
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
