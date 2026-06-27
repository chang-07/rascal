import Foundation
import CoreServices

/// Reads Spotlight metadata attributes that aren't on `FileItem` — the Finder
/// comment (`kMDItemFinderComment`) and the date a file was added to its folder
/// (`kMDItemDateAdded`) — for the configurable list-view columns.
///
/// `MDItemCreateWithURL` does synchronous disk I/O, which can be slow on a large
/// or networked folder, so the list view fetches these OFF the main thread and
/// repaints the row when the value lands. This type only does the raw read; the
/// caching / async dispatch lives in `FileListController` next to the existing
/// folder-size cache so both share the same "fetch off-main, reload one row"
/// pattern.
enum SpotlightMetadata {

    /// The Finder comment for `url`, or empty string if none / unreadable.
    /// Safe to call off the main thread.
    static func finderComment(_ url: URL) -> String {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return "" }
        return (MDItemCopyAttribute(item, kMDItemFinderComment) as? String) ?? ""
    }

    /// The date `url` was added to its enclosing folder, or nil if Spotlight has
    /// no record of it (e.g. a freshly created file, or an unindexed volume).
    /// Safe to call off the main thread.
    static func dateAdded(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemDateAdded) as? Date
    }
}
