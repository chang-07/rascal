import AppKit
import Darwin

/// Reads and writes the same Finder-compatible tag xattr that macOS uses:
///   xattr name:    com.apple.metadata:_kMDItemUserTags
///   format:        binary plist of [String]   (each string is "tagname" or "tagname\n<colorNumber>")
///
/// Tags written here are picked up by Finder, Spotlight, and any other tool
/// that reads _kMDItemUserTags.
enum Tags {
    static let xattrName = "com.apple.metadata:_kMDItemUserTags"

    enum Color: Int, CaseIterable {
        case none = 0, gray = 1, green = 2, purple = 3, blue = 4, yellow = 5, red = 6, orange = 7
        var label: String {
            switch self {
            case .none: return "none"
            case .gray: return "Gray"
            case .green: return "Green"
            case .purple: return "Purple"
            case .blue: return "Blue"
            case .yellow: return "Yellow"
            case .red: return "Red"
            case .orange: return "Orange"
            }
        }
        var nsColor: NSColor {
            switch self {
            case .none: return .clear
            case .gray: return .systemGray
            case .green: return .systemGreen
            case .purple: return .systemPurple
            case .blue: return .systemBlue
            case .yellow: return .systemYellow
            case .red: return .systemRed
            case .orange: return .systemOrange
            }
        }
    }

    struct Tag: Equatable, Hashable {
        let name: String
        let color: Color
        var encoded: String {
            color == .none ? name : "\(name)\n\(color.rawValue)"
        }
        static func decode(_ s: String) -> Tag {
            let parts = s.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, let n = Int(parts[1]) {
                return Tag(name: String(parts[0]), color: Color(rawValue: n) ?? .none)
            }
            return Tag(name: String(parts[0]), color: .none)
        }
    }

    static func read(_ url: URL) -> [Tag] {
        guard let data = readXAttr(at: url, name: xattrName) else { return [] }
        guard let strings = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else {
            return []
        }
        return strings.map(Tag.decode)
    }

    static func write(_ tags: [Tag], to url: URL) {
        if tags.isEmpty {
            removeXAttr(at: url, name: xattrName)
            return
        }
        let strings = tags.map { $0.encoded }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: strings,
                                                              format: .binary,
                                                              options: 0) else { return }
        writeXAttr(at: url, name: xattrName, data: data)
    }

    static func addTag(_ tag: Tag, to url: URL) {
        var existing = read(url)
        if !existing.contains(where: { $0.name == tag.name }) {
            existing.append(tag)
            write(existing, to: url)
        }
    }

    static func removeTag(named name: String, from url: URL) {
        let updated = read(url).filter { $0.name != name }
        write(updated, to: url)
    }

    // MARK: xattr primitives

    private static func readXAttr(at url: URL, name: String) -> Data? {
        let path = url.path
        let len = getxattr(path, name, nil, 0, 0, 0)
        if len <= 0 { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        let read = getxattr(path, name, &buf, len, 0, 0)
        if read != len { return nil }
        return Data(buf)
    }

    private static func writeXAttr(at url: URL, name: String, data: Data) {
        let path = url.path
        _ = data.withUnsafeBytes { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return -1 }
            return setxattr(path, name, base, data.count, 0, 0)
        }
    }

    private static func removeXAttr(at url: URL, name: String) {
        _ = removexattr(url.path, name, 0)
    }
}
