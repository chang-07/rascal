import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowControllers: [BrowserWindowController] = []
    var testWindowControllers: [BrowserWindowController] { windowControllers }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchMetrics.shared.didFinishLaunching = ProcessInfo.processInfo.systemUptime
        PluginHost.shared.loadAll()
        installMainMenu()
        // Rebuild the menu live whenever a custom shortcut changes so edits in
        // Settings take effect immediately.
        NotificationCenter.default.addObserver(
            forName: ActionRegistry.shortcutsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.installMainMenu()
        }
        if ProcessInfo.processInfo.environment["FT_RUN_TESTS"] == "1" {
            DispatchQueue.main.async {
                TestRunner().runAll(appDelegate: self)
            }
            return
        }
        if let cliPath = AppDelegate.cliPath() {
            openNewBrowserWindow(at: URL(fileURLWithPath: cliPath))
        } else if !(Settings.restoreSession && restoreSession()) {
            // Restore disabled (or nothing to restore): open at the configured
            // default location, falling back to home.
            let target = Settings.defaultLocation.url ?? FileManager.default.homeDirectoryForCurrentUser
            let dir = FileManager.default.fileExists(atPath: target.path)
                ? target : FileManager.default.homeDirectoryForCurrentUser
            openNewBrowserWindow(at: dir)
        }
        let isHeadless = ProcessInfo.processInfo.environment["FT_HEADLESS_TESTING"] == "1"
        if !isHeadless {
            NSApp.activate(ignoringOtherApps: true)
        }
        LaunchMetrics.shared.firstWindowOnScreen = ProcessInfo.processInfo.systemUptime
        if ProcessInfo.processInfo.environment["FT_PRINT_LAUNCH_TIMING"] == "1" {
            let m = LaunchMetrics.shared
            let didLaunchMs = Int((m.didFinishLaunching - m.processStart) * 1000)
            let firstWinMs = Int((m.firstWindowOnScreen - m.processStart) * 1000)
            NSLog("FT cold launch — to didFinishLaunching: \(didLaunchMs)ms · to first window: \(firstWinMs)ms")
        }
    }

    func applicationWillTerminate(_ notification: Notification) { saveSession() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Session

    private static let sessionKey = "FinderTwo.session.v1"
    private func saveSession() {
        let windows = windowControllers.compactMap { wc -> [String: Any]? in
            let snap = wc.sessionSnapshot()
            return (snap["panes"] as? [Any])?.isEmpty == false ? snap : nil
        }
        if windows.isEmpty {
            UserDefaults.standard.removeObject(forKey: AppDelegate.sessionKey)
        } else {
            UserDefaults.standard.set(["windows": windows], forKey: AppDelegate.sessionKey)
        }
    }

    @discardableResult
    private func restoreSession() -> Bool {
        guard let raw = UserDefaults.standard.dictionary(forKey: AppDelegate.sessionKey),
              let windows = raw["windows"] as? [[String: Any]],
              !windows.isEmpty else { return false }
        for w in windows {
            let firstURL: URL = {
                if let panes = w["panes"] as? [[String: Any]],
                   let firstPane = panes.first,
                   let urls = firstPane["urls"] as? [String],
                   let first = urls.first,
                   FileManager.default.fileExists(atPath: first) {
                    return URL(fileURLWithPath: first)
                }
                return FileManager.default.homeDirectoryForCurrentUser
            }()
            let wc = openBrowserWindowAndReturn(at: firstURL)
            wc.restoreFromSnapshot(w)
        }
        return !windowControllers.isEmpty
    }

    @discardableResult
    private func openBrowserWindowAndReturn(at url: URL) -> BrowserWindowController {
        let wc = BrowserWindowController(rootURL: url)
        finishOpening(wc)
        return wc
    }

    func openNewBrowserWindow(at url: URL) {
        let wc = BrowserWindowController(rootURL: url)
        finishOpening(wc)
    }

    private func finishOpening(_ wc: BrowserWindowController) {
        let isHeadless = ProcessInfo.processInfo.environment["FT_HEADLESS_TESTING"] == "1"
        if isHeadless {
            // For tests: park the window far off-screen so it's never visible,
            // but order it front + key so AppKit treats it as the active
            // window for AX queries.
            wc.window?.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        }
        wc.window?.makeKeyAndOrderFront(nil)
        windowControllers.append(wc)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: wc.window, queue: .main
        ) { [weak self, weak wc] _ in
            guard let self, let wc else { return }
            self.windowControllers.removeAll { $0 === wc }
        }
    }

    // MARK: - Dispatcher (the key change for menu reliability)

    /// Returns the most relevant BrowserWindowController to receive an action.
    func currentBrowserWC() -> BrowserWindowController? {
        if let key = NSApp.keyWindow?.windowController as? BrowserWindowController { return key }
        return windowControllers.last
    }

    /// Universal dispatch — every action-routed menu item targets AppDelegate
    /// with this selector and carries the Action id in `representedObject`.
    /// AppDelegate is always reachable regardless of activation state, so menu
    /// items always fire (vs first-responder-chain lookup which fails in
    /// background activation policy).
    @objc func dispatchAction(_ sender: NSMenuItem) {
        guard let wc = currentBrowserWC() else { return }
        if let id = sender.representedObject as? String,
           let action = ActionRegistry.action(id: id) {
            action.perform(wc)
            return
        }
        // Tab-by-index uses the tag field.
        if sender.tag > 0 {
            wc.testActivePane?.selectTab(at: sender.tag - 1)
        }
    }

    // MARK: - Menu

    private func installMainMenu() {
        let mainMenu = NSMenu()
        mainMenu.autoenablesItems = false

        // ---- FinderTwo (App menu) ----
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About FinderTwo",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(item(title: "Settings…",
                             action: #selector(showSettings(_:)),
                             key: ",", mods: [.command]))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(systemItem(title: "Hide FinderTwo",
                                   action: #selector(NSApplication.hide(_:)),
                                   key: "h"))
        appMenu.addItem(systemItem(title: "Quit FinderTwo",
                                   action: #selector(NSApplication.terminate(_:)),
                                   key: "q"))
        attach(appMenu, to: mainMenu)

        // ---- File ----
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(item(title: "New Window",
                              action: #selector(newWindow(_:)),
                              key: "n", mods: [.command]))
        fileMenu.addItem(routed("tab.new"))
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(routed("file.new-folder"))
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(routed("tab.close"))
        fileMenu.addItem(systemItem(title: "Close Window",
                                    action: #selector(NSWindow.performClose(_:)),
                                    key: "w", mods: [.command, .shift]))
        fileMenu.addItem(routed("file.get-info"))
        fileMenu.addItem(routed("file.rename"))
        fileMenu.addItem(item(title: "Batch Rename…",
                              action: #selector(showBatchRename(_:)),
                              key: "r", mods: [.command, .shift]))
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(routed("workspace.save", key: "s", mods: [.command, .control]))
        fileMenu.addItem(routed("workspace.open", key: "o", mods: [.command, .control]))
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(routed("search.palette"))
        fileMenu.addItem(routed("search.find-files"))
        fileMenu.addItem(routed("search.grep"))
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(routed("file.copy-path"))
        fileMenu.addItem(routed("file.open-in-terminal"))
        fileMenu.addItem(routed("project.open-editor", title: "Open in Editor"))
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(routed("tool.browse-archive"))
        fileMenu.addItem(routed("tool.folder-sync"))
        fileMenu.addItem(routed("tool.analyze-disk"))
        fileMenu.addItem(routed("tool.uninstall-app"))
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(routed("file.trash"))
        attach(fileMenu, to: mainMenu)

        // ---- Edit ----
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(systemItem(title: "Undo", action: Selector(("undo:")), key: "z"))
        editMenu.addItem(systemItem(title: "Redo", action: Selector(("redo:")), key: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(systemItem(title: "Cut", action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(routed("edit.copy"))
        editMenu.addItem(routed("edit.paste"))
        editMenu.addItem(routed("edit.paste-move"))
        editMenu.addItem(routed("edit.duplicate"))
        editMenu.addItem(systemItem(title: "Select All",
                                    action: #selector(NSResponder.selectAll(_:)),
                                    key: "a"))
        attach(editMenu, to: mainMenu)

        // ---- View ----
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(routed("view.as-list"))
        viewMenu.addItem(routed("view.as-columns"))
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(routed("view.toggle-hidden", title: "Show Hidden Files"))
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(routed("pane.toggle-extra", title: "Open Extra Pane"))
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(routed("panel.terminal"))
        viewMenu.addItem(routed("panel.notes"))
        attach(viewMenu, to: mainMenu)

        // ---- Go ----
        let goMenu = NSMenu(title: "Go")
        goMenu.addItem(routed("nav.back",
                              title: "Back",
                              key: "[", mods: [.command]))
        goMenu.addItem(routed("nav.forward",
                              title: "Forward",
                              key: "]", mods: [.command]))
        goMenu.addItem(routed("nav.up",
                              title: "Enclosing Folder",
                              key: String(UnicodeScalar(NSUpArrowFunctionKey)!),
                              mods: [.command]))
        goMenu.addItem(routed("nav.open",
                              title: "Open",
                              key: String(UnicodeScalar(NSDownArrowFunctionKey)!),
                              mods: [.command]))
        goMenu.addItem(NSMenuItem.separator())
        goMenu.addItem(routed("nav.goto", title: "Go to Folder…"))
        goMenu.addItem(routed("nav.home", title: "Home"))
        goMenu.addItem(routed("project.jump-root", title: "Jump to Project Root"))
        goMenu.addItem(routed("net.connect-server", title: "Connect to Server…"))
        goMenu.addItem(NSMenuItem.separator())
        for i in 1...9 {
            let tabItem = NSMenuItem(title: "Show Tab \(i)",
                                     action: #selector(dispatchAction(_:)),
                                     keyEquivalent: "\(i)")
            tabItem.keyEquivalentModifierMask = [.command, .option]
            tabItem.tag = i
            goMenu.addItem(tabItem)
        }
        attach(goMenu, to: mainMenu)

        // ---- Window ----
        let windowMenu = NSMenu(title: "Window")
        NSApp.windowsMenu = windowMenu
        windowMenu.addItem(systemItem(title: "Minimize",
                                      action: #selector(NSWindow.performMiniaturize(_:)),
                                      key: "m"))
        windowMenu.addItem(systemItem(title: "Zoom",
                                      action: #selector(NSWindow.performZoom(_:)),
                                      key: ""))
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(systemItem(title: "Bring All to Front",
                                      action: #selector(NSApplication.arrangeInFront(_:)),
                                      key: ""))
        attach(windowMenu, to: mainMenu)

        disableAutoenable(mainMenu)
        NSApp.mainMenu = mainMenu
    }

    private func attach(_ submenu: NSMenu, to parent: NSMenu) {
        let mi = NSMenuItem()
        mi.title = submenu.title
        mi.submenu = submenu
        parent.addItem(mi)
    }

    /// A "system" menu item targeting AppKit's standard selectors (Hide, Cut,
    /// performClose, etc). These already work in any responder chain.
    private func systemItem(title: String, action: Selector, key: String, mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { it.keyEquivalentModifierMask = mods }
        return it
    }

    /// A menu item bound to a selector found on AppDelegate (which is always
    /// the NSApp.delegate). Leaves `target` nil so AX-click + key-equivalent
    /// dispatch traverse the standard responder chain → NSApp.delegate.
    private func item(title: String, action: Selector, key: String = "", mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { it.keyEquivalentModifierMask = mods }
        return it
    }

    /// A menu item whose action id (from ActionRegistry) is dispatched through
    /// `dispatchAction(_:)` on AppDelegate. Target left nil for responder-chain
    /// resolution; AppDelegate always wins because it's NSApp.delegate.
    private func routed(_ actionId: String,
                        title: String? = nil,
                        key: String? = nil,
                        mods: NSEvent.ModifierFlags? = nil) -> NSMenuItem {
        let action = ActionRegistry.action(id: actionId)
        let label = title ?? action?.title ?? actionId
        let resolvedShortcut = ActionRegistry.shortcut(for: actionId)
        let useKey = key ?? resolvedShortcut?.key ?? ""
        let useMods = mods ?? resolvedShortcut?.modifiers ?? [.command]
        let it = NSMenuItem(title: label, action: #selector(dispatchAction(_:)), keyEquivalent: useKey)
        it.representedObject = actionId
        if !useKey.isEmpty { it.keyEquivalentModifierMask = useMods }
        return it
    }

    private func disableAutoenable(_ menu: NSMenu) {
        menu.autoenablesItems = false
        for it in menu.items {
            it.isEnabled = true
            if let sub = it.submenu { disableAutoenable(sub) }
        }
    }

    @objc func newWindow(_ sender: Any?) {
        openNewBrowserWindow(at: FileManager.default.homeDirectoryForCurrentUser)
    }

    @objc func showBatchRename(_ sender: Any?) {
        guard let wc = currentBrowserWC() else { return }
        BatchRenameSheetController.show(for: wc)
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsController.show()
    }

    // MARK: - CLI

    static func cliPath() -> String? {
        let args = CommandLine.arguments.dropFirst()
        var iter = args.makeIterator()
        while let a = iter.next() {
            switch a {
            case "--path", "-p":
                if let next = iter.next() { return resolvePath(next) }
            case _ where a.hasPrefix("-"):
                continue
            default:
                if let r = resolvePath(a) { return r }
            }
        }
        return nil
    }

    private static func resolvePath(_ raw: String) -> String? {
        let expanded = (raw as NSString).expandingTildeInPath
        let abs = expanded.hasPrefix("/")
            ? expanded
            : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(expanded)
        let std = (abs as NSString).standardizingPath
        return FileManager.default.fileExists(atPath: std) ? std : nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if windowControllers.isEmpty {
                openNewBrowserWindow(at: FileManager.default.homeDirectoryForCurrentUser)
            } else {
                windowControllers.last?.window?.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls {
            openNewBrowserWindow(at: u)
        }
    }
}
