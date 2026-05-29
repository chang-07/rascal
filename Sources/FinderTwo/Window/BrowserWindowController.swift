import AppKit

final class BrowserWindowController: NSWindowController, NSWindowDelegate {

    private let splitVC = NSSplitViewController()
    private let sidebarVC: SidebarController
    private let panesContainer: PanesContainerController
    private var vimKeyMonitor: Any?
    /// Off-main branch lookups for the window subtitle (reads .git/HEAD).
    private static let gitInfoQueue = DispatchQueue(label: "FinderTwo.windowGitInfo", qos: .utility)

    init(rootURL: URL) {
        self.sidebarVC = SidebarController()
        self.panesContainer = PanesContainerController(initialURL: rootURL)

        let initialFrame = NSRect(x: 200, y: 200, width: 1100, height: 700)
        let window = NSWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
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
        // NSSplitViewController auto-sizes the window via preferredContentSize.
        // Setting it explicitly keeps us at 1100×700 instead of full-screen.
        splitVC.preferredContentSize = NSSize(width: 1100, height: 700)
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

        sidebarVC.onSelect = { [weak self] url in
            self?.panesContainer.activePane?.navigate(to: url)
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
            guard VimMode.shared.enabled else { return event }
            // Only handle events targeted at our window.
            guard event.window === self.window else { return event }
            // Never intercept while the user is editing text.
            if self.firstResponderIsTextEditing() { return event }
            guard let pane = self.panesContainer.activePane else { return event }
            if VimMode.shared.handle(event: event, in: pane, fileList: pane.testFileList) {
                // Pull focus to the file list so j/k selection is visible even
                // if the sidebar (or nothing) had focus when the key was hit.
                if self.window?.firstResponder !== pane.testFileList.tableView {
                    self.window?.makeFirstResponder(pane.testFileList.tableView)
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
        if let tv = responder as? NSTextView {
            // A field editor is a shared NSTextView; treat any editable text view
            // as "typing in progress".
            return tv.isFieldEditor || tv.isEditable
        }
        return responder is NSTextField
    }

    deinit {
        GitBranchWorkspaces.shared.unregister(self)
        if let m = vimKeyMonitor { NSEvent.removeMonitor(m) }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Helpers

    private var activePane: PaneController? { panesContainer.activePane }

    // MARK: Menu actions

    @objc func compressSelection(_ sender: Any?) { activePane?.compressSelection() }
    @objc func extractSelection(_ sender: Any?) { activePane?.extractSelection() }
    @objc func makeAliasSelection(_ sender: Any?) { activePane?.makeAliasSelection() }
    @objc func newTab(_ sender: Any?) { panesContainer.activePane?.newTab(at: nil) }
    @objc func closeTab(_ sender: Any?) { panesContainer.activePane?.closeActiveTab() }
    @objc func nextTab(_ sender: Any?) { activePane?.nextTab() }
    @objc func prevTab(_ sender: Any?) { activePane?.prevTab() }
    @objc func selectLastTab(_ sender: Any?) { activePane?.selectLastTab() }
    @objc func moveTabLeft(_ sender: Any?) { activePane?.moveActiveTab(by: -1) }
    @objc func moveTabRight(_ sender: Any?) { activePane?.moveActiveTab(by: 1) }
    @objc func focusNextPane(_ sender: Any?) { panesContainer.focusPane(by: 1) }
    @objc func focusPrevPane(_ sender: Any?) { panesContainer.focusPane(by: -1) }
    @objc func newFolder(_ sender: Any?) {
        guard let pane = activePane,
              let url = FileOps.newFolder(in: pane.currentURL) else { return }
        pane.reload()
        pane.select(url: url)
    }

    @objc func moveToTrash(_ sender: Any?) {
        guard let pane = activePane else { return }
        let sel = pane.selectedURLs()
        guard !sel.isEmpty else { NSSound.beep(); return }
        FileOps.moveToTrash(sel)
    }

    @objc func pasteMove(_ sender: Any?) { activePane?.pasteMoveHere() }
    @objc func copyFiles(_ sender: Any?) { activePane?.copySelection() }
    @objc func pasteFiles(_ sender: Any?) { activePane?.pasteHere() }
    @objc func duplicate(_ sender: Any?) { activePane?.duplicateSelection() }

    @objc func getInfo(_ sender: Any?) {
        guard let pane = activePane else { return }
        let sel = pane.selectedURLs()
        FileOps.getInfo(sel.isEmpty ? [pane.currentURL] : sel)
    }

    @objc func viewAsList(_ sender: Any?) { activePane?.setViewMode(.list) }
    @objc func viewAsColumns(_ sender: Any?) { activePane?.setViewMode(.columns) }

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
