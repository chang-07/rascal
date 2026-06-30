import Foundation

/// A GLOBAL "Recent Directories" history — the folders the user has visited,
/// across every pane, tab, and window in the session. Distinct from a pane's
/// per-tab back/forward stacks: this is a flat, de-duplicated, most-recent-first
/// list (capped at `maxCount`) that powers the "Recent Directories" command.
///
/// Mirrors the small-store pattern used by `DropStack` / `SidebarBookmarks`:
/// a stateless enum over a single UserDefaults key, posting `didChange` when it
/// mutates so any open menu/list rebuilds live. Persists across launches.
enum RecentDirectories {
    static let didChange = Notification.Name("FinderTwo.recentDirectoriesDidChange")
    private static let key = "FinderTwo.recentDirectories.v1"
    /// Keep the list short enough to scan at a glance / arrow through quickly.
    static let maxCount = 20
    private static let d = UserDefaults.standard

    /// Record a visit to `url`. Most-recent-first with de-duplication by path:
    /// re-visiting a folder moves it to the front rather than adding a copy, and
    /// the list is trimmed to `maxCount`. Re-recording the current front is a
    /// no-op (so it doesn't churn `didChange` on repeated navigations to the
    /// same place).
    static func record(_ url: URL) {
        let path = url.path
        guard !path.isEmpty else { return }
        var paths = storedPaths()
        if paths.first == path { return }           // already at the front
        paths.removeAll { $0 == path }              // dedup any earlier visit
        paths.insert(path, at: 0)                    // most-recent-first
        if paths.count > maxCount { paths.removeLast(paths.count - maxCount) }
        save(paths)
    }

    /// Current history, most-recent-first, filtered to paths that still exist on
    /// disk (a deleted/unmounted folder shouldn't linger in the menu).
    static func all() -> [URL] {
        storedPaths()
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func clear() { save([]) }

    /// Raw stored list (unfiltered). Used by `record` so trimming/dedup operate
    /// on the persisted truth, not the existence-filtered view.
    private static func storedPaths() -> [String] {
        d.array(forKey: key) as? [String] ?? []
    }

    private static func save(_ paths: [String]) {
        d.set(paths, forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
