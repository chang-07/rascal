import Foundation

/// Surfaces cloud-storage roots that macOS exposes through File Provider
/// extensions (Google Drive, Dropbox, OneDrive, ShareFile, …) plus iCloud
/// Drive. Finder shows these under Locations; without this they were invisible
/// in Rascal because they aren't mounted volumes and don't live under a
/// standard favorite folder.
///
/// Why not `NSFileProviderManager.getDomainsWithCompletionHandler`? That API
/// only reports domains registered by the *calling* app's own provider
/// extensions. A regular app that isn't a file provider gets
/// `NSFileProviderErrorDomain -2001 ("The application cannot be used right
/// now")` — verified empirically on macOS 26 with both ad-hoc and unsigned
/// builds, and consistent with the framework docs. Finder can see everything
/// because it's Finder; we can't. So we do what other third-party file
/// managers do:
///
///   • Each provider surfaces its user-visible root as a directory under
///     `~/Library/CloudStorage` (e.g. "GoogleDrive-user@gmail.com"). The
///     folder carries a Finder display name ("Google Drive"), which
///     `FileManager.displayName(atPath:)` resolves for us.
///   • iCloud Drive predates that layout and lives at
///     `~/Library/Mobile Documents/com~apple~CloudDocs`.
enum FileProviderDomains {

    /// A resolved cloud-storage location ready to drop into the sidebar.
    struct Location {
        /// Display name, e.g. "Google Drive" or "iCloud Drive".
        let title: String
        /// A browsable on-disk root URL the panes can navigate to.
        let url: URL
    }

    /// Enumerate cloud-storage roots and report on the main queue. Runs the
    /// disk scan off-main; yields an empty array when nothing is configured so
    /// the caller can simply omit the section.
    static func enumerate(completion: @escaping ([Location]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = scan()
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Synchronous scan, separated for testability.
    static func scan(fm: FileManager = .default) -> [Location] {
        var locations: [Location] = []
        let home = fm.homeDirectoryForCurrentUser

        // Third-party providers: one visible directory per provider domain.
        let cloudStorage = home.appendingPathComponent("Library/CloudStorage")
        if let children = try? fm.contentsOfDirectory(
            at: cloudStorage,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) {
            for child in children {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                else { continue }
                // Finder's pretty name ("Google Drive"), falling back to the
                // raw folder name if localization has nothing better.
                let title = fm.displayName(atPath: child.path)
                locations.append(Location(title: title, url: child))
            }
        }

        // iCloud Drive: legacy CloudDocs layout, not under CloudStorage.
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: iCloud.path, isDirectory: &isDir), isDir.boolValue {
            locations.append(Location(title: "iCloud Drive", url: iCloud))
        }

        // Stable, predictable order in the sidebar.
        locations.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return locations
    }
}
