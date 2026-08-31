import Foundation

/// Canonical selection for one pane.
///
/// AppKit views own their visual highlights, but file commands must not infer a
/// selection from whichever hidden view happens to retain one. Keeping URLs here
/// makes copy, trash, tags, and status text agree across list, icon, gallery,
/// and column views.
final class SelectionModel {
    private(set) var urls: [URL] = []
    private(set) var focusedURL: URL?

    func replace(with urls: [URL], focusedURL: URL? = nil) {
        var seen = Set<String>()
        self.urls = urls.filter { seen.insert(Self.key(for: $0)).inserted }
        if let focusedURL, self.urls.contains(where: { Self.key(for: $0) == Self.key(for: focusedURL) }) {
            self.focusedURL = focusedURL
        } else {
            self.focusedURL = self.urls.first
        }
    }

    func clear() {
        urls = []
        focusedURL = nil
    }

    /// Drops paths that disappeared from the active directory after a reload.
    func retain(available items: [FileItem]) {
        let available = Set(items.map { Self.key(for: $0.url) })
        replace(with: urls.filter { available.contains(Self.key(for: $0)) }, focusedURL: focusedURL)
    }

    private static func key(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
