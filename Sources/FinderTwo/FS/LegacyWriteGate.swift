import Foundation
import Darwin

enum LegacyWriteCapability: String, CaseIterable, Sendable {
    case transferMove
    case crossVolumeMove
    case replace
    case merge
    case fileUndoRedo
    case folderSync
    case batchRename
    case permanentDelete
    case archiveWrite
    case sftpWrite
    case inPlaceQuickAction
    case appUninstall
}

final class LegacyWriteDenial: NSObject, @unchecked Sendable {
    let capability: LegacyWriteCapability
    let reason: String

    init(capability: LegacyWriteCapability, reason: String) {
        self.capability = capability
        self.reason = reason
    }
}

/// Main-thread presentation latch for the AppDelegate's user-facing denial.
/// Backend denials are still emitted for every blocked mutation attempt; only
/// the modal UI is coalesced so key repeat or several guarded layers cannot
/// queue an alert storm.
struct LegacyWriteDenialPresentationGate {
    private var didClaim = false

    mutating func claim() -> Bool {
        guard !didClaim else { return false }
        didClaim = true
        return true
    }
}

extension Notification.Name {
    static let legacyWriteDenied = Notification.Name("Rascal.LegacyWriteDenied")
}

enum LegacyWriteGate {
    /// Read exactly once at process startup. Release code does not inspect the environment at all.
    private static let processEnabled: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["RASCAL_ENABLE_LEGACY_WRITES"] == "1"
        #else
        false
        #endif
    }()

    static func allows(_ capability: LegacyWriteCapability, reason: String? = nil) -> Bool {
        guard processEnabled else {
            deny(capability, reason: reason)
            return false
        }
        return true
    }

    @discardableResult
    static func deny(_ capability: LegacyWriteCapability, reason: String? = nil) -> Bool {
        let explanation = reason
            ?? "Legacy \(capability.rawValue) is disabled while the transactional engine is being validated."
        NotificationCenter.default.post(
            name: .legacyWriteDenied,
            object: LegacyWriteDenial(capability: capability, reason: explanation)
        )
        return false
    }
}

enum LegacyTransferClassification: String, Sendable {
    case sameLocal
    case crossVolume
    case remoteOrProvider
    case unknown
}

/// Facts are separated from classification so verification can cover every
/// branch without depending on whichever volumes happen to be mounted on the
/// test machine.
struct LegacyTransferEndpointFacts {
    let volumeIdentity: NSObject?
    let isLocal: Bool?
    let isProviderLike: Bool
    let hasSymlinkAncestor: Bool?
}

struct LegacyPathIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let owner: UInt32
    let group: UInt32
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64

    init(device: UInt64, inode: UInt64, mode: UInt32, owner: UInt32,
         group: UInt32, size: Int64 = 0,
         modificationSeconds: Int64 = 0, modificationNanoseconds: Int64 = 0,
         changeSeconds: Int64 = 0, changeNanoseconds: Int64 = 0) {
        self.device = device
        self.inode = inode
        self.mode = mode
        self.owner = owner
        self.group = group
        self.size = size
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
        self.changeSeconds = changeSeconds
        self.changeNanoseconds = changeNanoseconds
    }

    var fileType: UInt32 { mode & UInt32(S_IFMT) }
    var stable: LegacyStablePathIdentity {
        LegacyStablePathIdentity(
            device: device, inode: inode, mode: mode, owner: owner, group: group
        )
    }
}

struct LegacyStablePathIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let owner: UInt32
    let group: UInt32
}

enum LegacyLStatResult: Equatable {
    case present(LegacyPathIdentity)
    case missing
    case failed(Int32)
}

enum LegacyReadlinkResult: Equatable {
    case value(Data)
    case failed(Int32)
}

enum LegacyResourceFactsResult {
    case value(LegacyTransferEndpointFacts)
    case failed
}

/// Injectable syscall surface used by the source-level gate probe. Production
/// classification always constructs a fresh live value, so `/var` and every
/// endpoint component are re-observed for each preflight/revalidation pass.
struct LegacyClassifierSystemCalls {
    let lstatPath: (String) -> LegacyLStatResult
    let readlinkPath: (String) -> LegacyReadlinkResult
    let resourceFacts: (URL) -> LegacyResourceFactsResult

    static var live: LegacyClassifierSystemCalls {
        LegacyClassifierSystemCalls(
            lstatPath: { path in
                var info = stat()
                let result = path.withCString { Darwin.lstat($0, &info) }
                if result == 0 {
                    return .present(LegacyPathIdentity(
                        device: UInt64(info.st_dev), inode: UInt64(info.st_ino),
                        mode: UInt32(info.st_mode), owner: info.st_uid, group: info.st_gid,
                        size: Int64(info.st_size),
                        modificationSeconds: Int64(info.st_mtimespec.tv_sec),
                        modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                        changeSeconds: Int64(info.st_ctimespec.tv_sec),
                        changeNanoseconds: Int64(info.st_ctimespec.tv_nsec)
                    ))
                }
                let code = errno
                return code == ENOENT ? .missing : .failed(code)
            },
            readlinkPath: { path in
                var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
                let count = path.withCString { pathPointer in
                    buffer.withUnsafeMutableBytes { bytes in
                        Darwin.readlink(pathPointer, bytes.baseAddress, bytes.count)
                    }
                }
                guard count >= 0 else { return .failed(errno) }
                return .value(Data(buffer.prefix(Int(count))))
            },
            resourceFacts: { url in
                do {
                    let values = try url.resourceValues(forKeys: [
                        .volumeIdentifierKey, .volumeIsLocalKey, .isUbiquitousItemKey
                    ])
                    let components = url.standardizedFileURL.pathComponents
                    let providerPath = zip(components, components.dropFirst()).contains {
                        $0.0 == "Library" && $0.1 == "CloudStorage"
                    }
                    return .value(LegacyTransferEndpointFacts(
                        volumeIdentity: values.volumeIdentifier as? NSObject,
                        isLocal: values.volumeIsLocal,
                        isProviderLike: values.isUbiquitousItem == true || providerPath,
                        hasSymlinkAncestor: false
                    ))
                } catch {
                    return .failed
                }
            }
        )
    }
}

struct LegacyAliasObservation: Equatable {
    let aliasIdentity: LegacyPathIdentity
    let target: Data
    let privateIdentity: LegacyPathIdentity
    let privateVarIdentity: LegacyPathIdentity

    static func == (lhs: LegacyAliasObservation, rhs: LegacyAliasObservation) -> Bool {
        lhs.aliasIdentity.stable == rhs.aliasIdentity.stable
            && lhs.target == rhs.target
            && lhs.privateIdentity.stable == rhs.privateIdentity.stable
            && lhs.privateVarIdentity.stable == rhs.privateVarIdentity.stable
    }
}

struct LegacyPathComponentObservation: Equatable {
    enum State: Equatable {
        case present(LegacyPathIdentity)
        case missing
    }

    let path: String
    let isLeaf: Bool
    let state: State

    static func == (lhs: LegacyPathComponentObservation,
                    rhs: LegacyPathComponentObservation) -> Bool {
        guard lhs.path == rhs.path, lhs.isLeaf == rhs.isLeaf else { return false }
        switch (lhs.state, rhs.state) {
        case (.missing, .missing): return true
        case let (.present(left), .present(right)):
            return lhs.isLeaf ? left == right : left.stable == right.stable
        default: return false
        }
    }
}

struct LegacyEndpointObservation: Equatable {
    let requestedURL: URL
    let operationalURL: URL?
    let alias: LegacyAliasObservation?
    let components: [LegacyPathComponentObservation]
    let facts: LegacyTransferEndpointFacts

    static func == (lhs: LegacyEndpointObservation,
                    rhs: LegacyEndpointObservation) -> Bool {
        lhs.requestedURL == rhs.requestedURL
            && lhs.operationalURL == rhs.operationalURL
            && lhs.alias == rhs.alias
            && lhs.components == rhs.components
            && lhs.facts.isLocal == rhs.facts.isLocal
            && lhs.facts.isProviderLike == rhs.facts.isProviderLike
            && lhs.facts.hasSymlinkAncestor == rhs.facts.hasSymlinkAncestor
            && equalVolume(lhs.facts.volumeIdentity, rhs.facts.volumeIdentity)
    }

    private static func equalVolume(_ lhs: NSObject?, _ rhs: NSObject?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return lhs.isEqual(rhs)
        default: return false
        }
    }
}

struct LegacyTransferObservation: Equatable {
    let classification: LegacyTransferClassification
    let source: LegacyEndpointObservation
    let destination: LegacyEndpointObservation
}

enum LegacyTransferClassifier {
    static func classify(source: URL, destination: URL) -> LegacyTransferClassification {
        observe(source: source, destination: destination).classification
    }

    static func observe(source: URL, destination: URL,
                        system: LegacyClassifierSystemCalls = .live) -> LegacyTransferObservation {
        let sourceObservation = observeEndpoint(
            source, allowMissingTail: false, system: system
        )
        let destinationObservation = observeEndpoint(
            destination, allowMissingTail: true, system: system
        )
        let classification: LegacyTransferClassification
        if sourceObservation.operationalURL == nil || destinationObservation.operationalURL == nil {
            classification = .unknown
        } else {
            classification = classify(
                source: sourceObservation.facts, destination: destinationObservation.facts
            )
        }
        return LegacyTransferObservation(
            classification: classification,
            source: sourceObservation,
            destination: destinationObservation
        )
    }

    static func classify(source: LegacyTransferEndpointFacts,
                         destination: LegacyTransferEndpointFacts) -> LegacyTransferClassification {
        guard source.hasSymlinkAncestor == false,
              destination.hasSymlinkAncestor == false else { return .unknown }
        if source.isProviderLike || destination.isProviderLike { return .remoteOrProvider }
        if source.isLocal == false || destination.isLocal == false { return .remoteOrProvider }
        guard source.isLocal == true, destination.isLocal == true,
              let sourceVolume = source.volumeIdentity,
              let destinationVolume = destination.volumeIdentity else { return .unknown }
        return sourceVolume.isEqual(destinationVolume) ? .sameLocal : .crossVolume
    }

    private static let unknownFacts = LegacyTransferEndpointFacts(
        volumeIdentity: nil, isLocal: nil, isProviderLike: false,
        hasSymlinkAncestor: nil
    )

    private static func observeEndpoint(
        _ requestedURL: URL,
        allowMissingTail: Bool,
        system: LegacyClassifierSystemCalls
    ) -> LegacyEndpointObservation {
        func invalid(_ alias: LegacyAliasObservation? = nil,
                     _ components: [LegacyPathComponentObservation] = [])
            -> LegacyEndpointObservation {
            LegacyEndpointObservation(
                requestedURL: requestedURL, operationalURL: nil, alias: alias,
                components: components, facts: unknownFacts
            )
        }

        guard requestedURL.isFileURL, requestedURL.path.hasPrefix("/") else { return invalid() }
        let requestedComponents = requestedURL.pathComponents
        guard requestedComponents.first == "/",
              !requestedComponents.dropFirst().contains(where: { $0 == "." || $0 == ".." })
        else { return invalid() }

        let standardized = requestedURL.standardizedFileURL
        let standardizedComponents = standardized.pathComponents
        guard standardizedComponents.first == "/" else { return invalid() }

        var alias: LegacyAliasObservation?
        let operationalURL: URL
        if standardizedComponents.dropFirst().first == "var" {
            guard let currentAlias = observeVarAlias(system: system) else { return invalid() }
            alias = currentAlias
            operationalURL = standardizedComponents.dropFirst(2).reduce(
                URL(fileURLWithPath: "/private/var", isDirectory: false)
            ) { partial, component in
                partial.appendingPathComponent(component, isDirectory: false)
            }
        } else {
            operationalURL = standardized
        }

        var observations: [LegacyPathComponentObservation] = []
        var currentPath = "/"
        var missingTail = false
        var nearestExistingPath: String?
        let pathTail = Array(operationalURL.pathComponents.dropFirst())
        for (componentIndex, component) in pathTail.enumerated() {
            let isLeaf = componentIndex == pathTail.count - 1
            currentPath = (currentPath as NSString).appendingPathComponent(component)
            switch system.lstatPath(currentPath) {
            case let .present(identity):
                guard !missingTail, identity.fileType != UInt32(S_IFLNK) else {
                    return invalid(alias, observations)
                }
                observations.append(.init(
                    path: currentPath, isLeaf: isLeaf, state: .present(identity)
                ))
                nearestExistingPath = currentPath
            case .missing:
                guard allowMissingTail else { return invalid(alias, observations) }
                missingTail = true
                observations.append(.init(path: currentPath, isLeaf: isLeaf, state: .missing))
            case .failed:
                return invalid(alias, observations)
            }
        }

        // The filesystem root is implicit in URL.pathComponents; observe it as
        // well so replacement of a mounted hierarchy invalidates the token.
        guard case let .present(rootIdentity) = system.lstatPath("/"),
              rootIdentity.fileType != UInt32(S_IFLNK) else { return invalid(alias, observations) }
        observations.insert(.init(
            path: "/", isLeaf: pathTail.isEmpty, state: .present(rootIdentity)
        ), at: 0)

        let factsURL = URL(fileURLWithPath: nearestExistingPath ?? "/", isDirectory: true)
        guard case let .value(facts) = system.resourceFacts(factsURL) else {
            return invalid(alias, observations)
        }
        return LegacyEndpointObservation(
            requestedURL: requestedURL,
            operationalURL: operationalURL,
            alias: alias,
            components: observations,
            facts: facts
        )
    }

    private static func observeVarAlias(
        system: LegacyClassifierSystemCalls
    ) -> LegacyAliasObservation? {
        guard case let .present(aliasIdentity) = system.lstatPath("/var"),
              aliasIdentity.fileType == UInt32(S_IFLNK),
              aliasIdentity.owner == 0, aliasIdentity.group == 0,
              case let .value(target) = system.readlinkPath("/var"),
              target == Data("private/var".utf8),
              case let .present(privateIdentity) = system.lstatPath("/private"),
              privateIdentity.fileType == UInt32(S_IFDIR),
              privateIdentity.owner == 0, privateIdentity.group == 0,
              case let .present(privateVarIdentity) = system.lstatPath("/private/var"),
              privateVarIdentity.fileType == UInt32(S_IFDIR),
              privateVarIdentity.owner == 0, privateVarIdentity.group == 0
        else { return nil }
        return LegacyAliasObservation(
            aliasIdentity: aliasIdentity,
            target: target,
            privateIdentity: privateIdentity,
            privateVarIdentity: privateVarIdentity
        )
    }
}

enum LegacyExclusiveRenameResult: Equatable {
    case moved
    case failed(Int32)
}

/// macOS namespace move primitive for the isolated legacy fixture. RENAME_EXCL
/// is essential: unlike rename(2), it never replaces a destination that raced
/// into existence after observation. No copy/delete fallback exists here.
enum LegacyExclusiveRename {
    typealias SystemCall = (
        UnsafePointer<CChar>, UnsafePointer<CChar>
    ) -> (result: Int32, error: Int32)

    static func move(source: URL, destination: URL,
                     systemCall: SystemCall? = nil) -> LegacyExclusiveRenameResult {
        let call = systemCall ?? { sourcePath, destinationPath in
            let result = Darwin.renameatx_np(
                AT_FDCWD, sourcePath, AT_FDCWD, destinationPath, UInt32(RENAME_EXCL)
            )
            return (result, result == 0 ? 0 : errno)
        }
        return source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return .failed(EINVAL) }
                let outcome = call(sourcePath, destinationPath)
                return outcome.result == 0 ? .moved : .failed(outcome.error)
            }
        }
    }
}

enum LegacyReplaceGuard {
    static func planIsExclusive(itemCount: Int, replacementCount: Int) -> Bool {
        replacementCount == 0 || (itemCount == 1 && replacementCount == 1)
    }

    static func revalidateAndTrash(
        initial: LegacyTransferObservation,
        source: URL,
        destination: URL,
        system: LegacyClassifierSystemCalls = .live,
        trash: (URL) throws -> Void
    ) -> Bool {
        let current = LegacyTransferClassifier.observe(
            source: source, destination: destination, system: system
        )
        guard current == initial,
              let canonicalDestination = current.destination.operationalURL else {
            LegacyWriteGate.deny(
                .replace,
                reason: "Replace endpoint changed before the destination could be preserved."
            )
            return false
        }
        do {
            try trash(canonicalDestination)
            return true
        } catch {
            LegacyWriteGate.deny(
                .replace,
                reason: "The existing destination could not be moved to Trash; Replace was stopped."
            )
            return false
        }
    }
}
