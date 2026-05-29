import Foundation
import AppKit
import NetFS

/// Mounts network volumes (SMB / FTP / AFP / NFS / WebDAV) via the NetFS
/// framework — the same machinery behind Finder's "Connect to Server" (⌘K),
/// no cloud account or entitlement required. SFTP is handled separately by the
/// in-app libssh2 browser.
enum NetMount {
    /// URL schemes we can mount as OS volumes.
    static let schemes: Set<String> = ["smb", "cifs", "afp", "ftp", "ftps", "nfs", "http", "https", "webdav"]

    /// True if `string` is a mountable server URL (known scheme + a host).
    static func isSupportedURL(_ string: String) -> Bool {
        guard let u = URL(string: string.trimmingCharacters(in: .whitespaces)),
              let scheme = u.scheme?.lowercased(),
              schemes.contains(scheme),
              let host = u.host, !host.isEmpty else { return false }
        return true
    }

    enum MountResult {
        case mounted(URL)      // NetFS returned a concrete mountpoint
        case systemHandoff     // fell back to the system connect dialog (async)
        case failure(String)
    }

    /// Mount off the main thread; deliver the result on main. When credentials
    /// are supplied, NetFS mounts directly and we learn the mountpoint. On any
    /// failure we hand off to NSWorkspace.open, which shows the standard system
    /// authentication dialog and mounts (the volume then appears under
    /// /Volumes and in the sidebar's Locations).
    static func mount(_ string: String, user: String?, password: String?,
                      completion: @escaping (MountResult) -> Void) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard isSupportedURL(trimmed), let url = URL(string: trimmed) else {
            completion(.failure("Enter a valid address, e.g. smb://server/share")); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var mountpoints: Unmanaged<CFArray>?
            let u = (user?.isEmpty == false) ? user as CFString? : nil
            let p = (password?.isEmpty == false) ? password as CFString? : nil
            let status = NetFSMountURLSync(url as CFURL, nil, u, p, nil, nil, &mountpoints)
            if status == 0,
               let paths = mountpoints?.takeRetainedValue() as? [String],
               let first = paths.first {
                DispatchQueue.main.async { completion(.mounted(URL(fileURLWithPath: first))) }
            } else {
                // Hand off to the system connect flow (handles interactive auth).
                DispatchQueue.main.async {
                    if NSWorkspace.shared.open(url) { completion(.systemHandoff) }
                    else { completion(.failure("Could not connect to the server (error \(status)).")) }
                }
            }
        }
    }
}
