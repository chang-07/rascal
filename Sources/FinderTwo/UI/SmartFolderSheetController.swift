import AppKit

/// Sheet for creating (or editing) a saved search / smart folder: a name,
/// optional filename + content substrings, and a search root. Saving persists
/// it via SmartFolders (which refreshes the sidebar) and, when creating new,
/// navigates the active pane to the synthetic `/smart/<id>` listing.
final class SmartFolderSheetController: NSWindowController, NSWindowDelegate {

    /// Present a sheet to create a new smart folder rooted at `defaultRoot`.
    static func show(for wc: NSWindowController, defaultRoot: URL?) {
        guard let parent = wc.window else { return }
        let c = SmartFolderSheetController(existing: nil, defaultRoot: defaultRoot,
                                          onSave: { [weak wc] folder in
            // Navigate the active pane to the new smart folder.
            if let bwc = wc as? BrowserWindowController {
                bwc.openSmartFolder(id: folder.id)
            }
        })
        parent.beginSheet(c.window!)
        PresentedControllers.retain(c)
    }

    private let nameField = NSTextField()
    private let nameContainsField = NSTextField()
    private let contentContainsField = NSTextField()
    private let rootLabel = NSTextField(labelWithString: "")
    private var rootPath: String
    private let editingId: String?
    private let onSave: (SmartFolder) -> Void

    init(existing: SmartFolder?, defaultRoot: URL?, onSave: @escaping (SmartFolder) -> Void) {
        self.editingId = existing?.id
        self.rootPath = existing?.rootPath ?? defaultRoot?.path ?? ""
        self.onSave = onSave
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 250),
                           styleMask: [.titled], backing: .buffered, defer: false)
        win.title = existing == nil ? "New Smart Folder" : "Edit Smart Folder"
        super.init(window: win)
        ThemeChrome.apply(to: window)
        win.delegate = self
        nameField.stringValue = existing?.name ?? ""
        nameContainsField.stringValue = existing?.nameContains ?? ""
        contentContainsField.stringValue = existing?.contentContains ?? ""
        win.contentView = buildContent()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildContent() -> NSView {
        for f in [nameField, nameContainsField, contentContainsField] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.font = .systemFont(ofSize: 13)
        }
        nameField.placeholderString = "My Smart Folder"
        nameContainsField.placeholderString = "filename contains… (optional)"
        contentContainsField.placeholderString = "content contains… (optional)"

        rootLabel.stringValue = rootPathDisplay()
        rootLabel.font = .systemFont(ofSize: 11)
        rootLabel.textColor = .secondaryLabelColor
        rootLabel.lineBreakMode = .byTruncatingMiddle
        rootLabel.translatesAutoresizingMaskIntoConstraints = false

        let chooseBtn = NSButton(title: "Choose…", target: self, action: #selector(chooseRoot))
        chooseBtn.bezelStyle = .rounded
        let anywhereBtn = NSButton(title: "Anywhere", target: self, action: #selector(clearRoot))
        anywhereBtn.bezelStyle = .rounded

        func row(_ label: String, _ field: NSView) -> NSStackView {
            let l = NSTextField(labelWithString: label)
            l.alignment = .right
            l.translatesAutoresizingMaskIntoConstraints = false
            l.widthAnchor.constraint(equalToConstant: 90).isActive = true
            let s = NSStackView(views: [l, field])
            s.orientation = .horizontal; s.spacing = 8
            s.translatesAutoresizingMaskIntoConstraints = false
            return s
        }

        let rootRow = NSStackView(views: [rootLabel, anywhereBtn, chooseBtn])
        rootRow.orientation = .horizontal; rootRow.spacing = 8

        let save = NSButton(title: "Save", target: self, action: #selector(saveAction))
        save.bezelStyle = .rounded; save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelAction))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, save])
        buttons.orientation = .horizontal; buttons.spacing = 10

        let stack = NSStackView(views: [
            row("Name:", nameField),
            row("Name has:", nameContainsField),
            row("Content has:", contentContainsField),
            row("Search in:", rootRow),
            buttons,
        ])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        let v = NSView()
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: v.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: v.bottomAnchor, constant: -18),
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
        return v
    }

    private func rootPathDisplay() -> String {
        rootPath.isEmpty ? "Anywhere" : (rootPath as NSString).abbreviatingWithTildeInPath
    }

    @objc private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if !rootPath.isEmpty { panel.directoryURL = URL(fileURLWithPath: rootPath) }
        let go: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard let self, resp == .OK, let url = panel.url else { return }
            self.rootPath = url.path
            self.rootLabel.stringValue = self.rootPathDisplay()
        }
        if let win = window { panel.beginSheetModal(for: win, completionHandler: go) }
        else { go(panel.runModal()) }
    }

    @objc private func clearRoot() {
        rootPath = ""
        rootLabel.stringValue = rootPathDisplay()
    }

    @objc private func saveAction() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = SmartFolder(
            id: editingId ?? SmartFolders.makeId(for: name.isEmpty ? "Search" : name),
            name: name.isEmpty ? "Search" : name,
            nameContains: nameContainsField.stringValue,
            contentContains: contentContainsField.stringValue,
            rootPath: rootPath)
        // Refuse a query that would match everything (both fields blank).
        if folder.isEmptyQuery {
            NSSound.beep()
            return
        }
        SmartFolders.upsert(folder)
        dismiss()
        onSave(folder)
    }

    @objc private func cancelAction() { dismiss() }

    private func dismiss() {
        guard let win = window else { return }
        if let parent = win.sheetParent { parent.endSheet(win) } else { close() }
    }
}
