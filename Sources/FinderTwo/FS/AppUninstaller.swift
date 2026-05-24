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
        for (subdir, label) in prefixes {
            let dir = library.appendingPathComponent(subdir)
            guard let kids = try? FileManager.default.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: []) else { continue }
            for k in kids {
                let name = k.lastPathComponent
                if name.lowercased().contains(bidLower) || name.lowercased().hasPrefix(bidLower) {
                    leftovers.append(Leftover(url: k,
                                              size: directorySize(k),
                                              kind: label))
                }
            }
        }
        return leftovers
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
