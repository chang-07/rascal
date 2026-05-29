import Foundation

/// Lightweight git porcelain reader. Shells out to the system `git` so there's
/// no dependency and it respects the user's git config. Everything here is
/// synchronous and meant to be called from a background queue.
enum GitStatus {

    /// Per-file working-tree state, mapped to a display glyph + color intent.
    enum FileState: Equatable {
        case modified       // tracked file changed (index or worktree)
        case added          // newly staged
        case untracked      // ?? not tracked
        case deleted        // removed
        case renamed        // R
        case conflicted     // U / merge conflict
        case ignored        // matched by .gitignore (only surfaced on request)
        case modifiedFolder // a directory that contains changes somewhere inside

        var letter: String {
            switch self {
            case .modified: return "M"
            case .added: return "A"
            case .untracked: return "U"
            case .deleted: return "D"
            case .renamed: return "R"
            case .conflicted: return "!"
            case .ignored: return "·"
            case .modifiedFolder: return "M"
            }
        }
    }

    struct RepoInfo: Equatable {
        let root: URL
        let branch: String?
        let ahead: Int
        let behind: Int
        /// Compact label like "main ↑2↓1" (omits arrows when zero).
        var label: String {
            var s = branch ?? "detached"
            if ahead > 0 { s += " ↑\(ahead)" }
            if behind > 0 { s += " ↓\(behind)" }
            return s
        }
    }

    private static let gitPath: String? = {
        for p in ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }()

    /// Walk up from `url` to find the enclosing git work tree (the dir holding
    /// `.git`). Returns nil if not inside a repo.
    static func repoRoot(for url: URL) -> URL? {
        var dir = url.standardizedFileURL
        // If url is a file, start from its parent.
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), !isDir.boolValue {
            dir = dir.deletingLastPathComponent()
        }
        while dir.pathComponents.count > 1 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Branch + ahead/behind for a repo, parsed from `git status -b --porcelain`.
    static func repoInfo(root: URL) -> RepoInfo {
        guard let header = run(["-C", root.path, "status", "-b", "--porcelain=v1"], in: root)?
            .split(separator: "\n").first.map(String.init) else {
            return RepoInfo(root: root, branch: nil, ahead: 0, behind: 0)
        }
        // Header looks like: "## main...origin/main [ahead 2, behind 1]"
        // or "## main" (no upstream) or "## HEAD (no branch)".
        var branch: String? = nil
        var ahead = 0, behind = 0
        if header.hasPrefix("## ") {
            var body = String(header.dropFirst(3))
            // Fresh repo with no commits: "## No commits yet on main".
            if let r = body.range(of: "No commits yet on ") {
                body = String(body[r.upperBound...])
            }
            let beforeBracket = body.split(separator: "[", maxSplits: 1).first.map(String.init) ?? body
            // branch portion is before "..."
            branch = beforeBracket.components(separatedBy: "...").first?
                .trimmingCharacters(in: .whitespaces)
            if branch == "HEAD (no branch)" || branch == "HEAD" || branch?.isEmpty == true { branch = nil }
            if let bracket = body.firstIndex(of: "[") {
                let tracking = body[bracket...]
                ahead = firstInt(after: "ahead ", in: String(tracking)) ?? 0
                behind = firstInt(after: "behind ", in: String(tracking)) ?? 0
            }
        }
        return RepoInfo(root: root, branch: branch, ahead: ahead, behind: behind)
    }

    /// Map every entry name in `dir` to its git state. Files report their own
    /// state; a subfolder of `dir` that contains any change reports
    /// `.modifiedFolder`. Names not present in the map are clean/tracked.
    static func fileStates(in dir: URL, repoRoot root: URL) -> [String: FileState] {
        // Path of `dir` relative to the repo root, with trailing slash.
        let rootPath = standardize(root.path)
        let dirPath = standardize(dir.path)
        guard dirPath == rootPath || dirPath.hasPrefix(rootPath + "/") else { return [:] }
        let rel = dirPath == rootPath ? "" : String(dirPath.dropFirst(rootPath.count + 1)) + "/"

        // Scope the scan to the viewed subdirectory via a pathspec so status
        // cost tracks the folder size, not the whole (possibly huge) repo. git
        // still reports paths relative to the repo root, so the prefix-strip and
        // folder-aggregation below are unaffected.
        var args = ["-C", root.path, "status", "--porcelain=v1", "-z", "--untracked-files=normal"]
        if !rel.isEmpty {
            args.append("--")
            args.append(String(rel.dropLast()))   // drop the trailing slash for the pathspec
        }
        guard let out = run(args, in: root) else { return [:] }

        var result: [String: FileState] = [:]
        // Records are NUL-separated. A rename record is "R  old\0new\0" — git
        // emits the new path then the old path as two NUL fields; we only need
        // the new path's first path token per record. Simplify: split on NUL and
        // parse "XY <path>" tokens, skipping bare path continuations.
        let records = out.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var i = 0
        while i < records.count {
            let rec = records[i]
            i += 1
            guard rec.count >= 4 else { continue }
            let x = rec[rec.startIndex]
            let y = rec[rec.index(rec.startIndex, offsetBy: 1)]
            let path = String(rec.dropFirst(3))
            // Rename/copy records carry a following NUL field (the original path).
            if x == "R" || x == "C" { i += 1 }
            guard path.hasPrefix(rel) || rel.isEmpty else { continue }
            let relInDir = rel.isEmpty ? path : String(path.dropFirst(rel.count))
            guard !relInDir.isEmpty else { continue }
            if let slash = relInDir.firstIndex(of: "/") {
                // Change lives inside a subfolder of `dir` → mark the folder.
                let folder = String(relInDir[..<slash])
                if result[folder] == nil { result[folder] = .modifiedFolder }
            } else {
                result[relInDir] = state(x: x, y: y)
            }
        }
        return result
    }

    private static func state(x: Character, y: Character) -> FileState {
        if x == "?" && y == "?" { return .untracked }
        if x == "U" || y == "U" || (x == "D" && y == "D") || (x == "A" && y == "A") { return .conflicted }
        if x == "R" { return .renamed }
        if x == "A" { return .added }
        if x == "D" || y == "D" { return .deleted }
        return .modified
    }

    // MARK: - helpers

    private static func standardize(_ path: String) -> String {
        (path as NSString).resolvingSymlinksInPath
    }

    private static func firstInt(after token: String, in s: String) -> Int? {
        guard let r = s.range(of: token) else { return nil }
        let tail = s[r.upperBound...]
        let digits = tail.prefix { $0.isNumber }
        return Int(digits)
    }

    private static func run(_ args: [String], in dir: URL) -> String? {
        guard let git = gitPath else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = args
        p.currentDirectoryURL = dir
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice  // unused; nullDevice avoids a full-pipe deadlock
        // Avoid hangs: git status shouldn't prompt, but be safe.
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        p.environment = env
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
