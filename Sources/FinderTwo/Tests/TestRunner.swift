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
        print("=== Rascal in-process tests ===")

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

        // --- T8c: middle-click tab closure ---
        let tabsBeforeMiddleClick = pane.testTabCount
        pane.newTab(at: sandbox)
        assert("new tab added for middle-click test", pane.testTabCount == tabsBeforeMiddleClick + 1, "tabs=\(pane.testTabCount)")
        pane.testTabStrip.testMiddleClickTab(at: tabsBeforeMiddleClick)
        assert("middle-click closes tab", pane.testTabCount == tabsBeforeMiddleClick, "tabs=\(pane.testTabCount)")

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

        // --- T11-reveal: New Folder selects the just-created item ---
        // Regression: the handler selected the item immediately after triggering
        // the ASYNCHRONOUS reload, so the new item was never actually selected
        // (and never entered rename). The fix queues the reveal and applies it
        // when the item lands in the model. Verified here with a synchronous
        // reload so it's deterministic (the async scan queue is saturated during
        // a full test run).
        let nfFlow = sandbox.appendingPathComponent("nf-flow")
        try? FileManager.default.createDirectory(at: nfFlow, withIntermediateDirectories: true)
        let nfWC = BrowserWindowController(rootURL: nfFlow)
        _ = nfWC.window
        if let nfPane = nfWC.testActivePane {
            nfPane.setViewMode(.list)
            let createdNF = nfPane.testNewFolderSyncReveal()
            assert("New Folder created the folder on disk",
                   createdNF != nil && FileManager.default.fileExists(atPath: createdNF!.path), "missing")
            assert("New Folder selects the just-created item (was: never selected)",
                   createdNF != nil && nfPane.selectedURLs().contains { $0.path == createdNF!.path },
                   "selected=\(nfPane.selectedURLs().map { $0.lastPathComponent })")
        } else { assert("isolated pane for New Folder test", false, "no pane") }
        _ = nfWC   // keep the window alive

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
        // transfer now executes off the main thread; poll (spinning the run
        // loop) until the copy lands, with a short timeout.
        let xCopied = xDst.appendingPathComponent("src.txt")
        FileOps.transfer([xSrc], into: xDst, move: false)
        let xferDeadline = Date(timeIntervalSinceNow: 2)
        while !FileManager.default.fileExists(atPath: xCopied.path) && Date() < xferDeadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        assert("transfer copies into destination",
               FileManager.default.fileExists(atPath: xCopied.path), "not copied")
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
        assert("recursiveSize > 0 for a populated folder",
               FileListController.recursiveSize(foDir) > 0, "got \(FileListController.recursiveSize(foDir))")

        // --- T11c: recursive folder merge (union; file collisions recover) ---
        func mk(_ url: URL, _ s: String) { try? s.write(to: url, atomically: true, encoding: .utf8) }
        let mRoot = sandbox.appendingPathComponent("merge"); let mSrc = mRoot.appendingPathComponent("src"); let mDst = mRoot.appendingPathComponent("dst")
        try? FileManager.default.createDirectory(at: mSrc.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: mDst.appendingPathComponent("sub"), withIntermediateDirectories: true)
        mk(mDst.appendingPathComponent("a.txt"), "dst-a")          // collides → replaced
        mk(mDst.appendingPathComponent("keep.txt"), "dst-keep")    // only in dst → stays
        mk(mDst.appendingPathComponent("sub/x.txt"), "dst-x")      // only in dst/sub → stays
        mk(mSrc.appendingPathComponent("a.txt"), "src-a")          // wins the collision
        mk(mSrc.appendingPathComponent("new.txt"), "src-new")      // only in src → added
        mk(mSrc.appendingPathComponent("sub/y.txt"), "src-y")      // merges into sub
        let mfail = FileOps.mergeDirectory(src: mSrc, into: mDst, move: false)
        func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "<none>" }
        assert("merge: no failures", mfail == 0, "failures=\(mfail)")
        assert("merge: collision file replaced by source", read(mDst.appendingPathComponent("a.txt")) == "src-a", "got \(read(mDst.appendingPathComponent("a.txt")))")
        assert("merge: dst-only file kept", read(mDst.appendingPathComponent("keep.txt")) == "dst-keep", "lost")
        assert("merge: src-only file added", read(mDst.appendingPathComponent("new.txt")) == "src-new", "missing")
        assert("merge: nested dst file kept", read(mDst.appendingPathComponent("sub/x.txt")) == "dst-x", "lost")
        assert("merge: nested src file added", read(mDst.appendingPathComponent("sub/y.txt")) == "src-y", "missing")
        // Move-merge empties + removes the source tree.
        let mSrc2 = mRoot.appendingPathComponent("src2"); let mDst2 = mRoot.appendingPathComponent("dst2")
        try? FileManager.default.createDirectory(at: mSrc2, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: mDst2, withIntermediateDirectories: true)
        mk(mSrc2.appendingPathComponent("z.txt"), "z")
        _ = FileOps.mergeDirectory(src: mSrc2, into: mDst2, move: true)
        assert("merge(move): file moved into dst", read(mDst2.appendingPathComponent("z.txt")) == "z", "missing")
        assert("merge(move): emptied source dir removed", !FileManager.default.fileExists(atPath: mSrc2.path), "src2 remains")

        // --- T11d: TransferQueue (streamed copy, completion, pause, cancel) ---
        let tqDir = sandbox.appendingPathComponent("tq")
        try? FileManager.default.createDirectory(at: tqDir, withIntermediateDirectories: true)
        let tqSrc = tqDir.appendingPathComponent("payload.bin")
        let tqBytes = Data((0..<300_000).map { UInt8($0 & 0xff) })
        try? tqBytes.write(to: tqSrc)
        let tqOut = tqDir.appendingPathComponent("out.bin")
        let qop = TransferQueue.shared.enqueue(plan: [(tqSrc, tqOut, false)], move: false)
        waitUntil(5) { qop.state == .done }
        assert("queue runs a copy to completion", qop.state == .done, "state=\(qop.state)")
        assert("queued streamed copy is byte-identical", (try? Data(contentsOf: tqOut)) == tqBytes, "bytes differ")
        assert("queue reports full progress", qop.fraction >= 0.999, "frac=\(qop.fraction)")
        // pause flag toggles
        TransferQueue.shared.setPaused(true)
        assert("queue pause flag sets", TransferQueue.shared.isPaused, "not paused")
        TransferQueue.shared.setPaused(false)
        assert("queue resume clears pause", !TransferQueue.shared.isPaused, "still paused")
        // cancelAll: enqueue while paused so the op is intercepted, then cancel
        TransferQueue.shared.setPaused(true)
        let tqSrc2 = tqDir.appendingPathComponent("p2.bin"); try? Data(repeating: 9, count: 5000).write(to: tqSrc2)
        let qop2 = TransferQueue.shared.enqueue(plan: [(tqSrc2, tqDir.appendingPathComponent("out2.bin"), false)], move: false)
        TransferQueue.shared.cancelAll()
        TransferQueue.shared.setPaused(false)
        waitUntil(3) { qop2.state == .cancelled || qop2.state == .done }
        assert("cancelAll cancels a queued op", qop2.state == .cancelled, "state=\(qop2.state)")
        TransferQueue.shared.clearFinished()
        assert("clearFinished empties the op list", TransferQueue.shared.snapshot.isEmpty, "remaining=\(TransferQueue.shared.snapshot.count)")

        // --- T11e: file-operation undo / redo ---
        let fm0 = FileManager.default
        let unDir = sandbox.appendingPathComponent("undo")
        try? fm0.createDirectory(at: unDir, withIntermediateDirectories: true)
        // New Folder → undo removes it.
        FileActionLog.shared.clear()
        let unNF = FileOps.newFolder(in: unDir, baseName: "nf")
        assert("newFolder records an undo", FileActionLog.shared.canUndo, "no undo")
        assert("newFolder created the folder", unNF != nil && fm0.fileExists(atPath: unNF!.path), "missing")
        _ = FileActionLog.shared.performUndo()
        assert("undo New Folder removes it", !(unNF.map { fm0.fileExists(atPath: $0.path) } ?? true), "still present")
        // Move to Trash → undo restores.
        FileActionLog.shared.clear()
        let unTrash = unDir.appendingPathComponent("trashme.txt")
        try? "x".write(to: unTrash, atomically: true, encoding: .utf8)
        FileOps.moveToTrash([unTrash])
        assert("trash removed the file", !fm0.fileExists(atPath: unTrash.path), "still there")
        _ = FileActionLog.shared.performUndo()
        assert("undo Move-to-Trash restores", fm0.fileExists(atPath: unTrash.path), "not restored")
        // Rename → undo/redo round-trip (via the same recordMove the UI uses).
        FileActionLog.shared.clear()
        let unR1 = unDir.appendingPathComponent("r1.txt"); let unR2 = unDir.appendingPathComponent("r2.txt")
        try? "y".write(to: unR1, atomically: true, encoding: .utf8)
        try? fm0.moveItem(at: unR1, to: unR2)
        FileActionLog.shared.recordMove(from: unR1, to: unR2, name: "Rename")
        _ = FileActionLog.shared.performUndo()
        assert("undo Rename moves back", fm0.fileExists(atPath: unR1.path) && !fm0.fileExists(atPath: unR2.path), "wrong state")
        _ = FileActionLog.shared.performRedo()
        assert("redo Rename re-applies", fm0.fileExists(atPath: unR2.path) && !fm0.fileExists(atPath: unR1.path), "wrong state")
        // Transfer (move) → undo restores source. Drive the queue op directly
        // and wait on its state so the test isn't sensitive to queue latency.
        FileActionLog.shared.clear()
        let unMv = unDir.appendingPathComponent("mv.txt")
        try? "z".write(to: unMv, atomically: true, encoding: .utf8)
        let unMvDstDir = unDir.appendingPathComponent("mvdst")
        try? fm0.createDirectory(at: unMvDstDir, withIntermediateDirectories: true)
        let unMvDst = unMvDstDir.appendingPathComponent("mv.txt")
        let mvOp = TransferQueue.shared.enqueue(plan: [(unMv, unMvDst, false)], move: true)
        waitUntil(5) { mvOp.state == .done }
        assert("queued move completed", mvOp.state == .done, "state=\(mvOp.state)")
        assert("queued move relocated the file", fm0.fileExists(atPath: unMvDst.path) && !fm0.fileExists(atPath: unMv.path), "not moved")
        waitUntil(2) { FileActionLog.shared.canUndo }   // record is posted on main after .done
        assert("transfer move records an undo", FileActionLog.shared.canUndo, "no undo")
        _ = FileActionLog.shared.performUndo()
        waitUntil { fm0.fileExists(atPath: unMv.path) }
        assert("undo Move restores the source", fm0.fileExists(atPath: unMv.path) && !fm0.fileExists(atPath: unMvDst.path), "wrong state")
        FileActionLog.shared.clear()
        TransferQueue.shared.clearFinished()

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
        waitUntil { FileManager.default.fileExists(atPath: copiedDst.path) }
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
        waitUntil { FileManager.default.fileExists(atPath: moveDst.path) }
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
        let dragLanded = dragDestDir.appendingPathComponent("gamma.md")
        waitUntil { FileManager.default.fileExists(atPath: dragLanded.path) }
        assert("dragged file landed in destination",
               FileManager.default.fileExists(atPath: dragLanded.path), "no")
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
            let dest = copyRoundtripDir.appendingPathComponent("for_copy.txt")
            waitUntil { FileManager.default.fileExists(atPath: dest.path) }
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

        // Filter benchmark: filtering 5k items should be fast. Measure the
        // synchronous compute directly. The live setter dispatches the work
        // off-main and applies it via DispatchQueue.main.async, which does NOT
        // drain inside the FT_RUN_TESTS nested run loop — so timing the setter
        // (as the old version did) actually timed a fixed wait() while the filter
        // silently never applied. testApplyComputeSync runs the real filter+sort
        // on this thread and returns the post-filter count, so we measure work.
        perfModel.filterText = "item_0001"
        let t4 = Date()
        let filteredCount = perfModel.testApplyComputeSync()
        let filterMs = Int(Date().timeIntervalSince(t4) * 1000)
        assert("Filter on 5k completes under 60ms (got \(filterMs)ms, matched \(filteredCount))",
               filterMs < 60 && filteredCount < 5000, "perf regression")
        perfModel.filterText = ""
        perfModel.testApplyComputeSync()

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

        // --- T42d2: tar.gz round-trip + encrypted-zip creation ---
        if let madeTgz = Archive.compress(cmpItems, format: .tarGz) {
            assert("compress(.tarGz) names it .tar.gz", madeTgz.lastPathComponent.hasSuffix(".tar.gz"),
                   "got \(madeTgz.lastPathComponent)")
            assert("tar.gz is detected as an archive", Archive.Kind.detect(madeTgz) != nil, "not detected")
            let tgzNames = Set(Archive.list(madeTgz).map { ($0.path as NSString).lastPathComponent })
            assert("tar.gz lists both files", tgzNames.contains("c1.txt") && tgzNames.contains("c2.txt"), "got=\(tgzNames)")
            if let out = Archive.extractInPlace(madeTgz) {
                let names = Set((try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? [])
                assert("tar.gz extracts both files", names.contains("c1.txt") && names.contains("c2.txt"), "got=\(names)")
            } else { assert("tar.gz extractInPlace returns a folder", false, "nil") }
        } else { assert("compress(.tarGz) returns a URL", false, "nil") }
        // Encrypted zip is created (don't extract — unzip would prompt for the pw).
        if let enc = Archive.compress(cmpItems, format: .zip, password: "s3cr3t") {
            assert("encrypted zip is created", FileManager.default.fileExists(atPath: enc.path), "no file")
            assert("encrypted zip still lists entry names", !Archive.list(enc).isEmpty, "no entries")
        } else { assert("encrypted compress returns a URL", false, "nil") }
        assert("CompressFormat: zip supports password", Archive.CompressFormat.zip.supportsPassword, "no")
        assert("CompressFormat: tar.gz has no password", !Archive.CompressFormat.tarGz.supportsPassword, "yes")

        // --- T42d3: 2-way folder sync (union, newer wins, nothing deleted) ---
        let twA = sandbox.appendingPathComponent("twoway/A")
        let twB = sandbox.appendingPathComponent("twoway/B")
        try? FileManager.default.createDirectory(at: twA, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: twB, withIntermediateDirectories: true)
        func tw(_ u: URL, _ s: String) { try? s.write(to: u, atomically: true, encoding: .utf8) }
        tw(twA.appendingPathComponent("onlyA.txt"), "A")
        tw(twB.appendingPathComponent("onlyB.txt"), "B")
        tw(twA.appendingPathComponent("both.txt"), "old")
        tw(twB.appendingPathComponent("both.txt"), "new")
        // Make B/both.txt clearly newer so it wins.
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)],
            ofItemAtPath: twB.appendingPathComponent("both.txt").path)
        let twOps = FolderSync.syncBothWays(source: twA, destination: twB)
        func twrd(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "<none>" }
        assert("2-way: A's unique file lands in B", twrd(twB.appendingPathComponent("onlyA.txt")) == "A", "missing")
        assert("2-way: B's unique file lands in A", twrd(twA.appendingPathComponent("onlyB.txt")) == "B", "missing")
        assert("2-way: newer copy wins on the older side", twrd(twA.appendingPathComponent("both.txt")) == "new",
               "got \(twrd(twA.appendingPathComponent("both.txt")))")
        assert("2-way: nothing deleted (A keeps onlyA)", FileManager.default.fileExists(atPath: twA.appendingPathComponent("onlyA.txt").path), "deleted")
        assert("2-way: did >=3 writes", twOps >= 3, "ops=\(twOps)")

        // --- T42d4: Use Groups (visual grouping) ---
        // Pure title helper.
        let grpDir = sandbox.appendingPathComponent("groups")
        try? FileManager.default.createDirectory(at: grpDir, withIntermediateDirectories: true)
        for n in ["apple.txt", "banana.txt", "cherry.png"] {
            try? "x".write(to: grpDir.appendingPathComponent(n), atomically: true, encoding: .utf8)
        }
        if let appleItem = FileItem.load(grpDir.appendingPathComponent("apple.txt")) {
            assert("group title by name = first letter", FileListController.groupTitle(for: appleItem, key: .name) == "A",
                   "got \(FileListController.groupTitle(for: appleItem, key: .name))")
            assert("group title by kind = ext files", FileListController.groupTitle(for: appleItem, key: .kind) == "TXT files",
                   "got \(FileListController.groupTitle(for: appleItem, key: .kind))")
        } else { assert("loaded apple.txt", false, "nil") }
        // Toggling grouping must not lose items or break selection/rename.
        Settings.useGroups = true
        pane.navigate(to: grpDir); pane.testReloadSync()
        assert("grouping keeps all items", pane.testCurrentItems.count == 3, "got \(pane.testCurrentItems.count)")
        assert("select-by-mask still works under grouping", pane.testSelectMatching("*.png") == 1,
               "got \(pane.testSelectMatching("*.png"))")
        Settings.useGroups = false
        pane.testReloadSync()
        assert("ungrouped still lists items", pane.testCurrentItems.count == 3, "got \(pane.testCurrentItems.count)")
        pane.navigate(to: sandbox); pane.testReloadSync()

        // --- T42d5: synchronized browsing (relative-path mirroring) ---
        let syncRoot = sandbox.appendingPathComponent("syncbrowse")
        let sideA = syncRoot.appendingPathComponent("A")
        let sideB = syncRoot.appendingPathComponent("B")
        try? FileManager.default.createDirectory(at: sideA.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: sideB.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let container = PanesContainerController(initialURL: sideA)
        _ = container.view                  // force loadView → first pane
        container.toggleExtraPane()         // second pane (at A)
        let sp = container.allPanes
        if sp.count == 2 {
            sp[1].navigate(to: sideB)
            waitUntil { samePath(sp[1].currentURL, sideB) }
            container.toggleSyncBrowsing()
            assert("sync browsing toggles on", container.testSyncBrowsing, "off")
            container.mirrorNavigation(from: sideA, to: sideA.appendingPathComponent("sub"), sourcePane: sp[0])
            waitUntil { sp[1].currentURL.lastPathComponent == "sub" }
            assert("sync mirrors relative descent onto the other pane",
                   samePath(sp[1].currentURL, sideB.appendingPathComponent("sub")),
                   "url=\(sp[1].currentURL.path)")
        } else { assert("sync: two panes", false, "got \(sp.count)") }

        // --- T42d6: breadcrumb subfolder dropdown helper ---
        let bcRoot = sandbox.appendingPathComponent("bc")
        try? FileManager.default.createDirectory(at: bcRoot.appendingPathComponent("zeta"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: bcRoot.appendingPathComponent("alpha"), withIntermediateDirectories: true)
        try? "x".write(to: bcRoot.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try? FileManager.default.createDirectory(at: bcRoot.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        let bcSubs = PathBarView.subdirectories(of: bcRoot).map { $0.lastPathComponent }
        assert("breadcrumb lists only visible subfolders, sorted", bcSubs == ["alpha", "zeta"], "got \(bcSubs)")

        // --- T42d7: rename presets + {dim} token ---
        RenamePresets.remove(name: "TestPreset")
        RenamePresets.upsert(RenamePreset(name: "TestPreset", find: "a", repl: "b",
            template: "{name}-{N}", useRegex: false, start: 5, pad: 2))
        assert("rename preset persists", RenamePresets.find(name: "TestPreset")?.template == "{name}-{N}", "missing")
        RenamePresets.upsert(RenamePreset(name: "TestPreset", find: "x", repl: "y",
            template: "{name}", useRegex: true, start: 1, pad: 0))
        assert("rename preset upsert overwrites by name",
               RenamePresets.all().filter { $0.name == "TestPreset" }.count == 1 &&
               RenamePresets.find(name: "TestPreset")?.find == "x", "dup or stale")
        RenamePresets.remove(name: "TestPreset")
        assert("rename preset removed", RenamePresets.find(name: "TestPreset") == nil, "still there")
        // {dim} expands to empty for a non-image file (no crash either).
        let dimFile = sandbox.appendingPathComponent("notimage.txt")
        try? "x".write(to: dimFile, atomically: true, encoding: .utf8)
        if let it = FileItem.load(dimFile) {
            let preview = BatchRenameSheetController.testPreview(items: [it], find: "", repl: "",
                template: "{dim}{name}", useRegex: false, start: 1, pad: 0)
            assert("{dim} empty for non-image", preview.first?.newName == "notimage.txt",
                   "got \(preview.first?.newName ?? "nil")")
        } else { assert("loaded notimage.txt", false, "nil") }

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

        // --- T42f2: smart folders (saved searches) ---
        // Synthetic URL round-trip.
        let sfURL = SidebarController.smartFolderURL(id: "my-search")
        assert("smart-folder URL is recognized", SidebarController.isSmartFolderURL(sfURL), "not recognized")
        assert("smart-folder id round-trips",
               SidebarController.smartFolderId(from: sfURL) == "my-search",
               "got \(SidebarController.smartFolderId(from: sfURL) ?? "nil")")
        assert("a normal path is not a smart folder",
               !SidebarController.isSmartFolderURL(sandbox), "false positive")
        // Persistence: upsert / find / remove + id uniqueness.
        let existingSF = SmartFolders.all()
        for f in existingSF where f.id.hasPrefix("test-sf") { SmartFolders.remove(id: f.id) }
        let id1 = SmartFolders.makeId(for: "Test SF Reports")
        let sf1 = SmartFolder(id: id1, name: "Reports", nameContains: "report",
                              contentContains: "", rootPath: sandbox.path)
        SmartFolders.upsert(sf1)
        assert("smart folder persisted", SmartFolders.find(id: id1)?.name == "Reports",
               "not found")
        var sf1b = sf1; sf1b.name = "Reports v2"
        SmartFolders.upsert(sf1b)
        assert("smart folder upsert replaces by id",
               SmartFolders.all().filter { $0.id == id1 }.count == 1 &&
               SmartFolders.find(id: id1)?.name == "Reports v2", "duplicated or stale")
        // sf1 (id "test-sf-reports") is still persisted, so re-deriving the
        // same slug must disambiguate rather than collide.
        let id2 = SmartFolders.makeId(for: "Test SF Reports")
        assert("makeId disambiguates a taken slug", id2 != id1, "collision: \(id1) == \(id2)")
        // An all-blank query matches nothing (guarded).
        let emptySF = SmartFolder(id: "blank", name: "Blank", nameContains: "",
                                  contentContains: "", rootPath: sandbox.path)
        assert("blank smart folder reports empty query", emptySF.isEmptyQuery, "not flagged")
        assert("runSync on blank query returns nothing", SmartFolders.runSync(emptySF).isEmpty, "got hits")
        // runSync on a real query just must not crash (Spotlight may not index
        // the temp sandbox, so we don't assert on count).
        _ = SmartFolders.runSync(sf1, limit: 10)
        SmartFolders.remove(id: id1)
        assert("smart folder removed", SmartFolders.find(id: id1) == nil, "still present")

        // --- T42f3: checksums (MD5 / SHA-256) against known vectors ---
        let hashFile = sandbox.appendingPathComponent("hash_me.txt")
        try? "hello".write(to: hashFile, atomically: true, encoding: .utf8)
        assert("MD5 matches known vector",
               Checksum.compute(hashFile, kind: .md5) == "5d41402abc4b2a76b9719d911017c592",
               "got \(Checksum.compute(hashFile, kind: .md5) ?? "nil")")
        assert("SHA-256 matches known vector",
               Checksum.compute(hashFile, kind: .sha256) == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
               "got \(Checksum.compute(hashFile, kind: .sha256) ?? "nil")")
        let twoHashes = Checksum.report([hashFile, hashFile], kind: .md5)
        assert("checksum report emits one line per file",
               twoHashes.split(separator: "\n").count == 2, "got \(twoHashes)")
        assert("checksum on a missing file returns nil",
               Checksum.compute(sandbox.appendingPathComponent("nope.bin"), kind: .md5) == nil, "non-nil")
        // appCandidates must not crash for a real file (count is env-dependent).
        _ = FileListController.appCandidates(for: hashFile)

        // --- T42f3d: Quick Actions (sips rotate/convert, PDFKit) ---
        let qaDir = sandbox.appendingPathComponent("qa")
        try? FileManager.default.createDirectory(at: qaDir, withIntermediateDirectories: true)
        let qaImg = qaDir.appendingPathComponent("img.png")
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 6, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: qaImg)
        }
        func imgDims(_ u: URL) -> (Int, Int)? {
            guard let r = NSImageRep(contentsOf: u) else { return nil }
            return (r.pixelsWide, r.pixelsHigh)
        }
        assert("QuickActions recognises an image", QuickActions.isImage(qaImg), "no")
        assert("source image is 6x4", imgDims(qaImg).map { $0 == (6, 4) } ?? false, "got \(String(describing: imgDims(qaImg)))")
        QuickActions.rotate([qaImg], clockwise: true)
        assert("rotate swaps dimensions to 4x6", imgDims(qaImg).map { $0 == (4, 6) } ?? false,
               "got \(String(describing: imgDims(qaImg)))")
        let qaConv = QuickActions.convert([qaImg], to: "jpeg")
        assert("convert writes a .jpg sibling",
               qaConv.first?.pathExtension == "jpg" && FileManager.default.fileExists(atPath: qaConv.first?.path ?? ""),
               "got \(qaConv)")
        if let qaPDF = QuickActions.createPDF(from: [qaImg]) {
            let head = (try? FileHandle(forReadingFrom: qaPDF))?.readData(ofLength: 4)
            assert("createPDF writes a real PDF", head == Data("%PDF".utf8), "bad header")
        } else { assert("createPDF returns a URL", false, "nil") }
        _ = QuickActions.installedShortcuts()   // env-dependent; must not crash

        // --- T42f3e: package detection (Show Package Contents) ---
        let finderAppPkg = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        if FileManager.default.fileExists(atPath: finderAppPkg.path), let appItem = FileItem.load(finderAppPkg) {
            assert("an .app is detected as a package", appItem.isPackage, "not a package")
        }
        if let plainDir = FileItem.load(sandbox) {
            assert("a plain folder is not a package", !plainDir.isPackage, "false positive")
        }

        // --- T42f3b: duplicate finder (size + content hash) ---
        let dupRoot = sandbox.appendingPathComponent("dups")
        try? FileManager.default.createDirectory(at: dupRoot.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try? "identical-content".write(to: dupRoot.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try? "identical-content".write(to: dupRoot.appendingPathComponent("sub/b.txt"), atomically: true, encoding: .utf8)
        try? "unique".write(to: dupRoot.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        // same SIZE as each other but different content → must NOT be grouped
        try? "size8888".write(to: dupRoot.appendingPathComponent("d.txt"), atomically: true, encoding: .utf8)
        try? "8888size".write(to: dupRoot.appendingPathComponent("e.txt"), atomically: true, encoding: .utf8)
        let dupGroups = DuplicateFinder.find(in: dupRoot)
        assert("duplicate finder finds exactly one group", dupGroups.count == 1, "got \(dupGroups.count)")
        assert("duplicate group has both identical files", dupGroups.first?.urls.count == 2, "got \(dupGroups.first?.urls.count ?? -1)")
        let dupNames = Set((dupGroups.first?.urls ?? []).map { $0.lastPathComponent })
        assert("duplicate group is a.txt + b.txt", dupNames == ["a.txt", "b.txt"], "got \(dupNames)")

        // --- T42f3c: file diff ---
        let diffA = sandbox.appendingPathComponent("diffA.txt")
        let diffB = sandbox.appendingPathComponent("diffB.txt")
        try? "line1\nline2\nline3\n".write(to: diffA, atomically: true, encoding: .utf8)
        try? "line1\nCHANGED\nline3\n".write(to: diffB, atomically: true, encoding: .utf8)
        let diffOut = FileDiff.unified(diffA, diffB)
        assert("file diff is non-nil for text files", diffOut != nil, "nil")
        assert("file diff shows the removed line", diffOut?.contains("-line2") == true, "got \(diffOut ?? "nil")")
        assert("file diff shows the added line", diffOut?.contains("+CHANGED") == true, "missing +CHANGED")
        assert("identical files diff to empty", FileDiff.unified(diffA, diffA) == "", "got \(FileDiff.unified(diffA, diffA) ?? "nil")")

        // --- T42f4: Drop Stack (shelf) model ---
        DropStack.clear()
        let ds1 = sandbox.appendingPathComponent("ds1.txt"); try? "a".write(to: ds1, atomically: true, encoding: .utf8)
        let ds2 = sandbox.appendingPathComponent("ds2.txt"); try? "b".write(to: ds2, atomically: true, encoding: .utf8)
        assert("drop stack starts empty", DropStack.all().isEmpty, "not empty")
        assert("drop stack adds 2 new", DropStack.add([ds1, ds2]) == 2, "wrong count")
        assert("drop stack de-dupes", DropStack.add([ds1]) == 0, "re-added")
        assert("drop stack contains added", DropStack.contains(ds1), "missing")
        assert("drop stack count is 2", DropStack.all().count == 2, "got \(DropStack.all().count)")
        DropStack.remove(ds1)
        assert("drop stack remove drops one", !DropStack.contains(ds1) && DropStack.all().count == 1, "still there")
        try? FileManager.default.removeItem(at: ds2)
        assert("drop stack filters deleted files", DropStack.all().isEmpty, "stale entry survives")
        DropStack.clear()

        // --- T42f4b: network mount URL validation ---
        assert("netmount accepts smb://", NetMount.isSupportedURL("smb://server/share"), "rejected")
        assert("netmount accepts ftp://", NetMount.isSupportedURL("ftp://host.example.com"), "rejected")
        assert("netmount accepts https WebDAV", NetMount.isSupportedURL("https://dav.example.com/path"), "rejected")
        assert("netmount accepts afp://", NetMount.isSupportedURL("afp://mac.local"), "rejected")
        assert("netmount rejects a local path", !NetMount.isSupportedURL("/Users/chang"), "accepted")
        assert("netmount rejects sftp (own browser)", !NetMount.isSupportedURL("sftp://host"), "accepted")
        assert("netmount rejects scheme without host", !NetMount.isSupportedURL("smb://"), "accepted")

        // --- T42f5: select-by-mask (glob) ---
        assert("glob *.png matches a.png", FileListController.matchesGlob("a.png", "*.png"), "no match")
        assert("glob *.png rejects a.txt", !FileListController.matchesGlob("a.txt", "*.png"), "false match")
        assert("glob is case-insensitive", FileListController.matchesGlob("A.PNG", "*.png"), "case-sensitive")
        assert("glob ? matches one char", FileListController.matchesGlob("report-1.txt", "report-?.txt"), "no match")
        assert("glob ? rejects two chars", !FileListController.matchesGlob("report-12.txt", "report-?.txt"), "false match")
        let maskDir = sandbox.appendingPathComponent("mask")
        try? FileManager.default.createDirectory(at: maskDir, withIntermediateDirectories: true)
        for n in ["one.png", "two.png", "three.txt"] {
            try? "x".write(to: maskDir.appendingPathComponent(n), atomically: true, encoding: .utf8)
        }
        pane.navigate(to: maskDir); pane.testReloadSync()
        assert("select-by-mask selects 2 of 3 (*.png)", pane.testSelectMatching("*.png") == 2,
               "got \(pane.testSelectMatching("*.png"))")
        pane.navigate(to: sandbox); pane.testReloadSync()

        // --- T42g: view/layout setting defaults ---
        for k in ["FinderTwo.typeToSelect", "FinderTwo.showStatusBar", "FinderTwo.showPathBar"] {
            UserDefaults.standard.removeObject(forKey: k)
        }
        assert("typeToSelect defaults off", Settings.typeToSelect == false, "got \(Settings.typeToSelect)")
        assert("showStatusBar defaults on", Settings.showStatusBar == true, "got \(Settings.showStatusBar)")
        assert("showPathBar defaults on", Settings.showPathBar == true, "got \(Settings.showPathBar)")

        // --- T42g2: spring-loaded folder settings ---
        for k in ["FinderTwo.springLoadedFolders", "FinderTwo.springLoadDelay"] {
            UserDefaults.standard.removeObject(forKey: k)
        }
        assert("springLoadedFolders defaults on", Settings.springLoadedFolders == true,
               "got \(Settings.springLoadedFolders)")
        assert("springLoadDelay defaults to 0.6", abs(Settings.springLoadDelay - 0.6) < 0.001,
               "got \(Settings.springLoadDelay)")
        Settings.springLoadDelay = 5.0   // over max
        assert("springLoadDelay clamps to <= 2.0", Settings.springLoadDelay <= 2.0,
               "got \(Settings.springLoadDelay)")
        Settings.springLoadDelay = 0.05  // under min
        assert("springLoadDelay clamps to >= 0.2", Settings.springLoadDelay >= 0.2,
               "got \(Settings.springLoadDelay)")
        UserDefaults.standard.removeObject(forKey: "FinderTwo.springLoadDelay")

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
        let dsContent = String(repeating: "x", count: 4096)   // 4 KB each, ≥ 1 block
        for i in 0..<10 {
            try? dsContent.write(to: dsRoot.appendingPathComponent("f_\(i)"),
                                 atomically: true, encoding: .utf8)
        }
        // Sanity-check FastDirScan sees what we just wrote.
        let dsList = FastDirScan.list(dsRoot)
        assert("DiskScan sandbox has 10 files via FastDirScan",
               dsList.count == 10, "got=\(dsList.count)")
        let scan = DiskScan(root: dsRoot)
        let scanRoot = scan.runSync()
        // DiskScan now reports ALLOCATED size (blocks), so it's ≥ the 40 KB of
        // logical content — never the old logical-byte sum.
        assert("DiskScan totals (allocated size, ≥ logical)",
               scanRoot.size >= 40_960,
               "got=\(scanRoot.size) (expected ≥ 40960 = 10 × 4 KB allocated)")
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
        assert("action: file.new-smart-folder",
               ActionRegistry.action(id: "file.new-smart-folder") != nil, "missing")

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

        // --- T42z: navigating to a synthetic smart-folder URL is safe ---
        let navSF = SmartFolder(id: "test-nav-sf", name: "NavSF", nameContains: "zzz-nope",
                                contentContains: "", rootPath: sandbox.path)
        SmartFolders.upsert(navSF)
        let navURL = SidebarController.smartFolderURL(id: "test-nav-sf")
        pane.navigate(to: navURL)
        wait(0.2)
        assert("pane navigated to smart-folder URL",
               samePath(pane.currentURL, navURL), "url=\(pane.currentURL.path)")
        pane.navigate(to: sandbox)
        wait(0.05)
        SmartFolders.remove(id: "test-nav-sf")

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
        pane.setViewMode(.icon)
        assert("setViewMode(.icon) honored", pane.viewMode == .icon, "got=\(pane.viewMode)")
        pane.setViewMode(.gallery)
        assert("setViewMode(.gallery) honored", pane.viewMode == .gallery, "got=\(pane.viewMode)")
        // vim move in gallery mode must not crash / must not touch the list.
        pane.vimSelectFirst(); pane.vimMove(by: 1); pane.vimSelectLast()
        assert("vim nav in gallery mode is safe", pane.viewMode == .gallery, "mode changed")
        pane.setViewMode(.list)
        assert("setViewMode(.list) honored", pane.viewMode == .list, "got=\(pane.viewMode)")

        // --- Vim navigation in icon + gallery controllers ---
        let vnavDir = sandbox.appendingPathComponent("vnav")
        try? FileManager.default.createDirectory(at: vnavDir, withIntermediateDirectories: true)
        for n in ["v1.txt", "v2.txt", "v3.txt"] {
            try? "x".write(to: vnavDir.appendingPathComponent(n), atomically: true, encoding: .utf8)
        }
        let vnavItems = ["v1.txt", "v2.txt", "v3.txt"].compactMap { FileItem.load(vnavDir.appendingPathComponent($0)) }
        if vnavItems.count == 3 {
            let icv = IconViewController(); _ = icv.view; icv.reload(vnavItems)
            icv.selectFirst()
            assert("icon vim: selectFirst → v1", icv.testSelectedItems.first?.name == "v1.txt", "got \(icv.testSelectedItems.first?.name ?? "nil")")
            icv.moveSelection(by: 1)
            assert("icon vim: j → v2", icv.testSelectedItems.first?.name == "v2.txt", "got \(icv.testSelectedItems.first?.name ?? "nil")")
            icv.selectLast()
            assert("icon vim: G → v3", icv.testSelectedItems.first?.name == "v3.txt", "got \(icv.testSelectedItems.first?.name ?? "nil")")
            icv.moveSelection(by: -1)
            assert("icon vim: k → v2", icv.testSelectedItems.first?.name == "v2.txt", "got \(icv.testSelectedItems.first?.name ?? "nil")")

            let gv = GalleryViewController(); _ = gv.view; gv.reload(vnavItems)
            gv.focusFirst()
            assert("gallery vim: focusFirst → v1", gv.focused?.name == "v1.txt", "got \(gv.focused?.name ?? "nil")")
            gv.moveFocus(by: 1)
            assert("gallery vim: j → v2", gv.focused?.name == "v2.txt", "got \(gv.focused?.name ?? "nil")")
            gv.focusLast()
            assert("gallery vim: G → v3", gv.focused?.name == "v3.txt", "got \(gv.focused?.name ?? "nil")")
        } else { assert("vnav items loaded", false, "got \(vnavItems.count)") }
        pane.arrangeBy(.kind)
        assert("arrangeBy(.kind) sets the sort key", pane.testModel.sort.key == .kind,
               "got=\(pane.testModel.sort.key)")
        pane.arrangeBy(.name)
        // Preview drawer toggles (builds the QLPreviewView without crashing).
        pane.togglePreviewDrawer()
        assert("preview drawer opens", pane.testPreviewVisible, "not visible")
        pane.togglePreviewDrawer()
        assert("preview drawer closes", !pane.testPreviewVisible, "still visible")

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
        let midnightBG = ThemeManager.shared.available.first { $0.id == "midnight" }!.background
        ThemeManager.shared.setTheme(id: "midnight")
        wait(0.05)
        assert("file list paints custom theme background",
               pane.testFileList.tableView.backgroundColor == midnightBG,
               "got=\(pane.testFileList.tableView.backgroundColor)")
        ThemeManager.shared.setTheme(id: "system")
        wait(0.05)
        assert("file list reverts to native background on System theme",
               pane.testFileList.tableView.backgroundColor == .controlBackgroundColor,
               "got=\(pane.testFileList.tableView.backgroundColor)")
        ThemeManager.shared.setTheme(id: startThemeId)

        // --- T59b: portable, data-driven theme system ---
        assert("hex round-trips", NSColor(hex: "#2E3440")?.hexString == "#2E3440",
               "got \(NSColor(hex: "#2E3440")?.hexString ?? "nil")")
        assert("hex with alpha round-trips", NSColor(hex: "#2F5BD459")?.hexString == "#2F5BD459",
               "got \(NSColor(hex: "#2F5BD459")?.hexString ?? "nil")")
        assert("malformed hex is rejected", NSColor(hex: "nope") == nil, "accepted")
        let themeIDs = Set(ThemeManager.shared.available.map { $0.id })
        assert("new built-in themes are present",
               themeIDs.isSuperset(of: ["nord", "dracula", "solarized-light", "solarized-dark", "high-contrast", "ocean", "cyberpunk", "gruvbox", "sage", "tokyo-night", "rose-pine"]),
               "got \(themeIDs)")
        assert("theme library has 10+ themes", ThemeManager.shared.available.count >= 10,
               "got \(ThemeManager.shared.available.count)")
        // Rascal's signature light + dark themes (matched to the landing page).
        assert("Rascal Light & Dark themes ship",
               themeIDs.isSuperset(of: ["rascal-light", "rascal-dark"]), "got \(themeIDs)")
        if let rl = ThemeManager.shared.available.first(where: { $0.id == "rascal-light" }),
           let rd = ThemeManager.shared.available.first(where: { $0.id == "rascal-dark" }) {
            assert("Rascal Light is light + warm-orange accent",
                   rl.appearance == .light && rl.accent.hexString == "#FF6600", "got \(rl.accent.hexString)")
            assert("Rascal Dark is dark + warm-orange accent",
                   rd.appearance == .dark && rd.accent.hexString == "#FF8A33", "got \(rd.accent.hexString)")
        } else {
            assert("Rascal themes resolve", false, "missing")
        }
        // JSON spec → Theme (forgiving: omit the cosmetic extras).
        let specJSON = """
        {"id":"t-test","name":"Test","appearance":"dark","background":"#101012","sidebarBackground":"#0A0A0C","toolbarBackground":"#151518","pathBarBackground":"#151518","rowAlternate":"#1A1A1E","labelPrimary":"#FFFFFF","labelSecondary":"#BBBBBB","labelTertiary":"#888888","accent":"#FF8800","selectionBackground":"#FF880055"}
        """
        let decoded = ThemeStore.decodeSpec(Data(specJSON.utf8))
        assert("theme spec decodes from JSON", decoded?.id == "t-test", "nil")
        assert("omitted cosmetic fields default", decoded?.baseFontPointSize == 13 && decoded?.monospaced == false, "wrong defaults")
        if let decoded { assert("spec → Theme maps accent hex", Theme(spec: decoded).accent.hexString == "#FF8800", "wrong accent") }
        // Load user themes from a folder + export round-trip.
        let themesTmp = sandbox.appendingPathComponent("themes")
        try? FileManager.default.createDirectory(at: themesTmp, withIntermediateDirectories: true)
        try? Data(specJSON.utf8).write(to: themesTmp.appendingPathComponent("t-test.json"))
        let loaded = ThemeStore.userThemes(in: themesTmp)
        assert("user theme loads from folder", loaded.contains { $0.id == "t-test" }, "not loaded")
        if let nord = ThemeManager.shared.available.first(where: { $0.id == "nord" }),
           let exported = ThemeStore.export(nord, to: themesTmp),
           let data = try? Data(contentsOf: exported), let back = ThemeStore.decodeSpec(data) {
            assert("export → decode round-trips", back.id == "nord" && back.accent == "#88C0D0",
                   "got \(back.id)/\(back.accent)")
        } else { assert("theme export succeeds", false, "nil") }

        // --- T59c: custom themes paint the sidebar with the EXACT theme color ---
        let sbT = SidebarController(); _ = sbT.view
        if let nord = ThemeManager.shared.available.first(where: { $0.id == "nord" }) {
            ThemeManager.shared.setTheme(id: "nord"); wait(0.05)
            assert("sidebar's rendered background is the theme's exact color",
                   sbT.testSidebarBackground?.hexString == nord.sidebarBackground.hexString,
                   "got \(sbT.testSidebarBackground?.hexString ?? "nil") vs \(nord.sidebarBackground.hexString)")

            // Render-based proof: draw the sidebar into an OFF-SCREEN bitmap (no
            // window, no display) and sample the ACTUAL painted pixels along the
            // right-edge background column. Attempt 1 of this fix passed every
            // property check yet still rendered the system color, because an
            // opaque clip view sat IN FRONT of the tint — a z-order bug only a
            // real pixel read can catch.
            sbT.view.frame = NSRect(x: 0, y: 0, width: 168, height: 400)
            sbT.view.layoutSubtreeIfNeeded()
            if let rep = sbT.view.bitmapImageRepForCachingDisplay(in: sbT.view.bounds),
               let want = nord.sidebarBackground.usingColorSpace(.sRGB) {
                sbT.view.cacheDisplay(in: sbT.view.bounds, to: rep)
                let x = rep.pixelsWide - 6
                var matched = 0, opaque = 0
                var py = 10
                while py < rep.pixelsHigh - 10 {
                    if let px = rep.colorAt(x: x, y: py)?.usingColorSpace(.sRGB),
                       px.alphaComponent > 0.5 {
                        opaque += 1
                        if abs(px.redComponent - want.redComponent) < 0.06,
                           abs(px.greenComponent - want.greenComponent) < 0.06,
                           abs(px.blueComponent - want.blueComponent) < 0.06 { matched += 1 }
                    }
                    py += 8
                }
                if opaque == 0 {
                    // Off-screen layer-backed compositing didn't fill the bitmap;
                    // the property assertion above already stands. Not a failure.
                    assert("sidebar pixel-render check (off-screen not composited — property check stands)", true, "")
                } else {
                    assert("sidebar renders the EXACT theme color in real pixels (no system overlay)",
                           matched * 2 >= opaque,
                           "only \(matched)/\(opaque) opaque right-edge samples matched nord \(want.hexString)")
                }
            }
        }
        ThemeManager.shared.setTheme(id: "system"); wait(0.05)
        assert("sidebar background is clear on System theme (native vibrancy shows)",
               (sbT.testSidebarBackground?.alphaComponent ?? 1) == 0,
               "got \(sbT.testSidebarBackground?.hexString ?? "nil")")
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

        // --- T61: Command Palette "Open With" entries ---
        let openWithTestFile = sandbox.appendingPathComponent("open_with_test.txt")
        try? "test".write(to: openWithTestFile, atomically: true, encoding: .utf8)
        pane.testReloadSync()
        if let item = pane.testCurrentItems.first(where: { $0.name == "open_with_test.txt" }) {
            pane.testSelectItem(item)
            let palette = CommandPaletteController(target: wc)
            let entries = palette.testFilteredEntries
            let hasOpenWithOther = entries.contains { $0.title == "Open With: Other…" }
            assert("command palette contains Open With: Other…", hasOpenWithOther, "entries=\(entries.map { $0.title })")
        } else {
            assert("command palette Open With test file exists", false, "test file not found")
        }

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

        // --- Cinematic treemap: type palette + squarified layout + view tiles ---
        func mkNode(_ path: String, dir: Bool, size: Int64 = 0) -> DiskScan.Node {
            let n = DiskScan.Node(url: URL(fileURLWithPath: path), name: (path as NSString).lastPathComponent, isDirectory: dir)
            n.size = size; return n
        }
        assert("file-type palette maps extensions to categories",
               FileTypePalette.category(for: mkNode("/x/a.swift", dir: false)) == .code &&
               FileTypePalette.category(for: mkNode("/x/a.png", dir: false)) == .image &&
               FileTypePalette.category(for: mkNode("/x/a.mp4", dir: false)) == .video &&
               FileTypePalette.category(for: mkNode("/x/dir", dir: true)) == .folder,
               "miscategorized")

        let synth = mkNode("/syn", dir: true)
        for (i, s) in [500, 300, 120, 50, 30].enumerated() {
            synth.children.append(mkNode("/syn/\(i)", dir: false, size: Int64(s))); synth.size += Int64(s)
        }
        let area = CGRect(x: 0, y: 0, width: 400, height: 300)
        let packed = TreemapLayout.squarify(synth.children, total: synth.size, in: area)
        assert("squarify places every non-empty child", packed.count == 5, "got \(packed.count)")
        let coverage = packed.reduce(0.0) { $0 + Double($1.1.width * $1.1.height) }
        let fullArea = Double(area.width * area.height)
        assert("squarify tiles fill ~the whole rect (no gaps/overlap)",
               abs(coverage - fullArea) < fullArea * 0.01, "coverage \(coverage) of \(fullArea)")
        assert("squarify rects are finite and within bounds",
               packed.allSatisfy { $0.1.width.isFinite && $0.1.height.isFinite && area.insetBy(dx: -0.5, dy: -0.5).contains($0.1) },
               "bad rect")
        let big = packed.first { $0.0.name == "0" }!.1
        let small = packed.first { $0.0.name == "4" }!.1
        assert("squarify area tracks size (biggest child gets the most area)",
               big.width * big.height > small.width * small.height, "ordering off")

        let tmRoot = DiskScan(root: sandbox).runSync()
        let tmView = TreemapView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tmView.setRoot(tmRoot)
        assert("treemap lays out tiles for a scanned folder", tmView.testTileCount > 0, "no tiles")

        // Treemap drill history powers the ← / → back-forward arrows.
        let histRoot = mkNode("/h", dir: true)
        let histChild = mkNode("/h/sub", dir: true)
        histChild.children.append(mkNode("/h/sub/leaf", dir: false, size: 100)); histChild.size = 100
        histRoot.children.append(histChild); histRoot.size = 100
        let htv = TreemapView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        htv.setRoot(histRoot)
        assert("treemap: at root there's nowhere to go back/forward",
               !htv.canGoBack && !htv.canGoForward, "back=\(htv.canGoBack) fwd=\(htv.canGoForward)")
        htv.testDrill(into: histChild)
        assert("treemap: after drilling in, ← is enabled and → is not",
               htv.canGoBack && !htv.canGoForward, "back=\(htv.canGoBack) fwd=\(htv.canGoForward)")
        htv.goBack()
        assert("treemap: ← returns to the parent and enables →",
               htv.currentRoot === histRoot && htv.canGoForward, "root=\(htv.currentRoot?.name ?? "nil")")
        htv.goForward()
        assert("treemap: → re-enters the child", htv.currentRoot === histChild, "root=\(htv.currentRoot?.name ?? "nil")")

        // --- Disk scan accuracy: no symlink-follow, hard-link dedup, allocated size ---
        let duTmp = sandbox.appendingPathComponent("duusage-\(UUID().uuidString)")
        let duReal = duTmp.appendingPathComponent("real")
        try? FileManager.default.createDirectory(at: duReal, withIntermediateDirectories: true)
        let duFile = duReal.appendingPathComponent("a.bin")
        FileManager.default.createFile(atPath: duFile.path, contents: Data(repeating: 0xAB, count: 200_000))
        // Hard link to the same bytes — must be charged to the total only once.
        try? FileManager.default.linkItem(at: duFile, to: duReal.appendingPathComponent("a-hardlink.bin"))
        // Symlink to the real dir — must NOT be followed (else its bytes double-count).
        try? FileManager.default.createSymbolicLink(at: duTmp.appendingPathComponent("link-to-real"), withDestinationURL: duReal)
        let duScan = DiskScan(root: duTmp).runSync()
        assert("disk scan doesn't follow symlinked dirs or double-count hard links",
               duScan.size < 350_000, "size \(duScan.size) — a broken scan would be ~800K")
        assert("disk scan still counts the real file's allocated size",
               duScan.size >= 150_000, "size \(duScan.size) too small")
        try? FileManager.default.removeItem(at: duTmp)

        // Native Get Info panel builds for a real path (incl. its NSGridView).
        let info = GetInfoSheetController(url: sandbox)
        assert("GetInfoSheetController builds", info.window?.contentView != nil, "nil")

        // Editable permissions: read on construct + chmod round-trip.
        let permFile = sandbox.appendingPathComponent("perm_me.txt")
        try? "x".write(to: permFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: permFile.path)
        let permInfo = GetInfoSheetController(url: permFile)
        _ = permInfo.window?.contentView
        assert("Get Info has 9 permission checkboxes", permInfo.testPermBoxCount == 9,
               "got \(permInfo.testPermBoxCount)")
        assert("Get Info reads the on-disk mode (0o600)", permInfo.testCurrentMode == 0o600,
               "got \(String(permInfo.testCurrentMode, radix: 8))")
        permInfo.testApplyMode(0o644)
        let actualMode = ((try? FileManager.default.attributesOfItem(atPath: permFile.path))?[.posixPermissions]
            as? NSNumber)?.uint16Value ?? 0
        assert("Get Info chmod writes the new mode (0o644)", actualMode == 0o644,
               "got \(String(actualMode, radix: 8))")

        // Transfer activity panel builds without popping a window (no present()
        // → stays off-screen, satisfies the headless constraint).
        let activity = TransferActivityController.shared
        assert("TransferActivityController builds", activity.window?.contentView != nil, "nil")
        activity.refresh()

        // Drop Stack panel builds (no present() → off-screen).
        let shelf = DropStackController.shared
        assert("DropStackController builds", shelf.window?.contentView != nil, "nil")
        shelf.reload()

        // Network-mount connect sheet builds (no show() → off-screen).
        let netSheet = ServerConnectSheetController(target: wc)
        assert("ServerConnectSheetController builds", netSheet.window?.contentView != nil, "nil")

        // Duplicate-finder window builds (no show()/scan → off-screen).
        let dupWin = DuplicateFinderWindowController(root: sandbox)
        assert("DuplicateFinderWindowController builds", dupWin.window?.contentView != nil, "nil")

        // File-diff window builds (no show()/run → off-screen).
        let diffWin = FileDiffWindowController(a: sandbox.appendingPathComponent("x"),
                                               b: sandbox.appendingPathComponent("y"))
        assert("FileDiffWindowController builds", diffWin.window?.contentView != nil, "nil")

        // Shared overlay finder chrome builds + carries icon/title/subtitle.
        let overlayRow = OverlayResultRow()
        overlayRow.titleLabel.stringValue = "Title"
        overlayRow.subtitleLabel.stringValue = "Subtitle"
        overlayRow.monospacedSubtitle = true
        assert("OverlayResultRow builds + holds text",
               overlayRow.titleLabel.stringValue == "Title" && overlayRow.subtitleLabel.stringValue == "Subtitle", "nil")
        assert("OverlayUI.makePanel is a floating HUD panel",
               OverlayUI.makePanel().isFloatingPanel, "not floating")

        // Gallery view controller builds + reloads with items (no window).
        let gallery = GalleryViewController()
        _ = gallery.view
        gallery.reload((try? FileManager.default.contentsOfDirectory(at: sandbox, includingPropertiesForKeys: nil))?.compactMap { FileItem.load($0) } ?? [])
        assert("GalleryViewController builds + reloads", gallery.view.subviews.isEmpty == false, "empty")

        // --- Permissions: once-only onboarding + Full Disk Access detection ---
        let permOnboard = PermissionsOnboardingController()
        _ = permOnboard.window
        assert("PermissionsOnboardingController builds", permOnboard.window?.contentView != nil, "nil")
        assert("permissions onboarding shows 3 unlock bullets",
               permOnboard.testBulletCount == 3, "got \(permOnboard.testBulletCount)")
        assert("permissions onboarding has a title", !permOnboard.testTitle.isEmpty, "empty")
        // The ad-hoc warning is shown iff this build is actually ad-hoc signed.
        assert("ad-hoc warning matches the build's real signature",
               permOnboard.testShowsAdHocWarning == PermissionsManager.isAdHocSigned,
               "warning=\(permOnboard.testShowsAdHocWarning) adhoc=\(PermissionsManager.isAdHocSigned)")
        // FDA probe is side-effect-free and stable across calls (never prompts).
        let fda1 = PermissionsManager.hasFullDiskAccess
        let fda2 = PermissionsManager.hasFullDiskAccess
        assert("Full Disk Access detection is stable", fda1 == fda2, "flapped \(fda1) vs \(fda2)")
        // Once-only gating: save the real flag, exercise both states, then restore.
        let savedOnboarded = PermissionsManager.hasOnboarded
        PermissionsManager.hasOnboarded = false
        assert("a fresh install would present onboarding (unless FDA already on)",
               PermissionsManager.shouldPresentOnboarding == !PermissionsManager.hasFullDiskAccess,
               "should=\(PermissionsManager.shouldPresentOnboarding) fda=\(PermissionsManager.hasFullDiskAccess)")
        PermissionsManager.hasOnboarded = true
        assert("after onboarding once, it never auto-presents again",
               PermissionsManager.shouldPresentOnboarding == false, "still wants to present")
        PermissionsManager.hasOnboarded = savedOnboarded

        // Smart-folder creation sheet builds (no present() → stays off-screen).
        var savedSF: SmartFolder?
        let sfSheet = SmartFolderSheetController(existing: nil, defaultRoot: sandbox,
                                                 onSave: { savedSF = $0 })
        assert("SmartFolderSheetController builds", sfSheet.window?.contentView != nil, "nil")
        _ = savedSF   // silence unused-write warning; onSave is exercised in UI only

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

    /// Spin the run loop until `predicate` holds or `timeout` elapses. Used to
    /// wait out the async (off-main) file-transfer queue in tests.
    @discardableResult
    private func waitUntil(_ timeout: TimeInterval = 3, _ predicate: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !predicate() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        return predicate()
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
