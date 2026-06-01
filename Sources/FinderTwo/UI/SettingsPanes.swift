import AppKit

// MARK: - Keyboard shortcuts

/// Full keyboard-shortcut editor: every action with a live recorder, conflict
/// detection, per-row reset, search filter, and a restore-all button.
final class KeyboardPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, ThemeObserving {

    private let search = NSSearchField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var actions: [Action] = ActionRegistry.allIncludingPlugins()
    private var filtered: [Action] = ActionRegistry.allIncludingPlugins()

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 460))

        search.translatesAutoresizingMaskIntoConstraints = false
        search.placeholderString = "Filter actions…"
        search.delegate = self

        let hint = NSTextField(labelWithString: "Click a shortcut to record. Press ⌫ to clear, Esc to cancel.")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.tag = 102
        hint.translatesAutoresizingMaskIntoConstraints = false

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        table.style = .inset
        table.rowHeight = 30
        table.usesAlternatingRowBackgroundColors = true
        table.headerView = NSTableHeaderView()
        table.dataSource = self
        table.delegate = self
        table.allowsColumnResizing = true
        let cAction = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action"))
        cAction.title = "Action"; cAction.width = 300; cAction.minWidth = 180
        let cKey = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("key"))
        cKey.title = "Shortcut"; cKey.width = 140; cKey.minWidth = 130
        let cReset = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("reset"))
        cReset.title = ""; cReset.width = 60; cReset.minWidth = 60
        table.addTableColumn(cAction)
        table.addTableColumn(cKey)
        table.addTableColumn(cReset)
        scroll.documentView = table

        let restore = NSButton(title: "Restore All Defaults", target: self, action: #selector(restoreAll))
        restore.bezelStyle = .rounded
        restore.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(search)
        root.addSubview(hint)
        root.addSubview(scroll)
        root.addSubview(restore)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            hint.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6),
            hint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: restore.topAnchor, constant: -10),
            restore.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            restore.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])
        self.view = root
        subscribeToTheme(self)
    }

    func controlTextDidChange(_ obj: Notification) {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { filtered = actions }
        else {
            filtered = actions.filter {
                $0.title.localizedCaseInsensitiveContains(q) ||
                $0.category.rawValue.localizedCaseInsensitiveContains(q)
            }
        }
        table.reloadData()
    }

    @objc private func restoreAll() {
        let alert = NSAlert()
        alert.messageText = "Restore all default shortcuts?"
        alert.informativeText = "This clears every custom keyboard shortcut."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        if let w = view.window {
            alert.beginSheetModal(for: w) { resp in
                guard resp == .alertFirstButtonReturn else { return }
                for a in ActionRegistry.allIncludingPlugins() { ActionRegistry.setShortcut(nil, forId: a.id) }
                self.table.reloadData()
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let action = filtered[row]
        switch tableColumn?.identifier.rawValue {
        case "action":
            let id = NSUserInterfaceItemIdentifier("kbAction")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
                let v = NSTableCellView()
                let title = NSTextField(labelWithString: "")
                title.translatesAutoresizingMaskIntoConstraints = false
                title.font = NSFont.systemFont(ofSize: 13)
                let sub = NSTextField(labelWithString: "")
                sub.translatesAutoresizingMaskIntoConstraints = false
                sub.font = NSFont.systemFont(ofSize: 10)
                sub.textColor = .tertiaryLabelColor
                sub.identifier = NSUserInterfaceItemIdentifier("subtitle")
                v.addSubview(title); v.addSubview(sub); v.textField = title
                NSLayoutConstraint.activate([
                    title.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4),
                    title.topAnchor.constraint(equalTo: v.topAnchor, constant: 3),
                    sub.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4),
                    sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 0),
                ])
                v.identifier = id
                return v
            }()
            cell.textField?.stringValue = action.title
            cell.textField?.textColor = ThemeChrome.primary
            if let subLabel = cell.subviews.first(where: { $0.identifier?.rawValue == "subtitle" }) as? NSTextField {
                subLabel.stringValue = action.category.rawValue
                subLabel.textColor = ThemeChrome.tertiary
            }
            return cell
        case "key":
            let recorder = ShortcutRecorderView(frame: .zero)
            recorder.shortcut = ActionRegistry.shortcut(for: action.id)
            recorder.onRecord = { [weak self] sc in
                self?.assign(sc, to: action, recorder: recorder)
            }
            // Wrap so the recorder is vertically centered in the row.
            let wrap = NSView()
            recorder.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(recorder)
            NSLayoutConstraint.activate([
                recorder.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 2),
                recorder.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -2),
                recorder.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
                recorder.heightAnchor.constraint(equalToConstant: 22),
            ])
            return wrap
        case "reset":
            guard ActionRegistry.isCustomized(action.id) else { return NSView() }
            let btn = NSButton(title: "Reset", target: self, action: #selector(resetRow(_:)))
            btn.bezelStyle = .inline
            btn.controlSize = .small
            btn.identifier = NSUserInterfaceItemIdentifier(action.id)
            let wrap = NSView()
            btn.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(btn)
            NSLayoutConstraint.activate([
                btn.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
                btn.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            ])
            return wrap
        default:
            return nil
        }
    }

    private func assign(_ shortcut: KeyShortcut?, to action: Action, recorder: ShortcutRecorderView) {
        if let sc = shortcut, let conflictId = ActionRegistry.conflictingActionId(for: sc, excluding: action.id) {
            let other = ActionRegistry.action(id: conflictId)?.title ?? conflictId
            let alert = NSAlert()
            alert.messageText = "“\(sc.displayLabel)” is already used by “\(other)”."
            alert.informativeText = "Reassign it to “\(action.title)” and remove it from “\(other)”?"
            alert.addButton(withTitle: "Reassign")
            alert.addButton(withTitle: "Cancel")
            let doIt: (NSApplication.ModalResponse) -> Void = { resp in
                if resp == .alertFirstButtonReturn {
                    ActionRegistry.setShortcut(nil, forId: conflictId)
                    ActionRegistry.setShortcut(sc, forId: action.id)
                } else {
                    recorder.shortcut = ActionRegistry.shortcut(for: action.id)
                }
                self.table.reloadData()
            }
            if let w = view.window { alert.beginSheetModal(for: w, completionHandler: doIt) }
            return
        }
        ActionRegistry.setShortcut(shortcut, forId: action.id)
        table.reloadData()
    }

    @objc private func resetRow(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        ActionRegistry.setShortcut(nil, forId: id)
        table.reloadData()
    }

    @objc func applyTheme() {
        if isViewLoaded {
            ThemeChrome.updateColors(in: view)
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

// MARK: - Hotbar

/// Edit which actions appear in the per-pane hotbar, and their order.
final class HotbarPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate, ThemeObserving {

    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let addPopup = NSPopUpButton()
    private var ids: [String] = HotbarView.currentIds()

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 460))

        let showToggle = NSButton(checkboxWithTitle: "Show the hotbar in each pane",
                                  target: self, action: #selector(toggleShowHotbar))
        showToggle.state = Settings.showHotbar ? .on : .off
        showToggle.translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(labelWithString: "Buttons shown in each pane's hotbar, top to bottom:")
        header.font = NSFont.systemFont(ofSize: 12)
        header.tag = 101
        header.translatesAutoresizingMaskIntoConstraints = false

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        table.style = .inset
        table.rowHeight = 26
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([.string])
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        col.title = ""; col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        scroll.documentView = table

        let up = NSButton(title: "↑", target: self, action: #selector(hotbarMoveUp))
        let down = NSButton(title: "↓", target: self, action: #selector(hotbarMoveDown))
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeSel))
        for b in [up, down, remove] { b.bezelStyle = .rounded; b.translatesAutoresizingMaskIntoConstraints = false }

        addPopup.translatesAutoresizingMaskIntoConstraints = false
        rebuildAddPopup()

        let addBtn = NSButton(title: "Add", target: self, action: #selector(addSel))
        addBtn.bezelStyle = .rounded
        addBtn.translatesAutoresizingMaskIntoConstraints = false

        let reset = NSButton(title: "Reset Hotbar", target: self, action: #selector(resetHotbar))
        reset.bezelStyle = .rounded
        reset.translatesAutoresizingMaskIntoConstraints = false

        let btnRow = NSStackView(views: [up, down, remove])
        btnRow.orientation = .horizontal; btnRow.spacing = 8
        btnRow.translatesAutoresizingMaskIntoConstraints = false
        let addRow = NSStackView(views: [addPopup, addBtn])
        addRow.orientation = .horizontal; addRow.spacing = 8
        addRow.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(showToggle)
        root.addSubview(header)
        root.addSubview(scroll)
        root.addSubview(btnRow)
        root.addSubview(addRow)
        root.addSubview(reset)
        NSLayoutConstraint.activate([
            showToggle.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            showToggle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            header.topAnchor.constraint(equalTo: showToggle.bottomAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.heightAnchor.constraint(equalToConstant: 240),
            btnRow.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            btnRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            addRow.topAnchor.constraint(equalTo: btnRow.bottomAnchor, constant: 10),
            addRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            addRow.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
            addPopup.widthAnchor.constraint(equalToConstant: 280),
            reset.topAnchor.constraint(equalTo: addRow.bottomAnchor, constant: 14),
            reset.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
        ])
        self.view = root
        subscribeToTheme(self)
    }

    @objc private func toggleShowHotbar(_ s: NSButton) { Settings.showHotbar = s.state == .on }

    private func availableActions() -> [Action] {
        ActionRegistry.allIncludingPlugins().filter { !ids.contains($0.id) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private func rebuildAddPopup() {
        addPopup.removeAllItems()
        for a in availableActions() {
            addPopup.addItem(withTitle: a.title)
            addPopup.lastItem?.representedObject = a.id
        }
        if addPopup.numberOfItems == 0 { addPopup.addItem(withTitle: "(all actions added)") }
    }
    private func commit() {
        HotbarView.setIds(ids)
        table.reloadData()
        rebuildAddPopup()
    }

    @objc private func addSel() {
        guard let id = addPopup.selectedItem?.representedObject as? String else { return }
        ids.append(id); commit()
    }
    @objc private func removeSel() {
        let r = table.selectedRow
        guard ids.indices.contains(r) else { return }
        ids.remove(at: r); commit()
    }
    @objc private func hotbarMoveUp() {
        let r = table.selectedRow
        guard r > 0, ids.indices.contains(r) else { return }
        ids.swapAt(r, r - 1); commit()
        table.selectRowIndexes(IndexSet(integer: r - 1), byExtendingSelection: false)
    }
    @objc private func hotbarMoveDown() {
        let r = table.selectedRow
        guard r >= 0, r < ids.count - 1 else { return }
        ids.swapAt(r, r + 1); commit()
        table.selectRowIndexes(IndexSet(integer: r + 1), byExtendingSelection: false)
    }
    @objc private func resetHotbar() {
        ids = HotbarView.defaultIds(); commit()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { ids.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard ids.indices.contains(row), let action = ActionRegistry.action(id: ids[row]) else { return nil }
        let id = NSUserInterfaceItemIdentifier("hotbarItem")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let v = NSTableCellView()
            let icon = NSImageView(); icon.translatesAutoresizingMaskIntoConstraints = false
            let tf = NSTextField(labelWithString: ""); tf.translatesAutoresizingMaskIntoConstraints = false
            tf.font = NSFont.systemFont(ofSize: 13)
            v.addSubview(icon); v.addSubview(tf); v.imageView = icon; v.textField = tf
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4),
                icon.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                tf.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                tf.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            ])
            v.identifier = id
            return v
        }()
        cell.textField?.stringValue = action.title
        cell.textField?.textColor = ThemeChrome.primary
        cell.imageView?.image = action.icon.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)
        }
        return cell
    }

    // Drag to reorder.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: .string)
        return item
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        op == .above ? .move : []
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        guard let str = info.draggingPasteboard.string(forType: .string), let from = Int(str) else { return false }
        guard ids.indices.contains(from) else { return false }
        let moved = ids.remove(at: from)
        let dest = from < row ? row - 1 : row
        ids.insert(moved, at: min(dest, ids.count))
        commit()
        return true
    }

    @objc func applyTheme() {
        if isViewLoaded {
            ThemeChrome.updateColors(in: view)
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

// MARK: - Advanced

final class DeveloperPane: SettingsPane {
    private let customShellField = NSTextField()

    override func build() {
        let gitEnabled = NSButton(checkboxWithTitle: "Enable Git integration (status & badges)",
                                  target: self, action: #selector(gitEnabledChanged(_:)))
        gitEnabled.state = Settings.gitIntegrationEnabled ? .on : .off
        addRow("Git:", gitEnabled)

        let gitStatus = NSButton(checkboxWithTitle: "Show Git branch in status bar",
                                 target: self, action: #selector(gitBranchChanged(_:)))
        gitStatus.state = Settings.showGitBranchInStatusBar ? .on : .off
        addRow("", gitStatus)

        // shell setup
        let shellPopup = NSPopUpButton()
        shellPopup.addItem(withTitle: "Zsh (/bin/zsh)")
        shellPopup.lastItem?.representedObject = "/bin/zsh"
        shellPopup.addItem(withTitle: "Bash (/bin/bash)")
        shellPopup.lastItem?.representedObject = "/bin/bash"
        shellPopup.addItem(withTitle: "Sh (/bin/sh)")
        shellPopup.lastItem?.representedObject = "/bin/sh"
        shellPopup.addItem(withTitle: "Custom...")
        shellPopup.lastItem?.representedObject = "custom"

        let currentShell = Settings.terminalShell
        if ["/bin/zsh", "/bin/bash", "/bin/sh"].contains(currentShell) {
            shellPopup.selectItem(withTitle: currentShell == "/bin/zsh" ? "Zsh (/bin/zsh)" :
                                             currentShell == "/bin/bash" ? "Bash (/bin/bash)" : "Sh (/bin/sh)")
        } else {
            shellPopup.selectItem(withTitle: "Custom...")
        }
        shellPopup.target = self
        shellPopup.action = #selector(shellPopupChanged(_:))

        customShellField.placeholderString = "/path/to/shell"
        customShellField.stringValue = currentShell
        customShellField.translatesAutoresizingMaskIntoConstraints = false
        customShellField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        customShellField.target = self
        customShellField.action = #selector(customShellPathChanged(_:))
        customShellField.isHidden = shellPopup.selectedItem?.representedObject as? String != "custom"

        let shellStack = NSStackView(views: [shellPopup, customShellField])
        shellStack.orientation = .horizontal
        shellStack.spacing = 8
        addRow("Terminal shell:", shellStack)
    }

    @objc private func gitEnabledChanged(_ s: NSButton) { Settings.gitIntegrationEnabled = s.state == .on }
    @objc private func gitBranchChanged(_ s: NSButton) { Settings.showGitBranchInStatusBar = s.state == .on }

    @objc private func shellPopupChanged(_ sender: NSPopUpButton) {
        if let val = sender.selectedItem?.representedObject as? String {
            if val == "custom" {
                customShellField.isHidden = false
                Settings.terminalShell = customShellField.stringValue
            } else {
                customShellField.isHidden = true
                Settings.terminalShell = val
            }
        }
    }

    @objc private func customShellPathChanged(_ sender: NSTextField) {
        Settings.terminalShell = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Advanced

final class AdvancedPane: SettingsPane {
    override func build() {
        let spring = NSButton(checkboxWithTitle: "Spring-loaded folders (open on drag-hover)",
                              target: self, action: #selector(springChanged(_:)))
        spring.state = Settings.springLoadedFolders ? .on : .off
        addRow("Dragging:", spring)

        let delay = NSSlider(value: Settings.springLoadDelay, minValue: 0.2, maxValue: 2.0,
                             target: self, action: #selector(springDelayChanged(_:)))
        delay.controlSize = .small
        delay.widthAnchor.constraint(equalToConstant: 150).isActive = true
        addRow("Spring delay:", delay)

        let calcSizes = NSButton(checkboxWithTitle: "Calculate folder sizes (slower)",
                                 target: self, action: #selector(calcSizesChanged(_:)))
        calcSizes.state = Settings.calculateFolderSizes ? .on : .off
        addRow("Folders:", calcSizes)

        let confirmTrash = NSButton(checkboxWithTitle: "Warn before moving items to Trash",
                                    target: self, action: #selector(confirmTrashChanged(_:)))
        confirmTrash.state = Settings.confirmTrash ? .on : .off
        addRow("Safety:", confirmTrash)

        let vim = NSButton(checkboxWithTitle: "Enable Vim navigation (hjkl, /, :, dd, yy, p, r, gt/gT)",
                           target: self, action: #selector(vimChanged(_:)))
        vim.state = VimMode.shared.enabled ? .on : .off
        addRow("Input:", vim)

        let hint = NSTextField(wrappingLabelWithString:
            "When Vim mode is on and the file list or sidebar has focus, plain letter keys are intercepted. Text fields, search, rename, and the terminal always type normally.")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.preferredMaxLayoutWidth = 380
        addRow("", hint)

        let pluginsBtn = NSButton(title: "Reveal Plugins Folder", target: self, action: #selector(revealPlugins))
        pluginsBtn.bezelStyle = .rounded
        addRow("Plugins:", pluginsBtn)

        let reloadBtn = NSButton(title: "Reload Plugins", target: self, action: #selector(reloadPlugins))
        reloadBtn.bezelStyle = .rounded
        addRow("", reloadBtn)

        let resetBtn = NSButton(title: "Reset General & Appearance", target: self, action: #selector(resetSettings))
        resetBtn.bezelStyle = .rounded
        addRow("Settings:", resetBtn)
    }

    @objc private func springChanged(_ s: NSButton) { Settings.springLoadedFolders = s.state == .on }
    @objc private func springDelayChanged(_ s: NSSlider) { Settings.springLoadDelay = s.doubleValue }
    @objc private func calcSizesChanged(_ s: NSButton) { Settings.calculateFolderSizes = s.state == .on }
    @objc private func confirmTrashChanged(_ s: NSButton) { Settings.confirmTrash = s.state == .on }

    @objc private func vimChanged(_ s: NSButton) { VimMode.shared.setEnabled(s.state == .on) }

    @objc private func revealPlugins() {
        let dir = PluginHost.pluginsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }
    @objc private func reloadPlugins() {
        PluginHost.shared.loadAll()
        if let w = view.window {
            let a = NSAlert()
            a.messageText = "Plugins reloaded"
            a.informativeText = "\(PluginHost.shared.plugins.count) plugin(s) loaded."
            a.beginSheetModal(for: w, completionHandler: { _ in })
        }
    }
    @objc private func resetSettings() {
        Settings.resetGeneralAndAppearance()
        // Rebuild the pane to reflect defaults.
        if let win = view.window?.windowController as? SettingsController {
            SettingsController.show(selecting: .advanced)
            _ = win
        }
    }
}
