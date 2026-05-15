import AppKit
import QuickLookThumbnailing

/// Generates real Quick Look thumbnails off the main thread, caches them in
/// memory, and notifies a completion callback so the file list can re-render
/// the affected row.
final class ThumbnailService {
    static let shared = ThumbnailService()

    private let cache: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>()
        c.countLimit = 4000
        return c
    }()
    private var inFlight = Set<URL>()
    private let queue = DispatchQueue(label: "FinderTwo.Thumbs", qos: .utility)

    /// Returns a cached thumbnail if available. Otherwise schedules generation
    /// in the background and calls `onLoad` on the main queue when ready.
    /// `onLoad` is only invoked if a real thumbnail was successfully generated.
    func thumbnail(for url: URL, size: CGSize, onLoad: @escaping (NSImage) -> Void) -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }
        // Only attempt QL thumbnails for likely-previewable types
        guard isThumbnailable(url) else { return nil }
        if inFlight.contains(url) { return nil }
        inFlight.insert(url)

        queue.async { [weak self] in
            guard let self else { return }
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: size,
                scale: scale,
                representationTypes: .thumbnail
            )
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                DispatchQueue.main.async {
                    self.inFlight.remove(url)
                    guard let rep else { return }
                    let img = rep.nsImage
                    self.cache.setObject(img, forKey: url as NSURL)
                    onLoad(img)
                }
            }
        }
        return nil
    }

    /// Whether the URL is a file type we will ask QuickLook to thumbnail.
    /// Callers can short-circuit by checking this before invoking `thumbnail`.
    func isThumbnailable(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif",
             "pdf",
             "mov", "mp4", "m4v", "avi", "mkv",
             "psd", "raw", "cr2", "nef", "arw":
            return true
        default:
            return false
        }
    }
}
