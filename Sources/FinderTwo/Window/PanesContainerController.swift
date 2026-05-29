import AppKit

/// Hosts 1..N PaneControllers in a horizontal split. Single-pane by default;
/// "Open Extra Pane" splits and adds a second pane. Each pane is independent.
final class PanesContainerController: NSSplitViewController {

    var onActivePathChange: ((URL) -> Void)?

    private var panes: [PaneController] = []
    private(set) var activeIndex: Int = 0
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
            if let idx = self.panes.firstIndex(where: { $0 === pane }), idx == self.activeIndex {
                self.onActivePathChange?(url)
            }
            pane.view.window?.invalidateRestorableState()
        }
        let item = NSSplitViewItem(viewController: pane)
        item.minimumThickness = 280
        item.holdingPriority = .defaultLow
        addSplitViewItem(item)
        panes.append(pane)
        if activate {
            activeIndex = panes.count - 1
            updateAfterActiveChange()
        }
        return pane
    }

    /// Move keyboard focus to the next/previous pane (wraps). No-op with one pane.
    func focusPane(by delta: Int) {
        guard panes.count > 1 else { return }
        activeIndex = (activeIndex + delta + panes.count) % panes.count
        updateAfterActiveChange()
        activePane?.focusFileList()
    }

    private func updateAfterActiveChange() {
        for (i, p) in panes.enumerated() {
            p.setActive(i == activeIndex)
        }
        if let url = activePane?.currentURL {
            onActivePathChange?(url)
        }
    }
}
