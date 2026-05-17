import AppKit

/// NSBrowser-based Miller column view. The browser owns the per-column data
/// (each column is the contents of one path component); we drive its delegate
/// from the active tab's DirectoryModel for the root and use direct filesystem
/// calls for deeper columns.
final class ColumnViewController: NSViewController, NSBrowserDelegate {

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

        reload()
    }

    func reload() {
        guard let pane = pane else { return }
        columnURLs = [pane.currentURL]
        browser.loadColumnZero()
    }

    private func entries(in url: URL) -> [URL] {
        guard let kids = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey, .nameKey],
            options: []
        ) else { return [] }
        let showHidden = pane?.testModel.showHidden ?? false
        let filtered = kids.filter { showHidden || !$0.lastPathComponent.hasPrefix(".") }
        return filtered.sorted { a, b in
            let aDir = (try? a.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let bDir = (try? b.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if aDir != bDir { return aDir }
            return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
    }

    // MARK: NSBrowserDelegate

    func browser(_ sender: NSBrowser, numberOfRowsInColumn column: Int) -> Int {
        let url = columnURLs.indices.contains(column) ? columnURLs[column] : columnURLs.last!
        return entries(in: url).count
    }

    func browser(_ sender: NSBrowser, willDisplayCell cell: Any, atRow row: Int, column: Int) {
        guard let cell = cell as? NSBrowserCell,
              let url = columnURLs.indices.contains(column) ? columnURLs[column] : nil else { return }
        let kids = entries(in: url)
        guard kids.indices.contains(row) else { return }
        let kid = kids[row]
        cell.title = kid.lastPathComponent
        let isDir = (try? kid.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        cell.isLeaf = !isDir
    }

    @objc private func handleSelection() {
        // When a row in column N is selected, push column N+1 if it's a folder.
        let col = browser.selectedColumn
        let row = browser.selectedRow(inColumn: col)
        guard col >= 0, row >= 0,
              columnURLs.indices.contains(col) else { return }
        let parent = columnURLs[col]
        let kids = entries(in: parent)
        guard kids.indices.contains(row) else { return }
        let sel = kids[row]
        let isDir = (try? sel.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        // Trim deeper columns
        if columnURLs.count > col + 1 {
            columnURLs = Array(columnURLs.prefix(col + 1))
        }
        if isDir {
            columnURLs.append(sel)
            browser.addColumn()
            browser.scrollColumnToVisible(col + 1)
        }
    }

    @objc private func handleDoubleClick() {
        let col = browser.selectedColumn
        let row = browser.selectedRow(inColumn: col)
        guard col >= 0, row >= 0,
              columnURLs.indices.contains(col) else { return }
        let parent = columnURLs[col]
        let kids = entries(in: parent)
        guard kids.indices.contains(row) else { return }
        let sel = kids[row]
        let isDir = (try? sel.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        if isDir {
            pane?.navigate(to: sel)
        } else {
            NSWorkspace.shared.open(sel)
        }
    }
}
