import Foundation

/// Bridges an `sftp://user@host:port/path` URL — how a remote location travels
/// through the app's URL-based navigation (pane history, breadcrumb, tabs, the
/// sidebar) — and the `SFTPClient.Connection` + absolute remote path that the
/// client actually needs.
///
/// Keeping remote locations as ordinary URLs is what lets the whole UI stack
/// (DirectoryModel, FileList, sorting/filtering, tabs) treat a server exactly
/// like a local folder: navigating into a subfolder is just
/// `url.appendingPathComponent(name)`, and going up is `deletingLastPathComponent`.
enum SFTPLocation {
    static let scheme = "sftp"

    static func isRemote(_ url: URL) -> Bool { url.scheme == scheme }

    /// Canonical URL for a connection rooted at an absolute remote `path`.
    static func url(user: String, host: String, port: Int, path: String) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.user = user
        c.host = host
        c.port = (port == 22) ? nil : port
        c.path = path.hasPrefix("/") ? path : "/" + path
        // URLComponents percent-encodes the path; the fallback covers a host so
        // malformed it can't form a URL (empty host is rejected before we get here).
        return c.url ?? URL(string: "\(scheme)://\(host)")!
    }

    static func url(_ conn: SFTPClient.Connection, path: String) -> URL {
        url(user: conn.user, host: conn.host, port: conn.port, path: path)
    }

    /// Decode a URL back into a connection + absolute remote path. Returns nil
    /// for any non-sftp or hostless URL. The path is percent-decoded (so a
    /// filename with spaces round-trips), ready to hand to `SFTPClient`.
    static func parse(_ url: URL) -> (conn: SFTPClient.Connection, path: String)? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == scheme,
              let host = c.host, !host.isEmpty else { return nil }
        let user = (c.user.map { !$0.isEmpty } == true) ? c.user! : NSUserName()
        let port = c.port ?? 22
        let path = c.path.isEmpty ? "/" : c.path
        let conn = SFTPClient.Connection(user: user, host: host, port: port, remotePath: path)
        return (conn, path)
    }
}
