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

    /// Maximum simultaneous panes (columns). Beyond this the columns get too
    /// narrow to be useful and the multi-pane workflow value drops off.
    static let maxPanes = 4
    var canAddPane: Bool { panes.count < Self.maxPanes }

    /// Add another column at the active pane's current folder (up to `maxPanes`)
    /// and make it active. The session/Workspace snapshot already captures every
    /// pane, so the extra columns persist and restore automatically.
    func addExtraPane() {
        guard canAddPane, let active = activePane else { return }
        addPane(at: active.currentURL, activate: true)
    }

    /// Close the active pane (down to a minimum of one).
    func closeActivePane() {
        guard panes.count > 1, let active = activePane else { return }
        closePane(active)
    }

    /// Remove the rightmost pane (used by layout restore to prune surplus panes).
    func removeLastPane() {
        guard panes.count > 1 else { return }
        closePane(panes[panes.count - 1])
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

    // MARK: Divider layout (save / restore)

    /// Capture each divider's position as a FRACTION of the split view's content
    /// width (0…1), so the layout restores proportionally regardless of the
    /// window size at restore time. With N panes there are N-1 dividers; an
    /// empty array means "no custom sizing" (panes fall back to equal widths).
    func dividerFractions() -> [Double] {
        let count = splitView.arrangedSubviews.count
        guard count > 1 else { return [] }
        let total = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        guard total > 1 else { return [] }
        var fractions: [Double] = []
        // The position of divider i is the trailing edge of arranged subview i.
        var running: CGFloat = 0
        for i in 0..<(count - 1) {
            let v = splitView.arrangedSubviews[i]
            running += splitView.isVertical ? v.frame.width : v.frame.height
            fractions.append(Double(max(0, min(1, running / total))))
        }
        return fractions
    }

    /// Apply previously captured divider fractions (see `dividerFractions`).
    /// Runs after the next layout pass so the split view already has its final
    /// bounds — setting positions against a zero-width split view would clamp
    /// everything to the minimum thickness.
    func applyDividerFractions(_ fractions: [Double]) {
        guard !fractions.isEmpty else { return }
        pendingDividerFractions = fractions
        view.needsLayout = true
        // Defer to the next runloop turn: during launch/restore the split view's
        // bounds aren't established until the window has been sized, and tests
        // build controllers without ever showing the window.
        DispatchQueue.main.async { [weak self] in self?.applyPendingDividerFractions() }
    }

    /// Divider fractions captured from a snapshot, waiting for the split view to
    /// gain non-zero bounds before they can be applied.
    private var pendingDividerFractions: [Double]?
    /// Re-entrancy guard: setPosition() dirties layout, so applying fractions can
    /// itself trigger another viewDidLayout. Without this, viewDidLayout →
    /// applyPendingDividerFractions → setPosition → viewDidLayout … can loop.
    private var isApplyingDividerFractions = false

    private func applyPendingDividerFractions() {
        guard !isApplyingDividerFractions else { return }
        guard let fractions = pendingDividerFractions else { return }
        let count = splitView.arrangedSubviews.count
        // Need one fraction per divider; bail (and keep them pending) until the
        // pane set and the split view bounds are both ready.
        guard count > 1, fractions.count == count - 1 else { return }
        let total = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        guard total > 1 else { return }   // not laid out yet — try again after layout
        isApplyingDividerFractions = true
        defer { isApplyingDividerFractions = false }
        // Clear FIRST so this is strictly one-shot: even if setPosition re-enters
        // viewDidLayout synchronously, there's nothing left pending to re-apply.
        pendingDividerFractions = nil
        // Don't force layout here — we may be inside a layout pass (viewDidLayout);
        // the guards above already confirm the split view has real bounds, which is
        // all setPosition needs.
        for (i, f) in fractions.enumerated() {
            splitView.setPosition(CGFloat(f) * total, ofDividerAt: i)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Apply any pending restore once the split view finally has real bounds.
        applyPendingDividerFractions()
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
