import AppKit
import UniformTypeIdentifiers

/// Makes Rascal the system handler for folders and drives, so opening a folder, a
/// volume, or a "Reveal in Finder" from another app routes to Rascal instead of
/// Finder.
///
/// What this can and can't do: macOS keeps Finder running for the desktop and for
/// mounting drives, and those can't be replaced — this is the same ceiling every
/// third-party file manager (Bloom, QSpace, ForkLift) hits. What IS achievable is
/// owning the *open-folder* role via Launch Services, which is what this does.
/// Because Rascal isn't sandboxed, it can set the handler directly through
/// `NSWorkspace` — no Terminal commands (the App Store builds of other managers
/// need them because the sandbox forbids this call).
enum DefaultFileManager {
    /// The content types a file manager should own: folders, generic directories,
    /// and mounted volumes. `public.folder` carries most folder opens; adding
    /// `public.volume` routes drives too. All three are declared in Info.plist, so
    /// Launch Services accepts Rascal as a candidate handler.
    private static let types: [UTType] = [.folder, .directory, .volume]

    private static var bundleID: String { Bundle.main.bundleIdentifier ?? "dev.chang.FinderTwo" }

    /// Is Rascal the current default handler for folders?
    static var isDefault: Bool {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: .folder),
            let id = Bundle(url: url)?.bundleIdentifier
        else { return false }
        return id == bundleID
    }

    /// Point the folder/volume handlers at the running Rascal bundle. Calls back on
    /// the main queue with the first error, or nil on success.
    static func makeDefault(completion: @escaping (Error?) -> Void) {
        apply(appURL: Bundle.main.bundleURL, completion: completion)
    }

    /// Hand the folder/volume handlers back to Finder.
    static func restoreFinder(completion: @escaping (Error?) -> Void) {
        guard let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else {
            completion(nil)
            return
        }
        apply(appURL: finder, completion: completion)
    }

    private static func apply(appURL: URL, completion: @escaping (Error?) -> Void) {
        let group = DispatchGroup()
        var firstError: Error?
        for type in types {
            group.enter()
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type) { error in
                if let error, firstError == nil { firstError = error }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(firstError) }
    }
}
