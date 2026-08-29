import Foundation
import Darwin
import CommonCrypto

package enum NativeNodeKind: String, Codable, Sendable {
    case regular, directory, symbolicLink, other
}

package struct NativeManifestEntry: Codable, Sendable, Equatable {
    package let relativePath: String
    package let kind: NativeNodeKind
    package let logicalSize: Int64
    package let allocatedBytes: Int64
    package let sparseDataRanges: [String]
    package let mode: UInt32
    package let flags: UInt32
    package let modificationSeconds: Int64
    package let modificationNanoseconds: Int64
    package let birthSeconds: Int64
    package let birthNanoseconds: Int64
    package let symlinkTarget: String?
    package let hardLinkGroup: String?
    package let extendedAttributes: [String: String]
    package let aclText: String
    package let contentSHA256: String?

    package var isSparse: Bool {
        guard kind == .regular, logicalSize > 0 else { return false }
        let dataBytes = sparseDataRanges.reduce(Int64(0)) { total, encoded in
            let bounds = encoded.split(separator: ":").compactMap { Int64($0) }
            return bounds.count == 2 ? total + max(0, bounds[1] - bounds[0]) : total
        }
        return dataBytes < logicalSize
    }
}

package struct NativeTreeManifest: Sendable, Equatable {
    package let entries: [NativeManifestEntry]
    package let digest: String
    package let totalRegularBytes: Int64

    package static func capture(
        root: URL,
        includeContentDigests: Bool
    ) throws -> NativeTreeManifest {
        var pending: [(relative: String, url: URL, info: stat)] = []
        try collect(root: root, url: root, relative: ".", into: &pending)

        let hardLinkCounts = pending.reduce(into: [String: Int]()) { counts, node in
            guard (node.info.st_mode & S_IFMT) == S_IFREG, node.info.st_nlink > 1 else {
                return
            }
            counts["\(node.info.st_dev):\(node.info.st_ino)", default: 0] += 1
        }
        var hardLinkLeaders: [String: String] = [:]
        var entries: [NativeManifestEntry] = []
        entries.reserveCapacity(pending.count)
        var total: Int64 = 0

        for node in pending {
            let type = node.info.st_mode & S_IFMT
            let kind: NativeNodeKind
            switch type {
            case S_IFREG: kind = .regular
            case S_IFDIR: kind = .directory
            case S_IFLNK: kind = .symbolicLink
            default: kind = .other
            }
            guard kind != .other else {
                throw NativeFileError(
                    code: .featureDisabled,
                    systemCode: nil,
                    message: "unsupported filesystem node at \(node.relative)"
                )
            }

            let hardLinkGroup: String?
            if kind == .regular, node.info.st_nlink > 1 {
                let key = "\(node.info.st_dev):\(node.info.st_ino)"
                if hardLinkCounts[key, default: 0] < 2 {
                    // Links outside the selected tree are not part of the
                    // copy's observable topology. Treat the selected node as
                    // an ordinary file instead of requiring the staged inode
                    // to retain an external link count.
                    hardLinkGroup = nil
                } else if let leader = hardLinkLeaders[key] {
                    hardLinkGroup = leader
                } else {
                    hardLinkLeaders[key] = node.relative
                    hardLinkGroup = node.relative
                }
            } else {
                hardLinkGroup = nil
            }

            let logicalSize = kind == .regular ? node.info.st_size : 0
            if kind == .regular { total += logicalSize }
            entries.append(NativeManifestEntry(
                relativePath: node.relative,
                kind: kind,
                logicalSize: logicalSize,
                allocatedBytes: kind == .regular ? Int64(node.info.st_blocks) * 512 : 0,
                sparseDataRanges: kind == .regular
                    ? try sparseRanges(node.url, size: logicalSize) : [],
                mode: UInt32(node.info.st_mode & 0o7777),
                flags: node.info.st_flags,
                modificationSeconds: Int64(node.info.st_mtimespec.tv_sec),
                modificationNanoseconds: Int64(node.info.st_mtimespec.tv_nsec),
                birthSeconds: Int64(node.info.st_birthtimespec.tv_sec),
                birthNanoseconds: Int64(node.info.st_birthtimespec.tv_nsec),
                symlinkTarget: kind == .symbolicLink ? try readLink(node.url) : nil,
                hardLinkGroup: hardLinkGroup,
                extendedAttributes: try xattrDigests(node.url),
                aclText: try accessControlText(node.url, isSymlink: kind == .symbolicLink),
                contentSHA256: includeContentDigests && kind == .regular
                    ? try SHA256Provider.file(node.url) : nil
            ))
        }

        let canonical = try JSONEncoder.canonical.encode(entries)
        return NativeTreeManifest(
            entries: entries,
            digest: SHA256Provider.data(canonical),
            totalRegularBytes: total
        )
    }

    package func firstMismatch(
        against staged: NativeTreeManifest,
        policy: VerificationPolicy
    ) -> String? {
        guard entries.count == staged.entries.count else {
            return "node count differs: source=\(entries.count) staged=\(staged.entries.count)"
        }
        for (source, target) in zip(entries, staged.entries) {
            guard source.relativePath == target.relativePath else {
                return "relative path differs: \(source.relativePath) vs \(target.relativePath)"
            }
            guard source.kind == target.kind else { return "type differs at \(source.relativePath)" }
            guard source.logicalSize == target.logicalSize else {
                return "logical size differs at \(source.relativePath)"
            }
            guard source.mode == target.mode else { return "POSIX mode differs at \(source.relativePath)" }
            guard source.flags == target.flags else { return "BSD flags differ at \(source.relativePath)" }
            guard source.modificationSeconds == target.modificationSeconds,
                  source.modificationNanoseconds == target.modificationNanoseconds else {
                return "modification time differs at \(source.relativePath)"
            }
            guard source.birthSeconds == target.birthSeconds,
                  source.birthNanoseconds == target.birthNanoseconds else {
                return "creation time differs at \(source.relativePath)"
            }
            guard source.symlinkTarget == target.symlinkTarget else {
                return "symlink target differs at \(source.relativePath)"
            }
            guard source.hardLinkGroup == target.hardLinkGroup else {
                return "hard-link topology differs at \(source.relativePath)"
            }
            guard source.extendedAttributes == target.extendedAttributes else {
                return "extended attributes differ at \(source.relativePath)"
            }
            guard source.aclText == target.aclText else { return "ACL differs at \(source.relativePath)" }
            guard source.sparseDataRanges == target.sparseDataRanges else {
                return "sparse topology differs at \(source.relativePath)"
            }
            if source.isSparse || target.isSparse,
               source.allocatedBytes != target.allocatedBytes {
                return "allocated blocks differ at \(source.relativePath)"
            }
            if policy == .sha256, source.contentSHA256 != target.contentSHA256 {
                return "SHA-256 differs at \(source.relativePath)"
            }
        }
        return nil
    }

    private static func collect(
        root: URL,
        url: URL,
        relative: String,
        into nodes: inout [(relative: String, url: URL, info: stat)]
    ) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw NativeFileError.fromErrno(errno, path: url.path, operation: "manifest lstat")
        }
        nodes.append((relative, url, info))
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return }

        let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
            .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        for name in names {
            let child = url.appendingPathComponent(name, isDirectory: false)
            let childRelative = relative == "." ? name : relative + "/" + name
            try collect(root: root, url: child, relative: childRelative, into: &nodes)
        }
    }

    private static func readLink(_ url: URL) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink(url.path, &buffer, Int(PATH_MAX))
        guard count >= 0 else {
            throw NativeFileError.fromErrno(errno, path: url.path, operation: "readlink")
        }
        return String(decoding: buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func xattrDigests(_ url: URL) throws -> [String: String] {
        let needed = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        if needed < 0 {
            if errno == ENOTSUP { return [:] }
            throw NativeFileError.fromErrno(errno, path: url.path, operation: "listxattr")
        }
        guard needed > 0 else { return [:] }
        var names = [CChar](repeating: 0, count: needed)
        let actual = listxattr(url.path, &names, names.count, XATTR_NOFOLLOW)
        guard actual == needed else {
            throw NativeFileError.fromErrno(errno, path: url.path, operation: "listxattr read")
        }
        var result: [String: String] = [:]
        var start = 0
        for index in 0..<names.count where names[index] == 0 {
            if index > start {
                let bytes = names[start..<index].map { UInt8(bitPattern: $0) }
                let name = String(decoding: bytes, as: UTF8.self)
                let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
                guard size >= 0 else {
                    throw NativeFileError.fromErrno(errno, path: url.path, operation: "getxattr size")
                }
                var value = [UInt8](repeating: 0, count: size)
                let read = value.withUnsafeMutableBytes {
                    getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW)
                }
                guard read == size else {
                    throw NativeFileError.fromErrno(errno, path: url.path, operation: "getxattr")
                }
                result[name] = SHA256Provider.data(Data(value))
            }
            start = index + 1
        }
        return result
    }

    private static func accessControlText(_ url: URL, isSymlink: Bool) throws -> String {
        errno = 0
        let acl = isSymlink
            ? acl_get_link_np(url.path, ACL_TYPE_EXTENDED)
            : acl_get_file(url.path, ACL_TYPE_EXTENDED)
        guard let acl else {
            if errno == 0 || errno == ENOENT || errno == EINVAL || errno == ENOTSUP { return "" }
            throw NativeFileError.fromErrno(errno, path: url.path, operation: "acl_get")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var length: ssize_t = 0
        guard let text = acl_to_text(acl, &length) else {
            throw NativeFileError.fromErrno(errno, path: url.path, operation: "acl_to_text")
        }
        defer { acl_free(UnsafeMutableRawPointer(text)) }
        return String(cString: text)
    }

    private static func sparseRanges(_ url: URL, size: Int64) throws -> [String] {
        guard size > 0 else { return [] }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            throw NativeFileError.fromErrno(errno, path: url.path, operation: "open sparse map")
        }
        defer { close(fd) }
        var ranges: [String] = []
        var cursor: off_t = 0
        while cursor < size {
            errno = 0
            let dataStart = lseek(fd, cursor, SEEK_DATA)
            if dataStart < 0 {
                if errno == ENXIO { break }
                throw NativeFileError.fromErrno(
                    errno, path: url.path, operation: "SEEK_DATA"
                )
            }
            let holeStart = lseek(fd, dataStart, SEEK_HOLE)
            guard holeStart >= dataStart else {
                throw NativeFileError.fromErrno(
                    errno, path: url.path, operation: "SEEK_HOLE"
                )
            }
            let end = min(Int64(holeStart), size)
            ranges.append("\(dataStart):\(end)")
            guard holeStart > cursor else {
                throw NativeFileError(
                    code: .invariantViolation,
                    systemCode: nil,
                    message: "sparse range cursor did not advance for \(url.path)"
                )
            }
            cursor = holeStart
        }
        return ranges
    }
}

package struct NativeTreeIdentityEntry: Codable, Sendable, Equatable {
    package let relativePath: String
    package let stableIdentity: NativeStableObjectIdentity
    package let mode: UInt32
    package let linkCount: UInt64
    package let size: Int64
    package let modificationSeconds: Int64
    package let modificationNanoseconds: Int64
    package let changeSeconds: Int64
    package let changeNanoseconds: Int64
    package let birthSeconds: Int64
    package let birthNanoseconds: Int64
}

/// A same-tree identity receipt. Unlike `NativeTreeManifest`, inode and ctime
/// are intentionally included because this snapshot is compared with the same
/// source or staging tree at a later authorization point, never across the
/// source/stage boundary.
package struct NativeTreeIdentitySnapshot: Sendable, Equatable {
    package let entries: [NativeTreeIdentityEntry]

    package static func capture(root: URL) throws -> NativeTreeIdentitySnapshot {
        let volumeUUID = try NativePathInspector.volumeUUIDString(for: root)
        var entries: [NativeTreeIdentityEntry] = []
        try collect(root: root, relative: ".", volumeUUID: volumeUUID, into: &entries)
        return NativeTreeIdentitySnapshot(entries: entries)
    }

    package var stableEntries: [String: NativeStableObjectIdentity] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.relativePath, $0.stableIdentity) })
    }

    private static func collect(
        root: URL,
        relative: String,
        volumeUUID: String,
        into entries: inout [NativeTreeIdentityEntry]
    ) throws {
        var info = stat()
        guard lstat(root.path, &info) == 0 else {
            throw NativeFileError.fromErrno(
                errno, path: root.path, operation: "tree identity lstat"
            )
        }
        entries.append(NativeTreeIdentityEntry(
            relativePath: relative,
            stableIdentity: NativeStableObjectIdentity(
                volumeUUID: volumeUUID,
                device: UInt64(info.st_dev),
                inode: UInt64(info.st_ino),
                nodeType: UInt32(info.st_mode & S_IFMT)
            ),
            mode: UInt32(info.st_mode),
            linkCount: UInt64(info.st_nlink),
            size: info.st_size,
            modificationSeconds: Int64(info.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changeSeconds: Int64(info.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(info.st_ctimespec.tv_nsec),
            birthSeconds: Int64(info.st_birthtimespec.tv_sec),
            birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec)
        ))
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return }
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        for name in names {
            try collect(
                root: root.appendingPathComponent(name),
                relative: relative == "." ? name : relative + "/" + name,
                volumeUUID: volumeUUID,
                into: &entries
            )
        }
    }
}

package enum SHA256Provider {
    package static func data(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(bytes.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    package static func file(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var context = CC_SHA256_CTX()
        CC_SHA256_Init(&context)
        while true {
            let data = try handle.read(upToCount: 1 << 20) ?? Data()
            if data.isEmpty { break }
            data.withUnsafeBytes { bytes in
                _ = CC_SHA256_Update(&context, bytes.baseAddress, CC_LONG(bytes.count))
            }
        }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &context)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

package struct CommonCryptoDigestProvider: DigestProvider {
    package init() {}
    package func digest(_ data: Data) throws -> String { SHA256Provider.data(data) }
}

private extension JSONEncoder {
    static var canonical: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
