import AppKit
import UniformTypeIdentifiers

struct FileItem: Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let isHidden: Bool
    let size: Int64        // for directories: -1 unless explicitly calculated
    let modified: Date
    let created: Date
    let ext: String        // lowercased, without dot
    let contentType: UTType?
    let kindDescription: String

    /// True for app/bundle "packages" — directories the Finder treats as a
    /// single opaque item (double-click launches; "Show Package Contents"
    /// browses inside). Computed so the memberwise init is unchanged.
    var isPackage: Bool {
        guard isDirectory else { return false }
        if let t = contentType,
           t.conforms(to: .package) || t.conforms(to: .bundle) || t.conforms(to: .application) {
            return true
        }
        return (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }

    static func load(_ url: URL) -> FileItem? {
        let keys: Set<URLResourceKey> = [
            .nameKey, .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey,
            .fileSizeKey, .totalFileAllocatedSizeKey,
            .contentModificationDateKey, .creationDateKey,
            .contentTypeKey, .localizedTypeDescriptionKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let name = values.name ?? url.lastPathComponent
        let isDir = values.isDirectory ?? false
        let isSym = values.isSymbolicLink ?? false
        let isHidden = (values.isHidden ?? false) || name.hasPrefix(".")
        let size = Int64(values.fileSize ?? values.totalFileAllocatedSize ?? 0)
        let modified = values.contentModificationDate ?? Date.distantPast
        let created = values.creationDate ?? modified
        let ext = url.pathExtension.lowercased()
        let type = values.contentType
        let kind = values.localizedTypeDescription
            ?? (isDir ? "Folder" : (ext.isEmpty ? "File" : ext.uppercased() + " file"))
        return FileItem(
            url: url,
            name: name,
            isDirectory: isDir,
            isSymlink: isSym,
            isHidden: isHidden,
            size: isDir ? -1 : size,
            modified: modified,
            created: created,
            ext: ext,
            contentType: type,
            kindDescription: kind
        )
    }
}

enum SortKey: String, CaseIterable {
    case name, dateModified, dateCreated, size, kind
}

struct SortDescriptor: Equatable {
    var key: SortKey = .name
    var ascending: Bool = true
    var foldersFirst: Bool = true

    func compare(_ a: FileItem, _ b: FileItem) -> Bool {
        if Settings.foldersFirst && a.isDirectory != b.isDirectory {
            return a.isDirectory && !b.isDirectory
        }
        let order: ComparisonResult
        switch key {
        case .name:
            order = a.name.localizedStandardCompare(b.name)
        case .dateModified:
            order = a.modified < b.modified ? .orderedAscending : (a.modified > b.modified ? .orderedDescending : .orderedSame)
        case .dateCreated:
            order = a.created < b.created ? .orderedAscending : (a.created > b.created ? .orderedDescending : .orderedSame)
        case .size:
            order = a.size < b.size ? .orderedAscending : (a.size > b.size ? .orderedDescending : .orderedSame)
        case .kind:
            order = a.kindDescription.localizedStandardCompare(b.kindDescription)
        }
        if order == .orderedSame {
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return ascending ? (order == .orderedAscending) : (order == .orderedDescending)
    }
}

enum SizeFormatter {
    private static let bcf: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB, .useBytes]
        f.countStyle = .file
        return f
    }()
    static func string(_ size: Int64) -> String {
        if size < 0 { return "—" }
        return bcf.string(fromByteCount: size)
    }
}

enum DateFormatterCache {
    static let medium: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
    static func string(_ date: Date) -> String {
        if date <= Date.distantPast.addingTimeInterval(1) { return "—" }
        return medium.string(from: date)
    }
}
