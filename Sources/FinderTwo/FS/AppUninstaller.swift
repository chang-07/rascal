import AppKit

/// Scans the standard macOS app-leftover locations for files associated with
/// a given .app bundle, by matching the bundle identifier (and its prefix).
enum AppUninstaller {

    struct Leftover {
        let url: URL
        let size: Int64
        let kind: String   // "Caches", "Application Support", etc.
    }

    /// Reads the Info.plist of an .app bundle and returns its bundle id.
    static func bundleId(for app: URL) -> String? {
        Bundle(url: app)?.bundleIdentifier
    }

    /// Find all leftover files associated with the given bundle id under
    /// `~/Library`. Search is recursive only one level deep in each location
    /// (the standard storage convention).
    static func scanLeftovers(bundleId: String) -> [Leftover] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library")
        let prefixes: [(String, String)] = [
            ("Application Support", "Application Support"),
            ("Caches", "Caches"),
            ("Preferences", "Preferences"),
            ("LaunchAgents", "LaunchAgents"),
            ("Saved Application State", "Saved Application State"),
            ("Containers", "Containers"),
            ("Group Containers", "Group Containers"),
            ("Logs", "Logs"),
            ("WebKit", "WebKit"),
            ("HTTPStorages", "HTTPStorages"),
        ]
        var leftovers: [Leftover] = []
        let bidLower = bundleId.lowercased()
        // Guard against dangerously generic ids: a 1-2 component id like
        // "com.apple" would match a huge swath of ~/Library. Require something
        // specific enough to be a real per-app identifier.
        guard bidLower.count >= 6, bidLower.contains(".") else { return [] }
        for (subdir, label) in prefixes {
            let dir = library.appendingPathComponent(subdir)
            guard let kids = try? FileManager.default.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: []) else { continue }
            for k in kids {
                if matchesBundleId(k.lastPathComponent, bidLower) {
                    leftovers.append(Leftover(url: k,
                                              size: directorySize(k),
                                              kind: label))
                }
            }
        }
        return leftovers
    }

    /// True when a leftover file/dir name belongs to this bundle id. Matches the
    /// id exactly or as a dotted/hyphenated prefix (e.g. "com.foo.App",
    /// "com.foo.App.plist", "com.foo.App.helper") — NOT an arbitrary substring,
    /// so "com.foo.App" never sweeps in a sibling app's "com.foo.AppExtras".
    static func matchesBundleId(_ rawName: String, _ bidLower: String) -> Bool {
        // Drop a known file extension so "com.foo.App.plist"/".savedState" match.
        var n = rawName.lowercased()
        for ext in [".plist", ".savedstate", ".binarycookies"] where n.hasSuffix(ext) {
            n = String(n.dropLast(ext.count)); break
        }
        if n == bidLower { return true }
        return n.hasPrefix(bidLower + ".") || n.hasPrefix(bidLower + "-")
    }

    /// Move every leftover (and the app bundle itself) to Trash.
    @discardableResult
    static func uninstall(app: URL, leftovers: [Leftover]) -> Bool {
        var ok = true
        for l in leftovers {
            do { try FileManager.default.trashItem(at: l.url, resultingItemURL: nil) }
            catch { ok = false }
        }
        do { try FileManager.default.trashItem(at: app, resultingItemURL: nil) }
        catch { ok = false }
        return ok
    }

    private static func directorySize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        let en = FileManager.default.enumerator(at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsPackageDescendants])
        while let next = en?.nextObject() as? URL {
            if let s = (try? next.resourceValues(forKeys: [.fileSizeKey]).fileSize), s > 0 {
                total += Int64(s)
            }
        }
        return total
    }
}
