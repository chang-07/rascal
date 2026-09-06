import Foundation

/// Minimal SFTP client that shells out to the system `sftp` and `scp`
/// binaries. Authenticates via the user's existing SSH config and SSH agent
/// (we don't handle passwords ourselves — host-based, key-based, and
/// agent-based auth all "just work" because we're invoking the same client
/// the user already uses for ssh).
///
/// This is a deliberately small surface: list a directory, download a file,
/// upload a file. Full SFTP semantics (rename, chmod, etc.) are deferred.
enum SFTPClient {

    struct Connection: Hashable, Codable {
        let user: String
        let host: String
        let port: Int
        /// Optional starting directory; defaults to `~`.
        var remotePath: String

        var sshTarget: String { "\(user)@\(host)" }
        var displayName: String {
            "\(user)@\(host)\(port == 22 ? "" : ":\(port)"):\(remotePath.isEmpty ? "~" : remotePath)"
        }
    }

    struct Entry {
        let name: String
        let isDirectory: Bool
        let size: Int64
    }

    /// Build the `cd` line for a remote path — or none at all.
    ///
    /// SFTP has no shell, so `~` is NOT expanded: `cd "~"` fails outright with
    /// "No such file or directory", which silently produced an empty listing for
    /// the default connection (whose path is `~`). An sftp session already
    /// starts in the user's home directory, so:
    ///   - home (`~`, `~/`, `.`, empty) → no `cd` at all
    ///   - `~/sub`                      → `cd "sub"` (relative to the home start)
    ///   - anything else                → `cd "<path>"` as given
    private static func cdLine(for path: String) -> String {
        let p = path.trimmingCharacters(in: .whitespaces)
        if p.isEmpty || p == "~" || p == "~/" || p == "." { return "" }
        if p.hasPrefix("~/") { return "cd \(escape(String(p.dropFirst(2))))\n" }
        return "cd \(escape(p))\n"
    }

    /// List entries at `path` on the given connection. Uses `sftp -b -` and
    /// parses the `ls -l`-style output.
    static func list(_ conn: Connection, path: String) -> [Entry] {
        let batch = cdLine(for: path) + "ls -la\nbye\n"
        let raw = run(conn, stdin: batch) ?? ""
        return parseLs(raw)
    }

    /// Download a single file to a local destination.
    ///
    /// Transfers go through the same `sftp -b -` channel as listing, NOT `scp`.
    /// OpenSSH 9.0+ makes `scp` speak the SFTP protocol, where the remote path
    /// is no longer expanded by a remote shell — so the single-quoting we used
    /// to apply for injection safety became *literal characters in the
    /// filename* and every transfer failed with "No such file or directory".
    ///
    /// sftp's own command parser understands the double-quoted form, and no
    /// shell is involved anywhere in this path, so quoting here is both correct
    /// and injection-proof by construction. Do not reintroduce shell quoting.
    @discardableResult
    static func download(_ conn: Connection, remotePath: String, to local: URL) -> Bool {
        let batch = "get \(escape(remotePath)) \(escape(local.path))\nbye\n"
        guard let result = runDetailed(conn, stdin: batch), result.status == 0 else { return false }
        return FileManager.default.fileExists(atPath: local.path)
    }

    /// Upload a local file to a remote path. See `download` for why this uses
    /// the sftp channel rather than `scp`.
    @discardableResult
    static func upload(_ conn: Connection, local: URL, to remotePath: String) -> Bool {
        let batch = "put \(escape(local.path)) \(escape(remotePath))\nbye\n"
        guard let result = runDetailed(conn, stdin: batch) else { return false }
        return result.status == 0
    }

    // MARK: - Mutating operations
    //
    // All of these go through the sftp batch channel, so the remote path is a
    // protocol field rather than shell text — no injection surface.

    /// Create a remote directory.
    @discardableResult
    static func makeDirectory(_ conn: Connection, path: String) -> Bool {
        runOK(conn, "mkdir \(escape(path))")
    }

    /// Rename (or move) a remote entry.
    @discardableResult
    static func rename(_ conn: Connection, from: String, to: String) -> Bool {
        runOK(conn, "rename \(escape(from)) \(escape(to))")
    }

    /// Delete a remote file.
    @discardableResult
    static func removeFile(_ conn: Connection, path: String) -> Bool {
        runOK(conn, "rm \(escape(path))")
    }

    /// Delete a remote directory and its contents. sftp's `rmdir` only removes
    /// EMPTY directories, so walk depth-first. A failed listing yields no
    /// children, in which case the final `rmdir` fails on a non-empty directory
    /// rather than silently reporting success.
    @discardableResult
    static func removeDirectory(_ conn: Connection, path: String) -> Bool {
        for entry in list(conn, path: path) {
            let child = (path as NSString).appendingPathComponent(entry.name)
            let ok = entry.isDirectory ? removeDirectory(conn, path: child)
                                       : removeFile(conn, path: child)
            if !ok { return false }
        }
        return runOK(conn, "rmdir \(escape(path))")
    }

    /// Delete a remote entry. NOTE: this is permanent — servers have no Trash.
    @discardableResult
    static func remove(_ conn: Connection, path: String, isDirectory: Bool) -> Bool {
        isDirectory ? removeDirectory(conn, path: path) : removeFile(conn, path: path)
    }

    /// True when `path` already exists remotely (used to pick a free name).
    static func exists(_ conn: Connection, path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        return list(conn, path: parent.isEmpty ? "/" : parent).contains { $0.name == name }
    }

    /// Run a single sftp command, reporting whether it succeeded.
    private static func runOK(_ conn: Connection, _ command: String) -> Bool {
        guard let result = runDetailed(conn, stdin: command + "\nbye\n") else { return false }
        return result.status == 0
    }

    /// Quickly verify we can connect using existing creds. Returns nil on
    /// success, an error message otherwise.
    static func ping(_ conn: Connection) -> String? {
        let raw = run(conn, stdin: "pwd\nbye\n")
        if raw == nil || raw!.isEmpty { return "could not connect" }
        return nil
    }

    /// Resolve a (possibly `~`, empty, or relative) path to an absolute remote
    /// path, so every `sftp://` URL we build is canonical and navigation
    /// (append/deleteLastPathComponent) stays consistent. Returns nil if the
    /// connection fails.
    static func realpath(_ conn: Connection, path: String) -> String? {
        let batch = cdLine(for: path) + "pwd\nbye\n"
        guard let raw = run(conn, stdin: batch) else { return nil }
        // `sftp` prints: "Remote working directory: /home/user"
        for line in raw.split(separator: "\n") {
            if let r = line.range(of: "Remote working directory: ") {
                return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // MARK: - Internals

    private static func escape(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // NOTE: a `remoteQuote` helper used to single-quote paths for the remote
    // shell that legacy `scp` ran them through. Every transfer now goes over the
    // SFTP protocol, which has no remote shell — that quoting broke all
    // transfers and has been removed deliberately. Don't add it back.

    private static func run(_ conn: Connection, stdin: String) -> String? {
        runDetailed(conn, stdin: stdin)?.out
    }

    /// Run an sftp batch and return its stdout plus the exit status. `sftp -b`
    /// exits non-zero when any command in the batch fails, which is how the
    /// transfer helpers detect failure (stderr is discarded to avoid a
    /// full-pipe deadlock).
    private static func runDetailed(_ conn: Connection, stdin: String) -> (out: String, status: Int32)? {
        let p = Process()
        p.launchPath = "/usr/bin/sftp"
        var args = ["-b", "-", "-o", "BatchMode=yes", "-o", "ConnectTimeout=7"]
        if conn.port != 22 { args.append(contentsOf: ["-P", "\(conn.port)"]) }
        args.append(conn.sshTarget)
        p.arguments = args
        let inPipe = Pipe()
        let outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice  // unused; nullDevice avoids a full-pipe deadlock
        do { try p.run() } catch { return nil }
        if let data = stdin.data(using: .utf8) {
            inPipe.fileHandleForWriting.write(data)
        }
        try? inPipe.fileHandleForWriting.close()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
    }

    private static func parseLs(_ raw: String) -> [Entry] {
        var out: [Entry] = []
        for line in raw.split(separator: "\n") {
            let s = String(line)
            // Match the typical sftp `ls -la` output line:
            //   drwxr-xr-x   3 user  staff  4096 Jan  1 12:00 name
            //   -rw-r--r--   1 user  staff   123 Jan  1 12:00 file
            // 8 fields (perms links owner group size  Mon D time) then the name;
            // maxSplits keeps spaces in the name intact.
            let parts = s.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 9, parts[0].count >= 10 else { continue }   // >=10: allow trailing @/+ (xattr/ACL)
            let perm = parts[0]
            let isDir = perm.hasPrefix("d")
            let isLink = perm.hasPrefix("l")
            let size = Int64(parts[4]) ?? 0
            var name = parts[8]
            // A symlink line is "name -> target" — keep just the link's own name.
            if isLink, let r = name.range(of: " -> ") { name = String(name[..<r.lowerBound]) }
            if name == "." || name == ".." || name.isEmpty { continue }
            out.append(Entry(name: name, isDirectory: isDir,
                             size: isDir ? -1 : size))
        }
        return out
    }

    /// Test hook — exercises the `ls -la` parser without a live connection.
    static func testParseLs(_ raw: String) -> [Entry] { parseLs(raw) }

    /// Test hook — exercises remote-path → `cd` line translation.
    static func testCdLine(_ path: String) -> String { cdLine(for: path) }
}

/// Persistent store of saved SFTP connections, surfaced in the sidebar.
enum SFTPBookmarks {
    private static let key = "FinderTwo.sftp.v1"

    static func all() -> [SFTPClient.Connection] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let arr = try? JSONDecoder().decode([SFTPClient.Connection].self, from: data) else {
            return []
        }
        return arr
    }
    static func add(_ c: SFTPClient.Connection) {
        var arr = all().filter { $0.user != c.user || $0.host != c.host || $0.port != c.port }
        arr.append(c)
        if let data = try? JSONEncoder().encode(arr) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    static func remove(user: String, host: String, port: Int) {
        let arr = all().filter { $0.user != user || $0.host != host || $0.port != port }
        if let data = try? JSONEncoder().encode(arr) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
