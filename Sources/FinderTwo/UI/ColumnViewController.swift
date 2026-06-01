import AppKit

/// NSBrowser reports a content-driven intrinsic size (≈ visible columns × column
/// width), so pushing/popping columns changed the view's fitting size — a second
/// path (besides the split controller's preferredContentSize) that could nudge
/// the window. Returning noIntrinsicMetric decouples column count from layout
/// size; the browser fills its host via edge constraints and scrolls instead.
private final class FixedWidthBrowser: NSBrowser {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
    /// NSBrowser.tile() grows the browser's OWN frame to fit every column, which —
    /// through the window's constraint-based layout — widened the whole window as
    /// columns were pushed (confirmed in the trace as
    /// -[NSWindow _changeWindowFrameFromConstraintsIfNecessary]). Clamp the width to
    /// the host so NSBrowser keeps its frame fixed and uses its horizontal scroller
    /// instead of widening itself (and the window).
    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        if let cap = superview?.bounds.width, cap > 0 {
            size.width = min(size.width, cap)
        }
        super.setFrameSize(size)
    }
}

/// NSBrowser-based Miller column view. The browser owns the per-column data
/// (each column is the contents of one path component); we drive its delegate
/// from the active tab's DirectoryModel for the root and use direct filesystem
/// calls for deeper columns.
final class ColumnViewController: NSViewController, NSBrowserDelegate, ThemeObserving {

    weak var pane: PaneController?
    private let browser = FixedWidthBrowser()
    /// For each column index, the directory URL whose contents that column shows.
    private var columnURLs: [URL] = []

    init(pane: PaneController) {
        self.pane = pane
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        browser.translatesAutoresizingMaskIntoConstraints = true   // autoresizing, not constraints (see host setup)
        browser.delegate = self
        browser.cellPrototype = NSBrowserCell()
        browser.hasHorizontalScroller = true
        browser.minColumnWidth = 180
        // Fixed-width columns, no user/auto column resizing. .userColumnResizing
        // makes NSBrowser manage column widths dynamically, which imposes a
        // content-driven width demand that pushed the window/panes around as you
        // drilled. .noColumnResizing pins every column to defaultColumnWidth so the
        // browser's width is constant; overflow scrolls horizontally.
        browser.columnResizingType = .noColumnResizing
        browser.setDefaultColumnWidth(220)
        browser.allowsMultipleSelection = true
        browser.allowsEmptySelection = true
        browser.target = self
        browser.action = #selector(handleSelection)
        browser.doubleAction = #selector(handleDoubleClick)
        browser.takesTitleFromPreviousColumn = true
        // No maxVisibleColumns target — NSBrowser uses the available width and the
        // horizontal scroller, never asking to grow to show a fixed column count.
        // Host the browser with autoresizing springs, NOT AutoLayout constraints.
        // NSBrowser's columns impose a *required* minimum width; pinned to the host
        // with required edge constraints, that demand propagated up and made AppKit
        // grow the whole window to fit as columns were pushed — confirmed in the
        // trace as -[NSWindow _changeWindowFrameFromConstraintsIfNecessary]. Springs
        // keep the demand contained: the browser just fills the host (kept in sync in
        // viewDidLayout) and scrolls columns horizontally instead of widening the
        // window.
        let host = NSView()
        browser.autoresizingMask = [.width, .height]
        host.addSubview(browser)
        self.view = host

        applyTheme()
        subscribeToTheme(self)
        reload()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        browser.frame = view.bounds   // fill the host without participating in its constraints
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

    /// Verify hook: drill into the first subfolder of the deepest column (push a column).
    @discardableResult
    func testDrillIntoFirstFolder() -> Bool {
        let col = max(0, columnURLs.count - 1)
        guard columnURLs.indices.contains(col) else { return false }
        let kids = entries(in: columnURLs[col])
        guard let row = kids.firstIndex(where: { $0.isDir }) else { return false }
        browser.selectRow(row, inColumn: col)
        handleSelection()
        return true
    }
    var testColumnCount: Int { columnURLs.count }
    var testBrowserWidth: CGFloat { browser.frame.width }

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
