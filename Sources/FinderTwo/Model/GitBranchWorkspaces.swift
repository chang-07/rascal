import Foundation

/// Auto-saves and restores per-branch workspaces for git repos.
///
///   - When a window is showing a path inside `<repo>/...`, we read the
///     current branch from `<repo>/.git/HEAD`.
///   - On any branch switch (detected via FSEvents on `.git/HEAD`), we save
///     the current window's tab/pane snapshot under
///     `git:<repo-path>:<previous-branch>` and try to restore
///     `git:<repo-path>:<new-branch>` if it exists.
///
/// This makes `git checkout feature/foo` automatically restore the tabs and
/// panes you had open while working on that branch.
final class GitBranchWorkspaces {

    /// Singleton — the manager has app-wide state because watchers persist
    /// across window opens and tab changes.
    static let shared = GitBranchWorkspaces()

    private struct ActiveWatch {
        let repoRoot: URL
        let watcher: DirectoryWatcher
        var lastBranch: String
        weak var wc: AnyObject? // BrowserWindowController weak
    }
    private var watches: [ObjectIdentifier: ActiveWatch] = [:]

    /// Discover the repo root for a URL (walks up looking for `.git`).
    static func repoRoot(for url: URL) -> URL? {
        var u = url.standardizedFileURL
        while u.pathComponents.count > 1 {
            let dot = u.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: dot.path) {
                return u
            }
            u = u.deletingLastPathComponent()
        }
        return nil
    }

    /// Read the current branch name from `.git/HEAD`. Returns nil for a
    /// detached HEAD.
    static func currentBranch(in repoRoot: URL) -> String? {
        let head = repoRoot.appendingPathComponent(".git/HEAD")
        guard let s = try? String(contentsOf: head, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Format: "ref: refs/heads/<branch>" or a bare SHA (detached HEAD)
        if trimmed.hasPrefix("ref: refs/heads/") {
            return String(trimmed.dropFirst("ref: refs/heads/".count))
        }
        return nil
    }

    /// Register a window controller — we'll watch its active tab's repo and
    /// fire restore-on-branch-change.
    func register(_ wc: AnyObject, withCurrentURL url: URL) {
        let key = ObjectIdentifier(wc)
        let oldRoot = watches[key]?.repoRoot
        let newRoot = GitBranchWorkspaces.repoRoot(for: url)
        if oldRoot?.path == newRoot?.path { return }
        // Tear down previous watcher
        watches[key]?.watcher.stop()
        watches.removeValue(forKey: key)
        guard let root = newRoot,
              let branch = GitBranchWorkspaces.currentBranch(in: root) else { return }
        let head = root.appendingPathComponent(".git")
        let watcher = DirectoryWatcher(url: head) { [weak self, weak wc] in
            DispatchQueue.main.async {
                guard let self, let wc else { return }
                self.handleHeadChange(for: wc)
            }
        }
        watcher.start()
        watches[key] = ActiveWatch(repoRoot: root, watcher: watcher, lastBranch: branch, wc: wc)
    }

    private func handleHeadChange(for wc: AnyObject) {
        let key = ObjectIdentifier(wc)
        guard var w = watches[key] else { return }
        guard let current = GitBranchWorkspaces.currentBranch(in: w.repoRoot) else { return }
        if current == w.lastBranch { return }
        // Save the now-leaving branch's workspace
        let leavingName = "git:\(w.repoRoot.path):\(w.lastBranch)"
        if let snap = (wc as? BrowserWindowController)?.sessionSnapshot() {
            WorkspaceStore.save(name: leavingName, snapshot: snap)
        }
        // Restore the new branch's workspace if it exists
        let arrivingName = "git:\(w.repoRoot.path):\(current)"
        if let snap = WorkspaceStore.snapshot(forName: arrivingName) {
            (wc as? BrowserWindowController)?.restoreFromSnapshot(snap)
        }
        w.lastBranch = current
        watches[key] = w
    }

    func unregister(_ wc: AnyObject) {
        let key = ObjectIdentifier(wc)
        watches[key]?.watcher.stop()
        watches.removeValue(forKey: key)
    }
}
