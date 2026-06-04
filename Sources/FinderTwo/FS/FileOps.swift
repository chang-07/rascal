import AppKit

enum FileOps {
    // MARK: - Cut / paste-as-move clipboard state
    //
    // macOS Finder has no true "cut"; the #1 user complaint. We add one: ⌘X
    // writes the URLs to the pasteboard (so ⌘V still works) AND remembers them
    // plus the pasteboard's changeCount. While that changeCount is still current
    // (nothing else was copied), the next ⌘V MOVES instead of copies and the cut
    // rows render dimmed. Any later copy bumps changeCount, which transparently
    // invalidates the cut — no stale state to clean up.
    private static var cutChangeCount: Int = -1
    private static var cutPaths: Set<String> = []

    /// Posted when the cut set changes so file lists can redraw dimmed rows.
    static let clipboardDidChange = Notification.Name("FinderTwo.clipboardDidChange")

    /// ⌘X: mark `urls` as cut. Writes them to `pasteboard` so a plain paste still
    /// works, and remembers them for move-on-paste + dimming.
    static func markCut(_ urls: [URL], to pasteboard: NSPasteboard) {
        guard !urls.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        cutChangeCount = pasteboard.changeCount
        cutPaths = Set(urls.map { $0.standardizedFileURL.path })
        NotificationCenter.default.post(name: clipboardDidChange, object: nil)
    }

    /// True while `pasteboard` still holds the most recent cut (nothing copied since).
    static func isCutActive(for pasteboard: NSPasteboard) -> Bool {
        pasteboard.changeCount == cutChangeCount && !cutPaths.isEmpty
    }

    /// For row dimming: is `url` part of the still-live cut set? Tied to the live
    /// general-pasteboard changeCount, so a subsequent copy auto-un-dims.
    static func isCut(_ url: URL) -> Bool {
        guard NSPasteboard.general.changeCount == cutChangeCount, !cutPaths.isEmpty else { return false }
        return cutPaths.contains(url.standardizedFileURL.path)
    }

    /// If `pasteboard` holds an active cut, clear the marker and return true (so
    /// the caller pastes as a MOVE). Otherwise false (paste as a copy).
    static func consumeCutFlag(for pasteboard: NSPasteboard) -> Bool {
        guard isCutActive(for: pasteboard) else { return false }
        clearCut()
        return true
    }

    /// Drop the cut marker (after a plain copy, or once a cut-move is underway)
    /// and refresh any dimmed rows.
    static func clearCut() {
        guard !cutPaths.isEmpty || cutChangeCount != -1 else { return }
        cutChangeCount = -1
        cutPaths = []
        NotificationCenter.default.post(name: clipboardDidChange, object: nil)
    }

    /// Move to Trash, optionally behind a confirmation alert (Settings.confirmTrash).
    static func trashWithConfirmation(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if Settings.confirmTrash {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = urls.count == 1
                ? "Move “\(urls[0].lastPathComponent)” to the Trash?"
                : "Move \(urls.count) items to the Trash?"
            a.informativeText = "You can put items back from the Trash."
            a.addButton(withTitle: "Move to Trash")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        moveToTrash(urls)
    }

    @discardableResult
    static func moveToTrash(_ urls: [URL]) -> Bool {
        let fm = FileManager.default
        var trashed: [(original: URL, inTrash: URL)] = []
        for u in urls {
            var out: NSURL?
            do {
                try fm.trashItem(at: u, resultingItemURL: &out)
                if let t = out as URL? { trashed.append((u, t)) }
            } catch {
                NSSound.beep()
            }
        }
        guard !trashed.isEmpty else { return false }
        let name = trashed.count == 1 ? "Move to Trash" : "Move \(trashed.count) Items to Trash"
        FileActionLog.shared.record(name,
            undo: {
                var ok = true
                for t in trashed {
                    if fm.fileExists(atPath: t.original.path) { continue }
                    // Re-create the parent if it was removed since, else restore fails.
                    try? fm.createDirectory(at: t.original.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if (try? fm.moveItem(at: t.inTrash, to: t.original)) == nil { ok = false }
                }
                return ok
            },
            redo: {
                // Re-trash and CAPTURE the fresh in-Trash URL: the OS assigns a
                // new path each time, so a later undo must restore from this one,
                // not the original (stale) trash location.
                for i in trashed.indices {
                    var out: NSURL?
                    if (try? fm.trashItem(at: trashed[i].original, resultingItemURL: &out)) != nil,
                       let fresh = out as URL? {
                        trashed[i].inTrash = fresh
                    }
                }
                return true
            })
        return true
    }

    @discardableResult
    static func newFolder(in parent: URL, baseName: String = "untitled folder", recordUndo: Bool = true) -> URL? {
        let fm = FileManager.default
        var candidate = parent.appendingPathComponent(baseName)
        var i = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(baseName) \(i)")
            i += 1
        }
        do {
            try fm.createDirectory(at: candidate, withIntermediateDirectories: false)
            if recordUndo { FileActionLog.shared.recordCreate(candidate, name: "New Folder") }
            return candidate
        } catch {
            NSSound.beep()
            return nil
        }
    }

    static func paste(_ pasteboard: NSPasteboard, into destination: URL, move: Bool, from window: NSWindow? = nil) {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            NSSound.beep(); return
        }
        transfer(urls, into: destination, move: move, from: window)
    }

    enum Conflict { case keepBoth, replace, skip, merge }

    private static func isDir(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// Copy or move `urls` into `destination`, resolving name collisions with a
    /// Finder-style prompt (Merge / Keep Both / Replace / Skip, with Apply to
    /// All) up front, then executing OFF the main thread so big copies never
    /// freeze the UI. Multi-item / folder operations show a cancellable progress
    /// sheet. "Merge" (offered only folder-into-folder) recursively unions the
    /// two trees; colliding files are replaced into the Trash (recoverable).
    /// Resolve copy-vs-move for a drop from the *drag's* operation mask, honoring
    /// an explicit Option-key override. Reading `info.draggingSourceOperationMask`
    /// (instead of transient global modifier state) makes cross-app and
    /// cross-volume drags do the right thing, and keeps the validate-drop feedback
    /// consistent with what accept-drop actually performs.
    static func dropIsCopy(_ info: NSDraggingInfo) -> Bool {
        let mask = info.draggingSourceOperationMask
        if NSEvent.modifierFlags.contains(.option), mask.contains(.copy) { return true }
        if mask.contains(.move) { return false }
        return mask.contains(.copy)
    }

    static func transfer(_ allURLs: [URL], into destination: URL, move: Bool, from window: NSWindow? = nil) {
        let fm = FileManager.default
        // Skip sources that no longer exist (e.g. a stale cut/copy whose file was
        // already moved away); copying a missing source would leave an empty stub.
        let urls = allURLs.filter { fm.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        // Phase 1 (main thread): resolve conflicts, build the work plan.
        var applyAll: Conflict?
        var plan: [(src: URL, dst: URL, merge: Bool)] = []
        var hasDirectory = false
        let dstStd = destination.standardizedFileURL.path
        for src in urls {
            let srcStd = src.standardizedFileURL.path
            // Never move/copy an item into itself or a descendant of itself (a
            // folder dropped onto/into itself → macOS error). Standardize so
            // trailing-slash / symlink / `..` variants all compare equal.
            if dstStd == srcStd || dstStd.hasPrefix(srcStd + "/") { continue }
            let sameParent = src.deletingLastPathComponent().standardizedFileURL.path == dstStd
            // Move into the item's own directory is a no-op.
            if sameParent && move { continue }
            var dst = destination.appendingPathComponent(src.lastPathComponent)
            var merge = false
            if sameParent && !move {
                // Copy into the same directory → unique-named duplicate (Finder
                // behavior); don't raise a self-collision "already exists" prompt.
                dst = uniqueDestination(dst)
            } else if fm.fileExists(atPath: dst.path) {
                let canMerge = isDir(src) && isDir(dst)
                var res: Conflict
                if let a = applyAll { res = a }
                else {
                    let (r, all) = promptConflict(name: src.lastPathComponent, multiple: urls.count > 1, canMerge: canMerge)
                    if all { applyAll = r }
                    res = r
                }
                // "Merge" only makes sense folder-into-folder; otherwise keep both.
                if res == .merge && !canMerge { res = .keepBoth }
                switch res {
                case .skip: continue
                case .keepBoth: dst = uniqueDestination(dst)
                case .replace: try? fm.trashItem(at: dst, resultingItemURL: nil)
                case .merge: merge = true
                }
            }
            if isDir(src) { hasDirectory = true }
            plan.append((src, dst, merge))
        }
        guard !plan.isEmpty else { return }

        // Phase 2: hand the plan to the shared transfer queue (serial, off-main,
        // pausable/cancellable, streamed). Surface the activity panel for
        // non-trivial work — but never in headless test runs (keeps tests
        // window-free).
        _ = window  // (the queue's activity panel is window-independent)
        TransferQueue.shared.enqueue(plan: plan, move: move)
        let headless = ProcessInfo.processInfo.environment["FT_HEADLESS_TESTING"] != nil
        if !headless && (plan.count > 1 || hasDirectory) {
            DispatchQueue.main.async { TransferActivityController.shared.present() }
        }
    }

    /// Recursively union `src` into the existing directory `dst`. Entries absent
    /// in `dst` are copied/moved in; two directories recurse; a file collision
    /// sends the destination file to the Trash and brings the source in
    /// (recoverable). Returns the number of failed leaf operations. Exposed for
    /// tests.
    @discardableResult
    static func mergeDirectory(src: URL, into dst: URL, move: Bool, fm: FileManager = .default) -> Int {
        var failures = 0
        let children = (try? fm.contentsOfDirectory(at: src,
            includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        for child in children {
            let target = dst.appendingPathComponent(child.lastPathComponent)
            var dest = target
            if fm.fileExists(atPath: target.path) {
                if isDir(child) && isDir(target) {
                    failures += mergeDirectory(src: child, into: target, move: move, fm: fm)
                    continue
                }
                // Same-type file collision → replace into the Trash (recoverable).
                // Type mismatch (file vs dir) → keep both rather than send a whole
                // directory to the Trash just to drop a file in its place.
                if isDir(child) == isDir(target) {
                    try? fm.trashItem(at: target, resultingItemURL: nil)
                } else {
                    dest = uniqueDestination(target)
                }
            }
            do {
                if move { try fm.moveItem(at: child, to: dest) }
                else { try fm.copyItem(at: child, to: dest) }
            } catch { failures += 1 }
        }
        // When moving, drop the source dir only if we emptied it (never nuke
        // files that failed to move).
        if move, ((try? fm.contentsOfDirectory(atPath: src.path))?.isEmpty ?? false) {
            try? fm.removeItem(at: src)
        }
        return failures
    }

    /// "<base> 2.ext", "<base> 3.ext", … — first name that doesn't exist.
    static func uniqueDestination(_ url: URL) -> URL {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var i = 2
        var candidate = url
        while fm.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            candidate = dir.appendingPathComponent(name)
            i += 1
        }
        return candidate
    }

    private static func promptConflict(name: String, multiple: Bool, canMerge: Bool) -> (Conflict, Bool) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "An item named “\(name)” already exists here."
        alert.informativeText = canMerge
            ? "Merge the folders, keep both, replace the existing item, or skip it?"
            : "Keep both, replace the existing item, or skip it?"
        // Buttons map to `actions` by order (alertFirstButtonReturn = index 0).
        var actions: [Conflict] = []
        if canMerge { alert.addButton(withTitle: "Merge"); actions.append(.merge) }
        alert.addButton(withTitle: "Keep Both"); actions.append(.keepBoth)
        alert.addButton(withTitle: "Replace");   actions.append(.replace)
        alert.addButton(withTitle: "Skip");      actions.append(.skip)
        var box: NSButton?
        if multiple {
            let cb = NSButton(checkboxWithTitle: "Apply to all", target: nil, action: nil)
            alert.accessoryView = cb
            box = cb
        }
        let resp = alert.runModal()
        let idx = resp.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let conflict = actions.indices.contains(idx) ? actions[idx] : .skip
        return (conflict, box?.state == .on)
    }

    /// Create an empty "untitled" file in `parent` (uniquely named). Returns it.
    @discardableResult
    static func newFile(in parent: URL, baseName: String = "untitled") -> URL? {
        let dest = uniqueDestination(parent.appendingPathComponent(baseName))
        guard FileManager.default.createFile(atPath: dest.path, contents: Data()) else { return nil }
        FileActionLog.shared.recordCreate(dest, name: "New File")
        return dest
    }

    /// Group `items` into a new folder in `parent` (Finder's "New Folder with
    /// Selection"). Returns the new folder, or nil on failure.
    @discardableResult
    static func newFolderWithItems(_ items: [URL], in parent: URL) -> URL? {
        guard !items.isEmpty,
              let folder = newFolder(in: parent, baseName: "New Folder With Items", recordUndo: false) else { return nil }
        let fm = FileManager.default
        var moved: [(from: URL, to: URL)] = []
        for src in items {
            let dst = folder.appendingPathComponent(src.lastPathComponent)
            if (try? fm.moveItem(at: src, to: dst)) != nil { moved.append((src, dst)) }
        }
        // Undo: move the items back to where they came from, then drop the folder.
        FileActionLog.shared.record("New Folder with Selection",
            undo: {
                moved.forEach { try? fm.moveItem(at: $0.to, to: $0.from) }
                try? fm.trashItem(at: folder, resultingItemURL: nil)
                return true
            },
            redo: {
                _ = try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
                moved.forEach { try? fm.moveItem(at: $0.from, to: $0.to) }
                return true
            })
        return folder
    }

    /// Permanently delete (bypass Trash) after confirmation. Returns true if done.
    @discardableResult
    static func deleteImmediately(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = urls.count == 1
            ? "Delete “\(urls[0].lastPathComponent)” immediately?"
            : "Delete \(urls.count) items immediately?"
        alert.informativeText = "This cannot be undone — the items are not moved to the Trash."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let fm = FileManager.default
        var ok = true
        for u in urls { do { try fm.removeItem(at: u) } catch { ok = false } }
        return ok
    }

    static let imageExtensions: Set<String> =
        ["jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "tif", "bmp", "webp"]

    /// Set the given image as the desktop picture on the main screen.
    static func setDesktopPicture(_ url: URL) {
        guard let screen = NSScreen.main else { return }
        try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
    }

    /// Empty the Trash via Finder (matches the system behavior + its warning).
    static func emptyTrash() {
        let src = "tell application \"Finder\" to empty trash"
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        if err != nil { NSSound.beep() }
    }

    static func revealInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Create a symlink ("alias") next to each item, named "<name> alias".
    @discardableResult
    static func makeAliases(for urls: [URL]) -> [URL] {
        let fm = FileManager.default
        var created: [URL] = []
        for u in urls {
            let dir = u.deletingLastPathComponent()
            var dest = dir.appendingPathComponent("\(u.lastPathComponent) alias")
            var i = 2
            while fm.fileExists(atPath: dest.path) {
                dest = dir.appendingPathComponent("\(u.lastPathComponent) alias \(i)"); i += 1
            }
            do { try fm.createSymbolicLink(at: dest, withDestinationURL: u); created.append(dest) }
            catch { NSSound.beep() }
        }
        return created
    }
}
