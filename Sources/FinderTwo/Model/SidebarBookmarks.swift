import Foundation

/// Editable sidebar favorites. User-added folders keep using the original v1
/// path store; ordering, hidden defaults, and display-name overrides live in
/// separate keys so existing installs migrate without losing bookmarks.
enum SidebarBookmarks {
    static let didChange = Notification.Name("FinderTwo.sidebarBookmarksDidChange")
    private static let key = "FinderTwo.sidebarBookmarks.v1"
    private static let orderKey = "FinderTwo.sidebarFavoriteOrder.v1"
    private static let hiddenKey = "FinderTwo.sidebarFavoriteHidden.v1"
    private static let titleKey = "FinderTwo.sidebarFavoriteTitles.v1"

    static func all() -> [URL] {
        (UserDefaults.standard.array(forKey: key) as? [String] ?? [])
            .map { URL(fileURLWithPath: $0) }
    }

    static func contains(_ url: URL) -> Bool {
        paths().contains(path(for: url))
    }

    static func add(_ url: URL) {
        let p = path(for: url)
        var ps = paths()
        var hidden = hiddenPaths()
        let changed = !ps.contains(p) || hidden.contains(p)
        if !ps.contains(p) { ps.append(p) }
        hidden.remove(p)
        guard changed else { return }
        save(paths: ps, hidden: hidden)
    }

    static func remove(_ url: URL) {
        let p = path(for: url)
        var hidden = hiddenPaths()
        hidden.insert(p)
        save(paths: paths().filter { $0 != p }, hidden: hidden,
             order: orderPaths().filter { $0 != p })
    }

    /// Merge built-in and user-added favorites, then apply persisted visibility
    /// and ordering. Unknown/stale order entries are ignored; new defaults append
    /// in their canonical order.
    static func ordered(defaults: [URL]) -> [URL] {
        var byPath: [String: URL] = [:]
        var base: [String] = []
        for url in defaults + all() {
            let p = path(for: url)
            if byPath[p] == nil {
                byPath[p] = url
                base.append(p)
            }
        }
        let hidden = hiddenPaths()
        let visible = base.filter { !hidden.contains($0) }
        let visibleSet = Set(visible)
        var result: [String] = []
        for p in orderPaths() where visibleSet.contains(p) && !result.contains(p) {
            result.append(p)
        }
        for p in visible where !result.contains(p) { result.append(p) }
        return result.compactMap { byPath[$0] }
    }

    /// Insert external folders or move existing favorites at a visible boundary.
    /// One notification covers the entire operation so an outline drop cannot
    /// rebuild midway through a multi-item insert.
    static func insert(_ urls: [URL], at insertionIndex: Int, among current: [URL]) {
        var moving: [String] = []
        for url in urls {
            let p = path(for: url)
            if !moving.contains(p) { moving.append(p) }
        }
        guard !moving.isEmpty else { return }

        let currentPaths = current.map(path(for:))
        let movingSet = Set(moving)
        var remaining = currentPaths.filter { !movingSet.contains($0) }
        let boundary = max(0, min(insertionIndex, currentPaths.count))
        let removedBeforeBoundary = currentPaths.prefix(boundary).filter { movingSet.contains($0) }.count
        let destination = max(0, min(boundary - removedBeforeBoundary, remaining.count))
        remaining.insert(contentsOf: moving, at: destination)

        var custom = paths()
        let formerlyVisible = Set(currentPaths)
        for p in moving where !formerlyVisible.contains(p) && !custom.contains(p) {
            custom.append(p)
        }
        var hidden = hiddenPaths()
        for p in moving { hidden.remove(p) }
        save(paths: custom, hidden: hidden, order: remaining)
    }

    static func customTitle(for url: URL) -> String? {
        titles()[path(for: url)]
    }

    static func setCustomTitle(_ title: String?, for url: URL) {
        let p = path(for: url)
        var values = titles()
        let clean = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if clean.isEmpty { values.removeValue(forKey: p) }
        else { values[p] = clean }
        UserDefaults.standard.set(values, forKey: titleKey)
        notify()
    }

    /// Restore built-in visibility/order/labels while retaining user-added
    /// folders. This is the recovery path after removing a built-in favorite.
    static func resetCustomization() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: orderKey)
        defaults.removeObject(forKey: hiddenKey)
        defaults.removeObject(forKey: titleKey)
        notify()
    }

    private static func paths() -> [String] {
        UserDefaults.standard.array(forKey: key) as? [String] ?? []
    }
    private static func orderPaths() -> [String] {
        UserDefaults.standard.array(forKey: orderKey) as? [String] ?? []
    }
    private static func hiddenPaths() -> Set<String> {
        Set(UserDefaults.standard.array(forKey: hiddenKey) as? [String] ?? [])
    }
    private static func titles() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: titleKey) as? [String: String] ?? [:]
    }
    private static func path(for url: URL) -> String {
        url.standardizedFileURL.path
    }
    private static func save(paths: [String], hidden: Set<String>, order: [String]? = nil) {
        UserDefaults.standard.set(paths, forKey: key)
        UserDefaults.standard.set(Array(hidden).sorted(), forKey: hiddenKey)
        if let order { UserDefaults.standard.set(order, forKey: orderKey) }
        notify()
    }
    private static func notify() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
