import Foundation

/// The Drop Stack ("shelf"): an ordered, de-duplicated bag of file URLs the
/// user collects from anywhere, then drags out (or copies/moves) to a
/// destination in one go. Persisted across launches in UserDefaults.
enum DropStack {
    static let didChange = Notification.Name("FinderTwo.dropStackDidChange")
    private static let key = "FinderTwo.dropStack.v1"
    private static let d = UserDefaults.standard

    /// Current contents, filtered to paths that still exist.
    static func all() -> [URL] {
        let paths = d.array(forKey: key) as? [String] ?? []
        return paths.filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func contains(_ url: URL) -> Bool {
        all().contains { $0.path == url.path }
    }

    /// Append `urls`, skipping duplicates (by path). Returns how many were new.
    @discardableResult
    static func add(_ urls: [URL]) -> Int {
        var paths = all().map { $0.path }
        let existing = Set(paths)
        var added = 0
        for u in urls where !existing.contains(u.path) {
            paths.append(u.path); added += 1
        }
        if added > 0 { save(paths) }
        return added
    }

    static func remove(_ url: URL) {
        save(all().map { $0.path }.filter { $0 != url.path })
    }

    static func clear() { save([]) }

    private static func save(_ paths: [String]) {
        d.set(paths, forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
