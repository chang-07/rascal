import Foundation

/// Compare two folder trees and produce a unified diff: files only in src,
/// files only in dst, files in both that differ (by size + mtime), files
/// in both that are identical.
enum FolderSync {

    enum Status {
        case onlySource
        case onlyDestination
        case differs
        case identical
    }

    struct Entry {
        let relPath: String
        let status: Status
        let srcSize: Int64
        let dstSize: Int64
    }

    /// Walk both roots and produce the per-relative-path diff.
    static func compare(source: URL, destination: URL) -> [Entry] {
        let src = listTree(source)
        let dst = listTree(destination)
        var keys = Set(src.keys); keys.formUnion(dst.keys)
        var result: [Entry] = []
        result.reserveCapacity(keys.count)
        for key in keys.sorted() {
            let s = src[key]
            let d = dst[key]
            switch (s, d) {
            case (.some(let sm), nil):
                result.append(Entry(relPath: key, status: .onlySource,
                                    srcSize: sm.size, dstSize: 0))
            case (nil, .some(let dm)):
                result.append(Entry(relPath: key, status: .onlyDestination,
                                    srcSize: 0, dstSize: dm.size))
            case let (.some(sm), .some(dm)):
                if sm.size == dm.size && abs(sm.mtime.timeIntervalSince(dm.mtime)) < 2 {
                    result.append(Entry(relPath: key, status: .identical,
                                        srcSize: sm.size, dstSize: dm.size))
                } else {
                    result.append(Entry(relPath: key, status: .differs,
                                        srcSize: sm.size, dstSize: dm.size))
                }
            case (nil, nil):
                break
            }
        }
        return result
    }

    private struct Meta {
        let size: Int64
        let mtime: Date
    }

    private static func listTree(_ root: URL) -> [String: Meta] {
        var out: [String: Meta] = [:]
        // /var/.../ resolves to /private/var/.../ during enumeration. Resolve
        // the root once and standardize so the prefix-strip step works.
        let standardized = (root.path as NSString).resolvingSymlinksInPath
        let rootPath = standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
        guard let en = FileManager.default.enumerator(at: URL(fileURLWithPath: rootPath),
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return out }
        while let next = en.nextObject() as? URL {
            guard let v = try? next.resourceValues(forKeys:
                [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                v.isRegularFile == true else { continue }
            let abs = (next.path as NSString).resolvingSymlinksInPath
            guard abs.hasPrefix(rootPath) else { continue }
            let rel = String(abs.dropFirst(rootPath.count + 1))
            out[rel] = Meta(size: Int64(v.fileSize ?? 0),
                            mtime: v.contentModificationDate ?? .distantPast)
        }
        return out
    }

    /// Apply a 1-way sync: every entry that is `onlySource` or `differs`
    /// gets copied from source to destination (overwriting existing).
    /// `onlyDestination` entries are LEFT IN PLACE — call `prune` if you
    /// want to mirror.
    @discardableResult
    static func mirrorSourceToDestination(_ entries: [Entry],
                                          source: URL,
                                          destination: URL,
                                          prune: Bool) -> Int {
        let fm = FileManager.default
        var ops = 0
        for e in entries {
            let from = source.appendingPathComponent(e.relPath)
            let to   = destination.appendingPathComponent(e.relPath)
            switch e.status {
            case .onlySource, .differs:
                try? fm.createDirectory(at: to.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                if fm.fileExists(atPath: to.path) { try? fm.removeItem(at: to) }
                if (try? fm.copyItem(at: from, to: to)) != nil { ops += 1 }
            case .onlyDestination:
                if prune {
                    if (try? fm.trashItem(at: to, resultingItemURL: nil)) != nil { ops += 1 }
                }
            case .identical: break
            }
        }
        return ops
    }
}
