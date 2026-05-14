import Foundation
import Darwin

/// Fast directory enumeration that bypasses Foundation's `contentsOfDirectory`
/// + per-URL `resourceValues` overhead. We use `opendir`/`readdir` to list
/// names and `lstat` to fetch metadata in one syscall per entry. On a 25k-file
/// directory this typically halves cold-load time compared to `FileManager`.
///
/// Only the fields we render in the file list (name, isDir, isSymlink, size,
/// mtime, ctime) are computed; richer metadata (UTType, localizedTypeDescription)
/// is filled in lazily by FileItem.load when a row scrolls into view.
enum FastDirScan {

    struct Entry {
        let url: URL
        let name: String
        let isDirectory: Bool
        let isSymlink: Bool
        let isHidden: Bool
        let size: Int64
        let modified: Date
        let created: Date
        let ext: String
    }

    /// List `dir` quickly. Returns name + lstat metadata for every entry that
    /// `readdir` reports (including hidden — filtering happens in DirectoryModel).
    static func list(_ dir: URL) -> [Entry] {
        var out: [Entry] = []
        out.reserveCapacity(256)

        let path = dir.path
        guard let d = opendir(path) else { return out }
        defer { closedir(d) }

        let parentPath = path.hasSuffix("/") ? path : path + "/"
        while let entryPtr = readdir(d) {
            let entry = entryPtr.pointee
            // Skip "." and ".."
            var name = withUnsafeBytes(of: entry.d_name) { rawPtr -> String in
                let buf = rawPtr.bindMemory(to: CChar.self)
                return String(cString: buf.baseAddress!)
            }
            if name == "." || name == ".." { continue }

            // Build path C-string for lstat
            let fullPath = parentPath + name
            var st = stat()
            if lstat(fullPath, &st) != 0 { continue }

            let isSymlink = (st.st_mode & S_IFMT) == S_IFLNK
            let isDir: Bool
            if isSymlink {
                // Resolve symlinks once so directory icons follow Finder behavior.
                var stTarget = stat()
                if stat(fullPath, &stTarget) == 0 {
                    isDir = (stTarget.st_mode & S_IFMT) == S_IFDIR
                } else {
                    isDir = false
                }
            } else {
                isDir = (st.st_mode & S_IFMT) == S_IFDIR
            }
            let mtime = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec)
                                + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000)
            let ctime = Date(timeIntervalSince1970: Double(st.st_birthtimespec.tv_sec)
                                + Double(st.st_birthtimespec.tv_nsec) / 1_000_000_000)
            let size = isDir ? Int64(-1) : Int64(st.st_size)
            let isHidden = name.hasPrefix(".")
            let dot = name.lastIndex(of: ".")
            let ext = (dot != nil && dot != name.startIndex)
                ? String(name[name.index(after: dot!)...]).lowercased()
                : ""

            // Strip a take-it-while strategy: name keeps its original encoding
            // even when filesystem returns precomposed unicode (HFS+/APFS varies).
            // Compatibility-decompose only when needed (very cheap for ASCII names).
            name = (name as NSString).precomposedStringWithCanonicalMapping

            let url = URL(fileURLWithPath: fullPath, isDirectory: isDir)
            out.append(Entry(
                url: url, name: name,
                isDirectory: isDir, isSymlink: isSymlink, isHidden: isHidden,
                size: size, modified: mtime, created: ctime, ext: ext
            ))
        }
        return out
    }

    /// Wrap a fast-scan Entry as a FileItem with a placeholder kind label that
    /// is good enough for the list view header column. Real UTType-based kind
    /// is filled in on demand by `FileItem.load` when needed.
    static func toFileItem(_ e: Entry) -> FileItem {
        let kind: String
        if e.isDirectory { kind = "Folder" }
        else if e.isSymlink { kind = "Alias" }
        else if e.ext.isEmpty { kind = "File" }
        else { kind = e.ext.uppercased() + " file" }
        return FileItem(
            url: e.url,
            name: e.name,
            isDirectory: e.isDirectory,
            isSymlink: e.isSymlink,
            isHidden: e.isHidden,
            size: e.size,
            modified: e.modified,
            created: e.created,
            ext: e.ext,
            contentType: nil,
            kindDescription: kind
        )
    }
}
