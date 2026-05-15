import AppKit

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
        // Special-case directories so we share the system folder icon.
        if item.isDirectory {
            return folderIcon
        }
        let ext = item.ext
        if let cached = extCache.object(forKey: ext as NSString) {
            return cached
        }
        // Per-extension generic icon: NSWorkspace.icon(forFileType:) sees only
        // the extension, never opens the file.
        let img: NSImage
        if ext.isEmpty {
            img = NSWorkspace.shared.icon(forFile: item.url.path)
        } else {
            img = NSWorkspace.shared.icon(forFileType: ext)
        }
        img.size = NSSize(width: 16, height: 16)
        extCache.setObject(img, forKey: ext as NSString)
        return img
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
        let img = NSWorkspace.shared.icon(forFileType: "public.folder")
        img.size = NSSize(width: 16, height: 16)
        return img
    }()
}
