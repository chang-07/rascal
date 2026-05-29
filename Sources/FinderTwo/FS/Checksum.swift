import Foundation
import CryptoKit

/// Streamed file checksums (MD5 / SHA-256). Reads in chunks so hashing a large
/// file never loads it whole into memory.
enum Checksum {
    enum Kind: String, CaseIterable { case md5 = "MD5", sha256 = "SHA-256" }

    static func compute(_ url: URL, kind: Kind) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let chunkSize = 1 << 20  // 1 MiB
        switch kind {
        case .md5:
            var h = Insecure.MD5()
            while case let data = handle.readData(ofLength: chunkSize), !data.isEmpty {
                h.update(data: data)
            }
            return h.finalize().map { String(format: "%02x", $0) }.joined()
        case .sha256:
            var h = SHA256()
            while case let data = handle.readData(ofLength: chunkSize), !data.isEmpty {
                h.update(data: data)
            }
            return h.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Hash one or many files; returns one "hash  name" line per readable file.
    static func report(_ urls: [URL], kind: Kind) -> String {
        urls.compactMap { url -> String? in
            guard let h = compute(url, kind: kind) else { return nil }
            return urls.count == 1 ? h : "\(h)  \(url.lastPathComponent)"
        }.joined(separator: "\n")
    }
}
