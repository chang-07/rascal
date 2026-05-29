import Foundation

/// User-added sidebar favorites — folders the user dragged/added into the
/// sidebar. Stored as paths in UserDefaults; posts `didChange` so the sidebar
/// rebuilds live when an entry is added or removed.
enum SidebarBookmarks {
    static let didChange = Notification.Name("FinderTwo.sidebarBookmarksDidChange")
    private static let key = "FinderTwo.sidebarBookmarks.v1"

    static func all() -> [URL] {
        (UserDefaults.standard.array(forKey: key) as? [String] ?? [])
            .map { URL(fileURLWithPath: $0) }
    }

    static func contains(_ url: URL) -> Bool {
        paths().contains(url.path)
    }

    static func add(_ url: URL) {
        let p = url.path
        var ps = paths()
        guard !ps.contains(p) else { return }
        ps.append(p)
        save(ps)
    }

    static func remove(_ url: URL) {
        let p = url.path
        save(paths().filter { $0 != p })
    }

    private static func paths() -> [String] {
        UserDefaults.standard.array(forKey: key) as? [String] ?? []
    }
    private static func save(_ ps: [String]) {
        UserDefaults.standard.set(ps, forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
