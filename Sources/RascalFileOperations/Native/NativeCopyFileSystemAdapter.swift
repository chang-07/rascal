import Foundation
import Darwin

package final class NativeCopyWorkspaceRegistry: @unchecked Sendable {
    package struct Key: Hashable, Sendable {
        package let operationID: OperationID
        package let itemID: OperationItemID
    }

    package struct Record: Sendable {
        package let source: URL
        package var destination: URL
        package let staging: URL
        package let stagingParentIdentity: NativeStableObjectIdentity
        package var stagingIdentity: NativeCompositeIdentity?
        package var ownedNodes: [String: NativeStableObjectIdentity]
        package var verifiedStagingManifest: NativeTreeManifest?
        package var verifiedStagingTreeIdentity: NativeTreeIdentitySnapshot?
        package var committedIdentity: NativeCompositeIdentity?
        package var commitKnownNotPerformed: Bool
    }

    package struct PreflightReceipt: Sendable, Equatable {
        package let source: URL
        package let destination: URL
        package let sourceIdentity: NativeCompositeIdentity
        package let sourceTreeIdentity: NativeTreeIdentitySnapshot
        package let destinationParentIdentity: NativeStableObjectIdentity
        package let safety: NativeSafetyCapabilities
        package let fidelityLosses: Set<MetadataField>
    }

    private let lock = NSLock()
    private var records: [Key: Record] = [:]
    private var preflightReceipts: [Key: PreflightReceipt] = [:]
    private var destinationPlans: [OperationID: [URL?]] = [:]

    package init() {}

    package func register(_ record: Record, for key: Key) throws {
        lock.lock(); defer { lock.unlock() }
        if let existing = records[key], existing.staging != record.staging ||
            existing.destination != record.destination || existing.source != record.source {
            throw NativeFileError(
                code: .invariantViolation,
                systemCode: nil,
                message: "native workspace key was rebound to different paths"
            )
        }
        records[key] = record
    }

    package func record(for key: Key) -> Record? {
        lock.lock(); defer { lock.unlock() }
        return records[key]
    }

    package func storePreflightReceipt(_ receipt: PreflightReceipt, for key: Key) throws {
        try lock.withLock {
            if let existing = preflightReceipts[key], existing != receipt {
                throw NativeFileError(
                    code: .sourceChanged,
                    systemCode: nil,
                    message: "preflight receipt was rebound to different filesystem objects"
                )
            }
            preflightReceipts[key] = receipt
        }
    }

    package func preflightReceipt(for key: Key) -> PreflightReceipt? {
        lock.lock(); defer { lock.unlock() }
        return preflightReceipts[key]
    }

    package func updateStageIdentity(_ identity: NativeCompositeIdentity?, for key: Key) {
        lock.lock(); defer { lock.unlock() }
        guard var record = records[key] else { return }
        record.stagingIdentity = identity
        records[key] = record
    }

    package func recordOwnedNode(
        relativePath: String,
        identity: NativeStableObjectIdentity,
        for key: Key
    ) throws {
        try lock.withLock {
            guard var record = records[key] else {
                throw NativeFileError(
                    code: .invariantViolation,
                    systemCode: nil,
                    message: "staging ownership record is unavailable"
                )
            }
            if let existing = record.ownedNodes[relativePath], existing != identity {
                throw NativeFileError(
                    code: .recoveryRequired,
                    systemCode: nil,
                    message: "staging node identity changed while recording ownership"
                )
            }
            record.ownedNodes[relativePath] = identity
            records[key] = record
        }
    }

    package func recordVerifiedStaging(
        manifest: NativeTreeManifest,
        treeIdentity: NativeTreeIdentitySnapshot,
        for key: Key
    ) {
        lock.lock(); defer { lock.unlock() }
        guard var record = records[key] else { return }
        record.verifiedStagingManifest = manifest
        record.verifiedStagingTreeIdentity = treeIdentity
        records[key] = record
    }

    package func resetStagingOwnership(for key: Key) {
        lock.lock(); defer { lock.unlock() }
        guard var record = records[key] else { return }
        record.stagingIdentity = nil
        record.ownedNodes = [:]
        record.verifiedStagingManifest = nil
        record.verifiedStagingTreeIdentity = nil
        records[key] = record
    }

    package func markCommitNotPerformed(for key: Key) {
        lock.lock(); defer { lock.unlock() }
        guard var record = records[key] else { return }
        record.stagingIdentity = nil
        record.commitKnownNotPerformed = true
        records[key] = record
    }

    package func markCommitted(_ identity: NativeCompositeIdentity, for key: Key) {
        lock.lock(); defer { lock.unlock() }
        guard var record = records[key] else { return }
        record.stagingIdentity = nil
        record.committedIdentity = identity
        record.commitKnownNotPerformed = false
        records[key] = record
    }

    package func destinationPlan(for operationID: OperationID) -> [URL?]? {
        lock.lock(); defer { lock.unlock() }
        return destinationPlans[operationID]
    }

    package func storeDestinationPlan(_ plan: [URL?], for operationID: OperationID) {
        lock.lock(); defer { lock.unlock() }
        if destinationPlans[operationID] == nil {
            destinationPlans[operationID] = plan
        }
    }

    package func updateDestination(_ destination: URL, for key: Key) {
        lock.lock(); defer { lock.unlock() }
        guard var record = records[key] else { return }
        let previous = record.destination
        record.destination = destination
        records[key] = record
        if var plan = destinationPlans[key.operationID],
           let index = plan.indices.first(where: { plan[$0] == previous }) {
            plan[index] = destination
            destinationPlans[key.operationID] = plan
        }
    }
}

/// Deletes only nodes whose identities are present in the process-local
/// ownership record. All lookup and mutation operations are anchored to
/// directory descriptors; a path-based recursive remove is intentionally not
/// used because it can cross an identity check/delete race.
package enum NativeOwnedStageCleanup {
    @discardableResult
    package static func remove(
        record: NativeCopyWorkspaceRegistry.Record,
        requireCompositeRootIdentity: Bool,
        beforeDeletion: () throws -> Void = {},
        beforeNodeUnlink: (String, URL) throws -> Void = { _, _ in }
    ) throws -> Bool {
        if record.commitKnownNotPerformed, record.ownedNodes.isEmpty {
            return false
        }
        let stageName = record.staging.lastPathComponent
        let parentURL = record.staging.deletingLastPathComponent()
        let parent: NativeDirectoryHandle
        do {
            parent = try NativeDirectoryHandle.openAnchored(parentURL)
        } catch let native as NativeFileError
            where native.systemCode == ENOENT || native.systemCode == ENOTDIR {
            throw NativeFileError(
                code: .recoveryRequired,
                systemCode: native.systemCode,
                message: "authorized staging parent is no longer reachable"
            )
        }
        let actualParent = try NativePathInspector.stableIdentity(
            fileDescriptor: parent.fileDescriptor,
            volumeUUID: record.stagingParentIdentity.volumeUUID,
            diagnosticPath: parentURL.path
        )
        guard actualParent == record.stagingParentIdentity else {
            throw NativeFileError(
                code: .recoveryRequired,
                systemCode: nil,
                message: "staging parent identity changed before cleanup"
            )
        }

        var rootInfo = stat()
        guard fstatat(
            parent.fileDescriptor, stageName, &rootInfo, AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            if errno == ENOENT { return false }
            throw NativeFileError.fromErrno(
                errno, path: record.staging.path, operation: "inspect anchored staging root"
            )
        }
        guard let expectedRoot = record.ownedNodes["."] else {
            throw NativeFileError(
                code: .recoveryRequired,
                systemCode: nil,
                message: "staging exists without an owned root identity"
            )
        }
        let anchoredRoot = record.staging
        let actualRoot = try NativePathInspector.stableIdentity(
            parentFileDescriptor: parent.fileDescriptor,
            name: stageName,
            volumeUUID: expectedRoot.volumeUUID,
            diagnosticPath: anchoredRoot.path
        )
        guard actualRoot == expectedRoot else {
            throw NativeFileError(
                code: .recoveryRequired,
                systemCode: nil,
                message: "staging root identity changed before cleanup"
            )
        }
        if requireCompositeRootIdentity {
            guard let expectedComposite = record.stagingIdentity else {
                throw NativeFileError(
                    code: .recoveryRequired,
                    systemCode: nil,
                    message: "staging exists without a captured composite identity"
                )
            }
            let actualComposite = try NativePathInspector.identity(
                parentFileDescriptor: parent.fileDescriptor,
                name: stageName,
                volumeUUID: expectedComposite.volumeUUID,
                diagnosticPath: anchoredRoot.path
            )
            guard actualComposite == expectedComposite else {
                throw NativeFileError(
                    code: .recoveryRequired,
                    systemCode: nil,
                    message: "staging composite identity changed before cleanup"
                )
            }
        }

        let currentTree = try NativeTreeIdentitySnapshot.capture(root: anchoredRoot)
        guard currentTree.stableEntries == record.ownedNodes else {
            throw NativeFileError(
                code: .recoveryRequired,
                systemCode: nil,
                message: "staging contains an unowned, missing, or replaced node"
            )
        }
        if let verifiedIdentity = record.verifiedStagingTreeIdentity,
           currentTree != verifiedIdentity {
            throw NativeFileError(
                code: .recoveryRequired,
                systemCode: nil,
                message: "verified staging tree identity changed before cleanup"
            )
        }
        if let verifiedManifest = record.verifiedStagingManifest {
            let includeDigests = verifiedManifest.entries.contains {
                $0.contentSHA256 != nil
            }
            let currentManifest = try NativeTreeManifest.capture(
                root: anchoredRoot,
                includeContentDigests: includeDigests
            )
            guard currentManifest == verifiedManifest else {
                throw NativeFileError(
                    code: .recoveryRequired,
                    systemCode: nil,
                    message: "verified staging manifest changed before cleanup"
                )
            }
        }
        try beforeDeletion()
        let pathParent = try NativeDirectoryHandle.openAnchored(parentURL)
        let pathParentIdentity = try NativePathInspector.stableIdentity(
            fileDescriptor: pathParent.fileDescriptor,
            volumeUUID: record.stagingParentIdentity.volumeUUID,
            diagnosticPath: parentURL.path
        )
        guard pathParentIdentity == record.stagingParentIdentity else {
            throw NativeFileError(
                code: .recoveryRequired,
                systemCode: nil,
                message: "staging parent path moved before cleanup mutation"
            )
        }

        let rootDirectory: NativeDirectoryHandle?
        if expectedRoot.nodeType == UInt32(S_IFDIR) {
            rootDirectory = try parent.openChildDirectory(
                named: stageName,
                diagnosticPath: anchoredRoot.path
            )
            let openedRoot = try NativePathInspector.stableIdentity(
                fileDescriptor: rootDirectory!.fileDescriptor,
                volumeUUID: expectedRoot.volumeUUID,
                diagnosticPath: anchoredRoot.path
            )
            guard openedRoot == expectedRoot else {
                throw NativeFileError(
                    code: .recoveryRequired,
                    systemCode: nil,
                    message: "staging root changed while opening cleanup descriptor"
                )
            }
        } else {
            rootDirectory = nil
        }

        let orderedPaths = record.ownedNodes.keys.sorted {
            let leftDepth = $0 == "." ? 0 : $0.split(separator: "/").count
            let rightDepth = $1 == "." ? 0 : $1.split(separator: "/").count
            if leftDepth != rightDepth { return leftDepth > rightDepth }
            return $0 > $1
        }
        for relativePath in orderedPaths {
            guard let expected = record.ownedNodes[relativePath] else { continue }
            let deletionParent: NativeDirectoryHandle
            let name: String
            let diagnosticPath: String
            if relativePath == "." {
                deletionParent = parent
                name = stageName
                diagnosticPath = anchoredRoot.path
            } else {
                guard let rootDirectory else {
                    throw NativeFileError(
                        code: .recoveryRequired,
                        systemCode: nil,
                        message: "non-directory staging root owns descendant nodes"
                    )
                }
                let components = relativePath.split(separator: "/").map(String.init)
                name = components.last!
                var current = try rootDirectory.duplicate()
                var traversed: [String] = []
                for component in components.dropLast() {
                    traversed.append(component)
                    let nextPath = traversed.joined(separator: "/")
                    guard let expectedDirectory = record.ownedNodes[nextPath] else {
                        throw NativeFileError(
                            code: .recoveryRequired,
                            systemCode: nil,
                            message: "cleanup parent is absent from the ownership record"
                        )
                    }
                    current = try current.openChildDirectory(
                        named: component,
                        diagnosticPath: anchoredRoot
                            .appendingPathComponent(nextPath).path
                    )
                    let actualDirectory = try NativePathInspector.stableIdentity(
                        fileDescriptor: current.fileDescriptor,
                        volumeUUID: expectedDirectory.volumeUUID,
                        diagnosticPath: anchoredRoot
                            .appendingPathComponent(nextPath).path
                    )
                    guard actualDirectory == expectedDirectory else {
                        throw NativeFileError(
                            code: .recoveryRequired,
                            systemCode: nil,
                            message: "cleanup parent identity changed"
                        )
                    }
                }
                deletionParent = current
                diagnosticPath = anchoredRoot.appendingPathComponent(relativePath).path
            }

            // Faults and cancellation may run only before this checkpoint.
            // The final identity read and unlink remain adjacent and resolve
            // the same name through the same already-validated parent FD.
            try beforeNodeUnlink(
                relativePath,
                URL(fileURLWithPath: diagnosticPath)
            )
            let actual = try NativePathInspector.stableIdentity(
                parentFileDescriptor: deletionParent.fileDescriptor,
                name: name,
                volumeUUID: expected.volumeUUID,
                diagnosticPath: diagnosticPath
            )
            guard actual == expected else {
                throw NativeFileError(
                    code: .recoveryRequired,
                    systemCode: nil,
                    message: "owned staging node changed immediately before cleanup"
                )
            }
            let flags = expected.nodeType == UInt32(S_IFDIR) ? AT_REMOVEDIR : 0
            guard unlinkat(deletionParent.fileDescriptor, name, flags) == 0 else {
                throw NativeFileError.fromErrno(
                    errno, path: diagnosticPath, operation: "anchored staging cleanup"
                )
            }
            var remaining = stat()
            if fstatat(
                deletionParent.fileDescriptor, name, &remaining, AT_SYMLINK_NOFOLLOW
            ) == 0 || errno != ENOENT {
                throw NativeFileError(
                    code: .recoveryRequired,
                    systemCode: errno,
                    message: "staging name was recreated or remained after cleanup"
                )
            }
        }
        return true
    }
}

package struct NativeCopyFileSystemAdapter: FileSystemAdapter {
    package let registry: NativeCopyWorkspaceRegistry

    package init(registry: NativeCopyWorkspaceRegistry) {
        self.registry = registry
    }

    package func preflight(
        operationID: OperationID,
        itemID: OperationItemID,
        request: OperationRequest,
        itemIndex: Int,
        priorDecision: ResolvedOperationDecision?,
        controls: ExecutionControls
    ) async throws -> PreflightDisposition {
        guard request.kind == .copy else {
            return .failure(FileOperationFailure(
                code: .featureDisabled,
                diagnostic: "M2 native adapter only accepts copy requests",
                retryable: false
            ))
        }
        guard request.sources.indices.contains(itemIndex) else {
            return .failure(FileOperationFailure(
                code: .validation,
                diagnostic: "copy item index is out of range",
                retryable: false
            ))
        }
        if priorDecision != nil, priorDecision?.identityDigest == nil {
            return .failure(FileOperationFailure(
                code: .decisionExpired,
                diagnostic: "resolved decision lacks its item identity digest",
                retryable: true
            ))
        }
        await controls.checkpoint()
        if await controls.isCancelled() { return .skip }

        let source = request.sources[itemIndex].standardizedFileURL
        let rawProjections = RequestValidator.projectedDestinations(request)
        guard rawProjections.indices.contains(itemIndex),
              let rawProjected = rawProjections[itemIndex] else {
            return .failure(FileOperationFailure(
                code: .validation,
                diagnostic: "copy destination projection is unavailable",
                retryable: false
            ))
        }

        do {
            let sourceIdentity = try NativePathInspector.identity(at: source)
            var destination = rawProjected.standardizedFileURL
            let destinationParent = destination.deletingLastPathComponent()
            let safety = NativePathInspector.safetyCapabilities(
                source: source,
                destinationParent: destinationParent
            )
            if let reason = safety.firstBlockingReason {
                return .failure(FileOperationFailure(
                    code: .serviceSafeMode,
                    diagnostic: reason,
                    retryable: false
                ))
            }
            let fidelity = NativePathInspector.fidelityCapabilities(
                source: source,
                destinationParent: destinationParent
            )
            let fidelityLosses = fidelity.unavailableFields
            if !fidelityLosses.isEmpty {
                let identityDigest = sourceIdentity.digest + "|fidelity|" +
                    fidelityLosses.map(\.rawValue).sorted().joined(separator: ",")
                if let resolvedDigest = priorDecision?.identityDigest,
                   resolvedDigest != identityDigest {
                    return .failure(FileOperationFailure(
                        code: .decisionExpired,
                        diagnostic: "metadata decision identity changed while waiting",
                        retryable: true
                    ))
                }
                switch priorDecision?.decision {
                case let .approvePortable(losses, scope)
                    where losses == fidelityLosses &&
                        (scope == .item || scope == .remainingItems):
                    break
                case .cancel:
                    return .skip
                case .stop:
                    return .failure(FileOperationFailure(
                        code: .unsupportedMetadata,
                        diagnostic: "copy stopped because Finder metadata fidelity is unavailable",
                        retryable: false
                    ))
                case nil:
                    return .decision(PreflightDecision(
                        allowed: [
                            .approvePortable(losses: fidelityLosses, scope: .item),
                            .stop,
                            .cancel
                        ],
                        metadataLosses: fidelityLosses,
                        identityDigest: identityDigest
                    ))
                default:
                    return .decision(PreflightDecision(
                        allowed: [
                            .approvePortable(losses: fidelityLosses, scope: .item),
                            .stop,
                            .cancel
                        ],
                        metadataLosses: fidelityLosses,
                        identityDigest: identityDigest
                    ))
                }
            }
            let sourceManifest = try NativeTreeManifest.capture(
                root: source,
                includeContentDigests: false
            )
            let sourceTreeIdentity = try NativeTreeIdentitySnapshot.capture(root: source)
            let requiredAllocation = sourceManifest.entries.reduce(Int64(0)) {
                $0 + max(0, $1.allocatedBytes)
            }
            let availableAllocation = try availableBytes(at: destinationParent)
            let metadataReserve: Int64 = 4 * 1024 * 1024
            if requiredAllocation > max(0, availableAllocation - metadataReserve) {
                return .failure(FileOperationFailure(
                    code: .noSpace,
                    systemCode: ENOSPC,
                    diagnostic: "destination volume lacks space for the staged copy",
                    retryable: true
                ))
            }

            let parentFD = open(destinationParent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard parentFD >= 0 else {
                throw NativeFileError.fromErrno(
                    errno, path: destinationParent.path, operation: "open destination parent"
                )
            }
            close(parentFD)

            let projections = try destinationPlan(
                operationID: operationID,
                request: request,
                rawProjections: rawProjections
            )
            guard projections.indices.contains(itemIndex),
                  let planned = projections[itemIndex] else {
                throw FileOperationFailure(
                    code: .validation,
                    diagnostic: "copy destination plan is incomplete",
                    retryable: false
                )
            }
            destination = planned

            let destinationExists = lstatExists(destination)
            if destinationExists {
                let destinationIdentity = try NativePathInspector.identity(at: destination)
                let identityDigest = sourceIdentity.digest + "|" + destinationIdentity.digest
                if let resolvedDigest = priorDecision?.identityDigest,
                   resolvedDigest != identityDigest {
                    return .failure(FileOperationFailure(
                        code: .decisionExpired,
                        diagnostic: "conflict decision identity changed while waiting",
                        retryable: true
                    ))
                }
                let decision = priorDecision?.decision ?? policyDecision(request.conflictPolicy)
                switch decision {
                case let .skip(scope) where scope == .item || scope == .remainingItems:
                    return .skip
                case let .keepBoth(scope) where scope == .item || scope == .remainingItems:
                    destination = uniqueDestination(for: destination)
                case .stop:
                    return .failure(FileOperationFailure(
                        code: .destinationChanged,
                        diagnostic: "copy stopped because the destination exists",
                        retryable: true
                    ))
                case .replace, .merge:
                    return .failure(FileOperationFailure(
                        code: .featureDisabled,
                        diagnostic: "replace and merge decisions remain disabled until M3/M4",
                        retryable: false
                    ))
                case .cancel:
                    return .skip
                case .approvePortable, nil:
                    return .decision(PreflightDecision(
                        allowed: [
                            .skip(scope: .item),
                            .keepBoth(scope: .item),
                            .stop,
                            .cancel
                        ],
                        identityDigest: identityDigest
                    ))
                default:
                    return .failure(FileOperationFailure(
                        code: .decisionExpired,
                        diagnostic: "unsupported copy conflict decision",
                        retryable: false
                    ))
                }
            }

            await controls.checkpoint()
            if await controls.isCancelled() { return .skip }
            let key = NativeCopyWorkspaceRegistry.Key(
                operationID: operationID,
                itemID: itemID
            )
            try registry.storePreflightReceipt(.init(
                source: source,
                destination: destination,
                sourceIdentity: sourceIdentity,
                sourceTreeIdentity: sourceTreeIdentity,
                destinationParentIdentity: try NativePathInspector.stableIdentity(
                    at: destination.deletingLastPathComponent()
                ),
                safety: safety,
                fidelityLosses: fidelityLosses
            ), for: key)
            return .ready(
                destinations: replaceProjection(projections, at: itemIndex, with: destination),
                moveTopology: .sameVolume
            )
        } catch let native as NativeFileError {
            return .failure(native.failure())
        } catch let failure as FileOperationFailure {
            return .failure(failure)
        } catch {
            return .failure(FileOperationFailure(
                code: .invariantViolation,
                diagnostic: String(describing: error),
                retryable: false
            ))
        }
    }

    package func recoverOwnedStaging(
        operationID: OperationID,
        itemID: OperationItemID,
        effectID: UUID
    ) async -> ExecutionRecoveryOutcome {
        _ = effectID
        let key = NativeCopyWorkspaceRegistry.Key(operationID: operationID, itemID: itemID)
        guard let record = registry.record(for: key) else {
            return .failedBeforeEffect(FileOperationFailure(
                code: .recoveryRequired,
                operationID: operationID,
                itemID: itemID,
                diagnostic: "no process-local ownership record for staging cleanup",
                retryable: false
            ))
        }
        do {
            let removed = try NativeOwnedStageCleanup.remove(
                record: record,
                requireCompositeRootIdentity: true
            )
            if !removed {
                registry.resetStagingOwnership(for: key)
                registry.markCommitNotPerformed(for: key)
                return .completed
            }
            registry.updateStageIdentity(nil, for: key)
            registry.resetStagingOwnership(for: key)
            return .completed
        } catch let native as NativeFileError {
            return .ambiguous(native.failure(operationID: operationID, itemID: itemID))
        } catch {
            return .ambiguous(FileOperationFailure(
                code: .recoveryRequired,
                operationID: operationID,
                itemID: itemID,
                diagnostic: String(describing: error),
                retryable: false
            ))
        }
    }

    package func inspectOwnedStaging(
        operationID: OperationID,
        itemID: OperationItemID,
        effectID: UUID
    ) async -> ExecutionRecoveryInspection {
        _ = effectID
        let key = NativeCopyWorkspaceRegistry.Key(operationID: operationID, itemID: itemID)
        guard let record = registry.record(for: key) else {
            return .unknown(FileOperationFailure(
                code: .recoveryRequired,
                operationID: operationID,
                itemID: itemID,
                diagnostic: "staging ownership record is unavailable",
                retryable: false
            ))
        }
        do {
            guard lstatExists(record.staging) else {
                guard try NativePathInspector.isAnchoredEntryAbsent(
                    record.staging,
                    expectedParent: record.stagingParentIdentity
                ) else {
                    return .unknown(FileOperationFailure(
                        code: .recoveryRequired,
                        operationID: operationID,
                        itemID: itemID,
                        diagnostic: "staging appeared during its anchored absence check",
                        retryable: false
                    ))
                }
                return .completed
            }
            guard let expected = record.stagingIdentity,
                  try NativePathInspector.identity(at: record.staging) == expected,
                  try NativeTreeIdentitySnapshot.capture(root: record.staging).stableEntries ==
                    record.ownedNodes else {
                return .unknown(FileOperationFailure(
                    code: .sourceChanged,
                    operationID: operationID,
                    itemID: itemID,
                    diagnostic: "staging identity is not uniquely owned",
                    retryable: false
                ))
            }
            return .notPerformed
        } catch {
            return .unknown(FileOperationFailure(
                code: .recoveryRequired,
                operationID: operationID,
                itemID: itemID,
                diagnostic: String(describing: error),
                retryable: false
            ))
        }
    }

    private func policyDecision(_ policy: ConflictPolicy) -> OperationDecision? {
        switch policy {
        case .ask: return nil
        case .skip: return .skip(scope: .item)
        case .keepBoth: return .keepBoth(scope: .item)
        case .replace: return .replace(scope: .item)
        case .merge: return .merge(scope: .item)
        case .stop: return .stop
        }
    }

    private func availableBytes(at url: URL) throws -> Int64 {
        var facts = statfs()
        guard statfs(url.path, &facts) == 0 else {
            throw NativeFileError.fromErrno(
                errno,
                path: url.path,
                operation: "read destination capacity"
            )
        }
        return Int64(facts.f_bavail) * Int64(facts.f_bsize)
    }

    private func destinationPlan(
        operationID: OperationID,
        request: OperationRequest,
        rawProjections: [URL?]
    ) throws -> [URL?] {
        if let existing = registry.destinationPlan(for: operationID) { return existing }
        let projected = rawProjections.compactMap { $0?.standardizedFileURL }
        guard projected.count == request.sources.count else {
            throw FileOperationFailure(
                code: .validation,
                diagnostic: "copy destination projection contains a missing path",
                retryable: false
            )
        }

        var occupiedByParent: [String: Set<String>] = [:]
        var caseSensitiveByParent: [String: Bool] = [:]
        var planned: [URL?] = []
        planned.reserveCapacity(projected.count)

        for (index, rawDestination) in projected.enumerated() {
            let parent = rawDestination.deletingLastPathComponent()
            let parentPath = parent.path
            let caseSensitive: Bool
            if let cached = caseSensitiveByParent[parentPath] {
                caseSensitive = cached
            } else {
                let values = try parent.resourceValues(forKeys: [
                    .volumeSupportsCaseSensitiveNamesKey
                ])
                guard let supported = values.volumeSupportsCaseSensitiveNames else {
                    throw FileOperationFailure(
                        code: .destinationChanged,
                        diagnostic: "destination name equivalence is unknown",
                        retryable: false
                    )
                }
                caseSensitive = supported
                caseSensitiveByParent[parentPath] = supported
            }
            if occupiedByParent[parentPath] == nil {
                let names = try FileManager.default.contentsOfDirectory(atPath: parentPath)
                occupiedByParent[parentPath] = Set(names.map {
                    nameEquivalenceKey($0, caseSensitive: caseSensitive)
                })
            }
            var occupied = occupiedByParent[parentPath, default: []]
            var candidate = rawDestination
            var key = nameEquivalenceKey(
                candidate.lastPathComponent,
                caseSensitive: caseSensitive
            )
            let conflicts = occupied.contains(key)
            if conflicts, request.conflictPolicy == .keepBoth {
                candidate = uniqueDestination(for: rawDestination) { proposed in
                    !occupied.contains(nameEquivalenceKey(
                        proposed.lastPathComponent,
                        caseSensitive: caseSensitive
                    ))
                }
                key = nameEquivalenceKey(
                    candidate.lastPathComponent,
                    caseSensitive: caseSensitive
                )
            } else if conflicts, request.sources.count > 1,
                      [.ask, .stop, .replace, .merge].contains(request.conflictPolicy) {
                throw FileOperationFailure(
                    code: request.conflictPolicy == .replace || request.conflictPolicy == .merge
                        ? .featureDisabled : .destinationChanged,
                    diagnostic: "multi-source destination name collision at item \(index)",
                    retryable: request.conflictPolicy == .ask
                )
            }
            occupied.insert(key)
            occupiedByParent[parentPath] = occupied
            planned.append(candidate)
        }
        registry.storeDestinationPlan(planned, for: operationID)
        return registry.destinationPlan(for: operationID) ?? planned
    }

    private func nameEquivalenceKey(_ name: String, caseSensitive: Bool) -> String {
        let canonical = name.precomposedStringWithCanonicalMapping
        guard !caseSensitive else { return canonical }
        return canonical.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private func replaceProjection(
        _ projections: [URL?], at index: Int, with destination: URL
    ) -> [URL?] {
        var updated = projections
        updated[index] = destination
        return updated
    }

    private func uniqueDestination(for destination: URL) -> URL {
        uniqueDestination(for: destination) { !lstatExists($0) }
    }

    private func uniqueDestination(
        for destination: URL,
        isAvailable: (URL) -> Bool
    ) -> URL {
        let parent = destination.deletingLastPathComponent()
        let extensionName = destination.pathExtension
        let stem = extensionName.isEmpty
            ? destination.lastPathComponent
            : destination.deletingPathExtension().lastPathComponent
        for suffix in 1...10_000 {
            let label = suffix == 1 ? "\(stem) copy" : "\(stem) copy \(suffix)"
            let candidate = parent.appendingPathComponent(label)
                .appendingPathExtension(extensionName)
            if isAvailable(candidate) { return candidate }
        }
        return parent.appendingPathComponent("\(stem) copy \(UUID().uuidString)")
            .appendingPathExtension(extensionName)
    }
}

package func lstatExists(_ url: URL) -> Bool {
    var info = stat()
    if lstat(url.path, &info) == 0 { return true }
    return errno != ENOENT
}
