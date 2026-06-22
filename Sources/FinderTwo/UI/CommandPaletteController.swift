import AppKit

/// Spotlight-style fuzzy launcher over every Action in ActionRegistry, plus
/// every recent folder, every favorite, every open tab. Cmd+Shift+P.
final class CommandPaletteController: NSWindowController, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, ThemeObserving {

    private weak var target: BrowserWindowController?
    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    struct Entry {
        let title: String
        let subtitle: String
        let category: String
        let icon: NSImage?
        let perform: () -> Void
    }
    private var allEntries: [Entry] = []
    private var filtered: [Entry] = []

    /// Test-only: build the entry list using just the data sources (no UI).
    static func testEntries(for wc: BrowserWindowController) -> [Entry] {
        var entries: [Entry] = []
        for a in ActionRegistry.allIncludingPlugins() {
            let shortcut = ActionRegistry.shortcut(for: a.id)?.displayLabel ?? ""
            entries.append(Entry(
                title: a.title,
                subtitle: shortcut.isEmpty ? a.category.rawValue : "\(a.category.rawValue) · \(shortcut)",
                category: a.category.rawValue,
                icon: nil,
                perform: {}
            ))
        }
        for t in Theme.all {
            entries.append(Entry(
                title: "Theme: \(t.name)",
                subtitle: "Appearance · \(t.id)",
                category: "Themes",
                icon: nil,
                perform: {}
            ))
        }
        return entries
    }
    /// Test-only: apply the palette's fuzzy filter to a list of entries.
    static func testFilter(_ entries: [Entry], query q: String) -> [Entry] {
        if q.isEmpty { return entries }
        return entries
            .filter { fuzzyMatchStatic($0.title, needle: q) || fuzzyMatchStatic($0.subtitle, needle: q) }
            .sorted { scoreStatic($0.title, q) > scoreStatic($1.title, q) }
    }
    private static func fuzzyMatchStatic(_ s: String, needle: String) -> Bool {
        if s.localizedCaseInsensitiveContains(needle) { return true }
        var i = s.lowercased().startIndex
        let lower = s.lowercased()
        for ch in needle.lowercased() {
            guard let f = lower[i...].firstIndex(of: ch) else { return false }
            i = lower.index(after: f)
        }
        return true
    }
    private static func scoreStatic(_ s: String, _ q: String) -> Int {
        var score = 0
        if s.lowercased().hasPrefix(q.lowercased()) { score += 1000 }
        if s.localizedCaseInsensitiveContains(q) { score += 500 }
        score -= s.count
        return score
    }

    /// Show (or refocus) the palette for the given window controller.
    static func show(for wc: BrowserWindowController) {
        // Single-instance: if a palette is already up, pressing the shortcut
        // again toggles it closed rather than stacking another copy.
        if let open = PresentedControllers.existing(CommandPaletteController.self) {
            open.close()
            return
        }
        PresentedControllers.existing(SearchSheetController.self)?.close()
        let palette = CommandPaletteController(target: wc)
        PresentedControllers.retain(palette)
        if let w = palette.window { OverlayUI.present(w, over: wc.window) }
    }

    init(target: BrowserWindowController) {
        self.target = target
        let panel = OverlayUI.makePanel()
        panel.title = "Command Palette"
        super.init(window: panel)

        buildEntries()
        layout()
        subscribeToTheme(self)
    }

    @objc func applyTheme() {
        let t = ThemeManager.shared.current
        let custom = t.id != "system"
        searchField.textColor = custom ? t.labelPrimary : .controlTextColor
        searchField.backgroundColor = custom ? t.pathBarBackground : .controlBackgroundColor
        searchField.drawsBackground = true
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func layout() {
        guard let cv = window?.contentView else { return }

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Type a command, folder, or tab…"
        searchField.font = .systemFont(ofSize: 16)
        searchField.bezelStyle = .roundedBezel
        searchField.focusRingType = .none
        searchField.delegate = self

        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(performSelected)
        OverlayUI.configureResultsTable(tableView)
        OverlayUI.configureResultsScroll(scrollView, documentView: tableView)

        cv.addSubview(searchField)
        cv.addSubview(scrollView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: cv.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -14),
            searchField.heightAnchor.constraint(equalToConstant: 30),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -8),
        ])

        filtered = allEntries
        tableView.reloadData()
        if !filtered.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }

        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self?.searchField)
        }
    }

    private func buildEntries() {
        var entries: [Entry] = []
        let target = self.target

        // 1. Actions
        for a in ActionRegistry.allIncludingPlugins() {
            let img = a.icon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            let shortcut = ActionRegistry.shortcut(for: a.id)?.displayLabel ?? ""
            entries.append(Entry(
                title: a.title,
                subtitle: shortcut.isEmpty ? a.category.rawValue : "\(a.category.rawValue) · \(shortcut)",
                category: a.category.rawValue,
                icon: img,
                perform: { [weak target] in
                    guard let t = target else { return }
                    a.perform(t)
                }
            ))
        }
        // 2. Open tabs (cur window only — extension point: all windows)
        if let panes = target?.testActivePane.map({ [$0] }) {
            for (i, pane) in panes.enumerated() {
                let url = pane.currentURL
                entries.append(Entry(
                    title: "Go to: \(url.lastPathComponent)",
                    subtitle: "Tab \(i + 1) · \(url.path)",
                    category: "Tabs",
                    icon: NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: nil),
                    perform: { [weak target] in
                        target?.testActivePane?.navigate(to: url)
                    }
                ))
            }
        }
        // 3. Favorite directories (matches SidebarController structure)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let favorites: [(String, URL)] = [
            ("Home", home),
            ("Desktop", home.appendingPathComponent("Desktop")),
            ("Documents", home.appendingPathComponent("Documents")),
            ("Downloads", home.appendingPathComponent("Downloads")),
            ("Applications", URL(fileURLWithPath: "/Applications")),
        ]
        for (name, url) in favorites where FileManager.default.fileExists(atPath: url.path) {
            entries.append(Entry(
                title: "Go to: \(name)",
                subtitle: url.path,
                category: "Favorites",
                icon: NSWorkspace.shared.icon(forFile: url.path),
                perform: { [weak target] in
                    target?.testActivePane?.navigate(to: url)
                }
            ))
        }
        // 4. Themes
        for t in Theme.all {
            entries.append(Entry(
                title: "Theme: \(t.name)",
                subtitle: "Appearance · \(t.id)",
                category: "Themes",
                icon: NSImage(systemSymbolName: "paintbrush", accessibilityDescription: nil),
                perform: { ThemeManager.shared.setTheme(id: t.id) }
            ))
        }
        // 5. Open With
        if let pane = target?.testActivePane {
            let selected = pane.selectedURLs()
            if !selected.isEmpty {
                let fileURL = selected[0]
                let candidates = FileListController.appCandidates(for: fileURL)
                for appURL in candidates {
                    let appName = (appURL.lastPathComponent as NSString).deletingPathExtension
                    let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                    icon.size = NSSize(width: 16, height: 16)
                    entries.append(Entry(
                        title: "Open With: \(appName)",
                        subtitle: "Application",
                        category: "Open With",
                        icon: icon,
                        perform: {
                            NSWorkspace.shared.open(selected, withApplicationAt: appURL,
                                                    configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                        }
                    ))
                }
                entries.append(Entry(
                    title: "Open With: Other…",
                    subtitle: "Choose application…",
                    category: "Open With",
                    icon: NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil),
                    perform: { [weak pane] in
                        pane?.testFileList.menuOpenWith()
                    }
                ))
            }
        }

        self.allEntries = entries
    }

    // MARK: Filtering

    private func filter(query q: String) {
        if q.isEmpty {
            filtered = allEntries
        } else {
            filtered = allEntries.filter { fuzzyMatch($0.title, needle: q) || fuzzyMatch($0.subtitle, needle: q) }
                .sorted { score($0.title, q) > score($1.title, q) }
        }
        tableView.reloadData()
        if !filtered.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    private func fuzzyMatch(_ s: String, needle: String) -> Bool {
        if s.localizedCaseInsensitiveContains(needle) { return true }
        // subsequence match
        var i = s.lowercased().startIndex
        let lower = s.lowercased()
        for ch in needle.lowercased() {
            guard let f = lower[i...].firstIndex(of: ch) else { return false }
            i = lower.index(after: f)
        }
        return true
    }

    private func score(_ s: String, _ q: String) -> Int {
        var score = 0
        if s.lowercased().hasPrefix(q.lowercased()) { score += 1000 }
        if s.localizedCaseInsensitiveContains(q) { score += 500 }
        score -= s.count
        return score
    }

    /// Demo/screenshot hook: type a query and refresh synchronously.
    func demoSetQuery(_ q: String) {
        _ = window?.contentView          // ensure laid out
        searchField.stringValue = q
        filter(query: q)
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        filter(query: searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            let next = min(tableView.selectedRow + 1, filtered.count - 1)
            if next >= 0 {
                tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
                tableView.scrollRowToVisible(next)
            }
            return true
        case #selector(NSResponder.moveUp(_:)):
            let prev = max(tableView.selectedRow - 1, 0)
            tableView.selectRowIndexes(IndexSet(integer: prev), byExtendingSelection: false)
            tableView.scrollRowToVisible(prev)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            performSelected()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            window?.close()
            return true
        default:
            return false
        }
    }

    @objc private func performSelected() {
        let row = tableView.selectedRow
        guard row >= 0, filtered.indices.contains(row) else { return }
        let entry = filtered[row]
        window?.close()
        entry.perform()
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        OverlayUI.makeRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = filtered[row]
        let id = NSUserInterfaceItemIdentifier("OverlayRow")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? OverlayResultRow) ?? OverlayResultRow()
        cell.identifier = id
        cell.iconView.image = entry.icon
        cell.titleLabel.stringValue = entry.title
        cell.subtitleLabel.stringValue = entry.subtitle
        return cell
    }

    var testFilteredEntries: [Entry] { filtered }
}
