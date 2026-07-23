import AppKit

/// URL-level write operations for remote (SFTP) locations — the counterpart to
/// the parts of `FileOps` that still make sense on a server.
///
/// Callers pass ordinary `sftp://` URLs; the connection is decoded from the URL,
/// so nothing upstream needs to know about connections.
///
/// Kept separate from `FileOps` on purpose: `FileOps` is built on FileManager
/// and local semantics — Trash, undo registration, packages, aliases — none of
/// which exist on a remote server. Most importantly a server has **no Trash**,
/// so deletion here is permanent and always confirmed.
enum RemoteFileOps {

    static func isRemote(_ url: URL) -> Bool { SFTPLocation.isRemote(url) }

    // MARK: - Create

    /// Create a new folder inside a remote directory, choosing a free name the
    /// way Finder does ("untitled folder", "untitled folder 2", …).
    static func newFolder(in parent: URL, baseName: String = "untitled folder") -> URL? {
        guard let (conn, dir) = SFTPLocation.parse(parent) else { return nil }
        let taken = Set(SFTPClient.list(conn, path: dir).map { $0.name })
        var name = baseName
        var counter = 2
        while taken.contains(name) {
            name = "\(baseName) \(counter)"
            counter += 1
        }
        let remotePath = (dir as NSString).appendingPathComponent(name)
        guard SFTPClient.makeDirectory(conn, path: remotePath) else { return nil }
        return SFTPLocation.url(conn, path: remotePath)
    }

    // MARK: - Rename

    /// Rename a remote entry in place, returning its new URL. Refuses to
    /// overwrite an existing entry, and rejects names containing a path
    /// separator (which would silently move the item elsewhere).
    static func rename(_ url: URL, to newName: String) -> URL? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"),
              let (conn, path) = SFTPLocation.parse(url) else { return nil }
        let dir = (path as NSString).deletingLastPathComponent
        let dest = (dir as NSString).appendingPathComponent(trimmed)
        if dest == path { return url }                       // no-op rename
        guard !SFTPClient.exists(conn, path: dest) else { return nil }
        guard SFTPClient.rename(conn, from: path, to: dest) else { return nil }
        return SFTPLocation.url(conn, path: dest)
    }

    // MARK: - Delete

    /// Permanently delete remote items, always asking first.
    ///
    /// Unlike the local path there is no Trash to fall back on, so the
    /// confirmation is unconditional (not gated on `Settings.confirmTrash`) and
    /// says plainly that it can't be undone.
    @discardableResult
    static func deleteWithConfirmation(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty, let (conn, _) = SFTPLocation.parse(urls[0]) else { return false }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = urls.count == 1
            ? "Permanently delete “\(urls[0].lastPathComponent)”?"
            : "Permanently delete \(urls.count) items?"
        alert.informativeText =
            "Items on a remote server aren’t moved to the Trash. This can’t be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let paths = urls.compactMap { SFTPLocation.parse($0)?.path }
        let dirFlags = directoryFlags(conn, for: paths)
        var allOK = true
        for path in paths {
            if !SFTPClient.remove(conn, path: path, isDirectory: dirFlags[path] ?? false) {
                allOK = false
            }
        }
        return allOK
    }

    /// Route a delete request by location: remote items are permanently deleted
    /// (with their own confirmation), local items go to the Trash as before.
    /// Returns true when remote items were deleted, so the caller knows it must
    /// reload — a remote location has no FSEvents watcher to do it.
    @discardableResult
    static func routeDelete(_ urls: [URL]) -> Bool {
        let remote = urls.filter { isRemote($0) }
        let local = urls.filter { !isRemote($0) }
        if !local.isEmpty { FileOps.trashWithConfirmation(local) }
        guard !remote.isEmpty else { return false }
        return deleteWithConfirmation(remote)
    }

    /// Resolve which of `paths` are directories, with one listing per distinct
    /// parent rather than a probe per item (a multi-select usually shares one).
    private static func directoryFlags(_ conn: SFTPClient.Connection,
                                       for paths: [String]) -> [String: Bool] {
        var flags: [String: Bool] = [:]
        let byParent = Dictionary(grouping: paths) { ($0 as NSString).deletingLastPathComponent }
        for (parent, children) in byParent {
            let entries = SFTPClient.list(conn, path: parent.isEmpty ? "/" : parent)
            let dirNames = Set(entries.filter { $0.isDirectory }.map { $0.name })
            for child in children {
                flags[child] = dirNames.contains((child as NSString).lastPathComponent)
            }
        }
        return flags
    }

    // MARK: - Upload

    /// Copy local files/folders into a remote directory. Directories are walked
    /// and recreated remotely. Returns false if any item failed.
    @discardableResult
    static func upload(_ locals: [URL], into remoteDir: URL) -> Bool {
        guard let (conn, dir) = SFTPLocation.parse(remoteDir) else { return false }
        var allOK = true
        for local in locals {
            let dest = (dir as NSString).appendingPathComponent(local.lastPathComponent)
            if !uploadItem(conn, local: local, to: dest) { allOK = false }
        }
        return allOK
    }

    /// Copy remote files into a local directory. Files only for now —
    /// directories are skipped rather than silently half-copied.
    @discardableResult
    static func download(_ remotes: [URL], into localDir: URL) -> Bool {
        var allOK = true
        for url in remotes {
            guard let (conn, path) = SFTPLocation.parse(url) else { allOK = false; continue }
            let dest = FileOps.uniqueDestination(localDir.appendingPathComponent(url.lastPathComponent))
            if !SFTPClient.download(conn, remotePath: path, to: dest) { allOK = false }
        }
        return allOK
    }

    /// Route a drop/paste by where it's going. Returns true when a remote
    /// operation ran, so the caller reloads (no watcher on remote locations).
    ///
    /// Supported: local→remote (upload), remote→local (download), and
    /// remote→remote *move* on the same host (a server-side rename, so no bytes
    /// cross the wire). Remote→remote copy and cross-host transfers aren't
    /// implemented yet and beep rather than pretending to work.
    @discardableResult
    static func routeTransfer(_ urls: [URL], into destination: URL,
                              move: Bool, from window: NSWindow?) -> Bool {
        let remotes = urls.filter { isRemote($0) }
        let locals = urls.filter { !isRemote($0) }

        guard isRemote(destination) else {
            if !locals.isEmpty {
                FileOps.transfer(locals, into: destination, move: move, from: window)
            }
            if !remotes.isEmpty, !download(remotes, into: destination) { NSSound.beep() }
            return false
        }

        var ok = true
        if !locals.isEmpty { ok = upload(locals, into: destination) && ok }
        if !remotes.isEmpty {
            guard move, let (dstConn, dstDir) = SFTPLocation.parse(destination) else {
                NSSound.beep()          // remote→remote copy not supported yet
                return true
            }
            for url in remotes {
                guard let (srcConn, srcPath) = SFTPLocation.parse(url),
                      srcConn.host == dstConn.host, srcConn.user == dstConn.user else {
                    NSSound.beep(); ok = false; continue      // cross-host move
                }
                let dest = (dstDir as NSString).appendingPathComponent(url.lastPathComponent)
                if !SFTPClient.rename(srcConn, from: srcPath, to: dest) { ok = false }
            }
        }
        if !ok { NSSound.beep() }
        return true
    }

    private static func uploadItem(_ conn: SFTPClient.Connection,
                                   local: URL, to remotePath: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: local.path, isDirectory: &isDir) else {
            return false
        }
        guard isDir.boolValue else {
            return SFTPClient.upload(conn, local: local, to: remotePath)
        }
        // Directory: recreate remotely, then recurse into its children.
        guard SFTPClient.makeDirectory(conn, path: remotePath) else { return false }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: local, includingPropertiesForKeys: nil)) ?? []
        var allOK = true
        for child in children {
            let dest = (remotePath as NSString).appendingPathComponent(child.lastPathComponent)
            if !uploadItem(conn, local: child, to: dest) { allOK = false }
        }
        return allOK
    }
}
