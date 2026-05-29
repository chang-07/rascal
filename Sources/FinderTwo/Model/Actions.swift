import AppKit

/// One canonical, data-driven description of every command in the app.
///
/// Menus, the command palette, the customizable hotbar, the custom-shortcut
/// editor, and vim mode all read from `ActionRegistry.all` and dispatch via
/// `Action.perform`. This means a single source of truth for what the app
/// can *do*; UIs are just views over it.
struct Action {
    /// Stable identifier used for shortcut customization persistence and
    /// vim bindings (e.g. "nav.up").
    let id: String
    /// Human-visible name shown in menus and the palette.
    let title: String
    /// Top-level grouping for the palette and shortcut editor.
    let category: Category
    /// Optional SF Symbol name for buttons.
    let icon: String?
    /// Default macOS keyboard equivalent (key + modifiers) used by the menu.
    /// Users may override via the shortcut editor; the menu rebuilds from
    /// the effective shortcut.
    let defaultShortcut: KeyShortcut?
    /// Body of the action. Receives the active BrowserWindowController.
    let perform: (BrowserWindowController) -> Void

    enum Category: String, CaseIterable {
        case navigation = "Navigation"
        case file       = "File"
        case edit       = "Edit"
        case view       = "View"
        case tabs       = "Tabs"
        case panes      = "Panes"
        case search     = "Search"
        case workspace  = "Workspace"
    }
}

struct KeyShortcut: Equatable, Hashable {
    let key: String                    // a single-character keyEquivalent like "n", "↑", "g"
    let modifiers: NSEvent.ModifierFlags
    init(_ key: String, _ modifiers: NSEvent.ModifierFlags = [.command]) {
        self.key = key
        self.modifiers = modifiers
    }
    static func == (lhs: KeyShortcut, rhs: KeyShortcut) -> Bool {
        lhs.key == rhs.key && lhs.modifiers.rawValue == rhs.modifiers.rawValue
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(modifiers.rawValue)
    }

    /// Human-readable label like "⌘⇧G".
    var displayLabel: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option)  { s += "⌥" }
        if modifiers.contains(.shift)   { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        s += key.uppercased()
        return s
    }
}

enum ActionRegistry {
    /// Every command in the app. Iterate this once to build menus + palette.
    static let all: [Action] = [
        // -------- Navigation --------
        .init(id: "nav.up",
              title: "Enclosing Folder",
              category: .navigation,
              icon: "chevron.up",
              defaultShortcut: KeyShortcut(String(UnicodeScalar(NSUpArrowFunctionKey)!))) { $0.goUp(nil) },
        .init(id: "nav.open",
              title: "Open",
              category: .navigation,
              icon: "arrow.right.circle",
              defaultShortcut: KeyShortcut(String(UnicodeScalar(NSDownArrowFunctionKey)!))) { $0.openSelection(nil) },
        .init(id: "nav.back",
              title: "Back",
              category: .navigation,
              icon: "chevron.left",
              defaultShortcut: KeyShortcut("[", [.command])) { $0.goBack(nil) },
        .init(id: "nav.forward",
              title: "Forward",
              category: .navigation,
              icon: "chevron.right",
              defaultShortcut: KeyShortcut("]", [.command])) { $0.goForward(nil) },
        .init(id: "nav.goto",
              title: "Go to Folder…",
              category: .navigation,
              icon: "arrow.right.to.line",
              defaultShortcut: KeyShortcut("g", [.command, .shift])) { $0.goToFolder(nil) },
        .init(id: "nav.home",
              title: "Home",
              category: .navigation,
              icon: "house",
              defaultShortcut: KeyShortcut("h", [.command, .shift])) { $0.goHome(nil) },
        .init(id: "project.jump-root",
              title: "Jump to Project Root",
              category: .navigation,
              icon: "arrow.up.to.line.circle",
              defaultShortcut: KeyShortcut("r", [.command, .control])) { $0.jumpToProjectRoot(nil) },
        .init(id: "project.open-editor",
              title: "Open in Editor",
              category: .navigation,
              icon: "chevron.left.forwardslash.chevron.right",
              defaultShortcut: KeyShortcut("o", [.command, .shift])) { $0.openInEditor(nil) },

        // -------- File --------
        .init(id: "file.new-folder",
              title: "New Folder",
              category: .file,
              icon: "folder.badge.plus",
              defaultShortcut: KeyShortcut("N", [.command, .shift])) { $0.newFolder(nil) },
        .init(id: "file.get-info",
              title: "Get Info",
              category: .file,
              icon: "info.circle",
              defaultShortcut: KeyShortcut("i", [.command])) { $0.getInfo(nil) },
        .init(id: "file.rename",
              title: "Rename",
              category: .file,
              icon: "pencil",
              defaultShortcut: nil) { $0.renameSelection(nil) },
        .init(id: "file.trash",
              title: "Move to Trash",
              category: .file,
              icon: "trash",
              defaultShortcut: KeyShortcut(String(Character(UnicodeScalar(NSDeleteCharacter)!)),
                                           [.command])) { $0.moveToTrash(nil) },
        .init(id: "file.reveal-finder",
              title: "Reveal in Finder",
              category: .file,
              icon: "magnifyingglass",
              defaultShortcut: nil) { wc in
                  guard let p = wc.testActivePane else { return }
                  let sel = p.selectedURLs()
                  FileOps.revealInFinder(sel.isEmpty ? [p.currentURL] : sel)
              },
        .init(id: "file.copy-path",
              title: "Copy Path",
              category: .file,
              icon: "doc.on.clipboard",
              defaultShortcut: KeyShortcut("c", [.command, .option])) { $0.copyPath(nil) },
        .init(id: "file.open-in-terminal",
              title: "Open in Terminal",
              category: .file,
              icon: "terminal",
              defaultShortcut: KeyShortcut("t", [.command, .option])) { $0.openInTerminal(nil) },

        // -------- Edit --------
        .init(id: "edit.copy",
              title: "Copy",
              category: .edit,
              icon: "doc.on.doc",
              defaultShortcut: KeyShortcut("c", [.command])) { $0.copyFiles(nil) },
        .init(id: "edit.paste",
              title: "Paste",
              category: .edit,
              icon: "doc.on.clipboard",
              defaultShortcut: KeyShortcut("v", [.command])) { $0.pasteFiles(nil) },
        .init(id: "edit.paste-move",
              title: "Move Items Here",
              category: .edit,
              icon: "arrow.right.doc.on.clipboard",
              defaultShortcut: KeyShortcut("v", [.command, .option])) { $0.pasteMove(nil) },
        .init(id: "edit.duplicate",
              title: "Duplicate",
              category: .edit,
              icon: "plus.square.on.square",
              defaultShortcut: KeyShortcut("d", [.command])) { $0.duplicate(nil) },

        // -------- View --------
        .init(id: "view.as-list",
              title: "as List",
              category: .view,
              icon: "list.bullet",
              defaultShortcut: KeyShortcut("1", [.command, .option])) { $0.viewAsList(nil) },
        .init(id: "view.as-columns",
              title: "as Columns",
              category: .view,
              icon: "rectangle.split.3x1",
              defaultShortcut: KeyShortcut("2", [.command, .option])) { $0.viewAsColumns(nil) },
        .init(id: "view.toggle-hidden",
              title: "Toggle Hidden Files",
              category: .view,
              icon: "eye",
              defaultShortcut: KeyShortcut(".", [.command, .shift])) { $0.toggleHidden(nil) },
        .init(id: "view.cycle-theme",
              title: "Cycle Theme",
              category: .view,
              icon: "paintbrush",
              defaultShortcut: nil) { _ in ThemeManager.shared.cycle() },

        // -------- Tabs --------
        .init(id: "tab.new",
              title: "New Tab",
              category: .tabs,
              icon: "plus.rectangle.on.rectangle",
              defaultShortcut: KeyShortcut("t", [.command])) { $0.newTab(nil) },
        .init(id: "tab.close",
              title: "Close Tab",
              category: .tabs,
              icon: "xmark.rectangle",
              defaultShortcut: KeyShortcut("w", [.command])) { $0.closeTab(nil) },
        .init(id: "tab.next",
              title: "Next Tab",
              category: .tabs,
              icon: "arrowtriangle.right.square",
              defaultShortcut: KeyShortcut("]", [.command, .shift])) { $0.nextTab(nil) },
        .init(id: "tab.prev",
              title: "Previous Tab",
              category: .tabs,
              icon: "arrowtriangle.left.square",
              defaultShortcut: KeyShortcut("[", [.command, .shift])) { $0.prevTab(nil) },
        .init(id: "tab.move-left",
              title: "Move Tab Left",
              category: .tabs,
              icon: "arrow.left.to.line",
              defaultShortcut: KeyShortcut("[", [.command, .control])) { $0.moveTabLeft(nil) },
        .init(id: "tab.move-right",
              title: "Move Tab Right",
              category: .tabs,
              icon: "arrow.right.to.line",
              defaultShortcut: KeyShortcut("]", [.command, .control])) { $0.moveTabRight(nil) },

        // -------- Panes --------
        .init(id: "pane.toggle-extra",
              title: "Open Extra Pane",
              category: .panes,
              icon: "rectangle.split.2x1",
              defaultShortcut: KeyShortcut("\\", [.command])) { $0.toggleExtraPane(nil) },
        .init(id: "pane.focus-next",
              title: "Focus Next Pane",
              category: .panes,
              icon: "arrow.right.square",
              defaultShortcut: KeyShortcut(String(UnicodeScalar(NSRightArrowFunctionKey)!),
                                           [.command, .option])) { $0.focusNextPane(nil) },
        .init(id: "pane.focus-prev",
              title: "Focus Previous Pane",
              category: .panes,
              icon: "arrow.left.square",
              defaultShortcut: KeyShortcut(String(UnicodeScalar(NSLeftArrowFunctionKey)!),
                                           [.command, .option])) { $0.focusPrevPane(nil) },

        // -------- Search --------
        .init(id: "search.palette",
              title: "Command Palette…",
              category: .search,
              icon: "command",
              defaultShortcut: KeyShortcut("p", [.command, .shift])) { $0.showCommandPalette(nil) },
        .init(id: "search.find-files",
              title: "Find Files…",
              category: .search,
              icon: "magnifyingglass",
              defaultShortcut: KeyShortcut("f", [.command])) { $0.showFindFiles(nil) },
        .init(id: "search.grep",
              title: "Search File Contents…",
              category: .search,
              icon: "text.magnifyingglass",
              defaultShortcut: KeyShortcut("f", [.command, .shift])) { $0.showGrep(nil) },

        // -------- Tools / panels --------
        .init(id: "tool.analyze-disk",
              title: "Analyze Disk Usage…",
              category: .file,
              icon: "chart.pie",
              defaultShortcut: nil) { $0.analyzeDiskUsage(nil) },
        .init(id: "tool.uninstall-app",
              title: "Uninstall App…",
              category: .file,
              icon: "trash.slash",
              defaultShortcut: nil) { $0.uninstallApp(nil) },
        .init(id: "tool.browse-archive",
              title: "Browse Archive…",
              category: .file,
              icon: "archivebox",
              defaultShortcut: nil) { $0.openArchive(nil) },
        .init(id: "tool.folder-sync",
              title: "Sync Folder…",
              category: .file,
              icon: "arrow.triangle.2.circlepath",
              defaultShortcut: nil) { $0.openFolderSync(nil) },
        .init(id: "panel.terminal",
              title: "Toggle Terminal",
              category: .view,
              icon: "terminal",
              defaultShortcut: KeyShortcut("`", [.command])) { $0.toggleTerminal(nil) },
        .init(id: "panel.notes",
              title: "Toggle Notes Drawer",
              category: .view,
              icon: "note.text",
              defaultShortcut: KeyShortcut("e", [.command, .shift])) { $0.toggleNotes(nil) },
        .init(id: "net.connect-server",
              title: "Connect to Server…",
              category: .navigation,
              icon: "server.rack",
              defaultShortcut: KeyShortcut("k", [.command])) { $0.connectToServer(nil) },

        // -------- Workspace --------
        .init(id: "workspace.save",
              title: "Save Workspace…",
              category: .workspace,
              icon: "square.stack.3d.up",
              defaultShortcut: nil) { $0.saveWorkspace(nil) },
        .init(id: "workspace.open",
              title: "Open Workspace…",
              category: .workspace,
              icon: "square.stack.3d.up.fill",
              defaultShortcut: nil) { $0.openWorkspaceMenu(nil) },
    ]

    /// Find action by stable id. Includes plugin-registered actions.
    static func action(id: String) -> Action? {
        if let builtIn = all.first(where: { $0.id == id }) { return builtIn }
        return allIncludingPlugins().first { $0.id == id }
    }

    /// Resolved shortcut for an action, honoring user customization stored in
    /// UserDefaults under key "FinderTwo.shortcuts".
    static func shortcut(for id: String) -> KeyShortcut? {
        if let raw = (UserDefaults.standard.dictionary(forKey: "FinderTwo.shortcuts") as? [String: [String: Any]])?[id],
           let key = raw["key"] as? String {
            let mods = NSEvent.ModifierFlags(rawValue: UInt(raw["mods"] as? Int ?? 0))
            return KeyShortcut(key, mods)
        }
        return action(id: id)?.defaultShortcut
    }

    /// Set a custom shortcut (or clear if `shortcut` is nil).
    static func setShortcut(_ shortcut: KeyShortcut?, forId id: String) {
        var dict = UserDefaults.standard.dictionary(forKey: "FinderTwo.shortcuts") as? [String: [String: Any]] ?? [:]
        if let s = shortcut {
            dict[id] = ["key": s.key, "mods": Int(s.modifiers.rawValue)]
        } else {
            dict.removeValue(forKey: id)
        }
        UserDefaults.standard.set(dict, forKey: "FinderTwo.shortcuts")
        NotificationCenter.default.post(name: ActionRegistry.shortcutsDidChange, object: nil)
    }

    /// True when the action's effective shortcut differs from its built-in default.
    static func isCustomized(_ id: String) -> Bool {
        let dict = UserDefaults.standard.dictionary(forKey: "FinderTwo.shortcuts") as? [String: [String: Any]] ?? [:]
        return dict[id] != nil
    }

    /// Returns the id of an action already bound to `shortcut`, other than
    /// `excluding`. Used by the editor to flag conflicts before assigning.
    static func conflictingActionId(for target: KeyShortcut, excluding id: String) -> String? {
        for a in all where a.id != id {
            if shortcut(for: a.id) == target { return a.id }
        }
        return nil
    }

    /// Fired whenever a custom shortcut is set or cleared, so the menu can rebuild.
    static let shortcutsDidChange = Notification.Name("FinderTwo.shortcutsDidChange")
}
