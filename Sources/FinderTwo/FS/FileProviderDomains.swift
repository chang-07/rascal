import Foundation
import FileProvider

/// Surfaces cloud-storage roots that macOS exposes through File Provider
/// extensions (Citrix ShareFile, Google Drive, Dropbox, OneDrive, third-party
/// iCloud providers, …). Finder shows these under Locations; without this they
/// were invisible in Rascal because they aren't mounted volumes and don't live
/// under a standard favorite folder.
///
/// We talk to `NSFileProviderManager` rather than scanning `~/Library/CloudStorage`
/// directly: the manager is the supported API, it gives us the provider's display
/// name, and it resolves the *user-visible* on-disk URL even when the layout under
/// CloudStorage changes between macOS releases.
///
/// Entitlement caveat: `NSFileProviderManager.getDomainsWithCompletionHandler`
/// returns providers without any special entitlement, so this compiles and runs
/// in the unsigned / ad-hoc local build. A sandboxed App Store build would need
/// the `com.apple.developer.fileprovider.testing-mode` / iCloud container
/// entitlements to see *every* provider, but that's out of scope for the local
/// build and would break ad-hoc signing — see the PR notes.
enum FileProviderDomains {

    /// A resolved cloud-storage location ready to drop into the sidebar.
    struct Location {
        /// Display name, e.g. "Google Drive" or "ShareFile".
        let title: String
        /// A browsable on-disk root URL the panes can navigate to.
        let url: URL
    }

    /// Enumerate the user's File Provider domains and resolve a browsable root
    /// URL for each. Runs the FileProvider calls off the main thread and always
    /// reports back on the main queue.
    ///
    /// Gracefully yields an empty array when there are no providers, when the
    /// framework reports an error, or when a domain has no resolvable root — the
    /// caller can then simply omit the section rather than show a dangling one.
    static func enumerate(completion: @escaping ([Location]) -> Void) {
        // getDomainsWithCompletionHandler already calls back on a background
        // queue, so we don't need to hop off-main ourselves to start it.
        NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
            if let error {
                // No providers configured surfaces here as an error on some
                // macOS versions; treat any failure as "nothing to show".
                NSLog("Rascal: File Provider domain enumeration failed: \(error.localizedDescription)")
                DispatchQueue.main.async { completion([]) }
                return
            }
            guard !domains.isEmpty else {
                DispatchQueue.main.async { completion([]) }
                return
            }

            var locations: [Location] = []
            for domain in domains {
                // Hidden domains (e.g. a provider the user has hidden from
                // Finder's sidebar) shouldn't appear here either.
                if domain.isHidden { continue }
                guard let root = resolveRootURL(for: domain) else { continue }
                let title = domain.displayName.isEmpty ? root.lastPathComponent : domain.displayName
                locations.append(Location(title: title, url: root))
            }

            // Stable, predictable order in the sidebar.
            locations.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            DispatchQueue.main.async { completion(locations) }
        }
    }

    /// Resolve a browsable on-disk root URL for a domain.
    ///
    /// Uses the documented user-visible URL for the domain's root container
    /// (typically under `~/Library/CloudStorage/…`) — the supported way to get a
    /// path the panes can navigate to on macOS. (`documentStorageURL` /
    /// `pathRelativeToDocumentStorage` are iOS-only and unavailable here.)
    /// Returns nil if the URL can't be resolved or isn't actually on disk yet,
    /// so the caller silently skips that domain rather than adding a dead row.
    private static func resolveRootURL(for domain: NSFileProviderDomain) -> URL? {
        guard let manager = NSFileProviderManager(for: domain) else { return nil }

        // `getUserVisibleURL(for:)` is async; resolve it synchronously here since
        // we're already on a background queue. A short timeout keeps a wedged
        // provider from blocking the enumeration indefinitely.
        let semaphore = DispatchSemaphore(value: 0)
        var resolved: URL?
        manager.getUserVisibleURL(for: .rootContainer) { url, _ in
            if let url, FileManager.default.fileExists(atPath: url.path) {
                resolved = url
            }
            semaphore.signal()
        }
        // 2s is generous for a local metadata lookup; if it's slower the
        // provider is likely wedged and we just skip it for this build.
        _ = semaphore.wait(timeout: .now() + 2)
        return resolved
    }
}
