import AppKit

enum FileOps {
    @discardableResult
    static func moveToTrash(_ urls: [URL]) -> Bool {
        let fm = FileManager.default
        var anySucceeded = false
        for u in urls {
            do {
                try fm.trashItem(at: u, resultingItemURL: nil)
                anySucceeded = true
            } catch {
                NSSound.beep()
            }
        }
        return anySucceeded
    }

    @discardableResult
    static func newFolder(in parent: URL, baseName: String = "untitled folder") -> URL? {
        let fm = FileManager.default
        var candidate = parent.appendingPathComponent(baseName)
        var i = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(baseName) \(i)")
            i += 1
        }
        do {
            try fm.createDirectory(at: candidate, withIntermediateDirectories: false)
            return candidate
        } catch {
            NSSound.beep()
            return nil
        }
    }

    static func paste(_ pasteboard: NSPasteboard, into destination: URL, move: Bool) {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            NSSound.beep(); return
        }
        transfer(urls, into: destination, move: move)
    }

    enum Conflict { case keepBoth, replace, skip }

    /// Copy or move `urls` into `destination`, resolving name collisions with a
    /// Finder-style prompt (Keep Both / Replace / Skip, with Apply to All).
    /// Guards against dropping an item onto itself or into its own descendant.
    static func transfer(_ urls: [URL], into destination: URL, move: Bool) {
        let fm = FileManager.default
        var applyAll: Conflict?
        var failures = 0
        for src in urls {
            // No-op moving into the same directory; never copy/move into self.
            if move && src.deletingLastPathComponent().path == destination.path { continue }
            if destination.path == src.path || destination.path.hasPrefix(src.path + "/") { failures += 1; continue }
            var dst = destination.appendingPathComponent(src.lastPathComponent)
            if fm.fileExists(atPath: dst.path) {
                let res: Conflict
                if let a = applyAll { res = a }
                else {
                    let (r, all) = promptConflict(name: src.lastPathComponent, multiple: urls.count > 1)
                    if all { applyAll = r }
                    res = r
                }
                switch res {
                case .skip: continue
                case .keepBoth: dst = uniqueDestination(dst)
                case .replace: try? fm.trashItem(at: dst, resultingItemURL: nil)
                }
            }
            do {
                if move { try fm.moveItem(at: src, to: dst) } else { try fm.copyItem(at: src, to: dst) }
            } catch { failures += 1 }
        }
        if failures > 0 { NSSound.beep() }
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

    private static func promptConflict(name: String, multiple: Bool) -> (Conflict, Bool) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "An item named “\(name)” already exists here."
        alert.informativeText = "Keep both, replace the existing item, or skip it?"
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Skip")
        var box: NSButton?
        if multiple {
            let cb = NSButton(checkboxWithTitle: "Apply to all", target: nil, action: nil)
            alert.accessoryView = cb
            box = cb
        }
        let resp = alert.runModal()
        let conflict: Conflict
        switch resp {
        case .alertFirstButtonReturn: conflict = .keepBoth
        case .alertSecondButtonReturn: conflict = .replace
        default: conflict = .skip
        }
        return (conflict, box?.state == .on)
    }

    /// Create an empty "untitled" file in `parent` (uniquely named). Returns it.
    @discardableResult
    static func newFile(in parent: URL, baseName: String = "untitled") -> URL? {
        let dest = uniqueDestination(parent.appendingPathComponent(baseName))
        return FileManager.default.createFile(atPath: dest.path, contents: Data()) ? dest : nil
    }

    /// Group `items` into a new folder in `parent` (Finder's "New Folder with
    /// Selection"). Returns the new folder, or nil on failure.
    @discardableResult
    static func newFolderWithItems(_ items: [URL], in parent: URL) -> URL? {
        guard !items.isEmpty, let folder = newFolder(in: parent, baseName: "New Folder With Items") else { return nil }
        let fm = FileManager.default
        for src in items {
            try? fm.moveItem(at: src, to: folder.appendingPathComponent(src.lastPathComponent))
        }
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

    /// Delegates Get Info to Finder via AppleScript (path of least resistance for v0).
    static func getInfo(_ urls: [URL]) {
        for u in urls {
            // Escape backslash FIRST, then the quote — otherwise a filename
            // containing a backslash or an embedded quote can break out of the
            // AppleScript string literal (injection via attacker-named files).
            let posix = u.path
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let src = """
            tell application "Finder"
                activate
                open information window of (POSIX file "\(posix)" as alias)
            end tell
            """
            var err: NSDictionary?
            NSAppleScript(source: src)?.executeAndReturnError(&err)
            if err != nil { NSSound.beep() }
        }
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
