import AppKit

/// NSBrowser-based Miller column view. The browser owns the per-column data
/// (each column is the contents of one path component); we drive its delegate
/// from the active tab's DirectoryModel for the root and use direct filesystem
/// calls for deeper columns.
final class ColumnViewController: NSViewController, NSBrowserDelegate, ThemeObserving {

    weak var pane: PaneController?
    private let browser = NSBrowser()
    /// For each column index, the directory URL whose contents that column shows.
    private var columnURLs: [URL] = []

    init(pane: PaneController) {
        self.pane = pane
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        browser.translatesAutoresizingMaskIntoConstraints = false
        browser.delegate = self
        browser.cellPrototype = NSBrowserCell()
        browser.hasHorizontalScroller = true
        browser.minColumnWidth = 180
        browser.allowsMultipleSelection = true
        browser.allowsEmptySelection = true
        browser.target = self
        browser.action = #selector(handleSelection)
        browser.doubleAction = #selector(handleDoubleClick)
        browser.takesTitleFromPreviousColumn = true
        browser.maxVisibleColumns = 4

        let host = NSView()
        host.addSubview(browser)
        NSLayoutConstraint.activate([
            browser.topAnchor.constraint(equalTo: host.topAnchor),
            browser.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            browser.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            browser.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        self.view = host

        applyTheme()
        subscribeToTheme(self)
        reload()
    }

    @objc func applyTheme() {
        let t = ThemeManager.shared.current
        if t.id == "system" {
            browser.backgroundColor = .controlBackgroundColor
        } else {
            browser.backgroundColor = t.background
        }
    }

    func reload() {
        guard let pane = pane else { return }
        entryCache.removeAll()
        columnURLs = [pane.currentURL]
        browser.loadColumnZero()
    }

    private struct ColEntry { let url: URL; let isDir: Bool }
    /// Per-directory listing cache. NSBrowser calls `entries(in:)` once per
    /// visible cell *and* per row count, so without this the whole directory is
    /// re-read and re-stat-ed on every redraw — and resolving `isDir` once per
    /// entry (not twice per sort comparison) removes an O(n log n) stat storm.
    private var entryCache: [URL: [ColEntry]] = [:]

    private func entries(in url: URL) -> [ColEntry] {
        if let cached = entryCache[url] { return cached }
        // FastDirScan returns name + isDirectory from one lstat per entry —
        // far cheaper than contentsOfDirectory + a resourceValues call per URL.
        let showHidden = pane?.testModel.showHidden ?? false
        let resolved: [ColEntry] = FastDirScan.list(url).compactMap { e in
            if !showHidden && e.isHidden { return nil }
            return ColEntry(url: e.url, isDir: e.isDirectory)
        }
        let sorted = resolved.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
        }
        entryCache[url] = sorted
        return sorted
    }

    // MARK: NSBrowserDelegate

    func browser(_ sender: NSBrowser, numberOfRowsInColumn column: Int) -> Int {
        guard let url = columnURLs.indices.contains(column) ? columnURLs[column] : columnURLs.last
        else { return 0 }
        return entries(in: url).count
    }

    func browser(_ sender: NSBrowser, willDisplayCell cell: Any, atRow row: Int, column: Int) {
        guard let cell = cell as? NSBrowserCell,
              let url = columnURLs.indices.contains(column) ? columnURLs[column] : nil else { return }
        let kids = entries(in: url)
        guard kids.indices.contains(row) else { return }
        let kid = kids[row]
        cell.title = kid.url.lastPathComponent
        cell.isLeaf = !kid.isDir
    }

    @objc private func handleSelection() {
        // When a row in column N is selected, push column N+1 if it's a folder.
        let col = browser.selectedColumn
        let row = browser.selectedRow(inColumn: col)
        guard col >= 0, row >= 0,
              columnURLs.indices.contains(col) else { return }
        let kids = entries(in: columnURLs[col])
        guard kids.indices.contains(row) else { return }
        let sel = kids[row]
        // Trim deeper columns
        if columnURLs.count > col + 1 {
            columnURLs = Array(columnURLs.prefix(col + 1))
        }
        if sel.isDir {
            columnURLs.append(sel.url)
            browser.addColumn()
            browser.scrollColumnToVisible(col + 1)
        }
    }

    @objc private func handleDoubleClick() {
        let col = browser.selectedColumn
        let row = browser.selectedRow(inColumn: col)
        guard col >= 0, row >= 0,
              columnURLs.indices.contains(col) else { return }
        let kids = entries(in: columnURLs[col])
        guard kids.indices.contains(row) else { return }
        let sel = kids[row]
        if sel.isDir {
            pane?.navigate(to: sel.url)
        } else {
            NSWorkspace.shared.open(sel.url)
        }
    }
}
