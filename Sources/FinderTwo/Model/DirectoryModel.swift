import AppKit

protocol DirectoryModelDelegate: AnyObject {
    func directoryModelDidUpdate(_ model: DirectoryModel)
}

/// Loads + watches one directory. Holds the filtered/sorted item list shown in a pane.
final class DirectoryModel {
    weak var delegate: DirectoryModelDelegate?

    private(set) var url: URL
    private(set) var rawItems: [FileItem] = []
    private(set) var items: [FileItem] = []     // filtered + sorted

    var sort = SortDescriptor() { didSet { previousFilterAndItems = nil; recompute(forceSync: false) } }
    var showHidden = false { didSet { previousFilterAndItems = nil; recompute(forceSync: false) } }
    var filterText: String = "" {
        didSet {
            // Progressive filtering: if we already computed results for a prefix
            // of the new filter, narrow that result set instead of touching the
            // full raw list. Reset whenever the user shortens or otherwise
            // changes the filter.
            if oldValue.isEmpty || !filterText.hasPrefix(oldValue) || filterText == oldValue {
                previousFilterAndItems = nil
            } else {
                previousFilterAndItems = (oldValue, items)
            }
            recompute(forceSync: false)
        }
    }

    private var previousFilterAndItems: (filter: String, items: [FileItem])?

    private var watcher: DirectoryWatcher?
    private static let ioQueue = DispatchQueue(label: "FinderTwo.DirectoryModel.IO", qos: .userInitiated)
    private var loadGeneration: UInt64 = 0
    private var pendingReload = false
    private var lastReloadFinishedAt = Date.distantPast
    private var recomputeGeneration: UInt64 = 0

    init(url: URL) {
        self.url = url
        reload(sync: true)        // first load is sync so UI shows content immediately
        startWatcher()
    }

    func navigate(to url: URL) {
        guard url != self.url else { return }
        self.url = url
        if SidebarController.isTagURL(url) {
            // Tag smart folder: populate via Spotlight, no FS watcher.
            watcher?.stop()
            watcher = nil
            if let name = SidebarController.tagName(from: url) {
                TagIndex.filesWithTag(name) { [weak self] urls in
                    guard let self, self.url == url else { return }
                    self.rawItems = urls.compactMap { FileItem.load($0) }
                    self.recompute(forceSync: true)
                }
            }
            return
        }
        reload(sync: true)
        startWatcher()
    }

    /// Trigger a reload. By default async on a background queue. Set sync=true
    /// for the initial load and explicit navigations so the user sees content
    /// before the run loop returns.
    func reload(sync: Bool = false) {
        if sync {
            doLoad(generation: bumpGeneration(), targetURL: url, applyOnMain: false)
            return
        }
        // Debounce: if a reload finished < 200ms ago and another is pending,
        // delay this one. If one is already pending, drop it (the pending one
        // will pick up the latest filesystem state).
        if pendingReload { return }
        pendingReload = true
        let gen = bumpGeneration()
        let target = url
        DirectoryModel.ioQueue.async { [weak self] in
            self?.doLoad(generation: gen, targetURL: target, applyOnMain: true)
        }
    }

    private func bumpGeneration() -> UInt64 {
        loadGeneration &+= 1
        return loadGeneration
    }

    private func doLoad(generation: UInt64, targetURL: URL, applyOnMain: Bool) {
        let t0 = Date()
        let entries = FastDirScan.list(targetURL)
        let t1 = Date()
        let raw = entries.map { FastDirScan.toFileItem($0) }
        let t2 = Date()

        let apply: () -> Void = { [weak self] in
            guard let self else { return }
            // Drop stale results from a previous URL or superseded load.
            guard generation == self.loadGeneration, targetURL == self.url else {
                self.pendingReload = false
                return
            }
            self.rawItems = raw
            // If this came from the sync path (applyOnMain == false), keep the
            // recompute synchronous so the items are visible when caller returns.
            self.recompute(forceSync: !applyOnMain)
            self.lastReloadFinishedAt = Date()
            self.pendingReload = false
            let t3 = Date()
            if raw.count > 1000 {
                NSLog("DM: reload \(self.url.lastPathComponent) n=\(raw.count) dir=\(Int(t1.timeIntervalSince(t0)*1000))ms load=\(Int(t2.timeIntervalSince(t1)*1000))ms sort=\(Int(t3.timeIntervalSince(t2)*1000))ms async=\(applyOnMain)")
            }
        }
        if applyOnMain {
            DispatchQueue.main.async(execute: apply)
        } else {
            apply()
        }
    }

    private func recompute(forceSync: Bool = false) {
        // Progressive filtering shortcut: if the new filter is just an extension
        // of the previous filter, narrow the prior result set. This avoids the
        // full O(rawItems.count) scan + sort per keystroke.
        if let prior = previousFilterAndItems,
           !filterText.isEmpty,
           filterText.hasPrefix(prior.filter),
           filterText != prior.filter
        {
            let narrowed = prior.items.filter { DirectoryModel.fuzzyMatchStatic($0.name, needle: filterText) }
            self.items = narrowed
            recomputeGeneration &+= 1
            delegate?.directoryModelDidUpdate(self)
            return
        }

        // Cheap path: small list OR caller wants synchronous result.
        if forceSync || rawItems.count < 2_000 {
            self.items = computed(from: rawItems)
            recomputeGeneration &+= 1     // invalidate any in-flight async
            delegate?.directoryModelDidUpdate(self)
            return
        }
        // Hot path for big lists: snapshot the inputs, recompute off-main,
        // apply the result if no newer recompute has been queued.
        recomputeGeneration &+= 1
        let gen = recomputeGeneration
        let raw = rawItems
        let cfg = (sort: sort, showHidden: showHidden, filterText: filterText)
        DirectoryModel.ioQueue.async { [weak self] in
            guard let self else { return }
            let result = DirectoryModel.computeStatic(raw: raw,
                                                       sort: cfg.sort,
                                                       showHidden: cfg.showHidden,
                                                       filterText: cfg.filterText)
            DispatchQueue.main.async {
                guard gen == self.recomputeGeneration else { return }
                self.items = result
                self.delegate?.directoryModelDidUpdate(self)
            }
        }
    }

    private func computed(from raw: [FileItem]) -> [FileItem] {
        DirectoryModel.computeStatic(raw: raw,
                                     sort: sort,
                                     showHidden: showHidden,
                                     filterText: filterText)
    }

    private static func computeStatic(raw: [FileItem],
                                      sort: SortDescriptor,
                                      showHidden: Bool,
                                      filterText: String) -> [FileItem] {
        var arr = raw
        if !showHidden { arr.removeAll { $0.isHidden } }
        if !filterText.isEmpty {
            arr = arr.filter { fuzzyMatchStatic($0.name, needle: filterText) }
        }
        arr.sort(by: sort.compare)
        return arr
    }

    private static func fuzzyMatchStatic(_ haystack: String, needle: String) -> Bool {
        if haystack.localizedCaseInsensitiveContains(needle) { return true }
        let h = haystack.lowercased()
        let n = needle.lowercased()
        var hi = h.startIndex
        for ch in n {
            guard let f = h[hi...].firstIndex(of: ch) else { return false }
            hi = h.index(after: f)
        }
        return true
    }

    private func startWatcher() {
        watcher?.stop()
        watcher = DirectoryWatcher(url: url) { [weak self] in
            DispatchQueue.main.async {
                self?.reload(sync: false)
            }
        }
        watcher?.start()
    }

    deinit {
        watcher?.stop()
    }
}
