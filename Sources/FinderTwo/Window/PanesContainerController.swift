import AppKit

/// Hosts 1..N PaneControllers in a horizontal split. Single-pane by default;
/// "Open Extra Pane" splits and adds a second pane. Each pane is independent.
final class PanesContainerController: NSSplitViewController {

    var onActivePathChange: ((URL) -> Void)?

    private var panes: [PaneController] = []
    private(set) var activeIndex: Int = 0

    /// Synchronized browsing: navigating one pane mirrors the relative path
    /// change onto the others. Off by default; toggled from the View menu.
    private(set) var syncBrowsing = false
    private var paneLastURL: [ObjectIdentifier: URL] = [:]
    private var isMirroring = false
    var testSyncBrowsing: Bool { syncBrowsing }
    var activePane: PaneController? {
        panes.indices.contains(activeIndex) ? panes[activeIndex] : nil
    }
    var testPaneCount: Int { panes.count }
    var allPanes: [PaneController] { panes }

    func addPaneForRestore(snap: [String: Any]) {
        guard let urls = snap["urls"] as? [String],
              let first = urls.first,
              FileManager.default.fileExists(atPath: first) else { return }
        let pane = addPane(at: URL(fileURLWithPath: first), activate: false)
        pane.restoreFromSnapshot(snap)
    }

    private let initialURL: URL
    init(initialURL: URL) {
        self.initialURL = initialURL
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        addPane(at: initialURL, activate: true)
    }

    func toggleExtraPane() {
        if panes.count == 1 {
            let url = panes[0].currentURL
            addPane(at: url, activate: true)
        } else if panes.count > 1 {
            let removeIndex = panes.count - 1
            let pane = panes.remove(at: removeIndex)
            removeSplitViewItem(splitViewItems[removeIndex])
            pane.removeFromParent()
            if activeIndex >= panes.count { activeIndex = panes.count - 1 }
            updateAfterActiveChange()
        }
    }

    func closePane(_ pane: PaneController) {
        guard panes.count > 1 else { return }
        if let idx = panes.firstIndex(where: { $0 === pane }) {
            let removed = panes.remove(at: idx)
            removeSplitViewItem(splitViewItems[idx])
            removed.removeFromParent()
            if activeIndex >= panes.count { activeIndex = panes.count - 1 }
            updateAfterActiveChange()
        }
    }

    @discardableResult
    private func addPane(at url: URL, activate: Bool) -> PaneController {
        let pane = PaneController(url: url)
        pane.onBecomeActive = { [weak self, weak pane] in
            guard let self, let pane else { return }
            if let idx = self.panes.firstIndex(where: { $0 === pane }) {
                self.activeIndex = idx
                self.updateAfterActiveChange()
            }
        }
        pane.onURLChange = { [weak self, weak pane] url in
            guard let self, let pane else { return }
            let key = ObjectIdentifier(pane)
            let old = self.paneLastURL[key] ?? url
            self.paneLastURL[key] = url
            if let idx = self.panes.firstIndex(where: { $0 === pane }), idx == self.activeIndex {
                if self.syncBrowsing, !self.isMirroring, self.panes.count > 1 {
                    self.mirrorNavigation(from: old, to: url, sourcePane: pane)
                }
                self.onActivePathChange?(url)
            }
            pane.view.window?.invalidateRestorableState()
        }
        let item = NSSplitViewItem(viewController: pane)
        item.minimumThickness = 280
        item.holdingPriority = .defaultLow
        addSplitViewItem(item)
        panes.append(pane)
        paneLastURL[ObjectIdentifier(pane)] = url
        if activate {
            activeIndex = panes.count - 1
            updateAfterActiveChange()
        }
        return pane
    }

    /// Copy or move the active pane's selection into the OTHER pane's folder
    /// (dual-pane workflow). No-op with a single pane or empty selection.
    func transferSelectionToOtherPane(move: Bool) {
        guard panes.count > 1, let active = activePane else { return }
        let other = panes[(activeIndex + 1) % panes.count]
        let sel = active.selectedURLs()
        guard !sel.isEmpty else { return }
        FileOps.transfer(sel, into: other.currentURL, move: move, from: view.window)
    }

    /// Toggle synchronized browsing; re-baseline each pane's last URL so the
    /// first navigation after enabling mirrors from the current positions.
    func toggleSyncBrowsing() {
        syncBrowsing.toggle()
        for p in panes { paneLastURL[ObjectIdentifier(p)] = p.currentURL }
    }

    /// Apply the relative path change (`old`→`new`) on `sourcePane` to the other
    /// panes: pop the components that were removed, push the ones that were
    /// added, and navigate there if it exists. Exposed for tests.
    func mirrorNavigation(from old: URL, to new: URL, sourcePane: PaneController) {
        let oldC = old.pathComponents, newC = new.pathComponents
        var i = 0
        while i < min(oldC.count, newC.count) && oldC[i] == newC[i] { i += 1 }
        let up = oldC.count - i
        let down = Array(newC[i...])
        isMirroring = true
        defer { isMirroring = false }
        for p in panes where p !== sourcePane {
            var target = p.currentURL
            for _ in 0..<up { target.deleteLastPathComponent() }
            for c in down { target.appendPathComponent(c) }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue {
                p.navigate(to: target)
                paneLastURL[ObjectIdentifier(p)] = target
            }
        }
    }

    /// Move keyboard focus to the next/previous pane (wraps). No-op with one pane.
    func focusPane(by delta: Int) {
        guard panes.count > 1 else { return }
        activeIndex = (activeIndex + delta + panes.count) % panes.count
        updateAfterActiveChange()
        activePane?.focusFileList()
    }

    private func updateAfterActiveChange() {
        let multiPane = panes.count > 1
        for (i, p) in panes.enumerated() {
            p.setActive(i == activeIndex, showBorder: multiPane)
        }
        if let url = activePane?.currentURL {
            onActivePathChange?(url)
        }
    }
}
