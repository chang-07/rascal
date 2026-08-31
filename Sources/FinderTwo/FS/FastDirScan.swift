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
        let size: Int64          // logical size (st_size) — what the file list shows
        let modified: Date
        let created: Date
        let ext: String
        // Disk-usage fields (used by DiskScan, ignored by the file list):
        let physicalSize: Int64  // allocated bytes (st_blocks * 512) — the real footprint
        let inode: UInt64        // for de-duplicating hard links
        let device: Int32        // (device, inode) uniquely identifies a file
        let linkCount: Int       // st_nlink; > 1 means a hard-linked file
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
        // Raw bytes of the parent path (no trailing NUL), so each child's lstat path
        // can be assembled from bytes rather than a lossy String round-trip.
        let parentBytes: [CChar] = parentPath.withCString { p in
            Array(UnsafeBufferPointer(start: p, count: strlen(p)))
        }
        while let entryPtr = readdir(d) {
            let entry = entryPtr.pointee

            // Assemble "<parent><name>" as a NUL-terminated C path straight from the
            // raw d_name bytes. Do NOT decode the name to a String and rebuild the
            // path from it: String(cString:) substitutes U+FFFD for any byte that
            // isn't valid UTF-8, so the path would point at a file that doesn't exist,
            // lstat would fail, and the entry would silently vanish from the listing
            // (names copied from Linux, legacy encodings, some network volumes) — the
            // "some folders don't show all the files" bug.
            var pathBytes = parentBytes
            var isDotEntry = false
            let displayName: String = withUnsafeBytes(of: entry.d_name) { rawPtr -> String in
                let base = rawPtr.bindMemory(to: CChar.self).baseAddress!
                let len = strlen(base)
                if (len == 1 && base[0] == 0x2E) ||
                   (len == 2 && base[0] == 0x2E && base[1] == 0x2E) {
                    isDotEntry = true
                    return ""
                }
                pathBytes.append(contentsOf: UnsafeBufferPointer(start: base, count: len))
                return String(cString: base)   // display only; may contain U+FFFD
            }
            if isDotEntry { continue }          // "." / ".."
            pathBytes.append(0)                 // NUL-terminate for the C calls

            // Fetch metadata — but do NOT drop the entry if lstat fails. readdir
            // already reported the file exists; a failed lstat (a directory that's
            // readable but not searchable — mode r-- with no x — or an item racing
            // deletion) used to `continue` and silently hide the file, which is the
            // real local "some folders don't show all the files" bug. Keep the row
            // and fall back to readdir's d_type for the icon.
            var st = stat()
            let haveStat = lstat(pathBytes, &st) == 0

            let isSymlink: Bool
            let isDir: Bool
            if haveStat {
                isSymlink = (st.st_mode & S_IFMT) == S_IFLNK
                if isSymlink {
                    // Resolve symlinks once so directory icons follow Finder behavior.
                    var stTarget = stat()
                    isDir = (stat(pathBytes, &stTarget) == 0)
                        && (stTarget.st_mode & S_IFMT) == S_IFDIR
                } else {
                    isDir = (st.st_mode & S_IFMT) == S_IFDIR
                }
            } else {
                // No stat available — use the directory entry's own type, which
                // readdir provides without a stat. DT_UNKNOWN falls through to file.
                isSymlink = Int32(entry.d_type) == DT_LNK
                isDir = Int32(entry.d_type) == DT_DIR
            }
            let mtime = haveStat
                ? Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec)
                        + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000)
                : Date(timeIntervalSince1970: 0)
            let ctime = haveStat
                ? Date(timeIntervalSince1970: Double(st.st_birthtimespec.tv_sec)
                        + Double(st.st_birthtimespec.tv_nsec) / 1_000_000_000)
                : Date(timeIntervalSince1970: 0)
            let size = isDir ? Int64(-1) : (haveStat ? Int64(st.st_size) : 0)
            // st_blocks is in fixed 512-byte units (POSIX) — the actual on-disk
            // footprint (what `du` / Disk Utility "used" report). For symlinks this
            // is the link's own (tiny) allocation, not the target's.
            let physicalSize = haveStat ? Int64(st.st_blocks) * 512 : 0
            // Display name keeps its original encoding, precomposed for HFS+/APFS
            // consistency (cheap for ASCII names).
            let name = (displayName as NSString).precomposedStringWithCanonicalMapping
            let isHidden = name.hasPrefix(".")
            let dot = name.lastIndex(of: ".")
            let ext = (dot != nil && dot != name.startIndex)
                ? String(name[name.index(after: dot!)...]).lowercased()
                : ""

            // Build the URL from the file-system representation (the real bytes) so it
            // round-trips to the actual file even when the name isn't valid UTF-8.
            let url = pathBytes.withUnsafeBufferPointer { bp in
                URL(fileURLWithFileSystemRepresentation: bp.baseAddress!,
                    isDirectory: isDir, relativeTo: nil)
            }
            out.append(Entry(
                url: url, name: name,
                isDirectory: isDir, isSymlink: isSymlink, isHidden: isHidden,
                size: size, modified: mtime, created: ctime, ext: ext,
                physicalSize: physicalSize,
                inode: haveStat ? UInt64(st.st_ino) : 0,
                device: haveStat ? Int32(st.st_dev) : 0,
                linkCount: haveStat ? Int(st.st_nlink) : 1
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
