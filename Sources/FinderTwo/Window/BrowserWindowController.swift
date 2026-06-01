import AppKit

/// NSSplitViewController drives the window size from `preferredContentSize`,
/// recomputing it whenever content layout changes — which made the *window*
/// auto-resize as Miller-view columns were pushed/popped (the "side panel"
/// size flicker). Pinning it to .zero ("no size preference") stops content from
/// ever resizing the window; initial sizing is done explicitly (setContentSize /
/// the autosaved frame) and the user's manual resizes stick.
private final class NonResizingSplitViewController: NSSplitViewController {
    override var preferredContentSize: NSSize {
        get { .zero }
        set { /* ignore content-driven updates */ }
    }
}

/// The window only changes SIZE in response to a user gesture — dragging the
/// resize edge (live resize), zoom, or a fullscreen transition. Every other
/// resize is ignored: AppKit trying to grow the window to satisfy the Miller-
/// column browser's constraints, AX clients, content layout, etc. So the window
/// stays exactly the size the user set. Moving it (origin only) is always honored.
final class UserResizeOnlyWindow: NSWindow {
    /// Enabled once the initial frame is established (the content-view-controller
    /// assignment and autosaved-frame restore must run first).
    var sizeLockedToUser = false
    /// Lifted around programmatic-but-wanted resizes (zoom / fullscreen transition).
    var allowProgrammaticResize = false

    private var sizeChangeAllowed: Bool {
        !sizeLockedToUser || inLiveResize || allowProgrammaticResize
    }

    override func setContentSize(_ size: NSSize) {
        guard sizeChangeAllowed else { return }
        super.setContentSize(size)
    }
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        if !sizeChangeAllowed,
           abs(frameRect.width - frame.width) > 0.5 || abs(frameRect.height - frame.height) > 0.5 {
            // Reject the size change but still honor a move (origin only).
            super.setFrame(NSRect(origin: frameRect.origin, size: frame.size), display: flag)
            return
        }
        super.setFrame(frameRect, display: flag)
    }
    override func zoom(_ sender: Any?) {
        allowProgrammaticResize = true
        super.zoom(sender)
        allowProgrammaticResize = false
    }
}

final class BrowserWindowController: NSWindowController, NSWindowDelegate, ThemeObserving {

    let splitVC: NSSplitViewController = NonResizingSplitViewController()
    let sidebarVC: SidebarController
    private let panesContainer: PanesContainerController
    private var vimKeyMonitor: Any?
    /// Off-main branch lookups for the window subtitle (reads .git/HEAD).
    private static let gitInfoQueue = DispatchQueue(label: "FinderTwo.windowGitInfo", qos: .utility)

    init(rootURL: URL) {
        self.sidebarVC = SidebarController()
        self.panesContainer = PanesContainerController(initialURL: rootURL)

        let initialFrame = NSRect(x: 200, y: 200, width: 1100, height: 700)
        let headless = ProcessInfo.processInfo.environment["FT_HEADLESS_TESTING"] == "1"
        let style: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        // Headless audit runs use a window that refuses screen-constraint, so it
        // can be parked far off-screen for AX presence without AppKit yanking it
        // back onto a display (which would make it visible to the user). The real
        // app uses a window that only resizes on a user gesture (see below).
        let window: NSWindow = headless
            ? OffscreenSafeWindow(contentRect: initialFrame, styleMask: style, backing: .buffered, defer: false)
            : UserResizeOnlyWindow(contentRect: initialFrame, styleMask: style, backing: .buffered, defer: false)
        window.title = rootURL.lastPathComponent
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 600, height: 360)
        super.init(window: window)
        // Force the frame after super.init — some macOS builds auto-fit on first show.
        window.setFrame(initialFrame, display: false)
        window.center()
        window.delegate = self

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 130
        sidebarItem.maximumThickness = 240
        sidebarItem.preferredThicknessFraction = 0.15   // ~165pt on the default window, capped at 240
        sidebarItem.canCollapse = true
        // High holding priority pins the sidebar to its set width so the main
        // pane absorbs window resizing instead of the sidebar ballooning.
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        splitVC.addSplitViewItem(sidebarItem)

        let mainItem = NSSplitViewItem(viewController: panesContainer)
        mainItem.minimumThickness = 360
        mainItem.holdingPriority = .defaultLow + 1
        splitVC.addSplitViewItem(mainItem)

        window.contentViewController = splitVC
        // Initial size is set explicitly below; splitVC.preferredContentSize is
        // pinned to .zero (NonResizingSplitViewController) so neither the initial
        // contentViewController assignment nor later column navigation can
        // auto-resize the window.
        let isHeadless = ProcessInfo.processInfo.environment["FT_HEADLESS_TESTING"] == "1"
        if !isHeadless {
            windowFrameAutosaveName = "FinderTwo.BrowserWindow"
            if !window.setFrameUsingName("FinderTwo.BrowserWindow") {
                window.setContentSize(NSSize(width: 1100, height: 700))
                if let screen = NSScreen.main {
                    let f = window.frame
                    let vf = screen.visibleFrame
                    let centered = NSRect(
                        x: vf.minX + (vf.width - f.width) / 2,
                        y: vf.minY + (vf.height - f.height) / 2,
                        width: f.width, height: f.height
                    )
                    window.setFrame(centered, display: false)
                }
            }
        } else {
            window.setContentSize(NSSize(width: 1100, height: 700))
        }
        // Initial size is now set (default or autosaved). From here the window only
        // resizes when the user drags its edge / zooms / goes fullscreen — content
        // (e.g. Miller-view column navigation) can no longer auto-grow it.
        (window as? UserResizeOnlyWindow)?.sizeLockedToUser = true

        sidebarVC.onSelect = { [weak self] url in
            self?.panesContainer.activePane?.navigate(to: url)
        }
        sidebarVC.onOpenInNewTab = { [weak self] url in
            self?.panesContainer.activePane?.newTab(at: url)
        }
        sidebarVC.onOpenInNewWindow = { url in
            (NSApp.delegate as? AppDelegate)?.openNewBrowserWindow(at: url)
        }
        panesContainer.onActivePathChange = { [weak self] url in
            guard let self else { return }
            let name = url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent
            self.window?.title = name
            let abbreviated = (url.deletingLastPathComponent().path as NSString)
                .abbreviatingWithTildeInPath
            self.window?.subtitle = abbreviated
            self.sidebarVC.highlight(url: url)
            // Git-bound workspaces: register this WC against the new path's
            // repo so branch changes restore the right tabs.
            GitBranchWorkspaces.shared.register(self, withCurrentURL: url)
            // Prefix the branch when inside a git repo. Reading .git/HEAD is disk
            // I/O, so do it off-main and fold it into the subtitle when it lands
            // (skip if the user has already navigated elsewhere).
            BrowserWindowController.gitInfoQueue.async { [weak self] in
                guard let root = GitBranchWorkspaces.repoRoot(for: url),
                      let branch = GitBranchWorkspaces.currentBranch(in: root) else { return }
                DispatchQueue.main.async {
                    guard let self, self.panesContainer.activePane?.currentURL == url else { return }
                    self.window?.subtitle = "⎇ \(branch)  ·  \(abbreviated)"
                }
            }
        }

        installVimKeyMonitor()
        applyTitleBarVisibility()
        NotificationCenter.default.addObserver(self, selector: #selector(chromeSettingsChanged),
                                               name: Settings.didChange, object: nil)
        subscribeToTheme(self)
    }

    @objc func applyTheme() {
        ThemeChrome.apply(to: window)
    }

    @objc private func chromeSettingsChanged() { applyTitleBarVisibility() }

    /// Show/hide the window title bar. Hidden = full-size content under a
    /// transparent, title-less bar (traffic lights remain). The sidebar gets a
    /// top inset so its rows clear the traffic lights.
    private func applyTitleBarVisibility() {
        guard let window = window else { return }
        if Settings.showTitleBar {
            window.styleMask.remove(.fullSizeContentView)
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            sidebarVC.setTopInset(0)
        } else {
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            sidebarVC.setTopInset(PaneController.hiddenTitleBarInset)
        }
    }

    /// Window-level key interception for vim mode. This makes hjkl etc. work no
    /// matter which subview has focus (sidebar, empty pane, etc.) — not just
    /// when the file-list table is first responder. Skips text fields / field
    /// editors so typing in search, rename, path bar, and terminal is normal.
    private func installVimKeyMonitor() {
        vimKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            
            if event.window === self.window, event.keyCode == 48 {
                let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
                if mods == .control {
                    self.focusNextPane(nil)
                    return nil
                } else if mods == [.control, .shift] {
                    self.focusPrevPane(nil)
                    return nil
                }
            }

            // Orthodox-commander function keys (work regardless of Vim mode):
            // F5 copy to other pane, F6 move to other pane, F8 move to Trash.
            if event.window === self.window, !self.firstResponderIsTextEditing(),
               event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
               let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first {
                switch Int(scalar.value) {
                case 0xF708: self.copyToOtherPane(nil); return nil   // F5
                case 0xF709: self.moveToOtherPane(nil); return nil   // F6
                case 0xF70B: self.moveToTrash(nil); return nil       // F8
                default: break
                }
            }
            guard VimMode.shared.enabled else { return event }
            // Only handle events targeted at our window.
            guard event.window === self.window else { return event }
            // Never intercept while the user is editing text.
            if self.firstResponderIsTextEditing() { return event }
            guard let pane = self.panesContainer.activePane else { return event }
            let oldResponder = self.window?.firstResponder
            if VimMode.shared.handle(event: event, in: pane, fileList: pane.testFileList) {
                // Pull focus to the file list so j/k selection is visible even
                // if the sidebar (or nothing) had focus when the key was hit.
                // Do not pull focus back if the command explicitly shifted the responder (e.g. buffer switching)
                if self.window?.firstResponder === oldResponder {
                    if self.window?.firstResponder !== pane.testFileList.tableView {
                        self.window?.makeFirstResponder(pane.testFileList.tableView)
                    }
                }
                return nil   // consumed
            }
            return event
        }
    }

    /// True when the key window's first responder is a text field / field
    /// editor, so we must let keystrokes through verbatim.
    private func firstResponderIsTextEditing() -> Bool {
        guard let responder = window?.firstResponder else { return false }
        // Any focused text view should handle its own keys and Vim must keep its
        // hands off: an editable field editor (rename / search / path bar), OR a
        // read-only text panel like the Git-Diff / terminal / notes drawers. The
        // navigable views (file list, sidebar outline, icon/gallery) are never
        // NSTextViews, so this never blocks real Vim navigation — but it stops
        // j/k from moving the file-list selection while a drawer has focus.
        if responder is NSTextView { return true }
        return responder is NSTextField
    }

    // Fullscreen resizes the window programmatically; permit it around the
    // transition so the size lock doesn't trap the window in/out of fullscreen.
    func windowWillEnterFullScreen(_ notification: Notification) {
        (window as? UserResizeOnlyWindow)?.allowProgrammaticResize = true
    }
    func windowDidEnterFullScreen(_ notification: Notification) {
        (window as? UserResizeOnlyWindow)?.allowProgrammaticResize = false
    }
    func windowWillExitFullScreen(_ notification: Notification) {
        (window as? UserResizeOnlyWindow)?.allowProgrammaticResize = true
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        (window as? UserResizeOnlyWindow)?.allowProgrammaticResize = false
    }

    deinit {
        GitBranchWorkspaces.shared.unregister(self)
        if let m = vimKeyMonitor { NSEvent.removeMonitor(m) }
        NotificationCenter.default.removeObserver(self)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Helpers

    private var activePane: PaneController? { panesContainer.activePane }

    // MARK: Menu actions

    @objc func compressSelection(_ sender: Any?) { activePane?.compressSelection() }
    @objc func extractSelection(_ sender: Any?) { activePane?.extractSelection() }
    @objc func makeAliasSelection(_ sender: Any?) { activePane?.makeAliasSelection() }
    @objc func newTab(_ sender: Any?) { panesContainer.activePane?.newTab(at: nil) }
    @objc func closeTab(_ sender: Any?) {
        if let pane = activePane, pane.isGitDiffVisible {
            pane.toggleGitDiffDrawer()
        } else if let pane = activePane, pane.isTerminalVisible {
            pane.toggleTerminalDrawer()
        } else if panesContainer.allPanes.count > 1, let pane = activePane {
            panesContainer.closePane(pane)
        } else {
            panesContainer.activePane?.closeActiveTab()
        }
    }
    @objc func viewGitDiffs(_ sender: Any?) {
        guard let pane = activePane else { return }
        if let first = pane.selectedURLs().first,
           (try? first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
            pane.showGitDiffDrawer(for: first)
        } else {
            pane.toggleGitDiffDrawer()
        }
    }
    @objc func nextTab(_ sender: Any?) { activePane?.nextTab() }
    @objc func prevTab(_ sender: Any?) { activePane?.prevTab() }
    @objc func selectLastTab(_ sender: Any?) { activePane?.selectLastTab() }
    @objc func moveTabToNewWindow(_ sender: Any?) { activePane?.moveActiveTabToNewWindow() }
    @objc func moveTabLeft(_ sender: Any?) { activePane?.moveActiveTab(by: -1) }
    @objc func moveTabRight(_ sender: Any?) { activePane?.moveActiveTab(by: 1) }
    struct BufferTarget {
        let view: NSView
        let focus: () -> Void
    }

    func getBufferTargets() -> [BufferTarget] {
        var targets: [BufferTarget] = []
        
        // 1. Sidebar outline
        if !splitVC.splitViewItems[0].isCollapsed {
            targets.append(BufferTarget(view: sidebarVC.outline) { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self.sidebarVC.outline)
            })
        }
        
        // 2. Panes components
        for pane in panesContainer.allPanes {
            // Main file list table
            targets.append(BufferTarget(view: pane.fileList.tableView) { [weak pane] in
                pane?.focusFileList()
            })
            
            // Terminal input
            if pane.isTerminalVisible {
                targets.append(BufferTarget(view: pane.terminalView) { [weak pane] in
                    pane?.focusTerminal()
                })
            }
            
            // Git Diff
            if pane.isGitDiffVisible {
                targets.append(BufferTarget(view: pane.gitDiffView) { [weak pane] in
                    pane?.focusGitDiff()
                })
            }
            
            // Notes
            if pane.isNotesVisible {
                targets.append(BufferTarget(view: pane.notesView) { [weak pane] in
                    pane?.focusNotes()
                })
            }
        }
        
        return targets
    }

    func isResponder(_ responder: NSResponder?, descendingFrom view: NSView) -> Bool {
        var r: NSResponder? = responder
        
        // If responder is the window itself, check if there is an active field editor
        if let window = r as? NSWindow {
            if let fieldEditor = window.fieldEditor(false, for: nil),
               let delegate = fieldEditor.delegate as? NSView {
                r = delegate
            }
        }
        
        while let current = r {
            if current === view { return true }
            if let viewResponder = current as? NSView {
                if viewResponder.isDescendant(of: view) { return true }
            }
            if let textView = current as? NSTextView, let delegate = textView.delegate as? NSView {
                if delegate.isDescendant(of: view) { return true }
            }
            r = current.nextResponder
        }
        return false
    }



    func focusBufferLeft() {
        let targets = getBufferTargets()
        guard !targets.isEmpty else { return }
        
        guard let currentIdx = targets.firstIndex(where: { isResponder(window?.firstResponder, descendingFrom: $0.view) }) else {
            panesContainer.activePane?.focusFileList()
            return
        }
        
        let currentView = targets[currentIdx].view
        
        // If we are in Git Diff or Notes, move Left to the active pane's file list
        if let pane = activePane, currentView === pane.gitDiffView || currentView === pane.notesView {
            pane.focusFileList()
            return
        }
        
        // If we are in Pane 1 (right pane) file list/terminal, move Left to Pane 0 (left pane) file list
        if panesContainer.allPanes.count > 1, let active = activePane {
            let all = panesContainer.allPanes
            if active === all[1] {
                all[0].focusFileList()
                return
            }
        }
        
        // If we are in Pane 0 (left pane/only pane) file list/terminal, move Left to Sidebar
        if !splitVC.splitViewItems[0].isCollapsed {
            window?.makeFirstResponder(sidebarVC.outline)
        }
    }

    func focusBufferRight() {
        let targets = getBufferTargets()
        guard !targets.isEmpty else { return }
        
        guard let currentIdx = targets.firstIndex(where: { isResponder(window?.firstResponder, descendingFrom: $0.view) }) else {
            panesContainer.activePane?.focusFileList()
            return
        }
        
        let currentView = targets[currentIdx].view
        
        // If we are in Sidebar, move Right to the active pane's file list
        if currentView === sidebarVC.outline {
            activePane?.focusFileList()
            return
        }
        
        // If we are in Pane 0 (left pane), move Right to Pane 1 (right pane) file list if it exists,
        // otherwise to the active pane's Git Diff or Notes if visible
        if panesContainer.allPanes.count > 1, let active = activePane {
            let all = panesContainer.allPanes
            if active === all[0] {
                all[1].focusFileList()
                return
            }
        }
        
        // Move to Git Diff or Notes drawer if they are visible
        if let pane = activePane {
            if pane.isGitDiffVisible {
                pane.focusGitDiff()
            } else if pane.isNotesVisible {
                pane.focusNotes()
            }
        }
    }

    func focusBufferDown() {
        if let pane = activePane, pane.isTerminalVisible {
            pane.focusTerminal()
        }
    }

    func focusBufferUp() {
        let targets = getBufferTargets()
        guard !targets.isEmpty else { return }
        
        guard let currentIdx = targets.firstIndex(where: { isResponder(window?.firstResponder, descendingFrom: $0.view) }) else {
            panesContainer.activePane?.focusFileList()
            return
        }
        let currentView = targets[currentIdx].view
        
        if let pane = activePane, currentView === pane.terminalView {
            pane.focusFileList()
        }
    }

    @objc func focusNextPane(_ sender: Any?) { panesContainer.focusPane(by: 1) }
    @objc func focusPrevPane(_ sender: Any?) { panesContainer.focusPane(by: -1) }

    @objc func toggleSidebarItem(_ sender: Any?) { splitVC.toggleSidebar(sender) }
    @objc func toggleStatusBarItem(_ sender: Any?) { Settings.showStatusBar.toggle() }
    @objc func toggleUseGroups(_ sender: Any?) { Settings.useGroups.toggle() }
    @objc func togglePreview(_ sender: Any?) { activePane?.togglePreviewDrawer() }
    @objc func showTransferActivity(_ sender: Any?) { TransferActivityController.shared.present() }
    @objc func toggleDropStack(_ sender: Any?) { DropStackController.shared.toggle() }
    @objc func selectByPattern(_ sender: Any?) { activePane?.selectByPattern() }

    /// ⌘Z — undo the last file operation. While a text field is being edited
    /// (rename, search, path bar), forward to its own undo instead.
    @objc func fileUndo(_ sender: Any?) {
        if let text = window?.firstResponder as? NSText, text.undoManager?.canUndo == true {
            text.undoManager?.undo(); return
        }
        if FileActionLog.shared.performUndo() { activePane?.reload() }
    }
    @objc func fileRedo(_ sender: Any?) {
        if let text = window?.firstResponder as? NSText, text.undoManager?.canRedo == true {
            text.undoManager?.redo(); return
        }
        if FileActionLog.shared.performRedo() { activePane?.reload() }
    }
    @objc func addToDropStack(_ sender: Any?) {
        let sel = activePane?.selectedURLs() ?? []
        if DropStack.add(sel) > 0 { DropStackController.shared.present() } else { NSSound.beep() }
    }

    /// The frontmost browser window's active folder — used by the Drop Stack
    /// to know where "Copy/Move Here" should land.
    var activePaneURL: URL? { activePane?.currentURL }
    static var frontmost: BrowserWindowController? {
        NSApp.orderedWindows.compactMap { $0.windowController as? BrowserWindowController }.first
    }
    @objc func togglePathBarItem(_ sender: Any?) { Settings.showPathBar.toggle() }
    @objc func toggleSyncBrowsing(_ sender: Any?) { panesContainer.toggleSyncBrowsing() }
    var syncBrowsingOn: Bool { panesContainer.syncBrowsing }
    @objc func copyToOtherPane(_ sender: Any?) { panesContainer.transferSelectionToOtherPane(move: false) }
    @objc func moveToOtherPane(_ sender: Any?) { panesContainer.transferSelectionToOtherPane(move: true) }
    @objc func newFolder(_ sender: Any?) { activePane?.createNewFolder() }
    @objc func newFile(_ sender: Any?) { activePane?.createNewFile() }
    @objc func newFolderWithSelection(_ sender: Any?) { activePane?.createNewFolderWithSelection() }
    @objc func deleteImmediately(_ sender: Any?) {
        guard let pane = activePane else { return }
        let sel = pane.selectedURLs()
        guard !sel.isEmpty else { return }
        if FileOps.deleteImmediately(sel) { pane.reload() }
    }
    @objc func emptyTrash(_ sender: Any?) { FileOps.emptyTrash() }

    @objc func moveToTrash(_ sender: Any?) {
        guard let pane = activePane else { return }
        let sel = pane.selectedURLs()
        guard !sel.isEmpty else { NSSound.beep(); return }
        FileOps.trashWithConfirmation(sel)
    }

    @objc func pasteMove(_ sender: Any?) { activePane?.pasteMoveHere() }
    @objc func copyFiles(_ sender: Any?) { activePane?.copySelection() }
    @objc func pasteFiles(_ sender: Any?) { activePane?.pasteHere() }
    @objc func duplicate(_ sender: Any?) { activePane?.duplicateSelection() }

    @objc func getInfo(_ sender: Any?) {
        guard let pane = activePane else { return }
        let sel = pane.selectedURLs()
        let target = sel.first ?? pane.currentURL
        GetInfoSheetController.show(for: target, parent: window)
    }

    @objc func newSmartFolder(_ sender: Any?) {
        SmartFolderSheetController.show(for: self, defaultRoot: activePane?.currentURL)
    }

    /// Navigate the active pane to a saved search's synthetic listing.
    func openSmartFolder(id: String) {
        activePane?.navigate(to: SidebarController.smartFolderURL(id: id))
    }

    @objc func viewAsIcons(_ sender: Any?) { activePane?.setViewMode(.icon) }
    @objc func arrangeBy(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = SortKey(rawValue: raw) else { return }
        activePane?.arrangeBy(key)
    }
    @objc func viewAsList(_ sender: Any?) { activePane?.setViewMode(.list) }
    @objc func viewAsColumns(_ sender: Any?) { activePane?.setViewMode(.columns) }
    @objc func viewAsGallery(_ sender: Any?) { activePane?.setViewMode(.gallery) }

    @objc func toggleHidden(_ sender: Any?) { activePane?.toggleHidden() }
    @objc func toggleExtraPane(_ sender: Any?) { panesContainer.toggleExtraPane() }

    @objc func goBack(_ sender: Any?) { activePane?.goBack() }
    @objc func goForward(_ sender: Any?) { activePane?.goForward() }
    @objc func goUp(_ sender: Any?) { activePane?.goUp() }
    @objc func openSelection(_ sender: Any?) { activePane?.openSelection() }
    @objc func goHome(_ sender: Any?) {
        activePane?.navigate(to: FileManager.default.homeDirectoryForCurrentUser)
    }
    @objc func goToFolder(_ sender: Any?) { activePane?.showGoToFolderSheet() }

    @objc func renameSelection(_ sender: Any?) {
        activePane?.beginRenameSelection()
    }

    // MARK: Search + palette

    @objc func showCommandPalette(_ sender: Any?) {
        CommandPaletteController.show(for: self)
    }
    @objc func showFindFiles(_ sender: Any?) {
        SearchSheetController.show(for: self, mode: .fuzzyFilenames)
    }
    @objc func showGrep(_ sender: Any?) {
        SearchSheetController.show(for: self, mode: .contentGrep)
    }

    // MARK: Workspaces

    @objc func saveWorkspace(_ sender: Any?) {
        WorkspaceController.promptSave(in: self)
    }
    @objc func openWorkspaceMenu(_ sender: Any?) {
        WorkspaceController.promptOpen(in: self)
    }

    // MARK: Theme

    // MARK: QoL actions

    @objc func copyPath(_ sender: Any?) {
        guard let pane = activePane else { return }
        let urls = pane.selectedURLs()
        let paths = (urls.isEmpty ? [pane.currentURL] : urls).map { $0.path }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(paths.joined(separator: "\n"), forType: .string)
    }

    @objc func openInTerminal(_ sender: Any?) {
        guard let pane = activePane else { return }
        let dir: URL = {
            let sel = pane.selectedURLs()
            // If the user selected a folder, open Terminal there; else open the current pane URL.
            if let f = sel.first, (try? f.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                return f
            }
            return pane.currentURL
        }()
        // Try iTerm2, then default Terminal. Escape backslash FIRST, then the
        // quote — otherwise a directory name containing a backslash or quote can
        // break out of the AppleScript string and inject shell via `do script`.
        let path = dir.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let iterm = """
        if application "iTerm" is running then
            tell application "iTerm"
                activate
                set newWindow to create window with default profile
                tell current session of newWindow to write text "cd \\"\(path)\\""
            end tell
            return "iterm"
        end if
        """
        var err: NSDictionary?
        let result = NSAppleScript(source: iterm)?.executeAndReturnError(&err)
        if err == nil && result?.stringValue == "iterm" { return }
        // Fallback: Apple Terminal
        let terminal = """
        tell application "Terminal"
            activate
            do script "cd \\"\(path)\\""
        end tell
        """
        NSAppleScript(source: terminal)?.executeAndReturnError(&err)
        if err != nil { NSSound.beep() }
    }

    @objc func analyzeDiskUsage(_ sender: Any?) {
        guard let pane = activePane else { return }
        let target: URL = pane.selectedURLs().first ?? pane.currentURL
        DiskAnalyzerWindowController.show(for: self, rootURL: target)
    }

    @objc func compareFiles(_ sender: Any?) {
        guard let pane = activePane else { return }
        let files = pane.selectedURLs().filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
        }
        guard files.count == 2 else { NSSound.beep(); return }
        FileDiffWindowController.show(a: files[0], b: files[1], parent: window)
    }

    @objc func findDuplicates(_ sender: Any?) {
        guard let pane = activePane else { return }
        let target: URL = pane.selectedURLs().first(where: {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }) ?? pane.currentURL
        DuplicateFinderWindowController.show(for: target, parent: window)
    }

    @objc func openArchive(_ sender: Any?) {
        guard let pane = activePane else { return }
        let urls = pane.selectedURLs()
        guard let url = urls.first(where: Archive.isArchive) else {
            NSSound.beep(); return
        }
        ArchiveSheetController.show(for: self, archive: url)
    }

    @objc func toggleNotes(_ sender: Any?) { activePane?.toggleNotesDrawer() }
    @objc func toggleTerminal(_ sender: Any?) { activePane?.toggleTerminalDrawer() }

    @objc func openFolderSync(_ sender: Any?) {
        FolderSyncSheetController.show(for: self, source: activePane?.currentURL)
    }

    @objc func connectToServer(_ sender: Any?) {
        SFTPConnectSheetController.show(for: self)
    }
    @objc func mountNetworkVolume(_ sender: Any?) {
        ServerConnectSheetController.show(for: self)
    }

    // MARK: Project / editor

    /// Navigate the active pane to the enclosing project root (.git, package.json, …).
    @objc func jumpToProjectRoot(_ sender: Any?) {
        guard let pane = activePane else { return }
        guard let root = ProjectRoot.find(for: pane.currentURL) else {
            NSSound.beep(); return
        }
        pane.navigate(to: root)
    }

    /// Open the project root (or the selected folder / current dir) in the
    /// first installed editor. If a specific editor is encoded in the menu
    /// item's representedObject, use that one.
    @objc func openInEditor(_ sender: Any?) {
        guard let pane = activePane else { return }
        let base: URL = pane.selectedURLs().first(where: {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }) ?? pane.currentURL
        let target = ProjectRoot.find(for: base) ?? base
        let chosen: Editor?
        if let item = sender as? NSMenuItem, let raw = item.representedObject as? String {
            chosen = Editor(rawValue: raw)
        } else {
            chosen = Editor.installed.first
        }
        guard let editor = chosen, editor.open(target) else {
            NSSound.beep(); return
        }
    }

    @objc func uninstallApp(_ sender: Any?) {
        guard let pane = activePane,
              let url = pane.selectedURLs().first(where: { $0.pathExtension == "app" }) else {
            NSSound.beep(); return
        }
        AppUninstallerSheetController.show(for: self, appURL: url)
    }

    // MARK: Test accessors

    var testAllPanes: [PaneController] { panesContainer.allPanes }
    var testActivePane: PaneController? { panesContainer.activePane }
    var testPaneCount: Int { panesContainer.testPaneCount }
    func testToggleExtraPane() { panesContainer.toggleExtraPane() }

    // MARK: State persistence

    func sessionSnapshot() -> [String: Any] {
        let panes = panesContainer.allPanes.map { $0.sessionSnapshot() }
        return ["panes": panes]
    }
    func restoreFromSnapshot(_ snap: [String: Any]) {
        guard let panes = snap["panes"] as? [[String: Any]], !panes.isEmpty else { return }
        // First pane is the one created in init; restore it
        panesContainer.allPanes.first?.restoreFromSnapshot(panes[0])
        for p in panes.dropFirst() {
            panesContainer.addPaneForRestore(snap: p)
        }
    }
}

/// A window that does NOT constrain its frame to the visible screen. Used only
/// in headless audit runs so the window can be parked far off-screen (giving
/// the app AX/menu-bar presence) without AppKit pulling it back into view.
final class OffscreenSafeWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect   // never clamp onto a display
    }
}
