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
        // getDomainsWithCompletionHandler calls back on a private queue; we never
        // block it (or the main thread). Each domain's user-visible URL is resolved
        // via its own async callback and joined with a DispatchGroup, so a wedged
        // provider can't stall the others or the UI (the old code blocked up to 2s
        // PER domain on a semaphore, and risked a deadlock if the callback was
        // delivered on the very queue parked in the wait).
        NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
            if let error {
                // No providers configured surfaces here as an error on some
                // macOS versions; treat any failure as "nothing to show".
                NSLog("Rascal: File Provider domain enumeration failed: \(error.localizedDescription)")
                DispatchQueue.main.async { completion([]) }
                return
            }
            // Hidden domains (e.g. a provider the user has hidden from Finder's
            // sidebar) shouldn't appear here either.
            let visible = domains.filter { !$0.isHidden }
            guard !visible.isEmpty else {
                DispatchQueue.main.async { completion([]) }
                return
            }

            // Resolve every domain's root URL concurrently. `locations` is only
            // mutated inside `lock`, so the concurrent callbacks can't race.
            let group = DispatchGroup()
            let lock = NSLock()
            var locations: [Location] = []

            for domain in visible {
                guard let manager = NSFileProviderManager(for: domain) else { continue }
                group.enter()
                // `getUserVisibleURL(for:)` is async and runs the lookup off our
                // thread; we just record the result when it lands. No semaphore, no
                // per-domain blocking wait — a slow provider only delays its own row.
                manager.getUserVisibleURL(for: .rootContainer) { url, _ in
                    defer { group.leave() }
                    guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
                    let title = domain.displayName.isEmpty ? url.lastPathComponent : domain.displayName
                    lock.lock()
                    locations.append(Location(title: title, url: url))
                    lock.unlock()
                }
            }

            // Fire once all domains have reported, then hop to main with the
            // assembled, stably-ordered set.
            group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
                lock.lock()
                var result = locations
                lock.unlock()
                // Stable, predictable order in the sidebar.
                result.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                DispatchQueue.main.async { completion(result) }
            }
        }
    }
}
