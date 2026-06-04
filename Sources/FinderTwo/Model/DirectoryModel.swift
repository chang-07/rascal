import AppKit

protocol DirectoryModelDelegate: AnyObject {
    func directoryModelDidUpdate(_ model: DirectoryModel)
    /// Git state (badges/branch) changed but the item list did not — lets the
    /// pane refresh badges cheaply instead of doing a full table reload.
    func directoryModelDidUpdateGitStatus(_ model: DirectoryModel)
}

extension DirectoryModelDelegate {
    func directoryModelDidUpdateGitStatus(_ model: DirectoryModel) {
        directoryModelDidUpdate(model)
    }
}

/// Loads + watches one directory. Holds the filtered/sorted item list shown in a pane.
final class DirectoryModel {
    weak var delegate: DirectoryModelDelegate?

    private(set) var url: URL
    private(set) var rawItems: [FileItem] = []
    private(set) var items: [FileItem] = []     // filtered + sorted

    /// Git working-tree state for entries in this directory (filename → state),
    /// plus the enclosing repo's branch/ahead-behind. Computed asynchronously
    /// after each load; empty when the directory isn't inside a git repo.
    private(set) var gitStates: [String: GitStatus.FileState] = [:]
    private(set) var gitRepoInfo: GitStatus.RepoInfo?
    private static let gitQueue = DispatchQueue(label: "FinderTwo.git", qos: .utility)

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
    /// Set when a watcher event arrives while a reload is already in flight, so
    /// we run exactly one trailing reload afterward (no lost filesystem changes).
    private var reloadAgain = false
    private var recomputeGeneration: UInt64 = 0

    init(url: URL) {
        self.url = url
        reload(sync: true)        // first load is sync so UI shows content immediately
        startWatcher()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: Settings.didChange, object: nil)
    }

    func navigate(to url: URL) {
        guard url != self.url else { return }
        self.url = url
        filterText = ""   // a freshly-entered folder starts unfiltered (Finder behavior)
        if SidebarController.isRecentsURL(url) {
            // Recents smart folder: recently-modified files via Spotlight.
            watcher?.stop()
            watcher = nil
            TagIndex.recentFiles { [weak self] urls in
                guard let self, self.url == url else { return }
                self.rawItems = urls.compactMap { FileItem.load($0) }
                self.recompute(forceSync: true)
            }
            return
        }
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
        if SidebarController.isSmartFolderURL(url) {
            // Saved search: re-run the stored query via Spotlight, no watcher.
            watcher?.stop()
            watcher = nil
            rawItems = []
            recompute(forceSync: true)
            if let id = SidebarController.smartFolderId(from: url),
               let folder = SmartFolders.find(id: id) {
                SmartFolders.run(folder) { [weak self] urls in
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
        if pendingReload { reloadAgain = true; return }
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
            self.pendingReload = false
            // A watcher event that arrived mid-reload → run one trailing reload
            // so late filesystem changes aren't dropped.
            if self.reloadAgain {
                self.reloadAgain = false
                self.reload(sync: false)
            }
            self.scheduleGitStatus()
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

    /// Coalesce git recomputes: the directory watcher reloads on every file
    /// change, so an active repo / build / `npm install` would otherwise spawn a
    /// `git status` subprocess per event. Debounce to one run per quiet period.
    private var gitDebounce: DispatchWorkItem?
    private func scheduleGitStatus() {
        guard Settings.gitIntegrationEnabled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.gitDebounce?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.computeGitStatus() }
            self.gitDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    @objc private func settingsChanged() {
        if !Settings.gitIntegrationEnabled {
            gitDebounce?.cancel()
            if !gitStates.isEmpty || gitRepoInfo != nil {
                gitStates = [:]
                gitRepoInfo = nil
                delegate?.directoryModelDidUpdateGitStatus(self)
            }
        } else {
            if gitStates.isEmpty && gitRepoInfo == nil {
                scheduleGitStatus()
            }
        }
    }

    /// Compute git state for the current directory off-main, then publish on
    /// the main queue (dropping results if the directory changed meanwhile).
    private func computeGitStatus() {
        let dir = url
        let gen = loadGeneration
        DirectoryModel.gitQueue.async { [weak self] in
            let root = GitStatus.repoRoot(for: dir)
            let info = root.map { GitStatus.repoInfo(root: $0) }
            let states = root.map { GitStatus.fileStates(in: dir, repoRoot: $0) } ?? [:]
            DispatchQueue.main.async {
                guard let self, gen == self.loadGeneration, dir == self.url else { return }
                let changed = self.gitStates != states || self.gitRepoInfo != info
                self.gitStates = states
                self.gitRepoInfo = info
                // Items are unchanged here — only badges/branch. Use the light
                // path so we don't trigger a full table reload + map rebuild.
                if changed { self.delegate?.directoryModelDidUpdateGitStatus(self) }
            }
        }
    }

    /// Test hook: compute git state synchronously on the calling thread.
    func testRefreshGitSync() {
        guard let root = GitStatus.repoRoot(for: url) else {
            gitStates = [:]; gitRepoInfo = nil; return
        }
        gitRepoInfo = GitStatus.repoInfo(root: root)
        gitStates = GitStatus.fileStates(in: url, repoRoot: root)
    }

    /// Test hook: apply the current sort / showHidden / filterText synchronously
    /// and return the resulting item count. The live recompute uses an off-main
    /// hot path for large lists whose apply does not drain inside the FT_RUN_TESTS
    /// nested run loop — this measures the real filter+sort cost deterministically.
    @discardableResult
    func testApplyComputeSync() -> Int {
        items = computed(from: rawItems)
        recomputeGeneration &+= 1
        delegate?.directoryModelDidUpdate(self)
        return items.count
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
        NotificationCenter.default.removeObserver(self)
    }
}
