import AppKit
import UniformTypeIdentifiers

/// Cache for the small 16×16 icons we draw on each row. Two tiers:
///
/// 1. Per-URL cache (for QL thumbnails of images, PDFs, etc — actual contents)
/// 2. Per-extension cache (for generic file-type icons — share across files)
///
/// Cells should call `IconCache.shared.icon(for:)` instead of going through
/// NSWorkspace directly. The per-extension tier means that opening a folder
/// with 5000 .txt files only calls NSWorkspace.icon(forFileType:) once.
final class IconCache {
    static let shared = IconCache()

    /// 16×16 icon for an arbitrary URL. Honors the per-URL thumbnail cache
    /// when available (set elsewhere by ThumbnailService), otherwise returns
    /// the cached generic icon for the file's extension.
    func icon(for item: FileItem) -> NSImage {
        if let thumb = thumbCache.object(forKey: item.url as NSURL) {
            return thumb
        }
        // Special-case directories so we share the system folder icon, but NOT packages.
        if item.isDirectory && !item.isPackage {
            return folderIcon
        }
        // Reading an item's OWN icon via icon(forFile:) opens that path, which fires a
        // one-time TCC permission prompt for items in protected locations (Desktop/
        // Documents/Downloads/Library/Movies/Music/Pictures, /Volumes) when Full Disk
        // Access is off — the very prompt the onboarding flow exists to avoid. So per-file
        // reads (packages + extensionless files) are guarded by `mayReadFile`; the common
        // per-extension cached path below never reaches that check, keeping it hot.
        if item.isPackage {
            if mayReadFile(item.url) {
                let img = NSWorkspace.shared.icon(forFile: item.url.path)
                img.size = NSSize(width: 16, height: 16)
                thumbCache.setObject(img, forKey: item.url as NSURL)
                return img
            }
            // Generic, type-based package icon (e.g. .app → generic app icon). Not
            // cached per-URL so the real icon is read once FDA is granted this session.
            let type = UTType(filenameExtension: item.ext) ?? .package
            let img = NSWorkspace.shared.icon(for: type)
            img.size = NSSize(width: 16, height: 16)
            return img
        }
        let ext = item.ext
        if let cached = extCache.object(forKey: ext as NSString) {
            return cached   // hot path: no TCC probe, no file read
        }
        // Per-extension generic icon derived from the UTType for the extension —
        // never opens the file, and shared across all files of that extension.
        let img: NSImage
        if ext.isEmpty {
            img = mayReadFile(item.url) ? NSWorkspace.shared.icon(forFile: item.url.path)
                                        : NSWorkspace.shared.icon(for: .data)
        } else if let type = UTType(filenameExtension: ext) {
            img = NSWorkspace.shared.icon(for: type)
        } else {
            img = NSWorkspace.shared.icon(for: .data)
        }
        img.size = NSSize(width: 16, height: 16)
        extCache.setObject(img, forKey: ext as NSString)
        return img
    }

    /// Whether we're allowed to read this URL's own icon without risking a TCC
    /// prompt. Only consulted off the cached hot path (packages / extensionless).
    private func mayReadFile(_ url: URL) -> Bool {
        PermissionsManager.hasFullDiskAccess || !PermissionsManager.isProtectedPath(url.path)
    }

    /// Insert a real thumbnail (from QL) for a URL — used by FileListController
    /// when an async thumbnail finishes.
    func putThumbnail(_ image: NSImage, for url: URL) {
        image.size = NSSize(width: 16, height: 16)
        thumbCache.setObject(image, forKey: url as NSURL)
    }

    private let extCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 256
        return c
    }()
    private let thumbCache: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>()
        c.countLimit = 4000
        return c
    }()
    private let folderIcon: NSImage = {
        let img = NSWorkspace.shared.icon(for: .folder)
        img.size = NSSize(width: 16, height: 16)
        return img
    }()
}
