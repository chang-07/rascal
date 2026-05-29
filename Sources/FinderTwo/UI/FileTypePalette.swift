import AppKit

/// Maps files to a coarse type category and a distinct, demo-friendly color.
/// Used by the treemap (and available for any future "color by type" view).
enum FileTypePalette {

    enum Category: String, CaseIterable {
        case folder, image, video, audio, code, document, archive, app, data, other

        var label: String {
            switch self {
            case .folder:   return "Folders"
            case .image:    return "Images"
            case .video:    return "Video"
            case .audio:    return "Audio"
            case .code:     return "Code"
            case .document: return "Documents"
            case .archive:  return "Archives"
            case .app:      return "Apps"
            case .data:     return "Data"
            case .other:    return "Other"
            }
        }

        /// Base color — tiles are drawn as a soft vertical gradient around this.
        var color: NSColor {
            switch self {
            case .folder:   return NSColor(srgbRed: 0.42, green: 0.48, blue: 0.62, alpha: 1)
            case .image:    return NSColor(srgbRed: 0.91, green: 0.64, blue: 0.24, alpha: 1)
            case .video:    return NSColor(srgbRed: 0.88, green: 0.33, blue: 0.43, alpha: 1)
            case .audio:    return NSColor(srgbRed: 0.61, green: 0.36, blue: 0.90, alpha: 1)
            case .code:     return NSColor(srgbRed: 0.31, green: 0.66, blue: 0.87, alpha: 1)
            case .document: return NSColor(srgbRed: 0.34, green: 0.76, blue: 0.44, alpha: 1)
            case .archive:  return NSColor(srgbRed: 0.79, green: 0.54, blue: 0.37, alpha: 1)
            case .app:      return NSColor(srgbRed: 0.33, green: 0.78, blue: 0.76, alpha: 1)
            case .data:     return NSColor(srgbRed: 0.55, green: 0.60, blue: 0.68, alpha: 1)
            case .other:    return NSColor(srgbRed: 0.48, green: 0.51, blue: 0.57, alpha: 1)
            }
        }
    }

    private static let map: [String: Category] = {
        var m: [String: Category] = [:]
        func add(_ cat: Category, _ exts: String) { exts.split(separator: " ").forEach { m[String($0)] = cat } }
        add(.image,    "jpg jpeg png gif heic heif webp tiff tif bmp svg ico raw cr2 nef arw dng psd")
        add(.video,    "mp4 mov m4v avi mkv webm flv wmv mpg mpeg ts 3gp")
        add(.audio,    "mp3 aac flac wav aiff aif m4a ogg opus wma")
        add(.code,     "swift c h cpp cc cxx hpp m mm js mjs ts jsx tsx py rb go rs java kt kts php html htm css scss sass less json yaml yml xml sh bash zsh toml sql lua pl r dart")
        add(.document, "pdf doc docx xls xlsx ppt pptx pages numbers key txt md markdown rtf epub csv tex")
        add(.archive,  "zip tar gz tgz bz2 xz 7z rar dmg pkg jar war cab")
        add(.app,      "app")
        add(.data,     "db sqlite sqlite3 dat bin iso img log cache idx pack")
        return m
    }()

    static func category(for node: DiskScan.Node) -> Category {
        if node.isDirectory { return node.url.pathExtension.lowercased() == "app" ? .app : .folder }
        let ext = node.url.pathExtension.lowercased()
        return map[ext] ?? .other
    }

    static func color(for node: DiskScan.Node) -> NSColor { category(for: node).color }
}
