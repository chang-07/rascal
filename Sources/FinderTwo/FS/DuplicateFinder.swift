import Foundation

/// Finds byte-identical files under a folder tree. Two-pass: group by size
/// (cheap), then hash only the size-collision candidates (SHA-256) and group
/// by digest. Returns groups of 2+ identical files, each sorted by path.
enum DuplicateFinder {
    struct Group {
        let size: Int64
        let urls: [URL]
    }

    /// Synchronous scan (exposed for tests). `limitBytesPerFile` caps hashing
    /// cost — files larger are still grouped by exact size+full hash.
    static func find(in root: URL) -> [Group] {
        let fm = FileManager.default
        var bySize: [Int64: [URL]] = [:]
        guard let en = fm.enumerator(at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        while let u = en.nextObject() as? URL {
            guard let rv = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  rv.isRegularFile == true, let sz = rv.fileSize, sz > 0 else { continue }
            bySize[Int64(sz), default: []].append(u)
        }
        var groups: [Group] = []
        for (size, urls) in bySize where urls.count > 1 {
            var byHash: [String: [URL]] = [:]
            for u in urls {
                guard let h = Checksum.compute(u, kind: .sha256) else { continue }
                byHash[h, default: []].append(u)
            }
            for (_, dups) in byHash where dups.count > 1 {
                groups.append(Group(size: size, urls: dups.sorted { $0.path < $1.path }))
            }
        }
        return groups.sorted { ($0.urls.first?.path ?? "") < ($1.urls.first?.path ?? "") }
    }

    /// Run off the main thread, deliver groups on main.
    static func find(in root: URL, completion: @escaping ([Group]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let g = find(in: root)
            DispatchQueue.main.async { completion(g) }
        }
    }
}
