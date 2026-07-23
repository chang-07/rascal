import Foundation
import Darwin

/// Owns a directory descriptor reached one component at a time from `/`.
/// Every hop uses `O_NOFOLLOW`, so a symlink cannot be substituted for an
/// ancestor between a lexical check and the filesystem operation itself.
package final class NativeDirectoryHandle: @unchecked Sendable {
    package let fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit { close(fileDescriptor) }

    package static func openAnchored(_ directory: URL) throws -> NativeDirectoryHandle {
        let path = canonicalSystemRootAlias(directory.standardizedFileURL.path)
        guard path.hasPrefix("/") else {
            throw NativeFileError(
                code: .validation,
                systemCode: nil,
                message: "anchored directory path must be absolute: \(path)"
            )
        }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw NativeFileError.fromErrno(errno, path: "/", operation: "open anchor root")
        }
        do {
            for component in path.split(separator: "/", omittingEmptySubsequences: true) {
                let next = openat(
                    descriptor, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW
                )
                guard next >= 0 else {
                    throw NativeFileError.fromErrno(
                        errno, path: path, operation: "open anchored directory component"
                    )
                }
                close(descriptor)
                descriptor = next
            }
            return NativeDirectoryHandle(fileDescriptor: descriptor)
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func canonicalSystemRootAlias(_ path: String) -> String {
        if path == "/var" || path.hasPrefix("/var/") { return "/private" + path }
        if path == "/tmp" || path.hasPrefix("/tmp/") { return "/private" + path }
        if path == "/etc" || path.hasPrefix("/etc/") { return "/private" + path }
        return path
    }
}

package struct NativeAnchoredEntry {
    package let parent: NativeDirectoryHandle
    package let name: String

    package static func openParent(of entry: URL) throws -> NativeAnchoredEntry {
        let standardized = entry.standardizedFileURL
        let name = standardized.lastPathComponent
        guard !name.isEmpty, name != "/", name != ".", name != ".." else {
            throw NativeFileError(
                code: .validation,
                systemCode: nil,
                message: "invalid anchored entry name for \(entry.path)"
            )
        }
        return NativeAnchoredEntry(
            parent: try NativeDirectoryHandle.openAnchored(
                standardized.deletingLastPathComponent()
            ),
            name: name
        )
    }
}

package enum NativeCapabilityStatus: Sendable, Equatable {
    case supported
    case unsupported(String)
    case unknown(String)
}

package struct NativeSafetyCapabilities: Sendable, Equatable {
    package let localAPFS: NativeCapabilityStatus
    package let noFollowAncestors: NativeCapabilityStatus
    package let writableDestination: NativeCapabilityStatus
    package let providerIdentity: NativeCapabilityStatus

    package var firstBlockingReason: String? {
        for status in [localAPFS, noFollowAncestors, writableDestination, providerIdentity] {
            switch status {
            case .supported: continue
            case let .unsupported(reason), let .unknown(reason): return reason
            }
        }
        return nil
    }
}

/// Fidelity is intentionally separate from safety: an exact, item-bound
/// portable-copy decision may waive these fields, but it can never waive an
/// unknown path, identity, staging, or commit guarantee.
package struct NativeFidelityCapabilities: Sendable, Equatable {
    package let fields: [MetadataField: NativeCapabilityStatus]

    package var unavailableFields: Set<MetadataField> {
        Set(fields.compactMap { field, status in
            switch status {
            case .supported: return nil
            case .unsupported, .unknown: return field
            }
        })
    }
}

/// Versioned, conservative identity used for preflight/recheck and receipts.
/// URL resource identifiers alone are deliberately insufficient because they
/// are not guaranteed unique across restart, provider materialization, or inode
/// reuse.
package struct NativeCompositeIdentity: Sendable, Equatable {
    package static let adapterVersion: UInt16 = 1

    package let volumeUUID: String
    package let device: UInt64
    package let inode: UInt64
    package let mode: UInt32
    package let linkCount: UInt64
    package let size: Int64
    package let modificationSeconds: Int64
    package let modificationNanoseconds: Int64
    package let changeSeconds: Int64
    package let changeNanoseconds: Int64
    package let birthSeconds: Int64
    package let birthNanoseconds: Int64

    package var digest: String {
        [
            "native-v\(Self.adapterVersion)", volumeUUID,
            String(device), String(inode), String(mode), String(linkCount), String(size),
            String(modificationSeconds), String(modificationNanoseconds),
            String(changeSeconds), String(changeNanoseconds),
            String(birthSeconds), String(birthNanoseconds)
        ].joined(separator: ":")
    }
}

package enum NativePathInspector {
    package static func identity(at url: URL) throws -> NativeCompositeIdentity {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw NativeFileError.fromErrno(errno, path: url.path, operation: "lstat")
        }
        let volumeUUID = try volumeUUIDString(for: url)
        return NativeCompositeIdentity(
            volumeUUID: volumeUUID,
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            mode: UInt32(info.st_mode),
            linkCount: UInt64(info.st_nlink),
            size: info.st_size,
            modificationSeconds: Int64(info.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changeSeconds: Int64(info.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(info.st_ctimespec.tv_nsec),
            birthSeconds: Int64(info.st_birthtimespec.tv_sec),
            birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec)
        )
    }

    package static func safetyCapabilities(
        source: URL, destinationParent: URL
    ) -> NativeSafetyCapabilities {
        let localAPFS: NativeCapabilityStatus
        do {
            let sourceFS = try fileSystemFacts(for: source)
            let destinationFS = try fileSystemFacts(for: destinationParent)
            if sourceFS.type != "apfs" || destinationFS.type != "apfs" {
                localAPFS = .unsupported("M2 native copy is limited to verified APFS volumes")
            } else if !sourceFS.isLocal || !destinationFS.isLocal {
                localAPFS = .unsupported("network and remote filesystems require a later capability lane")
            } else {
                localAPFS = .supported
            }
        } catch {
            localAPFS = .unknown("filesystem type or locality could not be proven: \(error)")
        }

        let ancestors: NativeCapabilityStatus
        do {
            try requireNoSymlinkAncestors(of: source, includeLeaf: false)
            try requireNoSymlinkAncestors(of: destinationParent, includeLeaf: true)
            ancestors = .supported
        } catch {
            ancestors = .unsupported("symlinked or unreadable path ancestor: \(error)")
        }

        let writable: NativeCapabilityStatus
        do {
            let values = try destinationParent.resourceValues(forKeys: [
                .isDirectoryKey, .volumeIsReadOnlyKey
            ])
            if values.isDirectory != true {
                writable = .unsupported("destination parent is not a directory")
            } else if values.volumeIsReadOnly == true {
                writable = .unsupported("destination volume is read-only")
            } else if access(destinationParent.path, W_OK | X_OK) != 0 {
                writable = .unsupported("destination parent is not writable")
            } else {
                writable = .supported
            }
        } catch {
            writable = .unknown("destination writability could not be proven: \(error)")
        }

        let standardizedSource = source.standardizedFileURL.path
        let standardizedDestination = destinationParent.standardizedFileURL.path
        let providerRoots = ["/Library/CloudStorage/", "/Mobile Documents/"]
        let providerLike = providerRoots.contains {
            standardizedSource.contains($0) || standardizedDestination.contains($0)
        }
        let provider: NativeCapabilityStatus = providerLike
            ? .unsupported("File Provider and cloud-backed paths require a real provider lane")
            : .supported

        return NativeSafetyCapabilities(
            localAPFS: localAPFS,
            noFollowAncestors: ancestors,
            writableDestination: writable,
            providerIdentity: provider
        )
    }

    package static func fidelityCapabilities(
        source: URL, destinationParent: URL
    ) -> NativeFidelityCapabilities {
        let status: NativeCapabilityStatus
        do {
            let sourceFS = try fileSystemFacts(for: source)
            let destinationFS = try fileSystemFacts(for: destinationParent)
            if sourceFS.type == "apfs", destinationFS.type == "apfs",
               sourceFS.isLocal, destinationFS.isLocal {
                // This is capability eligibility, not preservation proof.
                // The before/after manifest remains authoritative per item.
                status = .supported
            } else {
                status = .unsupported(
                    "Finder-compatible metadata fidelity is only enabled for verified local APFS"
                )
            }
        } catch {
            status = .unknown("metadata fidelity could not be classified: \(error)")
        }
        return NativeFidelityCapabilities(
            fields: Dictionary(uniqueKeysWithValues: MetadataField.allCases.map { ($0, status) })
        )
    }

    package static func requireNoSymlinkAncestors(
        of url: URL, includeLeaf: Bool
    ) throws {
        let standardized = canonicalSystemRootAlias(url.standardizedFileURL.path)
        let parts = standardized.split(separator: "/", omittingEmptySubsequences: true)
        let count = includeLeaf ? parts.count : max(0, parts.count - 1)
        var current = "/"
        for component in parts.prefix(count) {
            current = (current as NSString).appendingPathComponent(String(component))
            var info = stat()
            guard lstat(current, &info) == 0 else {
                throw NativeFileError.fromErrno(errno, path: current, operation: "lstat ancestor")
            }
            guard (info.st_mode & S_IFMT) != S_IFLNK else {
                throw NativeFileError(
                    code: .validation,
                    systemCode: ELOOP,
                    message: "symlink ancestor is not allowed: \(current)"
                )
            }
        }
    }

    /// Darwin exposes these three root entries as OS-owned aliases into
    /// `/private`. Normalize only that fixed set before the no-follow walk;
    /// arbitrary user-controlled symlink ancestors remain rejected.
    private static func canonicalSystemRootAlias(_ path: String) -> String {
        if path == "/var" || path.hasPrefix("/var/") { return "/private" + path }
        if path == "/tmp" || path.hasPrefix("/tmp/") { return "/private" + path }
        if path == "/etc" || path.hasPrefix("/etc/") { return "/private" + path }
        return path
    }

    package static func volumeUUIDString(for url: URL) throws -> String {
        let existing = nearestExistingAncestor(of: url)
        let values = try existing.resourceValues(forKeys: [.volumeUUIDStringKey])
        guard let uuid = values.volumeUUIDString, !uuid.isEmpty else {
            throw NativeFileError(
                code: .serviceSafeMode,
                systemCode: nil,
                message: "volume UUID is unavailable for \(existing.path)"
            )
        }
        return uuid
    }

    private static func nearestExistingAncestor(of url: URL) -> URL {
        var candidate = url.standardizedFileURL
        while candidate.path != "/" && access(candidate.path, F_OK) != 0 {
            candidate.deleteLastPathComponent()
        }
        return candidate
    }

    private static func fileSystemFacts(for url: URL) throws -> (type: String, isLocal: Bool) {
        let existing = nearestExistingAncestor(of: url)
        var facts = statfs()
        guard statfs(existing.path, &facts) == 0 else {
            throw NativeFileError.fromErrno(errno, path: existing.path, operation: "statfs")
        }
        let type = withUnsafePointer(to: &facts.f_fstypename) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) {
                String(cString: $0)
            }
        }
        return (type, (facts.f_flags & UInt32(MNT_LOCAL)) != 0)
    }
}

package struct NativeFileError: Error, Sendable, CustomStringConvertible {
    package let code: FileOperationErrorCode
    package let systemCode: Int32?
    package let message: String

    package var description: String { message }

    package static func fromErrno(
        _ value: Int32, path: String, operation: String
    ) -> NativeFileError {
        let code: FileOperationErrorCode
        switch value {
        case EACCES, EPERM: code = .permissionDenied
        case ENOSPC, EDQUOT: code = .noSpace
        case ENXIO, ENODEV, ESTALE: code = .volumeDisconnected
        case EEXIST, ENOTEMPTY: code = .destinationChanged
        default: code = .invariantViolation
        }
        return NativeFileError(
            code: code,
            systemCode: value,
            message: "\(operation) failed for \(path): errno \(value)"
        )
    }

    package func failure(
        operationID: OperationID? = nil,
        itemID: OperationItemID? = nil,
        phase: OperationState? = nil,
        retryable: Bool = false
    ) -> FileOperationFailure {
        FileOperationFailure(
            code: code,
            operationID: operationID,
            itemID: itemID,
            phase: phase,
            systemCode: systemCode,
            diagnostic: message,
            retryable: retryable
        )
    }
}
