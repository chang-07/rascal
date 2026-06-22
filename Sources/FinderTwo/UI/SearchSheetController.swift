import AppKit

/// One sheet with two modes:
///   - `.fuzzyFilenames` (Cmd+F): in-process fuzzy match across all filenames
///     in the current directory tree. fzf-like.
///   - `.contentGrep` (Cmd+Shift+F): full-text search of file contents.
///     Prefers ripgrep (`rg`) if installed; falls back to BSD `grep -nr`.
///
/// Both modes run on background queues and stream results into the table as
/// they arrive. Enter on a result navigates the active pane to that file's
/// containing folder and selects it.
final class SearchSheetController: NSWindowController, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, ThemeObserving {

    enum Mode { case fuzzyFilenames, contentGrep }

    private weak var target: BrowserWindowController?
    let mode: Mode
    private let rootURL: URL

    private let searchField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    private struct Hit {
        let url: URL
        let title: String       // primary line ("path/to/file.swift" or "file.swift:42: snippet")
        let subtitle: String    // secondary line (parent path)
    }
    private var hits: [Hit] = []
    private var recentHits: [Hit] = []
    private var queryGeneration: UInt64 = 0
    private var indexCache: [URL]?      // filename mode prebuilds a list of all files under root

    private static let bgQueue = DispatchQueue(label: "FinderTwo.Search", qos: .userInitiated)
    private var currentTask: Process?

    static func show(for wc: BrowserWindowController, mode: Mode) {
        // Single-instance: re-triggering the same mode toggles it closed; any
        // other open finder (the other search mode, or the palette) is replaced
        // so only one floating finder is ever on screen.
        if let open = PresentedControllers.existing(SearchSheetController.self) {
            let sameMode = open.mode == mode
            open.close()
            if sameMode { return }
        }
        PresentedControllers.existing(CommandPaletteController.self)?.close()
        guard let pane = wc.testActivePane else { return }
        let s = SearchSheetController(target: wc, mode: mode, rootURL: pane.currentURL)
        PresentedControllers.retain(s)
        if let w = s.window { OverlayUI.present(w, over: wc.window) }
        s.window?.makeFirstResponder(s.searchField)
    }

    init(target: BrowserWindowController, mode: Mode, rootURL: URL) {
        self.target = target
        self.mode = mode
        self.rootURL = rootURL
        // Same floating HUD panel as the Command Palette, so the three finders
        // (palette, find, grep) feel like one control.
        let win = OverlayUI.makePanel()
        win.title = mode == .fuzzyFilenames ? "Find Files" : "Search File Contents"
        super.init(window: win)
        layout()
        if mode == .fuzzyFilenames {
            startFilenameIndex()
            loadRecentFiles()
        }
        subscribeToTheme(self)
    }

    private func loadRecentFiles() {
        TagIndex.recentFiles { [weak self] urls in
            guard let self else { return }
            self.recentHits = urls.map { url in
                Hit(url: url,
                    title: url.lastPathComponent,
                    subtitle: url.deletingLastPathComponent().path)
            }
            if self.searchField.stringValue.isEmpty {
                self.hits = self.recentHits
                let suffix = self.indexCache.map { " · \($0.count) files indexed" } ?? ""
                self.statusLabel.stringValue = "Recent files" + suffix
                self.tableView.reloadData()
                if !self.hits.isEmpty {
                    self.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                }
            }
        }
    }

    @objc func applyTheme() {
        let t = ThemeManager.shared.current
        let custom = t.id != "system"
        searchField.textColor = custom ? t.labelPrimary : .controlTextColor
        searchField.backgroundColor = custom ? t.pathBarBackground : .controlBackgroundColor
        searchField.drawsBackground = true
        statusLabel.textColor = custom ? t.labelSecondary : .secondaryLabelColor
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func layout() {
        guard let cv = window?.contentView else { return }
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.font = .systemFont(ofSize: 16)
        searchField.bezelStyle = .roundedBezel
        searchField.focusRingType = .none
        searchField.placeholderString = mode == .fuzzyFilenames
            ? "Fuzzy filename… (within \(rootURL.lastPathComponent))"
            : "grep pattern… (within \(rootURL.lastPathComponent))"
        searchField.delegate = self

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(activateSelection)
        OverlayUI.configureResultsTable(tableView)
        OverlayUI.configureResultsScroll(scrollView, documentView: tableView)

        cv.addSubview(searchField)
        cv.addSubview(scrollView)
        cv.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: cv.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -14),
            searchField.heightAnchor.constraint(equalToConstant: 30),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),

            statusLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -14),
            statusLabel.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -8),
        ])
    }

    // MARK: Filename index

    private func startFilenameIndex() {
        statusLabel.stringValue = "Indexing…"
        let root = rootURL
        SearchSheetController.bgQueue.async { [weak self] in
            var list: [URL] = []
            let fm = FileManager.default
            // Only prune protected dirs when searching from OUTSIDE the protected
            // tree (e.g. from ~/ we skip descending into ~/Documents to avoid a TCC
            // prompt). When the search root is itself protected, the user explicitly
            // chose to search inside it — pruning there would drop every nested
            // result and return only the top-level files.
            let pruneProtected = !PermissionsManager.hasFullDiskAccess
                && !PermissionsManager.isProtectedPath(root.path)
            if let en = fm.enumerator(at: root,
                                      includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                                      options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                      errorHandler: nil) {
                while let u = en.nextObject() as? URL {
                    if pruneProtected && PermissionsManager.isProtectedPath(u.path) {
                        if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                            en.skipDescendants()
                        }
                    }
                    list.append(u)
                    if list.count >= 200_000 { break }    // safety cap
                }
            }
            DispatchQueue.main.async {
                self?.indexCache = list
                self?.statusLabel.stringValue = "\(list.count) files indexed"
                self?.runQueryIfNeeded()
            }
        }
    }

    // MARK: Query dispatch

    private func runQueryIfNeeded() {
        queryGeneration &+= 1
        let gen = queryGeneration
        let q = searchField.stringValue
        if q.isEmpty {
            if mode == .fuzzyFilenames {
                hits = recentHits
                tableView.reloadData()
                if !hits.isEmpty {
                    tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                }
                let suffix = indexCache.map { " · \($0.count) files indexed" } ?? ""
                statusLabel.stringValue = "Recent files" + suffix
            } else {
                hits = []
                tableView.reloadData()
                statusLabel.stringValue = "Type to search"
            }
            return
        }
        switch mode {
        case .fuzzyFilenames:
            guard let index = indexCache else { return }
            SearchSheetController.bgQueue.async { [weak self] in
                let results = SearchSheetController.fuzzyFilter(index, needle: q, limit: 500)
                DispatchQueue.main.async {
                    guard let self, gen == self.queryGeneration else { return }
                    self.hits = results.map { url in
                        Hit(url: url,
                            title: url.lastPathComponent,
                            subtitle: url.deletingLastPathComponent().path)
                    }
                    self.statusLabel.stringValue = "\(results.count) match\(results.count == 1 ? "" : "es")"
                    self.tableView.reloadData()
                    if !self.hits.isEmpty {
                        self.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                    }
                }
            }
        case .contentGrep:
            currentTask?.terminate()
            currentTask = nil
            hits = []
            tableView.reloadData()
            statusLabel.stringValue = "Searching…"
            runGrep(pattern: q, generation: gen)
        }
    }

    /// Test hook: pure fuzzy filtering over a URL list. Mirrors what the
    /// filename-search mode uses internally.
    static func testFuzzy(_ urls: [URL], needle: String, limit: Int = 500) -> [URL] {
        return fuzzyFilter(urls, needle: needle, limit: limit)
    }

    private static func fuzzyFilter(_ urls: [URL], needle: String, limit: Int) -> [URL] {
        let nLower = needle.lowercased()
        let exact = needle.contains(" ") ? nil : nLower
        var scored: [(URL, Int)] = []
        for u in urls {
            let name = u.lastPathComponent.lowercased()
            if let exact, name.contains(exact) {
                let s = 1000 - name.count + (name.hasPrefix(exact) ? 500 : 0)
                scored.append((u, s))
            } else if SearchSheetController.subseq(name, n: nLower) {
                scored.append((u, 100 - name.count))
            }
            if scored.count > limit * 4 { break }
        }
        scored.sort { $0.1 > $1.1 }
        return scored.prefix(limit).map { $0.0 }
    }

    private static func subseq(_ h: String, n: String) -> Bool {
        if n.isEmpty { return true }
        var idx = h.startIndex
        for ch in n {
            guard let f = h[idx...].firstIndex(of: ch) else { return false }
            idx = h.index(after: f)
        }
        return true
    }

    // MARK: ripgrep / grep

    private func runGrep(pattern: String, generation: UInt64) {
        let task = Process()
        let pipe = Pipe()
        let rgPath = SearchSheetController.toolPath("rg")
        let grepPath = SearchSheetController.toolPath("grep")
        
        var ignores: [String] = []
        if !PermissionsManager.hasFullDiskAccess {
            let home = NSHomeDirectory()
            let protectedSubdirs = ["Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures"]
            let normalizedRoot = rootURL.path.hasSuffix("/") ? rootURL.path : (rootURL.path + "/")
            for sub in protectedSubdirs {
                let path = (home as NSString).appendingPathComponent(sub)
                if path.hasPrefix(normalizedRoot) && path != rootURL.path {
                    ignores.append(sub)
                }
            }
        }

        if let rg = rgPath {
            task.executableURL = URL(fileURLWithPath: rg)
            var args = [
                "--no-config", "--no-heading", "--line-number", "--color", "never",
                "--max-count", "10",
                "--max-filesize", "5M",
                "--smart-case"
            ]
            for sub in ignores {
                args.append(contentsOf: ["--glob", "!\(sub)"])
            }
            args.append(contentsOf: ["--", pattern, rootURL.path])   // -- so a pattern starting with '-' can't be read as a flag
            task.arguments = args
        } else if let g = grepPath {
            task.executableURL = URL(fileURLWithPath: g)
            var args = ["-nrI", "--include=*"]
            for sub in ignores {
                args.append("--exclude-dir=\(sub)")
            }
            args.append(contentsOf: ["--", pattern, rootURL.path])   // -- so a pattern starting with '-' can't be read as a flag
            task.arguments = args
        } else {
            statusLabel.stringValue = "No grep/rg available"
            return
        }
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice  // unused; nullDevice avoids a full-pipe deadlock

        currentTask = task
        SearchSheetController.bgQueue.async { [weak self] in
            do {
                try task.run()
            } catch {
                DispatchQueue.main.async {
                    self?.statusLabel.stringValue = "Failed to launch search"
                }
                return
            }
            // Read incrementally, batching output to the main queue.
            let fh = pipe.fileHandleForReading
            var pending = Data()
            while true {
                let chunk = fh.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                if let s = String(data: pending, encoding: .utf8) {
                    let parts = s.split(separator: "\n", omittingEmptySubsequences: false)
                    let complete = parts.dropLast()
                    let tail = parts.last.map(String.init) ?? ""
                    pending = Data(tail.utf8)
                    let lines = complete.map(String.init)
                    DispatchQueue.main.async {
                        guard let self, generation == self.queryGeneration else { return }
                        self.appendGrepLines(lines, generation: generation)
                    }
                }
                if pending.count > 1_000_000 { break } // safety
            }
            task.waitUntilExit()
            DispatchQueue.main.async {
                guard let self, generation == self.queryGeneration else { return }
                self.statusLabel.stringValue = "\(self.hits.count) match\(self.hits.count == 1 ? "" : "es")"
            }
        }
    }

    private func appendGrepLines(_ lines: [String], generation: UInt64) {
        guard generation == queryGeneration else { return }
        for line in lines {
            // Format: /path/to/file:LINE:SNIPPET
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let path = String(parts[0])
            let ln = String(parts[1])
            var snippet = String(parts[2])
            if snippet.count > 160 { snippet = String(snippet.prefix(160)) + "…" }
            let url = URL(fileURLWithPath: path)
            hits.append(Hit(url: url,
                            title: "\(url.lastPathComponent):\(ln)",
                            subtitle: snippet.trimmingCharacters(in: .whitespaces)))
            if hits.count > 2000 { break }
        }
        tableView.reloadData()
        if tableView.selectedRow < 0 && !hits.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    private static func toolPath(_ name: String) -> String? {
        for prefix in ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/", "/bin/"] {
            let p = prefix + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Demo/screenshot hook: synchronously index + fuzzy-filter so a capture
    /// shows real matches without waiting on the async search pipeline.
    func demoPopulate(query q: String) {
        _ = window?.contentView
        let fm = FileManager.default
        var list: [URL] = []
        let pruneProtected = !PermissionsManager.hasFullDiskAccess
            && !PermissionsManager.isProtectedPath(rootURL.path)
        if let en = fm.enumerator(at: rootURL,
                                  includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            while let u = en.nextObject() as? URL {
                if pruneProtected && PermissionsManager.isProtectedPath(u.path) {
                    if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        en.skipDescendants()
                    }
                }
                list.append(u)
                if list.count > 5000 { break }
            }
        }
        indexCache = list
        searchField.stringValue = q
        let results = SearchSheetController.fuzzyFilter(list, needle: q, limit: 30)
        hits = results.map { Hit(url: $0, title: $0.lastPathComponent, subtitle: $0.deletingLastPathComponent().path) }
        statusLabel.stringValue = "\(hits.count) match\(hits.count == 1 ? "" : "es") · \(list.count) files"
        tableView.reloadData()
        if !hits.isEmpty { tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        runQueryIfNeeded()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            if !hits.isEmpty {
                let next = min(tableView.selectedRow + 1, hits.count - 1)
                tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
                tableView.scrollRowToVisible(next)
            }
            return true
        case #selector(NSResponder.moveUp(_:)):
            if !hits.isEmpty {
                let prev = max(tableView.selectedRow - 1, 0)
                tableView.selectRowIndexes(IndexSet(integer: prev), byExtendingSelection: false)
                tableView.scrollRowToVisible(prev)
            }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            activateSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            closeSheet()
            return true
        default:
            return false
        }
    }

    @objc private func activateSelection() {
        let row = tableView.selectedRow
        guard row >= 0, hits.indices.contains(row) else { return }
        let h = hits[row]
        closeSheet()
        let pane = target?.testActivePane
        pane?.navigate(to: h.url.deletingLastPathComponent())
        DispatchQueue.main.async {
            pane?.select(url: h.url)
            pane?.focusFileList()
        }
    }

    @objc private func closeSheet() {
        currentTask?.terminate()
        if let w = window, let parent = w.sheetParent {
            parent.endSheet(w)
        } else {
            window?.close()
        }
    }

    // MARK: NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        OverlayUI.makeRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let h = hits[row]
        let id = NSUserInterfaceItemIdentifier("OverlayRow")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? OverlayResultRow) ?? OverlayResultRow()
        cell.identifier = id
        cell.monospacedSubtitle = (mode == .contentGrep)   // grep snippets read better monospaced
        cell.iconView.image = NSWorkspace.shared.icon(forFile: h.url.path)
        cell.titleLabel.stringValue = h.title
        cell.subtitleLabel.stringValue = h.subtitle
        return cell
    }
}
