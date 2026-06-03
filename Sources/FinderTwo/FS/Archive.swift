import Foundation

/// Read-only browsing of common archive formats (`.zip`, `.tar`, `.tar.gz`,
/// `.tgz`, `.tar.bz2`, `.tbz2`). Listing is done by shelling to `unzip -l`
/// or `tar -t`; extraction uses `unzip` / `tar -x`. We deliberately use the
/// system tools rather than libarchive to ship with zero new dependencies.
enum Archive {

    struct Entry: Hashable {
        let path: String          // e.g. "subdir/file.txt"
        let isDirectory: Bool
        let size: Int64           // -1 for directories
        let modified: Date?
    }

    enum Kind {
        case zip, tar, tarGz, tarBz2
        static func detect(_ url: URL) -> Kind? {
            let p = url.path.lowercased()
            if p.hasSuffix(".zip")      { return .zip }
            if p.hasSuffix(".tar")      { return .tar }
            if p.hasSuffix(".tar.gz")   { return .tarGz }
            if p.hasSuffix(".tgz")      { return .tarGz }
            if p.hasSuffix(".tar.bz2")  { return .tarBz2 }
            if p.hasSuffix(".tbz2")     { return .tarBz2 }
            return nil
        }
        /// List flags WITHOUT the `f` (the filename flag must come last so its
        /// argument is the archive path, not the trailing `v`).
        var tarFlags: String {
            switch self {
            case .tar: return "t"
            case .tarGz: return "tz"
            case .tarBz2: return "tj"
            case .zip: return ""
            }
        }
    }

    /// Detects whether a URL is a browsable archive.
    static func isArchive(_ url: URL) -> Bool { Kind.detect(url) != nil }

    /// Lists all entries in an archive. Cached per-URL for the lifetime of
    /// the process — re-list if the user explicitly reloads.
    static func list(_ url: URL) -> [Entry] {
        if let cached = cache.object(forKey: url as NSURL) { return cached.entries }
        guard let kind = Kind.detect(url) else { return [] }
        let entries: [Entry]
        switch kind {
        case .zip:
            entries = listZip(url)
        case .tar, .tarGz, .tarBz2:
            entries = listTar(url, flags: kind.tarFlags)
        }
        cache.setObject(EntryList(entries), forKey: url as NSURL)
        return entries
    }

    /// Returns entries whose path is an immediate child of `prefix` within
    /// the archive. Use prefix = "" for the archive root.
    static func children(of archive: URL, prefix: String) -> [Entry] {
        let all = list(archive)
        let pfx = prefix.isEmpty ? "" : (prefix.hasSuffix("/") ? prefix : prefix + "/")
        var seen = Set<String>()
        var result: [Entry] = []
        for e in all {
            guard e.path.hasPrefix(pfx) else { continue }
            let rest = String(e.path.dropFirst(pfx.count))
            if rest.isEmpty { continue }
            if let slash = rest.firstIndex(of: "/") {
                let head = String(rest[..<slash])
                if seen.insert(head).inserted {
                    let childPath = pfx + head
                    result.append(Entry(path: childPath, isDirectory: true,
                                        size: -1, modified: e.modified))
                }
            } else if seen.insert(rest).inserted {
                result.append(e)
            }
        }
        return result
    }

    /// Extract a single entry to `destination`. Returns the resulting URL,
    /// or nil on failure.
    @discardableResult
    static func extract(_ entry: Entry, from archive: URL, to destination: URL) -> URL? {
        guard let kind = Kind.detect(archive) else { return nil }
        let fm = FileManager.default
        var outFile = destination.appendingPathComponent((entry.path as NSString).lastPathComponent)
        // Don't clobber a same-basename sibling already extracted from this archive.
        if fm.fileExists(atPath: outFile.path) { outFile = uniquify(outFile, in: destination) }
        guard fm.createFile(atPath: outFile.path, contents: nil),
              let outHandle = try? FileHandle(forWritingTo: outFile) else { return nil }
        defer { try? outHandle.close() }

        let proc = Process()
        proc.standardOutput = outHandle      // stream straight to disk — no whole-file RAM buffer
        proc.standardError = FileHandle.nullDevice
        // The entry name is a literal path, but unzip/tar treat * ? [ ] in the
        // member argument as a glob — escape them so we extract exactly this entry
        // (an unescaped `a*b.txt` could match and concatenate sibling members).
        let pattern = escapeGlobPattern(entry.path)
        switch kind {
        case .zip:
            proc.launchPath = "/usr/bin/unzip"
            proc.arguments = ["-p", archive.path, pattern]
        case .tar, .tarGz, .tarBz2:
            proc.launchPath = "/usr/bin/tar"
            let flag: String
            switch kind {
            case .tarGz: flag = "-xzOf"
            case .tarBz2: flag = "-xjOf"
            default: flag = "-xOf"
            }
            proc.arguments = [flag, archive.path, pattern]
        }
        do { try proc.run() } catch { try? fm.removeItem(at: outFile); return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { try? fm.removeItem(at: outFile); return nil }
        return outFile
    }

    /// True if every entry stays within the destination when extracted — no
    /// absolute paths and no `..` traversal (guards against zip-slip, where a
    /// malicious archive writes outside the target dir).
    static func entriesAreSafe(_ archive: URL) -> Bool {
        for e in list(archive) {
            if e.path.hasPrefix("/") { return false }
            if e.path.split(separator: "/").contains("..") { return false }
        }
        return true
    }

    /// Extract the entire archive to a directory. Refuses archives whose
    /// entries would escape `destination` (zip-slip).
    @discardableResult
    static func extractAll(_ archive: URL, to destination: URL) -> Bool {
        guard let kind = Kind.detect(archive) else { return false }
        guard entriesAreSafe(archive) else { return false }
        let proc = Process()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        switch kind {
        case .zip:
            proc.launchPath = "/usr/bin/unzip"
            proc.arguments = ["-q", archive.path, "-d", destination.path]
        case .tar, .tarGz, .tarBz2:
            proc.launchPath = "/usr/bin/tar"
            let flag: String
            switch kind {
            case .tarGz: flag = "-xzf"
            case .tarBz2: flag = "-xjf"
            default: flag = "-xf"
            }
            proc.arguments = [flag, archive.path, "-C", destination.path]
        }
        do { try proc.run() } catch { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    /// Output formats for "Compress". Zip is Finder-compatible; Zip can be
    /// password-encrypted; tar.gz is the cross-platform UNIX default.
    enum CompressFormat: String, CaseIterable {
        case zip = "Zip"
        case tarGz = "Tar.gz"
        var ext: String { self == .zip ? "zip" : "tar.gz" }
        /// Encryption is only meaningful for zip.
        var supportsPassword: Bool { self == .zip }
    }

    /// Compress the given items (which must share a parent directory) into a new
    /// archive beside them. Returns the created archive URL, or nil on failure.
    /// Names like Finder: "<name>.<ext>" for one item, "Archive.<ext>" for many.
    /// A non-empty `password` (zip only) produces an encrypted zip.
    static func compress(_ items: [URL], format: CompressFormat = .zip, password: String? = nil) -> URL? {
        guard let first = items.first else { return nil }
        let parent = first.deletingLastPathComponent()
        let fm = FileManager.default
        let base = items.count == 1 ? first.deletingPathExtension().lastPathComponent : "Archive"
        var dest = parent.appendingPathComponent("\(base).\(format.ext)")
        var i = 2
        while fm.fileExists(atPath: dest.path) {
            dest = parent.appendingPathComponent("\(base) \(i).\(format.ext)"); i += 1
        }
        let names = items.map { $0.lastPathComponent }   // basenames safe: shared parent
        let p = Process()
        p.currentDirectoryURL = parent
        switch format {
        case .zip:
            p.launchPath = "/usr/bin/zip"
            var args = ["-r", "-q", "-X"]
            if let pw = password, !pw.isEmpty { args += ["-P", pw] }   // -P → encrypt
            p.arguments = args + [dest.path] + names
        case .tarGz:
            p.launchPath = "/usr/bin/tar"
            p.arguments = ["-czf", dest.path, "-C", parent.path] + names
        }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        return p.terminationStatus == 0 ? dest : nil
    }

    /// Extract an archive into a new sibling folder named after it (Finder-style).
    /// Returns the destination folder, or nil on failure / zip-slip refusal.
    static func extractInPlace(_ archive: URL) -> URL? {
        guard Kind.detect(archive) != nil else { return nil }
        let parent = archive.deletingLastPathComponent()
        let fm = FileManager.default
        var base = archive.lastPathComponent
        for ext in [".tar.gz", ".tar.bz2", ".tgz", ".tbz2", ".tar", ".zip"]
        where base.lowercased().hasSuffix(ext) { base = String(base.dropLast(ext.count)); break }
        var dest = parent.appendingPathComponent(base)
        var i = 2
        while fm.fileExists(atPath: dest.path) {
            dest = parent.appendingPathComponent("\(base) \(i)"); i += 1
        }
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        guard extractAll(archive, to: dest) else { try? fm.removeItem(at: dest); return nil }
        return dest
    }

    // MARK: - Tools

    /// Reference-type wrapper so NSCache (which requires class values) stores
    /// the struct array without lossy `as NSArray` bridging.
    private final class EntryList {
        let entries: [Entry]
        init(_ entries: [Entry]) { self.entries = entries }
    }
    private static let cache = NSCache<NSURL, EntryList>()

    private static func listZip(_ url: URL) -> [Entry] {
        // `unzip -l` outputs columns: Length, Date, Time, Name. Trailing slash
        // marks a directory entry.
        guard let raw = runForOutput("/usr/bin/unzip", ["-l", url.path]) else { return [] }
        var entries: [Entry] = []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd-yyyy HH:mm"
        for line in raw.split(separator: "\n") {
            let s = String(line)
            // Header/footer lines fail the `Int64(parts[0])` size parse below and
            // are rejected there — don't substring-match "files"/"Length"/"---",
            // which would wrongly drop real entries named e.g. "my files.txt".
            if s.isEmpty { continue }
            // Strip leading whitespace; first token = size
            let parts = s.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 4, let size = Int64(parts[0]) else { continue }
            let name = parts[3...].joined(separator: " ")
            let isDir = name.hasSuffix("/")
            let cleanName = isDir ? String(name.dropLast()) : name
            let date = formatter.date(from: "\(parts[1]) \(parts[2])")
            entries.append(Entry(path: cleanName, isDirectory: isDir,
                                 size: isDir ? -1 : size, modified: date))
        }
        return entries
    }

    private static func listTar(_ url: URL, flags: String) -> [Entry] {
        // `tar -tvf` gives a `ls -l`-like listing; we use simpler `-tf` for
        // names only and `-tvf` to grab sizes.
        // `f` must be the LAST flag so the next argv is the archive path.
        guard let raw = runForOutput("/usr/bin/tar", ["-" + flags + "vf", url.path]) else { return [] }
        var entries: [Entry] = []
        for line in raw.split(separator: "\n") {
            // Format: perms hard links owner group size MM DD time name
            // Example: -rw-r--r-- 0 chang staff 1234 Jan  1 12:00 path/to/file
            let s = String(line)
            if s.isEmpty { continue }
            // Limit to 8 splits so the name (field 9) keeps any internal spaces.
            let parts = s.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 9 else { continue }
            let perm = parts[0]
            let isDir = perm.hasPrefix("d") || s.hasSuffix("/")
            let size = Int64(parts[4]) ?? 0
            let name = parts[8]
            // Strip a trailing slash + a leading "./" (from `tar -c .`-style archives).
            var cleanName = name.hasSuffix("/") ? String(name.dropLast()) : name
            if cleanName.hasPrefix("./") { cleanName = String(cleanName.dropFirst(2)) }
            if cleanName.isEmpty || cleanName == "." { continue }
            entries.append(Entry(path: cleanName, isDirectory: isDir,
                                 size: isDir ? -1 : size, modified: nil))
        }
        return entries
    }

    /// Backslash-escape glob metacharacters so unzip/tar match a member name
    /// literally instead of treating * ? [ ] as wildcards.
    private static func escapeGlobPattern(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\*?[]".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// Return a non-existing URL by inserting " 2", " 3", … before the extension.
    private static func uniquify(_ url: URL, in dir: URL) -> URL {
        let fm = FileManager.default
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        var candidate = url
        while fm.fileExists(atPath: candidate.path) {
            let nm = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            candidate = dir.appendingPathComponent(nm); n += 1
        }
        return candidate
    }

    private static func runForOutput(_ tool: String, _ args: [String]) -> String? {
        let p = Process()
        p.launchPath = tool
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
