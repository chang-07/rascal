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
        let fm = FileManager.default
        for src in urls {
            let dst = destination.appendingPathComponent(src.lastPathComponent)
            do {
                if move {
                    try fm.moveItem(at: src, to: dst)
                } else {
                    try fm.copyItem(at: src, to: dst)
                }
            } catch {
                NSSound.beep()
            }
        }
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
