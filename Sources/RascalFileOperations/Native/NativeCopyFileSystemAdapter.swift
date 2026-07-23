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
        package var stagingIdentity: NativeCompositeIdentity?
        package var committedIdentity: NativeCompositeIdentity?
        package var commitKnownNotPerformed: Bool
    }

    private let lock = NSLock()
    private var records: [Key: Record] = [:]
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

    package func updateStageIdentity(_ identity: NativeCompositeIdentity?, for key: Key) {
        lock.lock(); defer { lock.unlock() }
        guard var record = records[key] else { return }
        record.stagingIdentity = identity
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

package struct NativeCopyFileSystemAdapter: FileSystemAdapter {
    package let registry: NativeCopyWorkspaceRegistry

    package init(registry: NativeCopyWorkspaceRegistry) {
        self.registry = registry
    }

    package func preflight(
        operationID: OperationID,
        request: OperationRequest,
        itemIndex: Int,
        priorDecision: OperationDecision?,
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
                switch priorDecision {
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
                        identityDigest: sourceIdentity.digest + "|fidelity|" +
                            fidelityLosses.map(\.rawValue).sorted().joined(separator: ",")
                    ))
                default:
                    return .failure(FileOperationFailure(
                        code: .decisionExpired,
                        diagnostic: "metadata decision does not match current fidelity losses",
                        retryable: false
                    ))
                }
            }
            let sourceManifest = try NativeTreeManifest.capture(
                root: source,
                includeContentDigests: false
            )
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
                let decision = priorDecision ?? policyDecision(request.conflictPolicy)
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
                case .approvePortable:
                    break
                case .cancel:
                    return .skip
                case nil:
                    let destinationIdentity = try NativePathInspector.identity(at: destination)
                    return .decision(PreflightDecision(
                        allowed: [
                            .skip(scope: .item),
                            .keepBoth(scope: .item),
                            .stop,
                            .cancel
                        ],
                        identityDigest: sourceIdentity.digest + "|" + destinationIdentity.digest
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
        guard lstatExists(record.staging) else { return .completed }
        do {
            guard let expected = record.stagingIdentity else {
                return .ambiguous(FileOperationFailure(
                    code: .recoveryRequired,
                    operationID: operationID,
                    itemID: itemID,
                    diagnostic: "staging exists without a captured ownership identity",
                    retryable: false
                ))
            }
            let actual = try NativePathInspector.identity(at: record.staging)
            guard actual == expected else {
                return .ambiguous(FileOperationFailure(
                    code: .sourceChanged,
                    operationID: operationID,
                    itemID: itemID,
                    diagnostic: "staging identity changed before cleanup",
                    retryable: false
                ))
            }
            try FileManager.default.removeItem(at: record.staging)
            guard !lstatExists(record.staging) else {
                return .ambiguous(FileOperationFailure(
                    code: .recoveryRequired,
                    operationID: operationID,
                    itemID: itemID,
                    diagnostic: "staging still exists after cleanup",
                    retryable: false
                ))
            }
            registry.updateStageIdentity(nil, for: key)
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
        guard lstatExists(record.staging) else { return .completed }
        do {
            guard let expected = record.stagingIdentity,
                  try NativePathInspector.identity(at: record.staging) == expected else {
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
