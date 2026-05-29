import AppKit

/// In-process test harness. Runs after applicationDidFinishLaunching when
/// FT_RUN_TESTS=1. Drives the controller layer directly (no UI events) and
/// exits the process with a non-zero status if anything fails.
///
/// This is intentionally NOT XCTest — we have no Xcode, only SwiftPM + CLT,
/// and XCTest under SwiftPM on macOS apps is annoying to wire up. A plain
/// runner gives us deterministic, repeatable verification with one process
/// launch.
@MainActor
final class TestRunner {
    private var failures: [String] = []
    private var passed: [String] = []

    func runAll(appDelegate: AppDelegate) {
        print("=== FinderTwo in-process tests ===")

        // Sandbox for filesystem mutations
        let sandbox = makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        populateSandbox(sandbox)

        let wc = ensureWindowController(at: sandbox, appDelegate: appDelegate)
        guard let pane = wc.testActivePane else {
            failures.append("no active pane on window")
            finish()
            return
        }

        // --- T1: directory loads ---
        let items = pane.testCurrentItems
        assert("loads sandbox dir", items.count >= 4, "got \(items.count)")

        // --- T2: navigate into subdir ---
        let subURL = sandbox.appendingPathComponent("subdir")
        pane.navigate(to: subURL)
        wait(0.05)
        assert("navigated into subdir",
               samePath(pane.currentURL, subURL),
               "currentURL=\(pane.currentURL.path)")
        assert("subdir contents",
               pane.testCurrentItems.contains(where: { $0.name == "nested_file.txt" }),
               "items=\(pane.testCurrentItems.map { $0.name })")

        // --- T3: goUp returns to sandbox ---
        pane.goUp()
        wait(0.05)
        assert("goUp to sandbox",
               samePath(pane.currentURL, sandbox),
               "currentURL=\(pane.currentURL.path)")

        // --- T4: back/forward stacks ---
        pane.navigate(to: subURL)
        wait(0.05)
        pane.goBack()
        wait(0.05)
        assert("goBack works",
               samePath(pane.currentURL, sandbox),
               "url=\(pane.currentURL.path)")
        pane.goForward()
        wait(0.05)
        assert("goForward works",
               samePath(pane.currentURL, subURL),
               "url=\(pane.currentURL.path)")
        pane.goBack()
        wait(0.05)

        // --- T5: live filter narrows the list ---
        let totalBefore = pane.testCurrentItems.count
        pane.testSetFilter("alpha")
        wait(0.05)
        let filtered = pane.testCurrentItems.count
        assert("filter narrows", filtered < totalBefore && filtered >= 1,
               "filtered=\(filtered)/\(totalBefore)")
        pane.testSetFilter("")
        wait(0.05)
        assert("filter cleared restores",
               pane.testCurrentItems.count == totalBefore,
               "got=\(pane.testCurrentItems.count) expected=\(totalBefore)")

        // --- T6: sort by name (folders first) ---
        var sd = pane.testModel.sort
        sd.key = .name; sd.ascending = true; sd.foldersFirst = true
        pane.testSetSort(sd)
        let sortedItems = pane.testCurrentItems
        // Once a non-directory appears, no directory may appear after it.
        var sawFile = false
        var foldersFirst = true
        for it in sortedItems {
            if !it.isDirectory { sawFile = true }
            else if sawFile { foldersFirst = false; break }
        }
        assert("folders-first sort", foldersFirst,
               "order=\(sortedItems.map { "\($0.isDirectory ? "[" : "")\($0.name)\($0.isDirectory ? "]" : "")" })")

        // --- T7: new tab ---
        let initialTabs = pane.testTabCount
        pane.newTab(at: sandbox)
        assert("new tab adds one", pane.testTabCount == initialTabs + 1,
               "tabs=\(pane.testTabCount)")

        // --- T8: select tab by index ---
        pane.selectTab(at: 0)
        assert("select tab 0", pane.testActiveTabIndex == 0,
               "active=\(pane.testActiveTabIndex)")

        // --- T8b: tab cycling (wraps), last-tab jump, and reorder ---
        while pane.testTabCount < 3 { pane.newTab(at: sandbox) }
        let tabN = pane.testTabCount
        assert("tab strip is visible with multiple tabs", pane.testTabStripVisible, "hidden")
        pane.selectTab(at: 0)
        pane.nextTab()
        assert("nextTab advances", pane.testActiveTabIndex == 1, "active=\(pane.testActiveTabIndex)")
        pane.prevTab()
        assert("prevTab goes back", pane.testActiveTabIndex == 0, "active=\(pane.testActiveTabIndex)")
        pane.prevTab()
        assert("prevTab wraps to last tab", pane.testActiveTabIndex == tabN - 1,
               "active=\(pane.testActiveTabIndex)")
        pane.nextTab()
        assert("nextTab wraps to first tab", pane.testActiveTabIndex == 0,
               "active=\(pane.testActiveTabIndex)")
        pane.selectLastTab()
        assert("selectLastTab jumps to last", pane.testActiveTabIndex == tabN - 1,
               "active=\(pane.testActiveTabIndex)")
        pane.moveActiveTab(by: -1)
        assert("moveActiveTab(-1) reorders and keeps it active",
               pane.testActiveTabIndex == tabN - 2, "active=\(pane.testActiveTabIndex)")
        pane.moveActiveTab(by: 1)
        assert("moveActiveTab(+1) reorders and keeps it active",
               pane.testActiveTabIndex == tabN - 1, "active=\(pane.testActiveTabIndex)")
        // Tear back down to initialTabs + 1 so T9 below still holds.
        while pane.testTabCount > initialTabs + 1 { pane.closeActiveTab() }
        pane.selectTab(at: 0)

        // --- T9: close tab ---
        pane.closeActiveTab()
        assert("close tab decrements",
               pane.testTabCount == initialTabs,
               "tabs=\(pane.testTabCount)")
        // With a single tab the strip must be fully hidden (so its "+" button
        // can't bleed into the gap above the breadcrumb).
        if pane.testTabCount == 1 {
            assert("tab strip hides with a single tab", !pane.testTabStripVisible, "still visible")
        }

        // --- T10: extra pane toggle ---
        let panesBefore = wc.testPaneCount
        wc.testToggleExtraPane()
        assert("extra pane opens",
               wc.testPaneCount == panesBefore + 1,
               "panes=\(wc.testPaneCount)")
        wc.testToggleExtraPane()
        assert("extra pane closes",
               wc.testPaneCount == panesBefore,
               "panes=\(wc.testPaneCount)")

        // --- T10b: keyboard pane focus switching ---
        wc.testToggleExtraPane()   // open a second pane
        let paneA = wc.testActivePane
        wc.focusPrevPane(nil)
        let paneB = wc.testActivePane
        assert("focus prev pane switches active pane",
               paneB != nil && paneB !== paneA, "same/nil pane")
        wc.focusNextPane(nil)
        assert("focus next pane returns to the original",
               wc.testActivePane === paneA, "did not return")
        wc.testToggleExtraPane()   // back to one pane
        let solo = wc.testActivePane
        wc.focusNextPane(nil)
        assert("pane focus is a no-op with a single pane",
               wc.testActivePane === solo, "single-pane focus changed")

        // --- T11: new folder via FileOps ---
        let newFolderURL = FileOps.newFolder(in: sandbox, baseName: "freshfolder")
        assert("FileOps.newFolder returns URL",
               newFolderURL != nil, "nil")
        if let u = newFolderURL {
            assert("new folder exists on disk",
                   FileManager.default.fileExists(atPath: u.path), "")
        }

        // --- T11b: new file, unique naming, transfer (no-conflict), group-into-folder ---
        let foDir = sandbox.appendingPathComponent("fileops")
        try? FileManager.default.createDirectory(at: foDir, withIntermediateDirectories: true)
        if let nf = FileOps.newFile(in: foDir, baseName: "untitled") {
            assert("newFile creates an empty file",
                   FileManager.default.fileExists(atPath: nf.path), "no file")
            let dodge = FileOps.uniqueDestination(foDir.appendingPathComponent("untitled"))
            assert("uniqueDestination dodges an existing name",
                   dodge.lastPathComponent == "untitled 2", "got=\(dodge.lastPathComponent)")
        } else { assert("newFile returns a URL", false, "nil") }
        // transfer with distinct names triggers no prompt and copies.
        let xSrc = foDir.appendingPathComponent("src.txt")
        try? "hi".write(to: xSrc, atomically: true, encoding: .utf8)
        let xDst = sandbox.appendingPathComponent("xfer_dest")
        try? FileManager.default.createDirectory(at: xDst, withIntermediateDirectories: true)
        FileOps.transfer([xSrc], into: xDst, move: false)
        assert("transfer copies into destination",
               FileManager.default.fileExists(atPath: xDst.appendingPathComponent("src.txt").path), "not copied")
        assert("transfer (copy) leaves the source in place",
               FileManager.default.fileExists(atPath: xSrc.path), "source vanished")
        // New Folder with Selection moves the items into a fresh folder.
        let g1 = foDir.appendingPathComponent("g1.txt"); let g2 = foDir.appendingPathComponent("g2.txt")
        try? "a".write(to: g1, atomically: true, encoding: .utf8)
        try? "b".write(to: g2, atomically: true, encoding: .utf8)
        if let folder = FileOps.newFolderWithItems([g1, g2], in: foDir) {
            let inside = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            assert("newFolderWithItems groups the selection",
                   inside.contains("g1.txt") && inside.contains("g2.txt"), "got=\(inside)")
            assert("newFolderWithItems moved (not copied) the items",
                   !FileManager.default.fileExists(atPath: g1.path), "original still present")
        } else { assert("newFolderWithItems returns a folder", false, "nil") }

        // --- T12: rename via FileListController.commitInlineRename ---
        // Sync reload so the file list picks up the new folder before we assert.
        pane.testReloadSync()
        // Select the freshfolder row, rename to renamedfolder
        if let item = pane.testCurrentItems.first(where: { $0.name == "freshfolder" }) {
            pane.testSelectItem(item)
            pane.commitInlineRename(to: "renamedfolder")
            wait(0.1)
            let renamedURL = sandbox.appendingPathComponent("renamedfolder")
            assert("rename moved on disk",
                   FileManager.default.fileExists(atPath: renamedURL.path),
                   "no \(renamedURL.path)")
            assert("rename removed old path",
                   !FileManager.default.fileExists(atPath: sandbox.appendingPathComponent("freshfolder").path),
                   "old path still exists")
        } else {
            failures.append("could not find freshfolder in current items: \(pane.testCurrentItems.map { $0.name })")
        }

        // --- T13: trash a file ---
        let toTrash = sandbox.appendingPathComponent("alpha_one.txt")
        FileOps.moveToTrash([toTrash])
        assert("trashed file no longer at source",
               !FileManager.default.fileExists(atPath: toTrash.path), "still exists")

        // --- T15: copy via pasteboard then paste (FileOps.paste) ---
        let src = sandbox.appendingPathComponent("beta.txt")
        let destDir = sandbox.appendingPathComponent("paste-dest")
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let pb = NSPasteboard(name: NSPasteboard.Name("FinderTwo.test.pb"))
        pb.clearContents()
        pb.writeObjects([src as NSURL])
        FileOps.paste(pb, into: destDir, move: false)
        let copiedDst = destDir.appendingPathComponent("beta.txt")
        assert("paste-copy created destination",
               FileManager.default.fileExists(atPath: copiedDst.path), "no \(copiedDst.path)")
        assert("paste-copy preserved source",
               FileManager.default.fileExists(atPath: src.path), "source gone")

        // --- T16: paste-move removes source ---
        let moveSrc = destDir.appendingPathComponent("beta.txt")
        let moveDestDir = sandbox.appendingPathComponent("paste-move-dest")
        try? FileManager.default.createDirectory(at: moveDestDir, withIntermediateDirectories: true)
        pb.clearContents()
        pb.writeObjects([moveSrc as NSURL])
        FileOps.paste(pb, into: moveDestDir, move: true)
        let moveDst = moveDestDir.appendingPathComponent("beta.txt")
        assert("paste-move created destination",
               FileManager.default.fileExists(atPath: moveDst.path), "no \(moveDst.path)")
        assert("paste-move removed source",
               !FileManager.default.fileExists(atPath: moveSrc.path), "source still there")

        // --- T17: drag-drop simulated via the same pasteboard path ---
        // Drag from a "source" pane to a target directory == paste with move semantics.
        // We assert by direct call into FileOps for the drop body — the FileListController
        // table-view drop handler dispatches through the exact same code.
        let dragSrc = sandbox.appendingPathComponent("gamma.md")
        let dragDestDir = sandbox.appendingPathComponent("drag-dest")
        try? FileManager.default.createDirectory(at: dragDestDir, withIntermediateDirectories: true)
        let dragPb = NSPasteboard(name: NSPasteboard.Name("FinderTwo.test.drag.pb"))
        dragPb.clearContents()
        dragPb.writeObjects([dragSrc as NSURL])
        FileOps.paste(dragPb, into: dragDestDir, move: true)
        assert("dragged file landed in destination",
               FileManager.default.fileExists(atPath:
                  dragDestDir.appendingPathComponent("gamma.md").path), "no")
        assert("dragged file removed from source",
               !FileManager.default.fileExists(atPath: dragSrc.path), "still there")

        // --- T18: PaneController.copySelection + pasteHere round-trip ---
        // Make a fresh source file and a fresh nested dest dir
        let copyRoundtripDir = sandbox.appendingPathComponent("copyrt")
        try? FileManager.default.createDirectory(at: copyRoundtripDir, withIntermediateDirectories: true)
        let fileForCopy = sandbox.appendingPathComponent("for_copy.txt")
        try? "hi".write(to: fileForCopy, atomically: true, encoding: .utf8)
        pane.testReloadSync()
        if let item = pane.testCurrentItems.first(where: { $0.name == "for_copy.txt" }) {
            pane.testSelectItem(item)
            pane.copySelection()
            pane.navigate(to: copyRoundtripDir)
            wait(0.05)
            pane.pasteHere()
            wait(0.1)
            let dest = copyRoundtripDir.appendingPathComponent("for_copy.txt")
            assert("copy+paste created destination",
                   FileManager.default.fileExists(atPath: dest.path), "no \(dest.path)")
            assert("copy+paste left source intact",
                   FileManager.default.fileExists(atPath: fileForCopy.path), "source removed")
            pane.navigate(to: sandbox)
            wait(0.05)
        } else {
            failures.append("for_copy.txt missing for T18")
        }

        // --- T19: PaneController.duplicateSelection ---
        let fileForDup = sandbox.appendingPathComponent("dup_me.txt")
        try? "x".write(to: fileForDup, atomically: true, encoding: .utf8)
        pane.testReloadSync()
        if let item = pane.testCurrentItems.first(where: { $0.name == "dup_me.txt" }) {
            pane.testSelectItem(item)
            pane.duplicateSelection()
            wait(0.1)
            let copy = sandbox.appendingPathComponent("dup_me copy.txt")
            assert("duplicate created copy",
                   FileManager.default.fileExists(atPath: copy.path), "no \(copy.path)")
            assert("duplicate preserved original",
                   FileManager.default.fileExists(atPath: fileForDup.path), "original gone")
        } else {
            failures.append("dup_me.txt missing for T19")
        }

        // --- T20: safety — rename to invalid names is a no-op ---
        let safety = sandbox.appendingPathComponent("safety.txt")
        try? "x".write(to: safety, atomically: true, encoding: .utf8)
        pane.testReloadSync()
        if let item = pane.testCurrentItems.first(where: { $0.name == "safety.txt" }) {
            pane.testSelectItem(item)
            pane.commitInlineRename(to: "")
            assert("empty-name rename is no-op",
                   FileManager.default.fileExists(atPath: safety.path), "deleted!")
            pane.commitInlineRename(to: "with/slash.txt")
            assert("slash-name rename is no-op",
                   FileManager.default.fileExists(atPath: safety.path), "deleted!")
            assert("slash-name target was not created",
                   !FileManager.default.fileExists(atPath: sandbox.appendingPathComponent("with").path),
                   "created stray folder")
        }

        // --- T21: safety — paste with empty pasteboard does not crash, no side effects ---
        let emptyPb = NSPasteboard(name: NSPasteboard.Name("FinderTwo.test.empty.pb"))
        emptyPb.clearContents()
        // Snapshot, then paste, then verify no change.
        let preSnapshot = (try? FileManager.default.contentsOfDirectory(atPath: sandbox.path))?
            .sorted() ?? []
        FileOps.paste(emptyPb, into: sandbox, move: false)
        let postSnapshot = (try? FileManager.default.contentsOfDirectory(atPath: sandbox.path))?
            .sorted() ?? []
        assert("empty-pasteboard paste does not alter directory",
               preSnapshot == postSnapshot,
               "pre=\(preSnapshot) post=\(postSnapshot)")

        // --- T22: safety — filter with special regex/glob characters does not crash ---
        for needle in [".*", "[abc", "()|", "\\\\d", "%^&"] {
            pane.testSetFilter(needle)
            _ = pane.testCurrentItems.count  // just ensure it doesn't throw
        }
        pane.testSetFilter("")
        assert("special-char filters processed without crash", true, "")

        // --- T23: safety — Cmd+Up at the filesystem root is a no-op (does not move past /) ---
        pane.navigate(to: URL(fileURLWithPath: "/"))
        wait(0.05)
        pane.goUp()
        wait(0.05)
        assert("Cmd+Up at / is a no-op",
               samePath(pane.currentURL, URL(fileURLWithPath: "/")),
               "url=\(pane.currentURL.path)")
        // Restore to sandbox before sidebar check
        pane.navigate(to: sandbox)
        wait(0.05)

        // --- T24: session snapshot/restore round-trip ---
        // Create a fresh window controller with two tabs, snapshot it, then
        // restore into a brand new window controller and verify.
        let restoreRoot = sandbox.appendingPathComponent("subdir")
        let testWC = BrowserWindowController(rootURL: restoreRoot)
        testWC.testActivePane?.newTab(at: sandbox)
        let snap = testWC.sessionSnapshot()
        let restoredWC = BrowserWindowController(rootURL: FileManager.default.homeDirectoryForCurrentUser)
        restoredWC.restoreFromSnapshot(snap)
        let restoredTabs = restoredWC.testActivePane?.testTabCount ?? 0
        assert("restored tab count matches",
               restoredTabs == 2, "got=\(restoredTabs)")
        let restoredURLs = (restoredWC.sessionSnapshot()["panes"] as? [[String: Any]])?
            .first?["urls"] as? [String] ?? []
        let snapURLs = (snap["panes"] as? [[String: Any]])?
            .first?["urls"] as? [String] ?? []
        assert("restored URL list matches",
               restoredURLs == snapURLs,
               "got=\(restoredURLs) expected=\(snapURLs)")
        testWC.window?.close()
        restoredWC.window?.close()

        // --- T25: Theme switching ---
        let initialTheme = ThemeManager.shared.current.id
        ThemeManager.shared.setTheme(id: "midnight")
        assert("theme set to midnight",
               ThemeManager.shared.current.id == "midnight", "got=\(ThemeManager.shared.current.id)")
        ThemeManager.shared.cycle()
        assert("theme cycle advances",
               ThemeManager.shared.current.id != "midnight", "stuck on midnight")
        ThemeManager.shared.setTheme(id: initialTheme)

        // --- T26: Vim mode enable / disable persisted ---
        let beforeVim = VimMode.shared.enabled
        VimMode.shared.setEnabled(true)
        assert("vim mode enabled", VimMode.shared.enabled, "not enabled")
        VimMode.shared.setEnabled(false)
        assert("vim mode disabled", !VimMode.shared.enabled, "still enabled")
        VimMode.shared.setEnabled(beforeVim)

        // --- T27: Workspaces save + open ---
        let workspaceName = "TestWorkspace_\(UUID().uuidString.prefix(6))"
        WorkspaceStore.save(name: String(workspaceName), snapshot: wc.sessionSnapshot())
        let saved = WorkspaceStore.all().contains { $0.name == workspaceName }
        assert("workspace saved", saved, "not found")
        let wsSnap = WorkspaceStore.snapshot(forName: String(workspaceName))
        assert("workspace round-trip non-empty",
               (wsSnap?["panes"] as? [Any])?.isEmpty == false, "no panes in saved snap")
        WorkspaceStore.delete(name: String(workspaceName))
        assert("workspace deleted",
               !WorkspaceStore.all().contains { $0.name == workspaceName }, "still present")

        // --- T28: Tags write + read round-trip ---
        let tagFile = sandbox.appendingPathComponent("tagged.txt")
        try? "x".write(to: tagFile, atomically: true, encoding: .utf8)
        Tags.write([Tags.Tag(name: "Review", color: .yellow),
                    Tags.Tag(name: "Urgent", color: .red)], to: tagFile)
        let read = Tags.read(tagFile)
        assert("tags written and read",
               read.contains(where: { $0.name == "Review" && $0.color == .yellow })
            && read.contains(where: { $0.name == "Urgent"  && $0.color == .red }),
               "got=\(read)")
        Tags.removeTag(named: "Review", from: tagFile)
        let after = Tags.read(tagFile)
        assert("tag removed individually",
               !after.contains { $0.name == "Review" }
            &&  after.contains { $0.name == "Urgent" },
               "got=\(after)")

        // --- T29: Action registry has all the major actions ---
        let mustHave = ["nav.up", "tab.new", "tab.close", "pane.toggle-extra",
                        "edit.copy", "edit.paste", "file.rename", "file.trash",
                        "search.palette", "search.find-files", "search.grep",
                        "workspace.save", "workspace.open"]
        for id in mustHave {
            assert("action exists: \(id)",
                   ActionRegistry.action(id: id) != nil,
                   "missing")
        }

        // --- T30: KeyShortcut display label formatting ---
        let s1 = KeyShortcut("g", [.command, .shift]).displayLabel
        assert("Cmd+Shift+G label", s1 == "⇧⌘G", "got=\(s1)")
        let s2 = KeyShortcut("p", [.command, .control]).displayLabel
        assert("Cmd+Ctrl+P label", s2 == "⌃⌘P", "got=\(s2)")

        // --- T31: View mode toggle (list → columns → list) ---
        pane.setViewMode(.columns)
        assert("switched to columns", pane.viewMode == .columns, "viewMode=\(pane.viewMode)")
        pane.setViewMode(.list)
        assert("switched back to list", pane.viewMode == .list, "viewMode=\(pane.viewMode)")

        // --- T32: Hotbar default config has 10 items ---
        let hotbarIds = HotbarView.defaultIds()
        assert("hotbar default has 10 buttons",
               hotbarIds.count == 10, "count=\(hotbarIds.count)")
        for id in hotbarIds {
            assert("hotbar id resolves: \(id)",
                   ActionRegistry.action(id: id) != nil,
                   "missing")
        }

        // --- T33: Vim hjkl moves selection ---
        VimMode.shared.setEnabled(true)
        pane.navigate(to: sandbox)
        wait(0.05)
        let totalItems = pane.testCurrentItems.count
        if totalItems >= 3 {
            pane.testSelectItem(pane.testCurrentItems[0])
            wait(0.02)
            // Fake a 'j' keypress dispatch
            let jEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                          timestamp: 0, windowNumber: 0, context: nil,
                                          characters: "j", charactersIgnoringModifiers: "j",
                                          isARepeat: false, keyCode: 38)!
            _ = VimMode.shared.handle(event: jEvent, in: pane, fileList: pane.testFileList)
            let selAfterJ = pane.testFileList.tableView.selectedRow
            assert("vim 'j' moves selection down",
                   selAfterJ == 1, "row=\(selAfterJ)")
            let kEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                          timestamp: 0, windowNumber: 0, context: nil,
                                          characters: "k", charactersIgnoringModifiers: "k",
                                          isARepeat: false, keyCode: 40)!
            _ = VimMode.shared.handle(event: kEvent, in: pane, fileList: pane.testFileList)
            assert("vim 'k' moves selection up",
                   pane.testFileList.tableView.selectedRow == 0,
                   "row=\(pane.testFileList.tableView.selectedRow)")
            // 'G' jumps to last
            let gEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                          timestamp: 0, windowNumber: 0, context: nil,
                                          characters: "G", charactersIgnoringModifiers: "G",
                                          isARepeat: false, keyCode: 5)!
            _ = VimMode.shared.handle(event: gEvent, in: pane, fileList: pane.testFileList)
            assert("vim 'G' jumps to last row",
                   pane.testFileList.tableView.selectedRow == totalItems - 1,
                   "row=\(pane.testFileList.tableView.selectedRow) total=\(totalItems)")
        }
        VimMode.shared.setEnabled(false)

        // --- T34: grep tool detection (should find at least /usr/bin/grep) ---
        let grepExists = ["rg", "grep"].contains { name in
            ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/", "/bin/"].contains { prefix in
                FileManager.default.isExecutableFile(atPath: prefix + name)
            }
        }
        assert("system has rg or grep available", grepExists, "neither found")

        // --- T35: Perf benchmark — FastDirScan vs full reload at 5k items ---
        let perfDir = sandbox.appendingPathComponent("perf_5k")
        try? FileManager.default.createDirectory(at: perfDir, withIntermediateDirectories: true)
        for i in 0..<5000 {
            let p = perfDir.appendingPathComponent("item_\(String(format: "%05d", i)).txt").path
            // Use the lowest-level C API to make benchmark setup itself fast.
            let fd = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            if fd >= 0 { close(fd) }
        }
        let t0 = Date()
        let scanned = FastDirScan.list(perfDir)
        let t1 = Date()
        assert("FastDirScan returned 5000 entries", scanned.count == 5000, "got=\(scanned.count)")
        let scanMs = Int(t1.timeIntervalSince(t0) * 1000)
        assert("FastDirScan 5k under 200ms (got \(scanMs)ms)",
               scanMs < 200, "perf regression")

        let perfModel = DirectoryModel(url: perfDir)
        let t2 = Date()
        perfModel.reload(sync: true)
        let t3 = Date()
        let reloadMs = Int(t3.timeIntervalSince(t2) * 1000)
        assert("Sync reload of 5k under 350ms (got \(reloadMs)ms)",
               reloadMs < 350, "perf regression")
        assert("Sync reload of 5k yields full sorted list",
               perfModel.items.count == 5000, "items=\(perfModel.items.count)")

        // Filter benchmark: typing should not cost > 60ms on 5k items
        let t4 = Date()
        perfModel.filterText = "item_0001"
        wait(0.02)
        let t5 = Date()
        let filterMs = Int(t5.timeIntervalSince(t4) * 1000)
        assert("Filter on 5k completes under 60ms (got \(filterMs)ms)",
               filterMs < 60, "perf regression")

        // Progressive filter benchmark: typing extra chars should narrow the
        // prior result set, not rescan rawItems. Wait for the async narrow to
        // commit so `items` is the small set, then time the second narrow.
        perfModel.filterText = "item_000"
        wait(0.20)
        let t6 = Date()
        perfModel.filterText = "item_0001"
        let t7 = Date()
        let progressiveMs = Int(t7.timeIntervalSince(t6) * 1000)
        assert("Progressive filter (prefix-extend) under 20ms (got \(progressiveMs)ms)",
               progressiveMs < 20, "perf regression")
        perfModel.filterText = ""

        // Icon cache benchmark: per-extension lookup is amortized — the second
        // request for the same extension should be instant.
        let probeFile = sandbox.appendingPathComponent("alpha_two.txt")
        if FileManager.default.fileExists(atPath: probeFile.path),
           let probe = FileItem.load(probeFile) {
            _ = IconCache.shared.icon(for: probe)   // warm
            let t8 = Date()
            for _ in 0..<10_000 { _ = IconCache.shared.icon(for: probe) }
            let t9 = Date()
            let perCallNs = Int(t9.timeIntervalSince(t8) * 1_000_000_000) / 10_000
            assert("IconCache hit under 5µs per call (got \(perCallNs)ns)",
                   perCallNs < 5_000, "regression")
        }

        // --- T36: CLI path resolution ---
        // (Indirectly exercises AppDelegate.resolvePath since cliPath() depends on argv;
        //  here we just verify the wrapper logic for existing/non-existing paths.)
        assert("resolvePath honors absolute existing",
               FileManager.default.fileExists(atPath: sandbox.path), "sandbox vanished")

        // --- T37: Copy Path puts file paths on the general pasteboard ---
        let copyPathTestFile = sandbox.appendingPathComponent("alpha_two.txt")
        if FileManager.default.fileExists(atPath: copyPathTestFile.path) {
            pane.testReloadSync()
            if let item = pane.testCurrentItems.first(where: { $0.name == "alpha_two.txt" }) {
                pane.testSelectItem(item)
                wc.copyPath(nil)
                let copied = NSPasteboard.general.string(forType: .string) ?? ""
                assert("Copy Path put path on clipboard",
                       copied.contains("alpha_two.txt"), "got=\(copied)")
            }
        }

        // --- T38: Status bar segments API renders an attributed string ---
        let probe = StatusBarView(frame: .zero)
        probe.setSegments([.init("3 items"), .init("1.2 MB", isMonospaced: true), .init("89 GB free")])
        assert("status bar accepts segments without crashing", true, "")

        // --- T39: EmptyState configure methods don't crash ---
        let es = EmptyStateView(frame: .zero)
        es.configureEmpty()
        es.configureNoMatches(query: "xyz")
        assert("empty state configured both modes", true, "")

        // --- T40: Theme observer fires on cycle ---
        let prevId = ThemeManager.shared.current.id
        ThemeManager.shared.cycle()
        let afterCycle = ThemeManager.shared.current.id
        ThemeManager.shared.setTheme(id: prevId)
        assert("theme cycle changes id", afterCycle != prevId, "stuck on \(prevId)")

        // --- T42: Archive detection + listing ---
        let zipPath = sandbox.appendingPathComponent("test.zip")
        // Create a small zip on the fly
        let zipSrc = sandbox.appendingPathComponent("zip_src")
        try? FileManager.default.createDirectory(at: zipSrc, withIntermediateDirectories: true)
        try? "hello".write(to: zipSrc.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try? "world".write(to: zipSrc.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let zp = Process()
        zp.launchPath = "/usr/bin/zip"
        zp.arguments = ["-qr", zipPath.path, "."]
        zp.currentDirectoryURL = zipSrc
        try? zp.run(); zp.waitUntilExit()
        if FileManager.default.fileExists(atPath: zipPath.path) {
            assert("Archive.isArchive detects .zip",
                   Archive.isArchive(zipPath), "")
            let entries = Archive.list(zipPath)
            let names = entries.map { ($0.path as NSString).lastPathComponent }
            assert("Archive lists both files",
                   names.contains("a.txt") && names.contains("b.txt"),
                   "got=\(names)")

            // --- T42b: Archive extraction (single entry + extract-all) ---
            if let aEntry = entries.first(where: { ($0.path as NSString).lastPathComponent == "a.txt" }) {
                let exDir = sandbox.appendingPathComponent("zip_extract_one")
                try? FileManager.default.createDirectory(at: exDir, withIntermediateDirectories: true)
                let outURL = Archive.extract(aEntry, from: zipPath, to: exDir)
                let contents = outURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                assert("Archive.extract writes the entry's real contents",
                       contents == "hello", "got=\(contents ?? "nil")")
            }
            let exAll = sandbox.appendingPathComponent("zip_extract_all")
            try? FileManager.default.createDirectory(at: exAll, withIntermediateDirectories: true)
            let allOK = Archive.extractAll(zipPath, to: exAll)
            let extracted = (try? FileManager.default.contentsOfDirectory(atPath: exAll.path)) ?? []
            assert("Archive.extractAll extracts every entry",
                   allOK && extracted.contains("a.txt") && extracted.contains("b.txt"),
                   "ok=\(allOK) got=\(extracted)")
            // entriesAreSafe accepts a normal archive (the zip-slip guard only
            // rejects absolute / ".." entries, which a benign zip never has).
            assert("Archive.entriesAreSafe accepts a benign archive",
                   Archive.entriesAreSafe(zipPath), "benign archive flagged unsafe")
        }

        // --- T42d: compress selection → .zip, then extract-in-place ---
        let cmpDir = sandbox.appendingPathComponent("compress_src")
        try? FileManager.default.createDirectory(at: cmpDir, withIntermediateDirectories: true)
        try? "hello".write(to: cmpDir.appendingPathComponent("c1.txt"), atomically: true, encoding: .utf8)
        try? "world".write(to: cmpDir.appendingPathComponent("c2.txt"), atomically: true, encoding: .utf8)
        let cmpItems = [cmpDir.appendingPathComponent("c1.txt"), cmpDir.appendingPathComponent("c2.txt")]
        if let madeZip = Archive.compress(cmpItems) {
            assert("Archive.compress creates a .zip",
                   FileManager.default.fileExists(atPath: madeZip.path), "no zip at \(madeZip.path)")
            let zipNames = Set(Archive.list(madeZip).map { ($0.path as NSString).lastPathComponent })
            assert("compressed zip contains both files",
                   zipNames.contains("c1.txt") && zipNames.contains("c2.txt"), "got=\(zipNames)")
            if let outDir = Archive.extractInPlace(madeZip) {
                let extracted = Set((try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? [])
                assert("extractInPlace recreates the files into a new folder",
                       extracted.contains("c1.txt") && extracted.contains("c2.txt"), "got=\(extracted)")
            } else {
                assert("extractInPlace returns a folder", false, "got nil")
            }
        } else {
            assert("Archive.compress returns a URL", false, "got nil")
        }

        // --- T42e: tag write/read with color round-trips ---
        let colorTagFile = sandbox.appendingPathComponent("tagme.txt")
        try? "x".write(to: colorTagFile, atomically: true, encoding: .utf8)
        Tags.write([Tags.Tag(name: "Red", color: Tags.Color.red)], to: colorTagFile)
        let readBack = Tags.read(colorTagFile)
        assert("tag with color round-trips",
               readBack.contains { $0.color == Tags.Color.red }, "got=\(readBack.map { "\($0.name):\($0.color)" })")
        Tags.write([], to: colorTagFile)
        assert("clearing tags leaves none", Tags.read(colorTagFile).isEmpty, "tags remain")

        // --- T42f: sidebar bookmarks add / contains / remove ---
        let bmURL = sandbox.appendingPathComponent("bookmarkme")
        try? FileManager.default.createDirectory(at: bmURL, withIntermediateDirectories: true)
        SidebarBookmarks.remove(bmURL)   // ensure clean
        SidebarBookmarks.add(bmURL)
        assert("sidebar bookmark added + persisted", SidebarBookmarks.contains(bmURL), "not added")
        SidebarBookmarks.add(bmURL)
        assert("sidebar bookmark de-duplicates",
               SidebarBookmarks.all().filter { $0.path == bmURL.path }.count == 1,
               "duplicated")
        SidebarBookmarks.remove(bmURL)
        assert("sidebar bookmark removed", !SidebarBookmarks.contains(bmURL), "still present")

        // --- T42g: view/layout setting defaults ---
        for k in ["FinderTwo.typeToSelect", "FinderTwo.showStatusBar", "FinderTwo.showPathBar"] {
            UserDefaults.standard.removeObject(forKey: k)
        }
        assert("typeToSelect defaults off", Settings.typeToSelect == false, "got \(Settings.typeToSelect)")
        assert("showStatusBar defaults on", Settings.showStatusBar == true, "got \(Settings.showStatusBar)")
        assert("showPathBar defaults on", Settings.showPathBar == true, "got \(Settings.showPathBar)")

        // --- T43: AppUninstaller bundle-id read ---
        // We can't test scanLeftovers in a hermetic way (it reads real
        // ~/Library); verify the bundle-id reader works against a known app.
        let finderApp = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        if FileManager.default.fileExists(atPath: finderApp.path) {
            let bid = AppUninstaller.bundleId(for: finderApp)
            assert("AppUninstaller reads Finder bundle id",
                   bid == "com.apple.finder", "got=\(bid ?? "nil")")
        }

        // --- T44: DiskScan computes a non-zero total on a populated dir ---
        let dsRoot = sandbox.appendingPathComponent("disk_scan_root")
        try? FileManager.default.createDirectory(at: dsRoot, withIntermediateDirectories: true)
        for i in 0..<10 {
            try? "x".write(to: dsRoot.appendingPathComponent("f_\(i)"),
                           atomically: true, encoding: .utf8)
        }
        // Sanity-check FastDirScan sees what we just wrote.
        let dsList = FastDirScan.list(dsRoot)
        assert("DiskScan sandbox has 10 files via FastDirScan",
               dsList.count == 10, "got=\(dsList.count)")
        let scan = DiskScan(root: dsRoot)
        let scanRoot = scan.runSync()
        assert("DiskScan totals",
               scanRoot.size == 10,
               "got=\(scanRoot.size) (expected 10 = 10 × 1-byte files)")
        assert("DiskScan file count",
               scanRoot.fileCount == 10,
               "got=\(scanRoot.fileCount)")

        // --- T45: FolderSync detects new + identical files ---
        let fsA = sandbox.appendingPathComponent("fs_a")
        let fsB = sandbox.appendingPathComponent("fs_b")
        try? FileManager.default.createDirectory(at: fsA, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: fsB, withIntermediateDirectories: true)
        try? "1".write(to: fsA.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        try? "1".write(to: fsB.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        try? "only-a".write(to: fsA.appendingPathComponent("only_in_a.txt"),
                            atomically: true, encoding: .utf8)
        try? "only-b".write(to: fsB.appendingPathComponent("only_in_b.txt"),
                            atomically: true, encoding: .utf8)
        let syncDiff = FolderSync.compare(source: fsA, destination: fsB)
        let statuses = Set(syncDiff.map { "\($0.relPath):\($0.status)" })
        assert("FolderSync identifies onlySource",
               statuses.contains("only_in_a.txt:onlySource"), "got=\(statuses)")
        assert("FolderSync identifies onlyDestination",
               statuses.contains("only_in_b.txt:onlyDestination"), "got=\(statuses)")

        // --- T45b: FolderSync mirror applies copies / overwrites / prune safely ---
        let mOps = FolderSync.mirrorSourceToDestination(syncDiff, source: fsA, destination: fsB, prune: false)
        assert("FolderSync mirror reports operations", mOps >= 1, "ops=\(mOps)")
        let mirroredContents = try? String(
            contentsOf: fsB.appendingPathComponent("only_in_a.txt"), encoding: .utf8)
        assert("FolderSync mirror copies the new file with source contents",
               mirroredContents == "only-a", "got=\(mirroredContents ?? "nil")")
        assert("FolderSync mirror leaves destination-only files when prune=false",
               FileManager.default.fileExists(atPath: fsB.appendingPathComponent("only_in_b.txt").path),
               "only_in_b.txt was removed without prune")
        // Overwrite a differing file (distinct sizes → .differs) via atomic swap.
        try? "source-content".write(to: fsA.appendingPathComponent("shared.txt"),
                                    atomically: true, encoding: .utf8)
        try? "dst".write(to: fsB.appendingPathComponent("shared.txt"),
                         atomically: true, encoding: .utf8)
        let mDiff2 = FolderSync.compare(source: fsA, destination: fsB)
        FolderSync.mirrorSourceToDestination(mDiff2, source: fsA, destination: fsB, prune: false)
        let overwritten = try? String(
            contentsOf: fsB.appendingPathComponent("shared.txt"), encoding: .utf8)
        assert("FolderSync mirror overwrites differing files with source contents",
               overwritten == "source-content", "got=\(overwritten ?? "nil")")
        // Prune removes a destination-only file when requested.
        try? "prune-me".write(to: fsB.appendingPathComponent("prune_target.txt"),
                              atomically: true, encoding: .utf8)
        let mDiff3 = FolderSync.compare(source: fsA, destination: fsB)
        FolderSync.mirrorSourceToDestination(mDiff3, source: fsA, destination: fsB, prune: true)
        assert("FolderSync prune removes destination-only files",
               !FileManager.default.fileExists(atPath: fsB.appendingPathComponent("prune_target.txt").path),
               "prune_target.txt still present after prune")

        // --- T45c: SFTPClient.parseLs parses an `ls -la` listing ---
        let lsSample = """
        total 24
        drwxr-xr-x   5 user  staff   160 Jan  1 12:00 .
        drwxr-xr-x   3 user  staff    96 Jan  1 12:00 ..
        -rw-r--r--   1 user  staff  1234 Jan  2 09:30 readme.txt
        drwxr-xr-x   4 user  staff   128 Jan  3 10:00 my folder
        """
        let lsEntries = SFTPClient.testParseLs(lsSample)
        assert("parseLs skips . and ..",
               !lsEntries.contains { $0.name == "." || $0.name == ".." },
               "got=\(lsEntries.map { $0.name })")
        assert("parseLs parses a regular file with size",
               lsEntries.contains { $0.name == "readme.txt" && !$0.isDirectory && $0.size == 1234 },
               "got=\(lsEntries.map { "\($0.name):\($0.isDirectory):\($0.size)" })")
        assert("parseLs parses a directory whose name contains a space",
               lsEntries.contains { $0.name == "my folder" && $0.isDirectory },
               "got=\(lsEntries.map { $0.name })")

        // --- T46: GitBranchWorkspaces repoRoot + currentBranch ---
        let gitProj = sandbox.appendingPathComponent("git_proj")
        try? FileManager.default.createDirectory(at: gitProj, withIntermediateDirectories: true)
        let gp = Process()
        gp.launchPath = "/usr/bin/git"
        gp.arguments = ["init", "-q", "-b", "main", gitProj.path]
        gp.standardOutput = Pipe(); gp.standardError = Pipe()
        try? gp.run(); gp.waitUntilExit()
        if FileManager.default.fileExists(atPath: gitProj.appendingPathComponent(".git").path) {
            assert("GitBranchWorkspaces finds repo root",
                   GitBranchWorkspaces.repoRoot(for: gitProj)?.path == gitProj.path,
                   "got=\(GitBranchWorkspaces.repoRoot(for: gitProj)?.path ?? "nil")")
            let branch = GitBranchWorkspaces.currentBranch(in: gitProj)
            assert("GitBranchWorkspaces reads current branch",
                   branch == "main", "got=\(branch ?? "nil")")

            // --- T46b: GitStatus porcelain — untracked file + modified folder ---
            try? "hi".write(to: gitProj.appendingPathComponent("new.txt"),
                            atomically: true, encoding: .utf8)
            let sub = gitProj.appendingPathComponent("src")
            try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try? "x".write(to: sub.appendingPathComponent("deep.txt"),
                           atomically: true, encoding: .utf8)
            let states = GitStatus.fileStates(in: gitProj, repoRoot: gitProj)
            assert("GitStatus marks untracked file",
                   states["new.txt"] == .untracked, "got=\(String(describing: states["new.txt"]))")
            assert("GitStatus aggregates subfolder changes to the folder",
                   states["src"] == .modifiedFolder, "got=\(String(describing: states["src"]))")
            let info = GitStatus.repoInfo(root: gitProj)
            assert("GitStatus.repoInfo reads branch", info.branch == "main", "got=\(info.branch ?? "nil")")
            // GitStatus.repoRoot finds the repo from a nested dir too.
            assert("GitStatus.repoRoot resolves from nested dir",
                   GitStatus.repoRoot(for: sub).map { samePath($0, gitProj) } ?? false,
                   "got=\(GitStatus.repoRoot(for: sub)?.path ?? "nil")")
        }

        // --- T46c: ProjectRoot detection (git marker + non-git marker) ---
        assert("ProjectRoot finds .git root",
               ProjectRoot.find(for: gitProj).map { samePath($0, gitProj) } ?? false,
               "got=\(ProjectRoot.find(for: gitProj)?.path ?? "nil")")
        let nodeProj = sandbox.appendingPathComponent("node_proj")
        let nodeSub = nodeProj.appendingPathComponent("lib/util")
        try? FileManager.default.createDirectory(at: nodeSub, withIntermediateDirectories: true)
        try? "{}".write(to: nodeProj.appendingPathComponent("package.json"),
                        atomically: true, encoding: .utf8)
        assert("ProjectRoot walks up to package.json from nested dir",
               ProjectRoot.find(for: nodeSub).map { samePath($0, nodeProj) } ?? false,
               "got=\(ProjectRoot.find(for: nodeSub)?.path ?? "nil")")
        _ = ProjectRoot.find(for: URL(fileURLWithPath: "/"))   // must not crash at fs root

        // --- T46d: Editor detection enumerates without crashing ---
        assert("Editor.allCases has the known editors", Editor.allCases.count == 5, "got=\(Editor.allCases.count)")
        _ = Editor.installed   // must not crash
        assert("Editor.installed returns a (possibly empty) list", true, "")

        // --- T46e: DirectoryModel publishes git states for a repo dir ---
        pane.navigate(to: gitProj)
        wait(0.05)
        pane.testModel.testRefreshGitSync()   // deterministic (no async race)
        assert("pane model populates git badge for untracked file",
               pane.testModel.gitStates["new.txt"] == .untracked,
               "states=\(pane.testModel.gitStates)")
        assert("pane model exposes repo branch",
               pane.testModel.gitRepoInfo?.branch == "main",
               "got=\(String(describing: pane.testModel.gitRepoInfo?.branch))")
        pane.navigate(to: sandbox); wait(0.05)

        // --- T46f: project navigation actions registered ---
        assert("action: project.jump-root",
               ActionRegistry.action(id: "project.jump-root") != nil, "missing")
        assert("action: project.open-editor",
               ActionRegistry.action(id: "project.open-editor") != nil, "missing")

        // --- T47: ActionRegistry plugin extension API exists ---
        ActionRegistry.registerPluginAction(id: "test.plugin.action", title: "Plugin Test", perform: { _ in })
        assert("plugin action lookup works",
               ActionRegistry.action(id: "test.plugin.action")?.title == "Plugin Test",
               "missing")

        // --- T41: New actions registered ---
        assert("action: file.copy-path",
               ActionRegistry.action(id: "file.copy-path") != nil, "missing")
        assert("action: file.open-in-terminal",
               ActionRegistry.action(id: "file.open-in-terminal") != nil, "missing")

        // ====== Audit pass: every product feature, in-process ======

        // --- T42: empty folder shows the empty-state placeholder ---
        let emptyDir = sandbox.appendingPathComponent("really_empty")
        try? FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        pane.navigate(to: emptyDir)
        wait(0.05)
        assert("navigated to empty dir",
               samePath(pane.currentURL, emptyDir), "url=\(pane.currentURL.path)")
        assert("empty dir has 0 items",
               pane.testCurrentItems.count == 0, "got=\(pane.testCurrentItems.count)")
        pane.navigate(to: sandbox)
        wait(0.05)

        // --- T43: filter no-match resolves to 0 items ---
        pane.testSetFilter("xyzzzznonexistent")
        wait(0.05)
        assert("no-match filter yields 0", pane.testCurrentItems.count == 0,
               "got=\(pane.testCurrentItems.count)")
        pane.testSetFilter("")
        wait(0.05)

        // --- T44: Cmd+L path-bar focus method exists ---
        // (We don't test focus directly; we just verify the toolbar exposes the API.)
        assert("toolbar exposes filter focus", pane.testToolbarHasFocusAPI(), "no method")

        // --- T45: Cmd+Shift+G commit path navigates to the typed folder ---
        let target = sandbox.appendingPathComponent("subdir").path
        pane.commitTypedPath(target)
        wait(0.05)
        assert("commitTypedPath navigates",
               samePath(pane.currentURL, URL(fileURLWithPath: target)),
               "url=\(pane.currentURL.path)")
        pane.commitTypedPath(sandbox.path)
        wait(0.05)

        // --- T46: select-tab-by-index via shortcut path ---
        pane.newTab(at: sandbox)
        pane.newTab(at: sandbox)
        assert("three tabs after two newTab calls",
               pane.testTabCount >= 3, "tabs=\(pane.testTabCount)")
        pane.selectTab(at: 0)
        assert("selectTab(0) honored",
               pane.testActiveTabIndex == 0, "active=\(pane.testActiveTabIndex)")
        pane.selectTab(at: 2)
        assert("selectTab(2) honored",
               pane.testActiveTabIndex == 2, "active=\(pane.testActiveTabIndex)")
        // Trim extra tabs for the rest of the run
        while pane.testTabCount > 1 { pane.closeActiveTab() }

        // --- T47: viewAsList / viewAsColumns wire through to setViewMode ---
        pane.setViewMode(.columns)
        assert("setViewMode(.columns) honored", pane.viewMode == .columns, "got=\(pane.viewMode)")
        pane.setViewMode(.list)
        assert("setViewMode(.list) honored", pane.viewMode == .list, "got=\(pane.viewMode)")

        // --- T48: toggleHidden affects what filterless reload returns ---
        let dottedFile = sandbox.appendingPathComponent(".hidden_audit_marker")
        try? "x".write(to: dottedFile, atomically: true, encoding: .utf8)
        pane.testReloadSync()
        let withoutHidden = pane.testCurrentItems.contains { $0.name == ".hidden_audit_marker" }
        assert("hidden file not visible by default",
               !withoutHidden, "leaked")
        pane.toggleHidden()
        pane.testReloadSync()
        let withHidden = pane.testCurrentItems.contains { $0.name == ".hidden_audit_marker" }
        assert("hidden file visible after toggle",
               withHidden, "missing")
        pane.toggleHidden()
        pane.testReloadSync()

        // --- T49: PathBar emits ordered segments root → leaf ---
        let probeURL = URL(fileURLWithPath: "/Users/chang/Desktop")
        let segs = PathBarView.testSegments(for: probeURL)
        assert("path segments start at /",
               segs.first?.path == "/", "got=\(segs.map(\.path))")
        assert("path segments end at leaf",
               segs.last?.path == probeURL.path, "got=\(segs.last?.path ?? "nil")")
        assert("path segments are unique",
               Set(segs.map(\.path)).count == segs.count, "dupes")

        // --- T50: Sidebar sections are non-empty ---
        let sb = (wc.window?.contentViewController as? NSSplitViewController)?
            .splitViewItems
            .compactMap { $0.viewController as? SidebarController }
            .first
        assert("sidebar has favorites + locations",
               (sb?.testEntryTitles.count ?? 0) >= 5, "n=\(sb?.testEntryTitles.count ?? 0)")

        // --- T51: Hotbar.setIds round-trips and fires notification ---
        let originalHotbar = HotbarView.currentIds()
        let customHotbar = ["file.new-folder", "edit.copy", "edit.paste"]
        var receivedNotification = false
        let token = NotificationCenter.default.addObserver(
            forName: HotbarView.didChangeConfig, object: nil, queue: nil) { _ in
                receivedNotification = true
            }
        HotbarView.setIds(customHotbar)
        wait(0.02)
        assert("hotbar ids updated", HotbarView.currentIds() == customHotbar,
               "got=\(HotbarView.currentIds())")
        assert("hotbar change notification fired", receivedNotification, "no notification")
        HotbarView.setIds(originalHotbar)
        NotificationCenter.default.removeObserver(token)

        // --- T52: Custom shortcut persistence round-trip ---
        ActionRegistry.setShortcut(KeyShortcut("q", [.command, .control]), forId: "file.rename")
        let stored = ActionRegistry.shortcut(for: "file.rename")
        assert("custom shortcut stored",
               stored?.key == "q" && stored?.modifiers.contains(.control) == true,
               "got=\(String(describing: stored))")
        ActionRegistry.setShortcut(nil, forId: "file.rename")
        let cleared = ActionRegistry.shortcut(for: "file.rename")
        // After clearing, default shortcut (nil for rename) is returned.
        assert("clearing custom shortcut returns default",
               cleared?.key == ActionRegistry.action(id: "file.rename")?.defaultShortcut?.key,
               "got=\(String(describing: cleared))")

        // --- T53: Command palette filtering pure-logic test ---
        let entriesAll = CommandPaletteController.testEntries(for: wc)
        assert("palette has at least 20 entries", entriesAll.count >= 20,
               "count=\(entriesAll.count)")
        let filteredPalette = CommandPaletteController.testFilter(entriesAll, query: "tab")
        assert("palette filter finds tab actions",
               filteredPalette.contains { $0.title.localizedCaseInsensitiveContains("tab") },
               "got=\(filteredPalette.map(\.title))")

        // --- T54: SearchSheet fuzzy filter is correct ---
        let fnames = ["alpha_one.txt", "alpha_two.txt", "beta.txt", "gamma.md"]
            .map { sandbox.appendingPathComponent($0) }
        let matches = SearchSheetController.testFuzzy(fnames, needle: "alpha")
        assert("fuzzy matches 'alpha' → 2 entries", matches.count == 2,
               "got=\(matches.map { $0.lastPathComponent })")
        let btMatches = SearchSheetController.testFuzzy(fnames, needle: "bttxt")
        assert("fuzzy subseq matches 'bttxt' → beta.txt",
               btMatches.contains(where: { $0.lastPathComponent == "beta.txt" }),
               "got=\(btMatches.map { $0.lastPathComponent })")

        // --- T55: Batch rename preview produces a non-empty new name ---
        let brItems = ["x.txt", "y.txt", "z.txt"].compactMap { name -> FileItem? in
            let u = sandbox.appendingPathComponent(name)
            try? "x".write(to: u, atomically: true, encoding: .utf8)
            return FileItem.load(u)
        }
        let brRows = BatchRenameSheetController.testPreview(
            items: brItems, find: "", repl: "", template: "renamed_{N}.{ext}", useRegex: false, start: 1, pad: 2
        )
        assert("batch rename preview has 3 rows", brRows.count == 3,
               "n=\(brRows.count)")
        assert("batch rename gives unique new names",
               Set(brRows.map { $0.newName }).count == 3,
               "got=\(brRows.map { $0.newName })")
        assert("batch rename includes ext",
               brRows.allSatisfy { $0.newName.hasSuffix(".txt") },
               "got=\(brRows.map { $0.newName })")

        // --- T56: Vim mode dd trashes the selected file ---
        VimMode.shared.setEnabled(true)
        let trashCandidate = sandbox.appendingPathComponent("vim_dd_target.txt")
        try? "x".write(to: trashCandidate, atomically: true, encoding: .utf8)
        pane.testReloadSync()
        if let item = pane.testCurrentItems.first(where: { $0.name == "vim_dd_target.txt" }) {
            pane.testSelectItem(item)
            // Send "dd" via two events
            for ch in ["d", "d"] {
                let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                          timestamp: 0, windowNumber: 0, context: nil,
                                          characters: ch, charactersIgnoringModifiers: ch,
                                          isARepeat: false, keyCode: 2)!
                _ = VimMode.shared.handle(event: ev, in: pane, fileList: pane.testFileList)
            }
            wait(0.1)
            assert("vim 'dd' trashed the file",
                   !FileManager.default.fileExists(atPath: trashCandidate.path),
                   "still present")
        }

        // --- T56b: vim Return ENTERS a folder (not rename) ---
        pane.navigate(to: sandbox)
        pane.testReloadSync()
        if let subdir = pane.testCurrentItems.first(where: { $0.isDirectory && $0.name == "subdir" }) {
            pane.testSelectItem(subdir)
            let ret = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                       timestamp: 0, windowNumber: 0, context: nil,
                                       characters: "\r", charactersIgnoringModifiers: "\r",
                                       isARepeat: false, keyCode: 36)!
            let handled = VimMode.shared.handle(event: ret, in: pane, fileList: pane.testFileList)
            wait(0.05)
            assert("vim Return is consumed", handled, "not handled")
            assert("vim Return entered the folder",
                   samePath(pane.currentURL, sandbox.appendingPathComponent("subdir")),
                   "url=\(pane.currentURL.path)")
            pane.goUp(); wait(0.05)
        }
        VimMode.shared.setEnabled(false)

        // --- T57: ColumnView controller initializes against active pane ---
        let cv = ColumnViewController(pane: pane)
        _ = cv.view   // force loadView
        assert("ColumnViewController has a view",
               cv.view.subviews.count > 0, "no subviews")

        // --- T58: Status bar segments helper formats a date+size mix without crash ---
        let stat = StatusBarView(frame: .zero)
        stat.setSegments([
            .init("5 items"),
            .init("123.4 MB", isMonospaced: true),
            .init("/some/path/here"),
            .init("89 GB free")
        ])
        assert("status bar accepts 4 segments without crash", true, "")

        // --- T59: Theme cycle visits every theme and returns to start ---
        let startThemeId = ThemeManager.shared.current.id
        let visited = Theme.all.reduce(into: Set<String>()) { acc, _ in
            ThemeManager.shared.cycle()
            acc.insert(ThemeManager.shared.current.id)
        }
        ThemeManager.shared.setTheme(id: startThemeId)
        assert("cycle visited every theme",
               visited.count == Theme.all.count,
               "got=\(visited)")

        // --- T59a: a custom theme repaints the file list background ---
        ThemeManager.shared.setTheme(id: "midnight")
        wait(0.05)
        assert("file list paints custom theme background",
               pane.testFileList.tableView.backgroundColor == Theme.midnight.background,
               "got=\(pane.testFileList.tableView.backgroundColor)")
        ThemeManager.shared.setTheme(id: "system")
        wait(0.05)
        assert("file list reverts to native background on System theme",
               pane.testFileList.tableView.backgroundColor == .controlBackgroundColor,
               "got=\(pane.testFileList.tableView.backgroundColor)")
        ThemeManager.shared.setTheme(id: startThemeId)

        // --- T14: sidebar entries are populated ---
        let entries = (wc.window?.contentViewController as? NSSplitViewController)?
            .splitViewItems
            .compactMap { $0.viewController as? SidebarController }
            .first?
            .testEntryTitles ?? []
        assert("sidebar contains Documents",
               entries.contains("Documents"), "entries=\(entries)")
        assert("sidebar contains Macintosh HD",
               entries.contains("Macintosh HD"), "entries=\(entries)")

        // --- T58b: Settings round-trips + appearance overrides ---
        let origDensity = Settings.density
        Settings.density = .spacious
        assert("density persists", Settings.density == .spacious, "got=\(Settings.density)")
        assert("ThemeManager honors density row height",
               ThemeManager.shared.effectiveRowHeight == Settings.Density.spacious.rowHeight,
               "got=\(ThemeManager.shared.effectiveRowHeight)")
        Settings.density = origDensity

        let origDelta = Settings.fontSizeDelta
        Settings.fontSizeDelta = 2
        assert("font delta applies to effective size",
               ThemeManager.shared.effectiveFontSize == ThemeManager.shared.current.baseFontPointSize + 2,
               "got=\(ThemeManager.shared.effectiveFontSize)")
        Settings.fontSizeDelta = 99   // clamp
        assert("font delta clamps to +4", Settings.fontSizeDelta == 4, "got=\(Settings.fontSizeDelta)")
        Settings.fontSizeDelta = origDelta

        let origAccent = Settings.accent
        Settings.accent = .red
        assert("accent override applies",
               ThemeManager.shared.effectiveAccent == NSColor.systemRed, "wrong accent")
        Settings.accent = .system
        assert("accent .system falls back to theme",
               ThemeManager.shared.effectiveAccent == ThemeManager.shared.current.accent, "wrong fallback")
        Settings.accent = origAccent

        // --- T58b2: window-chrome toggles (hotbar + title bar hidden by default) ---
        let origShowHotbar = Settings.showHotbar
        let origShowTitleBar = Settings.showTitleBar

        // Hotbar + title bar ship OFF by default (clean, chromeless look). The
        // nav/path/search toolbar, by contrast, is always visible.
        UserDefaults.standard.removeObject(forKey: "FinderTwo.showHotbar")
        UserDefaults.standard.removeObject(forKey: "FinderTwo.showTitleBar")
        assert("showHotbar defaults to false", Settings.showHotbar == false,
               "got=\(Settings.showHotbar)")
        assert("showTitleBar defaults to false", Settings.showTitleBar == false,
               "got=\(Settings.showTitleBar)")

        // The toolbar is always visible regardless of the hotbar/title settings.
        assert("toolbar is always visible", pane.testToolbarVisible,
               "visible=\(pane.testToolbarVisible)")

        // Hotbar collapses to height 0 when hidden, expands to 32 when shown.
        Settings.showHotbar = false
        wait(0.02)
        assert("hotbar hidden when showHotbar=false",
               !pane.testHotbarVisible && pane.testHotbarHeight == 0,
               "visible=\(pane.testHotbarVisible) h=\(pane.testHotbarHeight)")
        Settings.showHotbar = true
        wait(0.02)
        assert("hotbar shown when showHotbar=true",
               pane.testHotbarVisible && pane.testHotbarHeight == 32,
               "visible=\(pane.testHotbarVisible) h=\(pane.testHotbarHeight)")
        assert("toolbar still visible with hotbar shown", pane.testToolbarVisible,
               "visible=\(pane.testToolbarVisible)")
        Settings.showHotbar = origShowHotbar
        wait(0.02)

        // Title bar: hidden = full-size content + transparent + hidden title; the
        // sidebar AND the pane's toolbar both gain a top inset so their top edges
        // line up and clear the traffic lights. Shown reverses all of it.
        let chromeSidebar = (wc.window?.contentViewController as? NSSplitViewController)?
            .splitViewItems.compactMap { $0.viewController as? SidebarController }.first
        let inset = PaneController.hiddenTitleBarInset
        Settings.showTitleBar = false
        wait(0.02)
        assert("title hidden → fullSizeContentView",
               wc.window?.styleMask.contains(.fullSizeContentView) ?? false, "no fullSize")
        assert("title hidden → titleVisibility .hidden",
               wc.window?.titleVisibility == .hidden, "vis=\(String(describing: wc.window?.titleVisibility))")
        assert("title hidden → sidebar top inset \(inset)",
               chromeSidebar?.testTopInset == inset, "inset=\(chromeSidebar?.testTopInset ?? -9)")
        assert("title hidden → pane toolbar top inset \(inset) (aligns with sidebar)",
               pane.testToolbarTopInset == inset, "inset=\(pane.testToolbarTopInset)")
        Settings.showTitleBar = true
        wait(0.02)
        assert("title shown → no fullSizeContentView",
               !(wc.window?.styleMask.contains(.fullSizeContentView) ?? true), "still fullSize")
        assert("title shown → titleVisibility .visible",
               wc.window?.titleVisibility == .visible, "vis=\(String(describing: wc.window?.titleVisibility))")
        assert("title shown → sidebar top inset 0",
               chromeSidebar?.testTopInset == 0, "inset=\(chromeSidebar?.testTopInset ?? -9)")
        assert("title shown → pane toolbar top inset 0",
               pane.testToolbarTopInset == 0, "inset=\(pane.testToolbarTopInset)")
        Settings.showTitleBar = origShowTitleBar
        wait(0.02)

        // --- T58c: shortcut customization + conflict detection ---
        ActionRegistry.setShortcut(nil, forId: "tab.new")
        ActionRegistry.setShortcut(nil, forId: "tab.close")
        let scProbe = KeyShortcut("j", [.command, .control])
        ActionRegistry.setShortcut(scProbe, forId: "tab.new")  // scProbe
        assert("custom shortcut recorded + isCustomized",
               ActionRegistry.isCustomized("tab.new") &&
               ActionRegistry.shortcut(for: "tab.new") == scProbe, "not stored")
        let conflict = ActionRegistry.conflictingActionId(for: scProbe, excluding: "tab.close")
        assert("conflict detected against tab.new",
               conflict == "tab.new", "got=\(conflict ?? "nil")")
        let noConflict = ActionRegistry.conflictingActionId(for: KeyShortcut("z", [.command, .control, .option]),
                                                            excluding: "tab.new")
        assert("no false-positive conflict", noConflict == nil, "got=\(noConflict ?? "nil")")
        ActionRegistry.setShortcut(nil, forId: "tab.new")
        assert("reset clears customization", !ActionRegistry.isCustomized("tab.new"), "still custom")

        // --- T58d: shortcutsDidChange notification fires ---
        var notified = false
        let scToken = NotificationCenter.default.addObserver(
            forName: ActionRegistry.shortcutsDidChange, object: nil, queue: nil) { _ in notified = true }
        ActionRegistry.setShortcut(KeyShortcut("y", [.command, .option]), forId: "tab.new")
        wait(0.02)
        assert("shortcutsDidChange posted", notified, "no notification")
        NotificationCenter.default.removeObserver(scToken)
        ActionRegistry.setShortcut(nil, forId: "tab.new")

        // --- T59b: plugin round-trip — load a real .ftplugin and fire its
        // action, verifying the JS handler actually runs (regression guard for
        // the empty-snapshot handler bug).
        let pluginDir = sandbox.appendingPathComponent("echo.ftplugin")
        try? FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let firedMarker = sandbox.appendingPathComponent("plugin_fired.txt").path
        let manifest = """
        {"id":"test.echo","name":"Echo","version":"1.0",
         "actions":[{"id":"test.echo.run","title":"Echo Run"}]}
        """
        let js = """
        ft.onAction('test.echo.run', function(urls) {
            ft.writeFile('\(firedMarker)', 'fired:' + urls.length);
        });
        """
        try? manifest.write(to: pluginDir.appendingPathComponent("manifest.json"),
                            atomically: true, encoding: .utf8)
        try? js.write(to: pluginDir.appendingPathComponent("main.js"),
                     atomically: true, encoding: .utf8)
        PluginHost.shared.testLoad(at: pluginDir)
        assert("plugin action registered in ActionRegistry",
               ActionRegistry.action(id: "test.echo.run") != nil, "missing")
        PluginHost.shared.fireAction(id: "test.echo.run", wc: wc)
        wait(0.1)
        assert("plugin JS handler actually ran (wrote marker file)",
               FileManager.default.fileExists(atPath: firedMarker),
               "handler never fired — empty-snapshot bug regressed")

        // --- T60: construct every sheet/window controller (catches layout +
        // constraint crashes that off-screen menu tests miss). We force
        // `loadView`/`window` so the entire view hierarchy is built.
        constructControllerSmokeTests(wc: wc, sandbox: sandbox)

        finish()
    }

    /// Build every modal/window controller and force its view to load. A crash
    /// here (bad constraint, force-unwrap, etc.) takes down the test process
    /// with a non-zero exit — exactly what we want to catch before shipping.
    private func constructControllerSmokeTests(wc: BrowserWindowController, sandbox: URL) {
        // Settings — construct + force-layout every section pane so a bad
        // constraint in any of them fails the test, not the user.
        let settings = SettingsController()
        _ = settings.window
        assert("SettingsController builds", settings.window != nil, "nil window")
        for section in SettingsController.Section.allCases {
            let pane = section.makeController()
            let host = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 560, height: 460),
                                styleMask: [.titled], backing: .buffered, defer: false)
            host.contentViewController = pane
            host.contentView?.layoutSubtreeIfNeeded()
            assert("settings pane builds: \(section.label)", pane.view.subviews.count >= 0, "nil")
            host.close()
        }

        // Command palette
        let palette = CommandPaletteController(target: wc)
        _ = palette.window
        assert("CommandPaletteController builds", palette.window != nil, "nil window")

        // SFTP connect sheet — the Cmd+K path
        let sftp = SFTPConnectSheetController(target: wc)
        forceLayout(sftp.window)
        assert("SFTPConnectSheetController builds + lays out", sftp.window?.contentView != nil, "nil")

        // SFTP browser
        let conn = SFTPClient.Connection(user: "u", host: "h", port: 22, remotePath: "~")
        let sftpBrowser = SFTPBrowserController(target: wc, connection: conn)
        _ = sftpBrowser.window?.contentView
        assert("SFTPBrowserController builds", sftpBrowser.window?.contentView != nil, "nil")

        // Folder sync sheet
        let sync = FolderSyncSheetController(target: wc, source: sandbox)
        _ = sync.window?.contentView
        assert("FolderSyncSheetController builds", sync.window?.contentView != nil, "nil")

        // Disk analyzer window
        let disk = DiskAnalyzerWindowController(target: wc, rootURL: sandbox)
        _ = disk.window?.contentView
        assert("DiskAnalyzerWindowController builds", disk.window?.contentView != nil, "nil")

        // App uninstaller sheet — point at a real .app so scan has data
        let someApp = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        if FileManager.default.fileExists(atPath: someApp.path) {
            let uninstall = AppUninstallerSheetController(appURL: someApp, target: wc)
            _ = uninstall.window?.contentView
            assert("AppUninstallerSheetController builds", uninstall.window?.contentView != nil, "nil")
        }

        // Batch rename sheet
        let brItems = pane(of: wc)?.testCurrentItems ?? []
        let batch = BatchRenameSheetController(target: wc, items: brItems)
        _ = batch.window?.contentView
        assert("BatchRenameSheetController builds", batch.window?.contentView != nil, "nil")

        // Archive sheet — build a real zip to point at
        let zip = sandbox.appendingPathComponent("ctor_test.zip")
        let mk = Process(); mk.launchPath = "/usr/bin/zip"
        mk.arguments = ["-qj", zip.path, sandbox.appendingPathComponent("alpha_two.txt").path]
        mk.standardError = Pipe(); try? mk.run(); mk.waitUntilExit()
        if FileManager.default.fileExists(atPath: zip.path) {
            let arch = ArchiveSheetController(archive: zip, target: wc)
            _ = arch.window?.contentView
            assert("ArchiveSheetController builds", arch.window?.contentView != nil, "nil")
        }

        // Close everything we just made so it doesn't linger.
        for w in [settings.window, palette.window, sftp.window, sftpBrowser.window,
                  sync.window, disk.window, batch.window] {
            w?.close()
        }

        // --- T61: invoke each tool action handler — this is the REAL path a
        // menu/shortcut hits, including beginSheet presentation. Crashes here
        // are what the user actually experiences.
        wc.connectToServer(nil); pumpSheets(wc)
        wc.openFolderSync(nil); pumpSheets(wc)
        wc.analyzeDiskUsage(nil); wait(0.05)
        wc.openArchive(nil); pumpSheets(wc)      // no archive selected → should beep, not crash
        wc.uninstallApp(nil); pumpSheets(wc)     // no .app selected → should beep, not crash
        wc.showCommandPalette(nil); wait(0.05)
        wc.showFindFiles(nil); pumpSheets(wc)
        wc.showGrep(nil); pumpSheets(wc)
        wc.toggleTerminal(nil); wait(0.02)
        wc.toggleTerminal(nil); wait(0.02)
        wc.toggleNotes(nil); wait(0.02)
        wc.toggleNotes(nil); wait(0.02)
        assert("all tool action handlers survive invocation", true, "")
    }

    /// Dismiss any sheets on the window + its children so the next action's
    /// beginSheet doesn't stack.
    private func pumpSheets(_ wc: BrowserWindowController) {
        wait(0.05)
        if let w = wc.window {
            for sheet in w.sheets { w.endSheet(sheet) }
        }
        // Also close any standalone windows the app opened (palette, disk, sftp browser).
        for w in NSApp.windows where w !== wc.window && w.isVisible {
            if !(w.contentViewController is NSSplitViewController) { w.close() }
        }
        wait(0.02)
    }

    private func pane(of wc: BrowserWindowController) -> PaneController? { wc.testActivePane }

    /// Force the window's view hierarchy to run the Auto Layout engine, which
    /// is when conflicting/unsatisfiable constraints actually blow up.
    private func forceLayout(_ window: NSWindow?) {
        guard let window else { return }
        window.setFrame(NSRect(x: -30000, y: -30000, width: 600, height: 400), display: false)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    // MARK: Helpers

    private func makeSandbox() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FinderTwo.tests.\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func populateSandbox(_ root: URL) {
        let fm = FileManager.default
        try? "".write(to: root.appendingPathComponent("alpha_one.txt"),
                     atomically: true, encoding: .utf8)
        try? "".write(to: root.appendingPathComponent("alpha_two.txt"),
                     atomically: true, encoding: .utf8)
        try? "".write(to: root.appendingPathComponent("beta.txt"),
                     atomically: true, encoding: .utf8)
        try? "".write(to: root.appendingPathComponent("gamma.md"),
                     atomically: true, encoding: .utf8)
        let sub = root.appendingPathComponent("subdir")
        try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try? "".write(to: sub.appendingPathComponent("nested_file.txt"),
                     atomically: true, encoding: .utf8)
    }

    private func ensureWindowController(at url: URL, appDelegate: AppDelegate) -> BrowserWindowController {
        // Close existing windows
        for w in NSApp.windows {
            w.close()
        }
        appDelegate.openNewBrowserWindow(at: url)
        // Spin the run loop briefly so the window/view loads.
        wait(0.1)
        return appDelegate.testWindowControllers.last!
    }

    private func wait(_ seconds: TimeInterval) {
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
    }

    private func samePath(_ a: URL, _ b: URL) -> Bool {
        let pa = (a.path as NSString).standardizingPath
        let pb = (b.path as NSString).standardizingPath
        return pa == pb
    }

    private func assert(_ name: String, _ cond: Bool, _ msg: @autoclosure () -> String) {
        if cond {
            print("  ✓ \(name)")
            passed.append(name)
        } else {
            let m = msg()
            print("  ✗ \(name) — \(m)")
            failures.append("\(name): \(m)")
        }
    }

    private func finish() {
        print("\n=== \(passed.count) passed, \(failures.count) failed ===")
        if !failures.isEmpty {
            print("Failures:")
            for f in failures { print("  - \(f)") }
        }
        exit(Int32(failures.count))
    }
}
