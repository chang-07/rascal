import Foundation

/// Remembers, per directory, the view mode + sort the user last chose there, so
/// a folder reopens the way they left it (Finder's per-folder views — but stored
/// centrally in our prefs rather than scattering `.DS_Store` files). Only folders
/// the user explicitly customizes get an entry; everything else uses the global
/// default. Bounded so the store can't grow without limit.
enum FolderViewPrefs {
    struct Pref: Codable, Equatable {
        var view: String        // ViewMode.rawValue
        var sortKey: String     // SortKey.rawValue
        var ascending: Bool

        /// Reconstruct a live SortDescriptor (foldersFirst follows the current
        /// global setting rather than being frozen per folder).
        var sortDescriptor: SortDescriptor {
            SortDescriptor(key: SortKey(rawValue: sortKey) ?? .name,
                           ascending: ascending,
                           foldersFirst: Settings.foldersFirst)
        }
    }

    // Headless tests use a separate key so the suite never clobbers the user's
    // real folder-view prefs.
    private static let storeKey: String =
        ProcessInfo.processInfo.environment["FT_HEADLESS_TESTING"] == "1"
            ? "FinderTwo.folderViewPrefs.test"
            : "FinderTwo.folderViewPrefs.v1"

    private static let maxEntries = 2000
    private static let lock = NSLock()

    private static var cache: [String: Pref] = {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode([String: Pref].self, from: data) else { return [:] }
        return decoded
    }()

    /// The remembered pref for `path`, or nil if the user never customized it.
    static func get(_ path: String) -> Pref? {
        lock.lock(); defer { lock.unlock() }
        return cache[path]
    }

    /// Persist the view + sort the user just chose for `path`.
    static func set(_ path: String, view: String, sort: SortDescriptor) {
        lock.lock(); defer { lock.unlock() }
        cache[path] = Pref(view: view, sortKey: sort.key.rawValue, ascending: sort.ascending)
        if cache.count > maxEntries {
            // Non-critical data: shed arbitrary excess to stay bounded.
            for k in cache.keys.prefix(cache.count - maxEntries) { cache.removeValue(forKey: k) }
        }
        persistLocked()
    }

    /// Forget every saved folder view (exposed for a "reset" affordance + tests).
    static func clearAll() {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll()
        UserDefaults.standard.removeObject(forKey: storeKey)
    }

    /// Number of stored folders (test/diagnostic hook).
    static var count: Int { lock.lock(); defer { lock.unlock() }; return cache.count }

    private static func persistLocked() {
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }
}
