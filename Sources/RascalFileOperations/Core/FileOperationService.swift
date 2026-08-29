import Foundation

private struct ManagedItem {
    var id: OperationItemID
    var source: URL
    var destination: URL?
    var state: OperationItemState
    var progress: OperationProgress
    var metadata: MetadataOutcome?
    var verification: VerificationOutcome?
    var receipt: OperationReceiptSummary?
    var failure: FileOperationFailure?

    init(_ snapshot: OperationItemSnapshot) {
        id = snapshot.id
        source = snapshot.source
        destination = snapshot.destination
        state = snapshot.state
        progress = snapshot.progress
        metadata = snapshot.metadata
        verification = snapshot.verification
        receipt = snapshot.receipt
        failure = snapshot.failure
    }

    var snapshot: OperationItemSnapshot {
        OperationItemSnapshot(id: id, source: source, destination: destination, state: state,
                              progress: progress, metadata: metadata, verification: verification,
                              receipt: receipt, failure: failure)
    }
}

private struct ManagedOperation {
    var id: OperationID
    var request: OperationRequest
    var state: OperationState
    var latestDurableSequence: EventSequence
    var latestEmittedSequence: EventSequence
    var reservedThrough: EventSequence
    var submissionOrdinal: UInt64
    var effectiveMetadataPolicy: MetadataPolicy
    var effectiveVerificationPolicy: VerificationPolicy
    var items: [ManagedItem]
    var pendingDecision: DecisionRequest?
    var priorDecisions: [OperationItemID: ResolvedOperationDecision] = [:]
    var remainingDecision: ResolvedOperationDecision?
    var itemMetadataPolicies: [OperationItemID: MetadataPolicy] = [:]
    var remainingMetadataPolicy: MetadataPolicy?
    var terminalFailure: FileOperationFailure?
    var availableActions: [RecoveryAction]
    var sourceRetained: Bool
    var completedRecoveryActions: Set<UUID> = []
    var inProgressRecoveryActions: Set<UUID> = []
    var recoveryEffectAttempts: [UUID: [OperationItemID: RecoveryEffectAttempt]] = [:]
    var committedEffects: [OperationItemID: OperationReceiptSummary] = [:]
    var nextProgressSequence: EventSequence

    init(snapshot: OperationSnapshot, submissionOrdinal: UInt64,
         latestDurableSequence: EventSequence, latestEmittedSequence: EventSequence,
         reservedThrough: EventSequence) {
        id = snapshot.id
        request = snapshot.request
        state = snapshot.state
        self.latestDurableSequence = latestDurableSequence
        self.latestEmittedSequence = latestEmittedSequence
        self.reservedThrough = reservedThrough
        self.submissionOrdinal = submissionOrdinal
        effectiveMetadataPolicy = snapshot.effectiveMetadataPolicy
        effectiveVerificationPolicy = snapshot.effectiveVerificationPolicy
        items = snapshot.items.map(ManagedItem.init)
        pendingDecision = snapshot.pendingDecision
        remainingDecision = nil
        remainingMetadataPolicy = nil
        terminalFailure = snapshot.terminalFailure
        availableActions = snapshot.availableActions
        sourceRetained = snapshot.sourceRetained
        nextProgressSequence = reservedThrough == UInt64.max ? UInt64.max : reservedThrough + 1
    }

    init(journalOperation: JournalOperation) {
        self.init(snapshot: journalOperation.snapshot,
                  submissionOrdinal: journalOperation.submissionOrdinal,
                  latestDurableSequence: journalOperation.latestDurableSequence,
                  latestEmittedSequence: journalOperation.latestDurableSequence,
                  reservedThrough: journalOperation.reservedThrough)
        priorDecisions = journalOperation.priorDecisions
        remainingDecision = journalOperation.remainingDecision
        itemMetadataPolicies = journalOperation.itemMetadataPolicies
        remainingMetadataPolicy = journalOperation.remainingMetadataPolicy
        completedRecoveryActions = journalOperation.completedRecoveryActions
        inProgressRecoveryActions = journalOperation.inProgressRecoveryActions
        recoveryEffectAttempts = journalOperation.recoveryEffectAttempts
        committedEffects = journalOperation.committedEffects
    }

    var progress: OperationProgress {
        OperationProgress(
            bytesCompleted: items.reduce(0) { $0 + $1.progress.bytesCompleted },
            bytesTotal: items.allSatisfy({ $0.progress.bytesTotal != nil })
                ? items.reduce(0) { $0 + ($1.progress.bytesTotal ?? 0) } : nil,
            itemsCompleted: items.filter { [.completed, .skipped].contains($0.state) }.count,
            itemsTotal: items.count
        )
    }

    var hasPartialCommit: Bool {
        // Receipts are append-only audit evidence, so a successfully
        // compensated item still has one. Only uncompensated receipts count
        // toward a live partial commit; otherwise a terminal rollback would
        // incorrectly continue to advertise an outstanding final effect.
        let hasUncompensatedCommit = items.contains {
            $0.receipt != nil && $0.state != .rolledBack
        }
        return hasUncompensatedCommit && items.contains {
            ![.completed, .skipped, .rolledBack].contains($0.state)
        }
    }

    func hasResolvedRecoveryEffect(for itemID: OperationItemID,
                                   effect: ExecutionRecoveryEffect) -> Bool {
        recoveryEffectAttempts.values.contains {
            guard let attempt = $0[itemID], attempt.effect == effect else { return false }
            return attempt.result != nil
        }
    }

    var hasUnresolvedRecoveryEffects: Bool {
        recoveryEffectAttempts.values.contains { attempts in
            attempts.values.contains { $0.result == nil }
        }
    }

    var hasUnexplainedFilesystemEffect: Bool {
        if (state == .committing || items.contains(where: { $0.state == .committing })) &&
            resumableDurableReceiptProjectionIndex == nil {
            return true
        }
        return items.contains { item in
            item.state == .cleaningSource &&
                !hasResolvedRecoveryEffect(for: item.id, effect: .cleanupSource)
        }
    }

    var hasPendingStagingRecovery: Bool {
        availableActions.contains {
            if case .discardKnownStaging = $0 { return true }
            return false
        }
    }

    var hasInterruptedPrecommit: Bool {
        if resumableDurableReceiptProjectionIndex != nil { return false }
        let interruptedOperations: Set<OperationState> = [
            .staging, .paused, .metadata, .verifying
        ]
        let interruptedItems: Set<OperationItemState> = [
            .staging, .paused, .metadata, .verifying
        ]
        return interruptedOperations.contains(state) ||
            items.contains { interruptedItems.contains($0.state) }
    }

    /// A receipt-backed copy projection may be interrupted between its
    /// durable, event-emitting phase checkpoints. Those checkpoints describe
    /// an already completed external effect and are safe to resume without an
    /// executor call. Cleanup-pending receipts remain explicit recovery work.
    var resumableDurableReceiptProjectionIndex: Int? {
        let operationPhases: Set<OperationState> = [
            .preflight, .staging, .metadata, .verifying, .committing
        ]
        let itemPhases: Set<OperationItemState> = [
            .preflight, .staging, .metadata, .verifying, .committing,
            .committed, .completed
        ]
        guard operationPhases.contains(state) else { return nil }
        return items.indices.first { index in
            let item = items[index]
            guard itemPhases.contains(item.state),
                  let receipt = item.receipt, !receipt.sourceCleanupPending,
                  committedEffects[item.id] == receipt,
                  let verification = item.verification else { return false }
            guard verification.policy == effectiveVerificationPolicy else { return false }
            if item.state == .committed || item.state == .completed {
                return state == .committing
            }
            return true
        }
    }

    var snapshot: OperationSnapshot {
        OperationSnapshot(schemaVersion: 1, id: id, kind: request.kind, state: state,
                          latestSequence: latestEmittedSequence, request: request,
                          effectiveMetadataPolicy: effectiveMetadataPolicy,
                          effectiveVerificationPolicy: effectiveVerificationPolicy,
                          progress: progress, items: items.map(\.snapshot),
                          pendingDecision: pendingDecision, terminalFailure: terminalFailure,
                          availableActions: availableActions, hasPartialCommit: hasPartialCommit,
                          sourceRetained: sourceRetained)
    }

    var journalOperation: JournalOperation {
        JournalOperation(snapshot: snapshot, submissionOrdinal: submissionOrdinal,
                         latestDurableSequence: latestDurableSequence,
                         latestEmittedSequence: latestEmittedSequence,
                         reservedThrough: reservedThrough,
                         priorDecisions: priorDecisions,
                         remainingDecision: remainingDecision,
                         itemMetadataPolicies: itemMetadataPolicies,
                         remainingMetadataPolicy: remainingMetadataPolicy,
                         completedRecoveryActions: completedRecoveryActions,
                         inProgressRecoveryActions: inProgressRecoveryActions,
                         recoveryEffectAttempts: recoveryEffectAttempts,
                         committedEffects: committedEffects)
    }
}

private struct Subscriber {
    var replayOrder: [OperationID]
    var replayIndex = 0
    var replayCursor: [OperationID: EventSequence] = [:]
    var watermarks: [OperationID: EventSequence]
    var replayPage: [OperationEvent] = []
    var live: [OperationEvent] = []
    var invalid = false
    var waiter: CheckedContinuation<OperationEvent?, Never>?
}

private enum FatalServiceReason: Hashable {
    case journalUnavailable
    case journalLoadFailure(String)
    case journalMutationFailure(String)
    case sequenceExhausted(OperationID)
    case invalidRecoverySelection(OperationID)
}

private enum RecoveryRequiredReason: Hashable {
    case durableCommand(OperationID)
    case unresolvedEffect(OperationID)
    case unexplainedFilesystemEffect(OperationID)
}

private enum ServiceMode {
    case normal
    case recoveryRequired(Set<RecoveryRequiredReason>)
    case fatal(Set<FatalServiceReason>)
}

private struct RecoveryLease: Equatable {
    let invocationID: UUID
    let actionID: UUID
}

public actor FileOperationService {
    private let dependencies: ServiceDependencies
    private var operations: [OperationID: ManagedOperation] = [:]
    private var controls: [OperationID: ExecutionControls] = [:]
    private var activeID: OperationID?
    private var subscribers: [UUID: Subscriber] = [:]
    private var serviceMode: ServiceMode
    /// In-memory authorization that survives actor reentrancy but never a
    /// restart. Durable command selection remains the source of truth.
    private var recoveryLeases: [OperationID: RecoveryLease] = [:]

    public init(configuration: ServiceConfiguration = .default) throws {
        _ = configuration
        let dependencies = ServiceDependencies(
            journal: UnavailableOperationJournal(), fileSystem: UnavailableFileSystemAdapter(),
            clock: SystemOperationClock(), ids: RandomOperationIDGenerator(), digest: NoopDigestProvider(),
            failpoints: NoopFailpointController(), executor: UnavailableExecutor(),
            diagnostics: NoopDiagnosticSink()
        )
        self.dependencies = dependencies
        self.serviceMode = .fatal([.journalUnavailable])
    }

    /// M2 debug-only vertical slice. The journal is intentionally volatile;
    /// callers must keep this factory behind the exact compile/runtime gate and
    /// must not describe it as restart- or crash-durable.
    package static func makeVolatileNativeCopy(
        faults: NativeCopyFaultController = NativeCopyFaultController(),
        serviceFailpoints: any FailpointController = NoopFailpointController()
    ) throws -> FileOperationService {
        let registry = NativeCopyWorkspaceRegistry()
        return try FileOperationService(dependencies: ServiceDependencies(
            journal: VolatileOperationJournal(),
            fileSystem: NativeCopyFileSystemAdapter(registry: registry),
            clock: SystemOperationClock(),
            ids: RandomOperationIDGenerator(),
            digest: CommonCryptoDigestProvider(),
            failpoints: serviceFailpoints,
            executor: NativeCopyExecutor(registry: registry, faults: faults),
            diagnostics: NoopDiagnosticSink()
        ))
    }

    package init(dependencies: ServiceDependencies) throws {
        self.dependencies = dependencies
        self.serviceMode = .normal
        var loadedOperations: [OperationID: ManagedOperation] = [:]
        var fatalReasons: Set<FatalServiceReason> = []
        var recoveryReasons: Set<RecoveryRequiredReason> = []
        if !dependencies.journal.isWritable {
            fatalReasons.insert(.journalUnavailable)
        }
        do {
            for stored in try dependencies.journal.loadOperations() {
                let operation = ManagedOperation(journalOperation: stored)
                loadedOperations[operation.id] = operation
                if operation.reservedThrough == UInt64.max {
                    fatalReasons.insert(.sequenceExhausted(operation.id))
                    dependencies.diagnostics.record(.journalFailure("event sequence space exhausted"))
                }
                if operation.inProgressRecoveryActions.count > 1 {
                    fatalReasons.insert(.invalidRecoverySelection(operation.id))
                    dependencies.diagnostics.record(.journalFailure(
                        "multiple durable recovery commands selected for one operation"
                    ))
                } else if !operation.inProgressRecoveryActions.isEmpty {
                    recoveryReasons.insert(.durableCommand(operation.id))
                }
                if operation.hasUnresolvedRecoveryEffects {
                    recoveryReasons.insert(.unresolvedEffect(operation.id))
                }
                if operation.hasUnexplainedFilesystemEffect {
                    recoveryReasons.insert(.unexplainedFilesystemEffect(operation.id))
                    dependencies.diagnostics.record(.journalFailure(
                        "ambiguous in-flight filesystem effect requires recovery inspection"
                    ))
                }
                if operation.state == .recoveryRequired {
                    recoveryReasons.insert(.unexplainedFilesystemEffect(operation.id))
                }
                if operation.hasPendingStagingRecovery {
                    recoveryReasons.insert(.unexplainedFilesystemEffect(operation.id))
                }
                if operation.hasInterruptedPrecommit {
                    recoveryReasons.insert(.unexplainedFilesystemEffect(operation.id))
                }
            }
        } catch {
            fatalReasons.insert(.journalLoadFailure(String(describing: error)))
            dependencies.diagnostics.record(.journalFailure(String(describing: error)))
        }
        operations = loadedOperations
        if !fatalReasons.isEmpty {
            serviceMode = .fatal(fatalReasons)
        } else if !recoveryReasons.isEmpty {
            serviceMode = .recoveryRequired(recoveryReasons)
        } else {
            serviceMode = .normal
        }
        if fatalReasons.isEmpty && recoveryReasons.isEmpty {
            Task { await self.runScheduler() }
        }
    }

    public func submit(_ request: OperationRequest) async throws -> OperationID {
        // Structural validation intentionally precedes the safe-mode check and every adapter/journal call.
        try RequestValidator.validate(request)
        if [.merge, .trash, .create].contains(request.kind) {
            throw FileOperationFailure(code: .featureDisabled,
                                       diagnostic: "\(request.kind.rawValue) is deferred to M5",
                                       retryable: false)
        }
        guard normalWritesAllowed else {
            throw FileOperationFailure(code: .serviceSafeMode,
                                       diagnostic: "File operation service is in read-only safe mode",
                                       retryable: false)
        }

        let id = dependencies.ids.operationID()
        let destinations = RequestValidator.projectedDestinations(request)
        let items = request.sources.enumerated().map { index, source in
            OperationItemSnapshot(
                id: dependencies.ids.itemID(), source: source,
                destination: destinations.indices.contains(index) ? destinations[index] : nil,
                state: .pending,
                progress: OperationProgress(bytesCompleted: 0, bytesTotal: nil,
                                            itemsCompleted: 0, itemsTotal: 1),
                metadata: nil, verification: nil, receipt: nil, failure: nil
            )
        }
        let initial = OperationSnapshot(
            schemaVersion: 1, id: id, kind: request.kind, state: .planned, latestSequence: 0,
            request: request, effectiveMetadataPolicy: request.metadataPolicy,
            effectiveVerificationPolicy: request.verificationPolicy,
            progress: OperationProgress(bytesCompleted: 0, bytesTotal: nil,
                                        itemsCompleted: 0, itemsTotal: items.count),
            items: items, pendingDecision: nil, terminalFailure: nil, availableActions: [],
            hasPartialCommit: false, sourceRetained: false
        )
        do {
            let admission = try dependencies.journal.admit(initial, at: dependencies.clock.now())
            let stored = admission.operation
            operations[id] = ManagedOperation(journalOperation: stored)
            broadcast(admission.event)
        } catch let failure as FileOperationFailure {
            throw failure
        } catch {
            throw FileOperationFailure(code: .journalFailure, operationID: id,
                                       diagnostic: String(describing: error), retryable: false)
        }
        await dependencies.failpoints.hit(.plannedPersisted, operationID: id)
        Task { await self.runScheduler() }
        return id
    }

    public func snapshot(_ id: OperationID) async throws -> OperationSnapshot {
        guard let operation = operations[id] else {
            throw FileOperationFailure(code: .validation, operationID: id,
                                       diagnostic: "unknown operation ID", retryable: false)
        }
        return operation.snapshot
    }

    public func events() -> AsyncStream<OperationEvent> {
        let id = UUID()
        let ordered = operations.values.sorted { $0.submissionOrdinal < $1.submissionOrdinal }
        let watermarks = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0.latestDurableSequence) })
        subscribers[id] = Subscriber(replayOrder: ordered.map(\.id), watermarks: watermarks)
        return AsyncStream(unfolding: { [weak self] in
            guard let self else { return nil }
            return await self.nextEvent(subscriberID: id)
        }, onCancel: { [weak self] in
            Task { await self?.removeSubscriber(id) }
        })
    }

    public func resolve(_ token: DecisionToken, with decision: OperationDecision) async throws {
        try requireNormalServiceMode(command: "resolve")
        guard let pair = operations.first(where: { $0.value.pendingDecision?.token == token }) else {
            throw FileOperationFailure(code: .decisionExpired,
                                       diagnostic: "unknown or consumed decision token", retryable: false)
        }
        let id = pair.key
        guard let request = pair.value.pendingDecision,
              request.allowed.contains(decision) else {
            throw FileOperationFailure(code: .decisionExpired, operationID: id,
                                       diagnostic: "decision no longer matches durable state", retryable: false)
        }
        let itemIndex = pair.value.items.firstIndex { $0.id == request.itemID }!
        try requireNormalOwnership(id: id, command: "resolve",
                                   expectedStates: [.waitingForDecision])
        if case let .approvePortable(losses, _) = decision {
            guard pair.value.request.kind == .copy, losses == request.metadataLosses else {
                throw FileOperationFailure(code: .unsupportedMetadata, operationID: id,
                                           itemID: request.itemID,
                                           diagnostic: "portable approval does not match requested losses",
                                           retryable: false)
            }
        }
        try commitEvent(id: id, itemID: request.itemID) { operation, _ in
            operation.pendingDecision = nil
            operation.priorDecisions[request.itemID] = ResolvedOperationDecision(
                decision: decision,
                identityDigest: request.identityDigest
            )
            if decision.scope == .remainingItems {
                operation.remainingDecision = ResolvedOperationDecision(
                    decision: decision,
                    identityDigest: request.identityDigest
                )
            }
            if case let .approvePortable(losses, scope) = decision {
                let policy = MetadataPolicy.portable(
                    PortableApproval(decisionID: token.rawValue, approvedLosses: losses)
                )
                if scope == .remainingItems {
                    operation.remainingMetadataPolicy = policy
                    operation.effectiveMetadataPolicy = policy
                } else {
                    operation.itemMetadataPolicies[request.itemID] = policy
                }
            }
            return .decisionResolved(token)
        }
        await dependencies.failpoints.hit(.decisionResolved, operationID: id)
        try requireNormalOwnership(id: id, command: "resolve",
                                   expectedStates: [.waitingForDecision])
        if decision == .cancel {
            try await cancelWaitingOperation(id: id, itemIndex: itemIndex)
            return
        }
        try transitionItem(id: id, index: itemIndex, to: .preflight)
        try transitionOperation(id: id, to: .preflight)
        Task { await self.continueActiveOperation(id) }
    }

    public func pause(_ id: OperationID) async {
        guard normalWritesAllowed else {
            rejectControlForServiceMode(id, command: "pause")
            return
        }
        guard let operation = operations[id] else {
            dependencies.diagnostics.record(.unknownControl(operationID: id, command: "pause")); return
        }
        guard activeID == id, operation.state == .staging,
              let index = activeItemIndex(operation), let control = controls[id] else {
            rejectKnownControl(id, command: "pause"); return
        }
        let result = await control.requestPauseAndWait()
        guard normalWritesAllowed else {
            rejectControlForServiceMode(id, command: "pause")
            return
        }
        guard case .paused = result,
              activeID == id,
              operations[id]?.state == .staging,
              controls[id] === control else {
            rejectKnownControl(id, command: "pause")
            return
        }
        do {
            try transitionItem(id: id, index: index, to: .paused)
            try transitionOperation(id: id, to: .paused)
        } catch { enterSafeMode(error) }
    }

    public func resume(_ id: OperationID) async {
        guard normalWritesAllowed else {
            rejectControlForServiceMode(id, command: "resume")
            return
        }
        guard let operation = operations[id] else {
            dependencies.diagnostics.record(.unknownControl(operationID: id, command: "resume")); return
        }
        guard activeID == id, operation.state == .paused,
              let index = activeItemIndex(operation), let control = controls[id] else {
            rejectKnownControl(id, command: "resume"); return
        }
        do {
            try transitionItem(id: id, index: index, to: .staging)
            try transitionOperation(id: id, to: .staging)
            await control.requestResume()
        } catch { enterSafeMode(error) }
    }

    public func cancel(_ id: OperationID) async {
        guard normalWritesAllowed else {
            rejectControlForServiceMode(id, command: "cancel")
            return
        }
        guard let operation = operations[id] else {
            dependencies.diagnostics.record(.unknownControl(operationID: id, command: "cancel")); return
        }
        guard let index = activeItemIndex(operation) ?? operation.items.indices.first(where: {
            ![.completed, .skipped, .cancelled, .rolledBack].contains(operation.items[$0].state)
        }) else {
            rejectKnownControl(id, command: "cancel"); return
        }
        switch operation.state {
        case .planned, .preflight:
            if operation.state == .planned, activeID != id {
                // A durably admitted queued operation owns no executor/control
                // slot. Cancelling it must not depend on, or release, the
                // different operation currently occupying the active slot.
                do { try await cancelBeforeStaging(id: id, itemIndex: index) }
                catch { enterSafeMode(error) }
                return
            }
            // Planning is executor work too. Wait for its cooperative
            // cancellation acknowledgement before releasing the active slot;
            // otherwise the next operation could overlap a still-running plan.
            let planningControl = controls[id]
            if let control = planningControl {
                await control.requestCancelAndWait()
            }
            let stillOwnsPlanning = planningControl == nil
                ? (activeID == nil || activeID == id)
                : (activeID == id && controls[id] === planningControl)
            guard normalWritesAllowed, stillOwnsPlanning,
                  let settled = operations[id],
                  [.planned, .preflight].contains(settled.state) else {
                rejectControlAfterAwait(id, command: "cancel")
                return
            }
            do { try await cancelBeforeStaging(id: id, itemIndex: index) }
            catch { enterSafeMode(error) }
        case .waitingForDecision:
            do { try await cancelBeforeStaging(id: id, itemIndex: index) }
            catch { enterSafeMode(error) }
        case .staging, .paused, .metadata, .verifying:
            guard let executionControl = controls[id] else {
                rejectKnownControl(id, command: "cancel")
                return
            }
            await executionControl.requestCancelAndWait()
            guard normalWritesAllowed else {
                rejectControlForServiceMode(id, command: "cancel")
                return
            }
            guard activeID == id,
                  controls[id] === executionControl,
                  let settled = operations[id],
                  [.staging, .paused, .metadata, .verifying].contains(settled.state) else {
                if operations[id]?.state == .committedAwaitingCleanup {
                    do { try await retainSourceAndStop(id: id, itemIndex: index) }
                    catch { enterSafeMode(error) }
                } else {
                    rejectControlAfterAwait(id, command: "cancel")
                }
                return
            }
            do {
                let action = try prepareCancelledStagingRecovery(id: id, itemIndex: index)
                try await recover(id, action: action)
            }
            catch { handleAutomaticRecoveryFailure(error, id: id) }
        case .committedAwaitingCleanup:
            do { try await retainSourceAndStop(id: id, itemIndex: index) }
            catch { enterSafeMode(error) }
        default:
            rejectKnownControl(id, command: "cancel")
        }
    }

    public func retry(_ id: OperationID) async throws {
        try requireNormalServiceMode(command: "retry")
        guard let operation = operations[id] else {
            throw FileOperationFailure(code: .validation, operationID: id,
                                       diagnostic: "unknown operation ID", retryable: false)
        }
        guard operation.state == .failedRecoverable,
              let index = activeItemIndex(operation) ?? operation.items.firstIndex(where: { $0.state == .failedRecoverable }) else {
            throw FileOperationFailure(code: .controlRejected, operationID: id, phase: operation.state,
                                       diagnostic: "retry is not available in this state", retryable: false)
        }
        guard activeID == nil else {
            throw FileOperationFailure(code: .controlRejected, operationID: id, phase: operation.state,
                                       diagnostic: "retry cannot preempt another active operation",
                                       retryable: true)
        }
        try transitionItem(id: id, index: index, to: .preflight)
        try transitionOperation(id: id, to: .preflight)
        operations[id]?.terminalFailure = nil
        activeID = id
        Task { await self.continueActiveOperation(id) }
    }

    public func recover(_ id: OperationID, action: RecoveryAction) async throws {
        guard var operation = operations[id] else {
            throw FileOperationFailure(code: .validation, operationID: id,
                                       diagnostic: "unknown operation ID", retryable: false)
        }
        let command = action.command
        if operation.completedRecoveryActions.contains(command.actionID) { return }
        guard !fatalModeActive else {
            throw FileOperationFailure(code: .serviceSafeMode, operationID: id,
                                       diagnostic: "fatal service mode forbids recovery",
                                       retryable: false)
        }
        guard operation.availableActions.contains(action) else {
            throw FileOperationFailure(code: .controlRejected, operationID: id,
                                       diagnostic: "stale or unavailable recovery action", retryable: false)
        }
        guard operation.inProgressRecoveryActions.count <= 1 else {
            throw FileOperationFailure(code: .serviceSafeMode, operationID: id,
                                       diagnostic: "journal contains multiple selected recovery commands",
                                       retryable: false)
        }
        if let selected = operation.inProgressRecoveryActions.first,
           selected != command.actionID {
            throw FileOperationFailure(code: .controlRejected, operationID: id,
                                       diagnostic: "a sibling recovery action is already durable",
                                       retryable: false)
        }
        let wasInProgress = operation.inProgressRecoveryActions.contains(command.actionID)
        if case .recoveryRequired = serviceMode, !wasInProgress,
           !recoveryModeAllowsSelection(for: id) {
            throw FileOperationFailure(
                code: .serviceSafeMode, operationID: id,
                diagnostic: "recovery-required mode permits only the durable selected action",
                retryable: false
            )
        }
        guard activeID == nil, recoveryLeases[id] == nil else {
            throw FileOperationFailure(code: .controlRejected, operationID: id,
                                       diagnostic: "another recovery invocation is active",
                                       retryable: true)
        }

        let lease = RecoveryLease(invocationID: UUID(), actionID: command.actionID)
        activeID = id
        recoveryLeases[id] = lease
        defer {
            if recoveryLeases[id] == lease { recoveryLeases[id] = nil }
            if activeID == id { activeID = nil }
            // Scheduling must happen after lease/active ownership is released;
            // otherwise the queued task can observe the old active ID and exit.
            Task { await self.runScheduler() }
        }

        // Select exactly one action and revoke all siblings in the same
        // durable checkpoint. Older M1 journals may already contain the
        // singleton in-progress marker but still expose sibling capabilities;
        // normalize them before the first inspection await.
        if !wasInProgress || operation.availableActions != [action] {
            operation.inProgressRecoveryActions = [command.actionID]
            operation.availableActions = [action]
            do {
                try dependencies.journal.checkpoint(operation.journalOperation)
                operations[id] = operation
                markRecoveryRequired(.durableCommand(id))
            } catch {
                enterSafeMode(error)
                throw FileOperationFailure(code: .journalFailure, operationID: id,
                                           diagnostic: String(describing: error), retryable: false)
            }
        }
        try requireRecoveryLease(id: id, actionID: command.actionID,
                                 invocationID: lease.invocationID)

        // A crash can leave terminal per-item recovery facts durable while the
        // operation-level terminal projection is still the old recovery state.
        // Repair that projection before looking for an active item; never use
        // this path to infer an unresolved or unknown external effect.
        try repairRecoveryProjectionIfPossible(id: id, action: action)

        if recoveryProjectionIsConverged(id: id, action: action) {
            try completeRecoveryCommand(id: id, actionID: command.actionID)
            return
        }

        guard let index = activeItemIndex(operation) ??
            operation.resumableDurableReceiptProjectionIndex ??
            operation.items.indices.first(where: {
            [.failedRecoverable, .recoveryRequired, .cleanupRequired,
             .committedAwaitingCleanup, .cleaningSource].contains(operation.items[$0].state)
        }) else {
            throw FileOperationFailure(code: .invariantViolation, operationID: id,
                                       diagnostic: "recovery state has no recoverable item", retryable: false)
        }

        switch action {
        case .rollbackCommittedDestination, .restoreBackup:
            if try await inspectUnknownCommits(
                id: id, actionID: command.actionID, invocationID: lease.invocationID
            ) {
                try await recoverCommittedEffects(
                    id: id, effect: .rollbackCommittedDestination,
                    actionID: command.actionID, invocationID: lease.invocationID
                )
                try requireRecoveryLease(id: id, actionID: command.actionID,
                                         invocationID: lease.invocationID)
                try await convergeRolledBack(id: id)
            } else {
                try await convergeConfirmedNoCommit(id: id)
            }
        case .resumeFromVerifiedStage:
            try requireRecoveryLease(id: id, actionID: command.actionID,
                                     invocationID: lease.invocationID)
            guard operations[id]?.state == .failedRecoverable else {
                throw FileOperationFailure(code: .controlRejected, operationID: id,
                                           diagnostic: "verified-stage resume requires writable failedRecoverable state",
                                           retryable: false)
            }
            try transitionItem(id: id, index: index, to: .preflight) { item in
                item.failure = nil
            }
            operations[id]?.terminalFailure = nil
            try transitionOperation(id: id, to: .preflight)
        case .retainSource:
            try await retainSourceAndStop(
                id: id, itemIndex: index, actionID: command.actionID,
                invocationID: lease.invocationID
            )
            try requireRecoveryLease(id: id, actionID: command.actionID,
                                     invocationID: lease.invocationID)
        case .discardKnownStaging:
            try await performRecoveryEffect(
                id: id, itemIndex: index, effect: .cleanupStaging,
                actionID: command.actionID, invocationID: lease.invocationID,
                receipt: nil
            )
            try requireRecoveryLease(id: id, actionID: command.actionID,
                                     invocationID: lease.invocationID,
                                     itemID: operation.items[index].id,
                                     effect: .cleanupStaging)
            try await convergeRecoveredStagingCleanup(id: id, itemIndex: index)
        case .retrySourceCleanup:
            try await retrySourceCleanup(
                id: id, itemIndex: index, actionID: command.actionID,
                invocationID: lease.invocationID
            )
        case .finalizeKnownCommit:
            if try await inspectUnknownCommits(
                id: id, actionID: command.actionID, invocationID: lease.invocationID
            ) {
                try await recoverCommittedEffects(
                    id: id, effect: .finalizeKnownCommit,
                    actionID: command.actionID, invocationID: lease.invocationID
                )
                try requireRecoveryLease(id: id, actionID: command.actionID,
                                         invocationID: lease.invocationID)
                try await convergeFinalizedPartialCommit(id: id)
            } else {
                try await convergeConfirmedNoCommit(id: id)
            }
        }
        await dependencies.failpoints.hit(.recoveryProjectionConverged, operationID: id)
        try Task.checkCancellation()
        try requireRecoveryLease(id: id, actionID: command.actionID,
                                 invocationID: lease.invocationID)
        try completeRecoveryCommand(id: id, actionID: command.actionID)
    }
}

// MARK: - Scheduling and execution

private extension FileOperationService {
    func runScheduler() async {
        guard normalWritesAllowed, activeID == nil else { return }
        let candidate = operations.values
            .filter {
                $0.state == .planned || $0.state == .preflight ||
                    $0.state == .waitingForDecision ||
                    $0.resumableDurableReceiptProjectionIndex != nil
            }
            .min { $0.submissionOrdinal < $1.submissionOrdinal }
        guard let candidate else { return }
        activeID = candidate.id
        if candidate.state == .waitingForDecision {
            // Resolving a decision durably clears pendingDecision before the
            // state transitions back to preflight. A process exit in that gap
            // resumes the recorded decision instead of waiting for a consumed token.
            guard candidate.pendingDecision == nil else { return }
            do {
                guard let index = candidate.items.firstIndex(where: {
                    $0.state == .waitingForDecision
                }) else {
                    throw FileOperationFailure(
                        code: .invariantViolation, operationID: candidate.id,
                        diagnostic: "resolved waiting operation has no waiting item",
                        retryable: false
                    )
                }
                try transitionItem(id: candidate.id, index: index, to: .preflight)
                try transitionOperation(id: candidate.id, to: .preflight)
            } catch {
                activeID = nil
                enterSafeMode(error)
                return
            }
        }
        await continueActiveOperation(candidate.id)
    }

    func continueActiveOperation(_ id: OperationID) async {
        do {
            guard var operation = operations[id], activeID == id else { return }
            if operation.state == .planned { try transitionOperation(id: id, to: .preflight) }
            operation = operations[id]!
            if let index = operation.resumableDurableReceiptProjectionIndex {
                try resumeDurableReceiptProjection(id: id, itemIndex: index)
                return
            }
            guard operation.state == .preflight else { return }
            guard let index = operation.items.firstIndex(where: { $0.state == .pending || $0.state == .preflight }) else {
                try finishOrAdvance(id: id)
                return
            }
            if operation.items[index].state == .pending { try transitionItem(id: id, index: index, to: .preflight) }
            operation = operations[id]!

            let control = ExecutionControls()
            controls[id] = control
            await control.beginPhase()
            let disposition: PreflightDisposition
            do {
                disposition = try await dependencies.fileSystem.preflight(
                    operationID: id, itemID: operation.items[index].id,
                    request: operation.request, itemIndex: index,
                    priorDecision: operation.priorDecisions[operation.items[index].id]
                        ?? operation.remainingDecision,
                    controls: control
                )
                await control.endPhase()
            } catch {
                await control.endPhase()
                if await control.isCancelled() || activeID != id ||
                    controls[id] !== control || operations[id]?.state != .preflight {
                    return
                }
                controls[id] = nil
                throw error
            }
            guard normalWritesAllowed, activeID == id, controls[id] === control,
                  operations[id]?.state == .preflight,
                  !(await control.isCancelled()) else { return }
            switch disposition {
            case let .ready(destinations, moveTopology):
                if destinations.indices.contains(index) {
                    operations[id]?.items[index].destination = destinations[index]
                }
                try checkpointMoveVerificationPolicy(id: id, topology: moveTopology)
                await dependencies.failpoints.hit(.preflightReadyBeforePlan, operationID: id)
                guard normalWritesAllowed, activeID == id, controls[id] === control,
                      operations[id]?.state == .preflight,
                      !(await control.isCancelled()) else { return }
                try await executeItem(id: id, index: index, control: control)
            case let .decision(spec):
                controls[id] = nil
                try requireDecision(id: id, itemIndex: index, specification: spec)
            case .skip:
                controls[id] = nil
                try transitionItem(id: id, index: index, to: .skipped)
                try finishOrAdvance(id: id)
            case let .failure(failure):
                controls[id] = nil
                try failItem(id: id, itemIndex: index, failure: failure, ambiguous: false)
            }
        } catch {
            enterSafeMode(error)
        }
    }

    func executeItem(id: OperationID, index: Int, control: ExecutionControls) async throws {
        guard let operation = operations[id] else { return }
        let item = operation.items[index]
        let metadataPolicy = operation.itemMetadataPolicies[item.id]
            ?? operation.remainingMetadataPolicy
            ?? operation.request.metadataPolicy
        let context = ExecutionContext(
            operationID: id, itemID: item.id, request: operation.request,
            source: item.source, destination: item.destination, itemIndex: index,
            metadataPolicy: metadataPolicy,
            verificationPolicy: operation.effectiveVerificationPolicy
        )
        await control.beginPhase()
        let requestedPlan: ExecutionPlan
        do {
            requestedPlan = try await dependencies.executor.plan(context, controls: control)
            await control.endPhase()
        } catch let failure as FileOperationFailure {
            await control.endPhase()
            if await control.isCancelled() || activeID != id || operations[id]?.state != .preflight {
                return
            }
            controls[id] = nil
            try failItem(id: id, itemIndex: index, failure: failure, ambiguous: false)
            return
        } catch {
            await control.endPhase()
            if await control.isCancelled() || activeID != id || operations[id]?.state != .preflight {
                return
            }
            controls[id] = nil
            try failItem(
                id: id, itemIndex: index,
                failure: FileOperationFailure(
                    code: .invariantViolation, operationID: id, itemID: item.id,
                    phase: .preflight, diagnostic: String(describing: error), retryable: false
                ), ambiguous: false
            )
            return
        }
        guard normalWritesAllowed, activeID == id, controls[id] === control,
              operations[id]?.state == .preflight,
              operations[id]?.items[index].state == .preflight,
              !(await control.isCancelled()) else { return }
        let plan = ExecutionPlan(
            sourceDisposition: requestedPlan.sourceDisposition,
            durableCommitReceipt: operations[id]?.committedEffects[item.id]
        )
        if operation.request.kind != .move, plan.sourceDisposition != .noCleanup {
            controls[id] = nil
            try failItem(
                id: id, itemIndex: index,
                failure: FileOperationFailure(
                    code: .invariantViolation, operationID: id, itemID: item.id,
                    phase: .preflight,
                    diagnostic: "non-move execution plan requested source cleanup",
                    retryable: false
                ), ambiguous: false
            )
            return
        }

        if let durableReceipt = plan.durableCommitReceipt {
            // A durable commit ledger suppresses every earlier filesystem
            // phase as well as commit. Re-project the normative phase states
            // from already durable metadata/verification facts without
            // invoking executor effects a second time.
            try projectDurableCommitIntent(
                id: id, itemIndex: index, receipt: durableReceipt
            )
        } else {
            try transitionItem(id: id, index: index, to: .staging)
            try transitionOperation(id: id, to: .staging)
            await dependencies.failpoints.hit(.stagingStarted, operationID: id)
            guard await shouldContinuePhase(id: id, state: .staging, control: control) else { return }
            let staged = await performPhase(.staging, context: context, plan: plan, control: control)
            guard await shouldContinueAfter(outcome: staged, phase: .staging, id: id, index: index,
                                            expected: .staging, control: control) else { return }
            guard case .staged = staged else {
                try failUnexpectedPhase(.staging, id: id, index: index)
                return
            }

            try transitionItem(id: id, index: index, to: .metadata)
            try transitionOperation(id: id, to: .metadata)
            guard await shouldContinuePhase(id: id, state: .metadata, control: control) else { return }
            let metadata = await performPhase(.metadata, context: context, plan: plan, control: control)
            guard await shouldContinueAfter(outcome: metadata, phase: .metadata, id: id, index: index,
                                            expected: .metadata, control: control) else { return }
            guard case let .metadataApplied(metadataOutcome) = metadata else {
                try failUnexpectedPhase(.metadata, id: id, index: index)
                return
            }

            try transitionItem(id: id, index: index, to: .verifying) { managedItem in
                managedItem.metadata = metadataOutcome
            }
            try transitionOperation(id: id, to: .verifying)
            guard await shouldContinuePhase(id: id, state: .verifying, control: control) else { return }
            let verification = await performPhase(
                .verification, context: context, plan: plan, control: control
            )
            guard await shouldContinueAfter(outcome: verification, phase: .verification,
                                            id: id, index: index, expected: .verifying,
                                            control: control) else { return }
            guard case let .verified(verificationOutcome) = verification else {
                try failUnexpectedPhase(.verification, id: id, index: index)
                return
            }
            guard verificationOutcome.policy == context.verificationPolicy else {
                controls[id] = nil
                try failItem(
                    id: id, itemIndex: index,
                    failure: FileOperationFailure(
                        code: .verificationMismatch, operationID: id, itemID: item.id,
                        phase: .verifying,
                        diagnostic: "executor verification policy does not match effective policy",
                        retryable: false
                    ), ambiguous: false
                )
                return
            }

            // The committing state is the durable pre-effect intent. If either
            // transition fails, perform(.commit) is never invoked.
            try transitionItem(id: id, index: index, to: .committing) { managedItem in
                managedItem.verification = verificationOutcome
            }
            try transitionOperation(id: id, to: .committing)
        }
        guard await shouldContinuePhase(id: id, state: .committing, control: control) else { return }
        let committed: ExecutionPhaseOutcome
        if let durableReceipt = plan.durableCommitReceipt {
            committed = .committed(durableReceipt)
        } else {
            committed = await performPhase(.commit, context: context, plan: plan, control: control)
        }
        guard await shouldContinueAfter(outcome: committed, phase: .commit,
                                        id: id, index: index, expected: .committing, control: control,
                                        cancellationAllowed: false) else { return }
        let receipt: OperationReceiptSummary
        switch committed {
        case let .committed(value):
            receipt = value
        case let .committedAt(value, destination):
            operations[id]?.items[index].destination = destination
            receipt = value
        default:
            try failUnexpectedPhase(.commit, id: id, index: index)
            return
        }
        controls[id] = nil

        let cleanupRequired = plan.sourceDisposition == .cleanupRequired
        // Persist the executor's commit acknowledgement before interpreting
        // any semantic mismatch. The destination effect is already visible;
        // losing this receipt would turn a diagnosable invariant failure into
        // an unsafe, uninspectable retry.
        if operations[id]?.items[index].receipt != receipt ||
            operations[id]?.committedEffects[item.id] != receipt {
            try recordReceipt(id: id, itemIndex: index, receipt: receipt)
        }
        guard receipt.sourceCleanupPending == cleanupRequired else {
            try failItem(
                id: id, itemIndex: index,
                failure: FileOperationFailure(
                    code: .invariantViolation, operationID: id, itemID: item.id,
                    phase: .committing,
                    diagnostic: "commit receipt source-cleanup flag contradicts execution plan",
                    retryable: false
                ), ambiguous: true
            )
            return
        }

        // Receipt durability is the cleanup barrier. No source cleanup phase
        // can begin until this event and both committed transitions succeed.
        try transitionItem(id: id, index: index, to: .committed)
        if !cleanupRequired {
            try transitionItem(id: id, index: index, to: .completed)
            try finishOrAdvance(id: id)
            return
        }

        try transitionItem(id: id, index: index, to: .committedAwaitingCleanup)
        try transitionOperation(id: id, to: .committedAwaitingCleanup)
        await dependencies.failpoints.hit(.committedAwaitingCleanup, operationID: id)
        guard cleanupIsAuthorized(
            id: id, itemIndex: index, expectedStates: [.committedAwaitingCleanup],
            expectedReceipt: receipt
        ) else { return }
        switch await dependencies.executor.inspectSourceBeforeCleanup(context, receipt: receipt) {
        case .sourcePresentMatching:
            break
        case .sourceAbsent:
            try convergeSourceAlreadyAbsent(id: id, itemIndex: index)
            return
        case let .sourceChanged(failure), let .unknown(failure):
            try failCleanup(id: id, itemIndex: index, failure: failure, ambiguous: true)
            return
        }
        try transitionItem(id: id, index: index, to: .sourceQuarantining)
        try transitionOperation(id: id, to: .sourceQuarantining)
        try transitionItem(id: id, index: index, to: .cleaningSource)
        try transitionOperation(id: id, to: .cleaningSource)

        let cleanupControl = ExecutionControls()
        controls[id] = cleanupControl
        let cleaned = await performPhase(
            .sourceCleanup, context: context, plan: plan, control: cleanupControl
        )
        let stillOwnsCleanup = controls[id] === cleanupControl && cleanupIsAuthorized(
            id: id, itemIndex: index, expectedStates: [.cleaningSource],
            expectedReceipt: receipt
        )
        controls[id] = nil
        guard stillOwnsCleanup else { return }
        switch cleaned {
        case .sourceCleaned:
            try recordSourceCleanupCompleted(id: id, itemIndex: index)
            operations[id]?.terminalFailure = nil
            try transitionItem(id: id, index: index, to: .completed)
            try finishOrAdvance(id: id)
        case let .failed(failure):
            try failCleanup(id: id, itemIndex: index, failure: failure, ambiguous: false)
        case let .recoveryRequired(failure):
            try failCleanup(id: id, itemIndex: index, failure: failure, ambiguous: true)
        default:
            try failCleanup(
                id: id, itemIndex: index,
                failure: FileOperationFailure(
                    code: .invariantViolation, operationID: id, itemID: item.id,
                    phase: .cleaningSource,
                    diagnostic: "unexpected source cleanup ACK", retryable: false
                ), ambiguous: true
            )
        }
    }

    func checkpointMoveVerificationPolicy(id: OperationID,
                                          topology: MoveTopology) throws {
        guard var operation = operations[id], operation.request.kind == .move else { return }
        switch topology {
        case .sameVolume:
            operation.effectiveVerificationPolicy = operation.request.verificationPolicy
        case .crossVolume, .unknown:
            operation.effectiveVerificationPolicy = .sha256
        }
        do {
            try dependencies.journal.checkpoint(operation.journalOperation)
            operations[id] = operation
        } catch {
            enterSafeMode(error)
            throw FileOperationFailure(
                code: .journalFailure, operationID: id,
                diagnostic: String(describing: error), retryable: false
            )
        }
    }

    func performPhase(_ phase: ExecutionPhase, context: ExecutionContext,
                      plan: ExecutionPlan, control: ExecutionControls) async
        -> ExecutionPhaseOutcome {
        await control.beginPhase()
        await dependencies.failpoints.hit(
            .phaseBeganBeforeAuthorization, operationID: context.operationID
        )
        guard await phaseIsAuthorized(phase, context: context, control: control) else {
            await control.endPhase()
            return .cancelled
        }
        let outcome = await dependencies.executor.perform(
            phase, context: context, plan: plan, controls: control
        ) { progress in
            await self.recordProgress(
                id: context.operationID, itemID: context.itemID, progress: progress
            )
        }
        await control.endPhase()
        return outcome
    }

    func phaseIsAuthorized(_ phase: ExecutionPhase, context: ExecutionContext,
                           control: ExecutionControls) async -> Bool {
        guard normalWritesAllowed, activeID == context.operationID,
              controls[context.operationID] === control,
              let operation = operations[context.operationID],
              operation.items.indices.contains(context.itemIndex),
              operation.items[context.itemIndex].id == context.itemID,
              !(await control.isCancelled()) else { return false }
        let expected: (OperationState, OperationItemState)
        switch phase {
        case .staging: expected = (.staging, .staging)
        case .metadata: expected = (.metadata, .metadata)
        case .verification: expected = (.verifying, .verifying)
        case .commit: expected = (.committing, .committing)
        case .sourceCleanup: expected = (.cleaningSource, .cleaningSource)
        }
        return operation.state == expected.0 &&
            operation.items[context.itemIndex].state == expected.1
    }

    func shouldContinuePhase(id: OperationID, state: OperationState,
                             control: ExecutionControls) async -> Bool {
        guard normalWritesAllowed, activeID == id, operations[id]?.state == state,
              !(await control.isCancelled()) else { return false }
        return true
    }

    func shouldContinueAfter(outcome: ExecutionPhaseOutcome, phase: ExecutionPhase,
                             id: OperationID, index: Int,
                             expected: OperationState, control: ExecutionControls,
                             cancellationAllowed: Bool = true) async -> Bool {
        if !normalWritesAllowed { return false }
        switch outcome {
        case let .failed(failure):
            controls[id] = nil
            do {
                if [.staging, .metadata, .verification].contains(phase) {
                    try await failPrecommitWithOwnedStaging(
                        id: id, itemIndex: index, failure: failure
                    )
                } else {
                    try failItem(id: id, itemIndex: index, failure: failure, ambiguous: false)
                }
            }
            catch { enterSafeMode(error) }
            return false
        case let .recoveryRequired(failure):
            controls[id] = nil
            do {
                if [.staging, .metadata, .verification].contains(phase) {
                    try await failPrecommitWithOwnedStaging(
                        id: id, itemIndex: index, failure: failure
                    )
                } else {
                    try failItem(id: id, itemIndex: index, failure: failure, ambiguous: true)
                }
            }
            catch { enterSafeMode(error) }
            return false
        case .cancelled:
            let cancellationRequested = await control.isCancelled()
            if !cancellationAllowed || !cancellationRequested {
                controls[id] = nil
                do { try failUnexpectedPhase(phase, id: id, index: index) }
                catch { enterSafeMode(error) }
            }
            return false
        default:
            guard activeID == id, operations[id]?.state == expected else { return false }
            if cancellationAllowed, await control.isCancelled() { return false }
            return true
        }
    }

    func failUnexpectedPhase(_ phase: ExecutionPhase, id: OperationID, index: Int) throws {
        controls[id] = nil
        let operationState = operations[id]?.state
        let ambiguous = phase == .commit || phase == .sourceCleanup
        try failItem(
            id: id, itemIndex: index,
            failure: FileOperationFailure(
                code: .invariantViolation, operationID: id,
                itemID: operations[id]?.items[index].id, phase: operationState,
                diagnostic: "unexpected ACK for \(phase.rawValue)", retryable: false
            ), ambiguous: ambiguous
        )
    }

    func failPrecommitWithOwnedStaging(id: OperationID, itemIndex: Int,
                                       failure: FileOperationFailure) async throws {
        let itemID = operations[id]!.items[itemIndex].id
        try commitEvent(id: id, itemID: itemID) { operation, _ in
            operation.items[itemIndex].failure = failure
            operation.terminalFailure = failure
            return .failure(failure)
        }
        let action = try issueDiscardStagingAction(id: id, itemIndex: itemIndex)
        // The operation remains cleanupRequired while the stable recovery
        // effect is inspected/executed. Ambiguity is represented by the
        // durable action plus service recovery mode, not by discarding the
        // only legal cleanupRequired -> failed/cancelled convergence path.
        try transitionItem(id: id, index: itemIndex, to: .cleanupRequired)
        try transitionOperation(id: id, to: .cleanupRequired)
        try transitionOperation(id: id, to: .recoveryRequired)
        controls[id] = nil
        activeID = nil
        markRecoveryRequired(.unexplainedFilesystemEffect(id))
        do {
            try await recover(id, action: action)
        } catch {
            handleAutomaticRecoveryFailure(error, id: id)
        }
    }

    func recordSourceCleanupCompleted(id: OperationID, itemIndex: Int) throws {
        guard let receipt = operations[id]?.items[itemIndex].receipt else {
            throw FileOperationFailure(
                code: .invariantViolation, operationID: id,
                itemID: operations[id]?.items[itemIndex].id, phase: .cleaningSource,
                diagnostic: "cleanup completed without a durable receipt", retryable: false
            )
        }
        let completed = OperationReceiptSummary(
            committedIdentityDigest: receipt.committedIdentityDigest,
            backupURL: receipt.backupURL, quarantineURL: receipt.quarantineURL,
            sourceCleanupPending: false
        )
        try recordReceipt(id: id, itemIndex: itemIndex, receipt: completed)
    }

    func failCleanup(id: OperationID, itemIndex: Int, failure: FileOperationFailure,
                     ambiguous: Bool) throws {
        let itemID = operations[id]!.items[itemIndex].id
        try commitEvent(id: id, itemID: itemID) { operation, _ in
            operation.items[itemIndex].failure = failure
            operation.terminalFailure = failure
            return .failure(failure)
        }
        try transitionItem(
            id: id, index: itemIndex, to: ambiguous ? .recoveryRequired : .cleanupRequired
        )
        try transitionOperation(id: id, to: ambiguous ? .recoveryRequired : .cleanupRequired)
        try issueCleanupRecoveryActions(id: id, itemIndex: itemIndex, ambiguous: ambiguous)
        activeID = nil
        Task { await self.runScheduler() }
    }

    func issueCleanupRecoveryActions(id: OperationID, itemIndex: Int,
                                     ambiguous: Bool) throws {
        _ = ambiguous
        let itemID = operations[id]!.items[itemIndex].id
        try commitEvent(id: id, itemID: itemID) { operation, sequence in
            let actions: [RecoveryAction] = [
                .retrySourceCleanup(RecoveryCommand(
                    actionID: dependencies.ids.actionID(), expectedSequence: sequence
                )),
                .retainSource(RecoveryCommand(
                    actionID: dependencies.ids.actionID(), expectedSequence: sequence
                ))
            ]
            operation.availableActions = actions
            return .recoveryAvailable(actions)
        }
    }

    func finishOrAdvance(id: OperationID) throws {
        guard let operation = operations[id] else { return }
        if operation.items.contains(where: { $0.state == .pending }) {
            try transitionOperation(id: id, to: .preflight)
            Task { await self.continueActiveOperation(id) }
            return
        }
        guard let terminal = OperationAggregator.terminalState(items: operation.items.map(\.snapshot),
                                                               sourceRetained: operation.sourceRetained) else { return }
        if terminal != operation.state { try transitionOperation(id: id, to: terminal) }
        try commitEvent(id: id, itemID: nil) { op, _ in .completed(op.snapshot) }
        if recoveryLeases[id] == nil {
            activeID = nil
            Task { await self.runScheduler() }
        }
    }
}

// MARK: - Durable state updates

private extension FileOperationService {
    func transitionItem(id: OperationID, index: Int, to newState: OperationItemState,
                        clearPendingDecision: Bool = false,
                        update: ((inout ManagedItem) -> Void)? = nil) throws {
        guard let operation = operations[id], operation.items.indices.contains(index) else { return }
        let old = operation.items[index].state
        if old == newState { return }
        try ItemStateMachine.validate(from: old, to: newState, operationID: id,
                                      itemID: operation.items[index].id)
        try commitEvent(id: id, itemID: operation.items[index].id) { operation, _ in
            operation.items[index].state = newState
            if clearPendingDecision { operation.pendingDecision = nil }
            update?(&operation.items[index])
            return .itemStateChanged(from: old, to: newState)
        }
    }

    func transitionOperation(id: OperationID, to newState: OperationState) throws {
        guard let operation = operations[id] else { return }
        let old = operation.state
        if old == newState { return }
        try OperationStateMachine.validate(from: old, to: newState, operationID: id)
        try commitEvent(id: id, itemID: nil) { operation, _ in
            operation.state = newState
            if newState == .staging,
               let activeItem = operation.items.first(where: { $0.state == .staging }) {
                operation.effectiveMetadataPolicy = operation.itemMetadataPolicies[activeItem.id]
                    ?? operation.remainingMetadataPolicy
                    ?? operation.request.metadataPolicy
            } else if newState == .preflight || [
                .completed, .completedWithSkips, .completedWithSourceRetained,
                .cancelled, .rolledBack
            ].contains(newState) {
                // Item approvals are deliberately scoped to the active item.
                // Once it leaves the execution pipeline, the observable
                // operation policy returns to the remaining/default policy.
                operation.effectiveMetadataPolicy = operation.remainingMetadataPolicy
                    ?? operation.request.metadataPolicy
            }
            if old != newState, Self.isRecoveryState(old), newState != .recoveryRequired,
               operation.inProgressRecoveryActions.isEmpty {
                // Recovery actions are capabilities bound to one exact durable
                // state, not to the broad family of recovery-like states.
                operation.availableActions.removeAll()
            }
            return .stateChanged(from: old, to: newState)
        }
        if newState == .recoveryRequired {
            markRecoveryRequired(.unexplainedFilesystemEffect(id))
        }
    }

    static func isRecoveryState(_ state: OperationState) -> Bool {
        [.failedRecoverable, .recoveryRequired, .cleanupRequired].contains(state)
    }

    func commitEvent(id: OperationID, itemID: OperationItemID?,
                     mutate: (inout ManagedOperation, EventSequence) -> OperationEventPayload) throws {
        guard var operation = operations[id] else { return }
        do {
            let reservation = try dependencies.journal.reserveSequences(for: id, count: 1)
            let sequence = reservation.lowerBound
            guard sequence > operation.latestEmittedSequence else {
                throw FileOperationFailure(code: .invariantViolation, operationID: id,
                                           diagnostic: "journal returned a reused event sequence",
                                           retryable: false)
            }
            operation.reservedThrough = max(operation.reservedThrough, reservation.upperBound)
            operation.latestDurableSequence = sequence
            operation.latestEmittedSequence = sequence
            // A durable event may jump past unused progress reservations. Those
            // gaps remain permanently consumed; progress must never walk back
            // into them after the durable event is visible.
            operation.nextProgressSequence = checkedSuccessor(reservation.upperBound)
            let payload = mutate(&operation, sequence)
            let event = OperationEvent(operationID: id, itemID: itemID, sequence: sequence,
                                       timestamp: dependencies.clock.now(), durability: .durable,
                                       payload: payload)
            try dependencies.journal.commit(operation.journalOperation, event: event)
            operations[id] = operation
            broadcast(event)
        } catch {
            // Every journal mutation failure is fatal for this service
            // instance. A later recovery checkpoint must never clear it.
            enterSafeMode(error)
            throw FileOperationFailure(code: .journalFailure, operationID: id,
                                       diagnostic: String(describing: error), retryable: false)
        }
    }

    func recordProgress(id: OperationID, itemID: OperationItemID, progress: OperationProgress) async {
        guard normalWritesAllowed, var operation = operations[id],
              operation.state == .staging,
              let index = operation.items.firstIndex(where: { $0.id == itemID }),
              operation.items[index].state == .staging else {
            return
        }
        let previous = operation.items[index].progress
        guard progress.bytesCompleted >= previous.bytesCompleted,
              progress.bytesCompleted >= 0,
              progress.itemsCompleted >= previous.itemsCompleted,
              progress.itemsCompleted >= 0,
              progress.itemsTotal >= previous.itemsTotal,
              progress.itemsTotal >= progress.itemsCompleted,
              progress.bytesTotal.map({ $0 >= progress.bytesCompleted }) ?? true,
              previous.bytesTotal.map({ previousTotal in
                  progress.bytesTotal.map { $0 >= previousTotal } ?? false
              }) ?? true else {
            return
        }
        do {
            if operation.nextProgressSequence <= operation.latestEmittedSequence ||
                operation.nextProgressSequence > operation.reservedThrough {
                let reservation = try dependencies.journal.reserveSequences(for: id, count: 8)
                guard reservation.lowerBound > operation.latestEmittedSequence else {
                    throw FileOperationFailure(code: .invariantViolation, operationID: id,
                                               diagnostic: "journal returned a reused progress sequence",
                                               retryable: false)
                }
                operation.nextProgressSequence = reservation.lowerBound
                operation.reservedThrough = reservation.upperBound
            }
            let sequence = operation.nextProgressSequence
            guard sequence != UInt64.max else {
                throw FileOperationFailure(code: .serviceSafeMode, operationID: id,
                                           diagnostic: "event sequence space exhausted",
                                           retryable: false)
            }
            operation.nextProgressSequence = checkedSuccessor(sequence)
            operation.latestEmittedSequence = sequence
            operation.latestDurableSequence = sequence // This progress checkpoint is persisted below.
            operation.items[index].progress = progress
            try dependencies.journal.checkpoint(operation.journalOperation)
            operations[id] = operation
            broadcast(OperationEvent(operationID: id, itemID: itemID, sequence: sequence,
                                     timestamp: dependencies.clock.now(), durability: .transient,
                                     payload: .progress(progress)))
        } catch {
            enterSafeMode(error)
            if let control = controls[id] {
                await control.revoke()
            }
        }
    }

    func recordReceipt(id: OperationID, itemIndex: Int, receipt: OperationReceiptSummary) throws {
        let itemID = operations[id]!.items[itemIndex].id
        try commitEvent(id: id, itemID: itemID) { operation, _ in
            operation.items[itemIndex].receipt = receipt
            // This durable ledger is the idempotency boundary for externally
            // visible commit effects. A restarted retry may repeat planning and
            // validation, but the executor receives this receipt and must not
            // apply the commit effect again.
            operation.committedEffects[itemID] = receipt
            return .receiptRecorded(receipt)
        }
    }

    func requireDecision(id: OperationID, itemIndex: Int, specification: PreflightDecision) throws {
        let itemID = operations[id]!.items[itemIndex].id
        let token = dependencies.ids.decisionToken()
        try transitionItem(id: id, index: itemIndex, to: .waitingForDecision)
        try transitionOperation(id: id, to: .waitingForDecision)
        try commitEvent(id: id, itemID: itemID) { operation, sequence in
            let request = DecisionRequest(token: token, operationID: id, itemID: itemID,
                                          expectedSequence: sequence, allowed: specification.allowed,
                                          metadataLosses: specification.metadataLosses,
                                          identityDigest: specification.identityDigest)
            operation.pendingDecision = request
            return .decisionRequired(request)
        }
    }

    func failItem(id: OperationID, itemIndex: Int, failure: FileOperationFailure,
                  ambiguous: Bool) throws {
        let itemID = operations[id]!.items[itemIndex].id
        try commitEvent(id: id, itemID: itemID) { operation, _ in
            operation.items[itemIndex].failure = failure
            operation.terminalFailure = failure
            return .failure(failure)
        }
        let itemTarget: OperationItemState = ambiguous ? .recoveryRequired : .failedRecoverable
        let operationTarget: OperationState = ambiguous ? .recoveryRequired : .failedRecoverable
        try transitionItem(id: id, index: itemIndex, to: itemTarget)
        try transitionOperation(id: id, to: operationTarget)
        if operations[id]?.hasPartialCommit == true, !ambiguous {
            try issuePartialCommitRecoveryActions(id: id, itemIndex: itemIndex)
        } else {
            try issueRecoveryActions(id: id, itemIndex: itemIndex, ambiguous: ambiguous)
        }
        if ambiguous { Task { await dependencies.failpoints.hit(.recoveryRequired, operationID: id) } }
        activeID = nil
        Task { await self.runScheduler() }
    }

    func issueRecoveryActions(id: OperationID, itemIndex: Int, ambiguous: Bool) throws {
        let itemID = operations[id]!.items[itemIndex].id
        try commitEvent(id: id, itemID: itemID) { operation, sequence in
            let actions: [RecoveryAction]
            if ambiguous {
                // These capabilities do not assume the commit outcome. recover
                // first asks the executor to re-inspect object identity; an
                // unknown answer keeps both tokens live and performs no effect.
                actions = [
                    .finalizeKnownCommit(RecoveryCommand(
                        actionID: dependencies.ids.actionID(), expectedSequence: sequence
                    )),
                    .rollbackCommittedDestination(RecoveryCommand(
                        actionID: dependencies.ids.actionID(), expectedSequence: sequence
                    ))
                ]
            } else {
                actions = [.resumeFromVerifiedStage(RecoveryCommand(
                    actionID: dependencies.ids.actionID(), expectedSequence: sequence
                ))]
            }
            operation.availableActions = actions
            return .recoveryAvailable(actions)
        }
    }

    func issuePartialCommitRecoveryActions(id: OperationID, itemIndex: Int) throws {
        let itemID = operations[id]!.items[itemIndex].id
        let partial = FileOperationFailure(
            code: .partialCommit, operationID: id, itemID: itemID,
            phase: operations[id]?.state,
            diagnostic: "one or more prior items are durably committed",
            retryable: false
        )
        try commitEvent(id: id, itemID: itemID) { operation, _ in
            operation.terminalFailure = partial
            return .failure(partial)
        }
        try commitEvent(id: id, itemID: itemID) { operation, sequence in
            let actions: [RecoveryAction] = [
                .rollbackCommittedDestination(RecoveryCommand(
                    actionID: dependencies.ids.actionID(), expectedSequence: sequence
                )),
                .finalizeKnownCommit(RecoveryCommand(
                    actionID: dependencies.ids.actionID(), expectedSequence: sequence
                ))
            ]
            operation.availableActions = actions
            return .recoveryAvailable(actions)
        }
    }
}

// MARK: - Control convergence

private extension FileOperationService {
    func cancelWaitingOperation(id: OperationID, itemIndex: Int) async throws {
        let partial = operations[id]!.items.contains { $0.receipt != nil }
        try transitionItem(id: id, index: itemIndex,
                           to: partial ? .failedRecoverable : .cancelled,
                           clearPendingDecision: true)
        try cancelRemainingPending(id: id)
        try transitionOperation(id: id, to: partial ? .failedRecoverable : .cancelled)
        if partial { try issuePartialCommitRecoveryActions(id: id, itemIndex: itemIndex) }
        activeID = nil
        Task { await self.runScheduler() }
    }

    func cancelBeforeStaging(id: OperationID, itemIndex: Int) async throws {
        let partial = operations[id]!.items.contains { $0.receipt != nil }
        let itemState = operations[id]!.items[itemIndex].state
        if itemState == .waitingForDecision {
            try transitionItem(id: id, index: itemIndex,
                               to: partial ? .failedRecoverable : .cancelled,
                               clearPendingDecision: true)
        }
        else if itemState == .preflight || itemState == .pending {
            try transitionItem(id: id, index: itemIndex,
                               to: partial ? .failedRecoverable : .cancelled)
        }
        try cancelRemainingPending(id: id)
        try transitionOperation(id: id, to: partial ? .failedRecoverable : .cancelled)
        if partial { try issuePartialCommitRecoveryActions(id: id, itemIndex: itemIndex) }
        controls[id] = nil
        if activeID == id { activeID = nil }
        Task { await self.runScheduler() }
    }

    func prepareCancelledStagingRecovery(id: OperationID, itemIndex: Int) throws
        -> RecoveryAction {
        try requireNormalOwnership(
            id: id, command: "cancel", expectedStates: [.staging, .paused, .metadata, .verifying]
        )
        // The recovery capability is durable before the first cleanup-state
        // projection. A crash at every later checkpoint can therefore resume
        // this exact owned-staging cleanup without inventing a new effect.
        let action = try issueDiscardStagingAction(id: id, itemIndex: itemIndex)
        markRecoveryRequired(.unexplainedFilesystemEffect(id))
        try transitionItem(id: id, index: itemIndex, to: .cleanupRequired)
        try transitionOperation(id: id, to: .cleanupRequired)
        try transitionOperation(id: id, to: .recoveryRequired)
        controls[id] = nil
        activeID = nil
        return action
    }

    func retainSourceAndStop(id: OperationID, itemIndex: Int,
                             actionID: UUID? = nil,
                             invocationID: UUID? = nil) async throws {
        guard let operation = operations[id], operation.items.indices.contains(itemIndex),
              let receipt = operation.items[itemIndex].receipt,
              receipt.sourceCleanupPending else {
            throw FileOperationFailure(
                code: .controlRejected, operationID: id,
                itemID: operations[id]?.items[itemIndex].id,
                diagnostic: "retain source requires a durable pending-cleanup receipt",
                retryable: false
            )
        }
        let context = executionContext(operation: operation, itemIndex: itemIndex)
        let inspection = await dependencies.executor.inspectSourceBeforeCleanup(
            context, receipt: receipt
        )
        if let actionID, let invocationID {
            try requireRecoveryLease(id: id, actionID: actionID,
                                     invocationID: invocationID,
                                     itemID: operation.items[itemIndex].id)
        } else {
            try requireNormalOwnership(
                id: id, command: "cancel", expectedStates: [.committedAwaitingCleanup]
            )
        }
        switch inspection {
        case .sourcePresentMatching:
            break
        case .sourceAbsent:
            try convergeSourceAlreadyAbsent(id: id, itemIndex: itemIndex)
            return
        case let .sourceChanged(failure), let .unknown(failure):
            if operation.state == .committedAwaitingCleanup {
                try failCleanup(id: id, itemIndex: itemIndex, failure: failure, ambiguous: true)
            }
            throw failure
        }
        try restoreDurableCleanupBarrier(id: id, itemIndex: itemIndex, receipt: receipt)
        let retained = OperationReceiptSummary(
            committedIdentityDigest: receipt.committedIdentityDigest,
            backupURL: receipt.backupURL, quarantineURL: receipt.quarantineURL,
            sourceCleanupPending: false
        )
        try commitEvent(id: id, itemID: operations[id]!.items[itemIndex].id) { operation, _ in
            operation.sourceRetained = true
            operation.terminalFailure = nil
            operation.items[itemIndex].receipt = retained
            operation.items[itemIndex].failure = nil
            operation.committedEffects[operation.items[itemIndex].id] = retained
            return .receiptRecorded(retained)
        }
        try transitionItem(id: id, index: itemIndex, to: .completed)
        try cancelRemainingPending(id: id)
        if let actionID, let invocationID {
            await dependencies.failpoints.hit(
                .recoveryItemProjectionConverged, operationID: id
            )
            try Task.checkCancellation()
            try requireRecoveryLease(
                id: id, actionID: actionID, invocationID: invocationID,
                itemID: operation.items[itemIndex].id
            )
        }
        try transitionOperation(id: id, to: .completedWithSourceRetained)
        if recoveryLeases[id] == nil {
            activeID = nil
            Task { await self.runScheduler() }
        }
    }

    func convergeSourceAlreadyAbsent(id: OperationID, itemIndex: Int) throws {
        try recordSourceCleanupCompleted(id: id, itemIndex: itemIndex)
        try transitionItem(id: id, index: itemIndex, to: .completed) { item in
            item.failure = nil
        }
        operations[id]?.terminalFailure = nil
        try finishOrAdvance(id: id)
    }

    func executionContext(operation: ManagedOperation, itemIndex: Int) -> ExecutionContext {
        let item = operation.items[itemIndex]
        return ExecutionContext(
            operationID: operation.id, itemID: item.id, request: operation.request,
            source: item.source, destination: item.destination, itemIndex: itemIndex,
            metadataPolicy: operation.itemMetadataPolicies[item.id]
                ?? operation.remainingMetadataPolicy ?? operation.request.metadataPolicy,
            verificationPolicy: operation.effectiveVerificationPolicy
        )
    }

    /// Rebuilds only the durable state projection for an item whose commit
    /// receipt already exists. No adapter or executor filesystem method is
    /// called here; replaying staging/metadata effects after a restart would
    /// violate effect-ledger idempotency and can leak a second staging object.
    func projectDurableCommitIntent(id: OperationID, itemIndex: Int,
                                    receipt: OperationReceiptSummary) throws {
        guard let operation = operations[id], operation.items.indices.contains(itemIndex),
              operation.items[itemIndex].receipt == receipt,
              operation.committedEffects[operation.items[itemIndex].id] == receipt,
              let verification = operation.items[itemIndex].verification,
              verification.policy == operation.effectiveVerificationPolicy else {
            throw FileOperationFailure(
                code: .invariantViolation, operationID: id,
                itemID: operations[id]?.items[itemIndex].id,
                diagnostic: "durable receipt projection lacks matching ledger or verification",
                retryable: false
            )
        }
        func itemRank(_ state: OperationItemState) -> Int? {
            switch state {
            case .preflight: return 0
            case .staging: return 1
            case .metadata: return 2
            case .verifying: return 3
            case .committing: return 4
            default: return nil
            }
        }
        func operationRank(_ state: OperationState) -> Int? {
            switch state {
            case .preflight: return 0
            case .staging: return 1
            case .metadata: return 2
            case .verifying: return 3
            case .committing: return 4
            default: return nil
            }
        }
        let itemTargets: [OperationItemState] = [
            .preflight, .staging, .metadata, .verifying, .committing
        ]
        let operationTargets: [OperationState] = [
            .preflight, .staging, .metadata, .verifying, .committing
        ]
        guard var currentItemRank = itemRank(operation.items[itemIndex].state),
              var currentOperationRank = operationRank(operation.state),
              currentItemRank == currentOperationRank ||
                currentItemRank == currentOperationRank + 1 else {
            throw FileOperationFailure(
                code: .invariantViolation, operationID: id,
                itemID: operation.items[itemIndex].id,
                diagnostic: "durable receipt projection phases are not resumable",
                retryable: false
            )
        }
        while currentItemRank < 4 || currentOperationRank < 4 {
            if currentItemRank == currentOperationRank {
                let next = currentItemRank + 1
                try transitionItem(id: id, index: itemIndex, to: itemTargets[next])
                currentItemRank = next
            } else {
                let next = currentOperationRank + 1
                try transitionOperation(id: id, to: operationTargets[next])
                currentOperationRank = next
            }
        }
    }

    func resumeDurableReceiptProjection(id: OperationID, itemIndex: Int) throws {
        guard let receipt = operations[id]?.items[itemIndex].receipt,
              !receipt.sourceCleanupPending else {
            throw FileOperationFailure(
                code: .invariantViolation, operationID: id,
                itemID: operations[id]?.items[itemIndex].id,
                diagnostic: "automatic projection resume requires a cleanup-free receipt",
                retryable: false
            )
        }
        let projectionStates: Set<OperationItemState> = [
            .preflight, .staging, .metadata, .verifying, .committing
        ]
        if let state = operations[id]?.items[itemIndex].state,
           projectionStates.contains(state) {
            try projectDurableCommitIntent(id: id, itemIndex: itemIndex, receipt: receipt)
        }
        if operations[id]?.items[itemIndex].state == .committing {
            try transitionItem(id: id, index: itemIndex, to: .committed)
        }
        if operations[id]?.items[itemIndex].state == .committed {
            try transitionItem(id: id, index: itemIndex, to: .completed)
        }
        guard operations[id]?.items[itemIndex].state == .completed,
              operations[id]?.state == .committing else {
            throw FileOperationFailure(
                code: .invariantViolation, operationID: id,
                itemID: operations[id]?.items[itemIndex].id,
                diagnostic: "receipt projection terminal checkpoint is inconsistent",
                retryable: false
            )
        }
        try finishOrAdvance(id: id)
    }

    /// Once read-only inspection makes a pending source cleanup unambiguous,
    /// fold the item back through its receipt-backed commit projection. This
    /// uses only durable facts and creates no filesystem effect.
    func restoreDurableCleanupBarrier(id: OperationID, itemIndex: Int,
                                      receipt: OperationReceiptSummary) throws {
        guard receipt.sourceCleanupPending,
              let operation = operations[id], operation.items.indices.contains(itemIndex) else {
            throw FileOperationFailure(
                code: .invariantViolation, operationID: id,
                diagnostic: "cleanup barrier requires a durable pending receipt",
                retryable: false
            )
        }
        if operation.state == .committedAwaitingCleanup { return }
        if operation.items[itemIndex].state == .recoveryRequired {
            try transitionItem(id: id, index: itemIndex, to: .failedRecoverable)
        } else if operation.items[itemIndex].state == .cleanupRequired {
            try transitionItem(id: id, index: itemIndex, to: .failedRecoverable)
        }
        if operations[id]?.state == .recoveryRequired || operations[id]?.state == .cleanupRequired {
            try transitionOperation(id: id, to: .failedRecoverable)
        }
        if operations[id]?.items[itemIndex].state == .failedRecoverable {
            try transitionItem(id: id, index: itemIndex, to: .preflight) { $0.failure = nil }
        }
        if operations[id]?.state == .failedRecoverable {
            try transitionOperation(id: id, to: .preflight)
        }
        let itemState = operations[id]!.items[itemIndex].state
        if [.preflight, .staging, .metadata, .verifying, .committing].contains(itemState) {
            try projectDurableCommitIntent(id: id, itemIndex: itemIndex, receipt: receipt)
        }
        if operations[id]?.items[itemIndex].state == .committing {
            try transitionItem(id: id, index: itemIndex, to: .committed)
        }
        if operations[id]?.items[itemIndex].state == .committed {
            try transitionItem(id: id, index: itemIndex, to: .committedAwaitingCleanup)
        }
        if operations[id]?.state == .committing {
            try transitionOperation(id: id, to: .committedAwaitingCleanup)
        }
        guard operations[id]?.items[itemIndex].state == .committedAwaitingCleanup,
              operations[id]?.state == .committedAwaitingCleanup else {
            throw FileOperationFailure(
                code: .invariantViolation, operationID: id,
                itemID: operations[id]?.items[itemIndex].id,
                diagnostic: "cleanup barrier projection did not converge",
                retryable: false
            )
        }
    }

    func cancelRemainingPending(id: OperationID) throws {
        guard let operation = operations[id] else { return }
        for index in operation.items.indices where operations[id]!.items[index].state == .pending {
            try transitionItem(id: id, index: index, to: .cancelled)
        }
    }

    func issueDiscardStagingAction(id: OperationID, itemIndex: Int) throws
        -> RecoveryAction {
        let itemID = operations[id]!.items[itemIndex].id
        try commitEvent(id: id, itemID: itemID) { operation, sequence in
            let action = RecoveryAction.discardKnownStaging(RecoveryCommand(
                actionID: dependencies.ids.actionID(), expectedSequence: sequence
            ))
            operation.availableActions = [action]
            return .recoveryAvailable([action])
        }
        guard let action = operations[id]?.availableActions.first,
              case .discardKnownStaging = action else {
            throw FileOperationFailure(
                code: .invariantViolation, operationID: id, itemID: itemID,
                diagnostic: "discard staging action was not durably projected",
                retryable: false
            )
        }
        return action
    }

    func cleanupIsAuthorized(id: OperationID, itemIndex: Int,
                             expectedStates: Set<OperationState>,
                             expectedReceipt: OperationReceiptSummary) -> Bool {
        guard normalWritesAllowed, activeID == id,
              let operation = operations[id], operation.items.indices.contains(itemIndex),
              expectedStates.contains(operation.state),
              operation.items[itemIndex].receipt == expectedReceipt,
              expectedReceipt.sourceCleanupPending else { return false }
        let validItemStates: Set<OperationItemState> = [
            .committedAwaitingCleanup, .sourceQuarantining, .cleaningSource,
            .cleanupRequired, .recoveryRequired
        ]
        return validItemStates.contains(operation.items[itemIndex].state)
    }

    func retrySourceCleanup(id: OperationID, itemIndex: Int,
                            actionID: UUID, invocationID: UUID) async throws {
        guard let operation = operations[id], operation.items.indices.contains(itemIndex),
              let receipt = operation.items[itemIndex].receipt,
              receipt.sourceCleanupPending,
              [.cleanupRequired, .recoveryRequired, .cleaningSource].contains(operation.state) else {
            throw FileOperationFailure(
                code: .controlRejected, operationID: id,
                diagnostic: "source cleanup retry lacks a known durable receipt",
                retryable: false
            )
        }
        let item = operation.items[itemIndex]
        let context = executionContext(operation: operation, itemIndex: itemIndex)
        if operation.state != .cleaningSource {
            let inspection = await dependencies.executor.inspectSourceBeforeCleanup(
                context, receipt: receipt
            )
            try requireRecoveryLease(id: id, actionID: actionID,
                                     invocationID: invocationID,
                                     itemID: item.id)
            switch inspection {
            case .sourcePresentMatching:
                break
            case .sourceAbsent:
                try restoreDurableCleanupBarrier(
                    id: id, itemIndex: itemIndex, receipt: receipt
                )
                try convergeSourceAlreadyAbsent(id: id, itemIndex: itemIndex)
                return
            case let .sourceChanged(failure), let .unknown(failure):
                throw failure
            }
            try restoreDurableCleanupBarrier(
                id: id, itemIndex: itemIndex, receipt: receipt
            )
            try transitionItem(id: id, index: itemIndex, to: .sourceQuarantining)
            try transitionOperation(id: id, to: .sourceQuarantining)
            try transitionItem(id: id, index: itemIndex, to: .cleaningSource)
            try transitionOperation(id: id, to: .cleaningSource)
        }

        try await performRecoveryEffect(
            id: id, itemIndex: itemIndex, effect: .cleanupSource,
            actionID: actionID, invocationID: invocationID, receipt: receipt
        )

        // A completed recovery-effect result prevents a second delete, but the
        // receipt is updated only after a read-only source identity inspection.
        let inspection = await dependencies.executor.inspectSourceBeforeCleanup(
            context, receipt: receipt
        )
        try requireRecoveryLease(id: id, actionID: actionID,
                                 invocationID: invocationID,
                                 itemID: item.id, effect: .cleanupSource)
        switch inspection {
        case .sourceAbsent:
            try recordSourceCleanupCompleted(id: id, itemIndex: itemIndex)
            operations[id]?.terminalFailure = nil
            // Preserve an explicit durable nonterminal projection between the
            // completed cleanup receipt and terminal aggregation. Recovery can
            // repair this window without replaying source deletion.
            if operations[id]?.state == .cleaningSource {
                try transitionOperation(id: id, to: .cleanupRequired)
            }
            try transitionItem(id: id, index: itemIndex, to: .completed)
            await dependencies.failpoints.hit(
                .recoveryItemProjectionConverged, operationID: id
            )
            try Task.checkCancellation()
            try requireRecoveryLease(
                id: id, actionID: actionID, invocationID: invocationID,
                itemID: item.id, effect: .cleanupSource
            )
            try finishOrAdvance(id: id)
        case .sourcePresentMatching:
            throw FileOperationFailure(
                code: .recoveryRequired, operationID: id, itemID: item.id,
                diagnostic: "cleanup effect is durable but source still appears present",
                retryable: false
            )
        case let .sourceChanged(failure), let .unknown(failure):
            throw failure
        }
    }

    func recoverCommittedEffects(id: OperationID, effect: ExecutionRecoveryEffect,
                                 actionID: UUID, invocationID: UUID) async throws {
        guard let operation = operations[id], !operation.committedEffects.isEmpty else {
            throw FileOperationFailure(
                code: .controlRejected, operationID: id,
                diagnostic: "recovery effect requires a durable commit receipt",
                retryable: false
            )
        }
        for (index, item) in operation.items.enumerated() {
            guard let receipt = operation.committedEffects[item.id] else { continue }
            try await performRecoveryEffect(
                id: id, itemIndex: index, effect: effect,
                actionID: actionID, invocationID: invocationID, receipt: receipt
            )
        }
    }

    func performRecoveryEffect(
        id: OperationID, itemIndex: Int, effect: ExecutionRecoveryEffect,
        actionID: UUID, invocationID: UUID,
        receipt: OperationReceiptSummary?
    ) async throws {
        guard let operation = operations[id], operation.items.indices.contains(itemIndex) else {
            throw FileOperationFailure(code: .invariantViolation, operationID: id,
                                       diagnostic: "recovery effect item vanished", retryable: false)
        }
        let item = operation.items[itemIndex]
        let context = executionContext(operation: operation, itemIndex: itemIndex)
        var attempt = operation.recoveryEffectAttempts[actionID]?[item.id]
        try requireRecoveryLease(id: id, actionID: actionID,
                                 invocationID: invocationID, itemID: item.id)
        if let attempt, attempt.effect != effect {
            throw FileOperationFailure(
                code: .invariantViolation, operationID: id, itemID: item.id,
                diagnostic: "durable recovery intent effect does not match command",
                retryable: false
            )
        }
        if attempt?.result == .completed { return }

        if let unresolved = attempt, unresolved.result == nil {
            let inspection = try await inspectRecoveryEffect(
                effect, effectID: unresolved.effectID, context: context,
                receipt: receipt
            )
            try requireRecoveryLease(
                id: id, actionID: actionID, invocationID: invocationID,
                itemID: item.id, effect: effect, effectID: unresolved.effectID
            )
            switch inspection {
            case .completed:
                attempt = RecoveryEffectAttempt(
                    effectID: unresolved.effectID, effect: effect, result: .completed
                )
                try persistRecoveryAttempt(
                    id: id, actionID: actionID, itemID: item.id, attempt: attempt
                )
                await dependencies.failpoints.hit(
                    .recoveryEffectResultPersisted, operationID: id
                )
                try Task.checkCancellation()
                try requireRecoveryLease(
                    id: id, actionID: actionID, invocationID: invocationID,
                    itemID: item.id, effect: effect, effectID: unresolved.effectID
                )
                return
            case .notPerformed:
                attempt = RecoveryEffectAttempt(
                    effectID: unresolved.effectID, effect: effect, result: .notPerformed
                )
                try persistRecoveryAttempt(
                    id: id, actionID: actionID, itemID: item.id, attempt: attempt
                )
            case let .unknown(failure):
                throw failure
            }
        }

        if attempt == nil {
            try requireRecoveryLease(id: id, actionID: actionID,
                                     invocationID: invocationID, itemID: item.id)
            attempt = RecoveryEffectAttempt(
                effectID: dependencies.ids.actionID(), effect: effect
            )
            try persistRecoveryAttempt(
                id: id, actionID: actionID, itemID: item.id, attempt: attempt
            )
            await dependencies.failpoints.hit(
                .recoveryEffectIntentPersisted, operationID: id
            )
            try Task.checkCancellation()
            try requireRecoveryLease(
                id: id, actionID: actionID, invocationID: invocationID,
                itemID: item.id, effect: effect, effectID: attempt?.effectID
            )
        } else if attempt?.result == .notPerformed {
            guard let resolved = attempt else { return }
            try requireRecoveryLease(
                id: id, actionID: actionID, invocationID: invocationID,
                itemID: item.id, effect: effect, effectID: resolved.effectID
            )
            // Re-arm the same stable effect ID only after the read-only
            // not-performed result is durable.
            attempt = RecoveryEffectAttempt(
                effectID: resolved.effectID, effect: effect, result: nil
            )
            try persistRecoveryAttempt(
                id: id, actionID: actionID, itemID: item.id, attempt: attempt
            )
        }

        guard let armed = attempt, armed.result == nil else {
            throw FileOperationFailure(
                code: .invariantViolation, operationID: id, itemID: item.id,
                diagnostic: "recovery effect is not armed",
                retryable: false
            )
        }
        try requireRecoveryLease(
            id: id, actionID: actionID, invocationID: invocationID,
            itemID: item.id, effect: effect, effectID: armed.effectID
        )
        let outcome = try await executeRecoveryEffect(
            effect, effectID: armed.effectID, context: context, receipt: receipt
        )
        try Task.checkCancellation()
        try requireRecoveryLease(
            id: id, actionID: actionID, invocationID: invocationID,
            itemID: item.id, effect: effect, effectID: armed.effectID
        )
        switch outcome {
        case .completed:
            try persistRecoveryAttempt(
                id: id, actionID: actionID, itemID: item.id,
                attempt: RecoveryEffectAttempt(
                    effectID: armed.effectID, effect: effect, result: .completed
                )
            )
            await dependencies.failpoints.hit(
                .recoveryEffectResultPersisted, operationID: id
            )
            try Task.checkCancellation()
            try requireRecoveryLease(
                id: id, actionID: actionID, invocationID: invocationID,
                itemID: item.id, effect: effect, effectID: armed.effectID
            )
        case let .failedBeforeEffect(failure):
            // Only a typed guarantee that mutation never began can remove the
            // write-ahead intent and authorize a future fresh attempt.
            try persistRecoveryAttempt(
                id: id, actionID: actionID, itemID: item.id, attempt: nil
            )
            throw failure
        case let .ambiguous(failure):
            // Preserve the unresolved durable intent. A later call must inspect
            // this exact effect ID and must not blindly call recover again.
            throw failure
        }
    }

    func inspectRecoveryEffect(
        _ effect: ExecutionRecoveryEffect, effectID: UUID,
        context: ExecutionContext, receipt: OperationReceiptSummary?
    ) async throws -> ExecutionRecoveryInspection {
        if effect == .cleanupStaging {
            return await dependencies.fileSystem.inspectOwnedStaging(
                operationID: context.operationID, itemID: context.itemID,
                effectID: effectID
            )
        }
        guard let receipt else {
            throw FileOperationFailure(
                code: .invariantViolation, operationID: context.operationID,
                itemID: context.itemID,
                diagnostic: "committed recovery effect lacks a durable receipt",
                retryable: false
            )
        }
        return await dependencies.executor.inspectRecoveryEffect(
            effect, effectID: effectID, context: context, receipt: receipt
        )
    }

    func executeRecoveryEffect(
        _ effect: ExecutionRecoveryEffect, effectID: UUID,
        context: ExecutionContext, receipt: OperationReceiptSummary?
    ) async throws -> ExecutionRecoveryOutcome {
        if effect == .cleanupStaging {
            return await dependencies.fileSystem.recoverOwnedStaging(
                operationID: context.operationID, itemID: context.itemID,
                effectID: effectID
            )
        }
        guard let receipt else {
            throw FileOperationFailure(
                code: .invariantViolation, operationID: context.operationID,
                itemID: context.itemID,
                diagnostic: "committed recovery effect lacks a durable receipt",
                retryable: false
            )
        }
        return await dependencies.executor.recover(
            effect, effectID: effectID, context: context, receipt: receipt
        )
    }

    /// Re-inspects only commit-ambiguous items that have no durable effect
    /// receipt. Unknown results remain recoveryRequired and the token is left
    /// unconsumed. A positive result is journaled before any recovery effect;
    /// a negative result must first converge an operation-owned staging cleanup
    /// through the same durable recovery ledger. `notCommitted` proves only
    /// that the final destination effect is absent, never that staging vanished.
    func inspectUnknownCommits(id: OperationID, actionID: UUID,
                               invocationID: UUID) async throws -> Bool {
        guard let operation = operations[id] else { return false }
        for (index, item) in operation.items.enumerated()
        where item.state == .recoveryRequired && operation.committedEffects[item.id] == nil {
            let context = ExecutionContext(
                operationID: id, itemID: item.id, request: operation.request,
                source: item.source, destination: item.destination, itemIndex: index,
                metadataPolicy: operation.itemMetadataPolicies[item.id]
                    ?? operation.remainingMetadataPolicy ?? operation.request.metadataPolicy,
                verificationPolicy: operation.effectiveVerificationPolicy
            )
            let inspection = await dependencies.executor.inspectCommit(context)
            try requireRecoveryLease(id: id, actionID: actionID,
                                     invocationID: invocationID,
                                     itemID: item.id)
            switch inspection {
            case let .committed(receipt):
                try recordReceipt(id: id, itemIndex: index, receipt: receipt)
            case .notCommitted:
                try await performRecoveryEffect(
                    id: id, itemIndex: index, effect: .cleanupStaging,
                    actionID: actionID, invocationID: invocationID, receipt: nil
                )
                try requireRecoveryLease(
                    id: id, actionID: actionID, invocationID: invocationID,
                    itemID: item.id, effect: .cleanupStaging
                )
            case let .unknown(failure):
                throw failure
            }
        }
        return operations[id]?.committedEffects.isEmpty == false
    }

    func persistRecoveryAttempt(
        id: OperationID, actionID: UUID, itemID: OperationItemID,
        attempt: RecoveryEffectAttempt?
    ) throws {
        guard var candidate = operations[id] else { return }
        if let attempt {
            candidate.recoveryEffectAttempts[actionID, default: [:]][itemID] = attempt
        } else {
            candidate.recoveryEffectAttempts[actionID]?[itemID] = nil
            if candidate.recoveryEffectAttempts[actionID]?.isEmpty == true {
                candidate.recoveryEffectAttempts[actionID] = nil
            }
        }
        do {
            try dependencies.journal.checkpoint(candidate.journalOperation)
            operations[id] = candidate
            recomputeRecoveryModeAfterDurableCheckpoint()
        } catch {
            enterSafeMode(error)
            throw FileOperationFailure(
                code: .journalFailure, operationID: id, itemID: itemID,
                diagnostic: String(describing: error), retryable: false
            )
        }
    }

    func requireRecoveryLease(
        id: OperationID, actionID: UUID, invocationID: UUID,
        itemID: OperationItemID? = nil,
        effect: ExecutionRecoveryEffect? = nil,
        effectID: UUID? = nil
    ) throws {
        guard !fatalModeActive else {
            throw FileOperationFailure(
                code: .serviceSafeMode, operationID: id, itemID: itemID,
                diagnostic: "fatal service mode revoked recovery authorization",
                retryable: false
            )
        }
        let expected = RecoveryLease(invocationID: invocationID, actionID: actionID)
        guard activeID == id, recoveryLeases[id] == expected,
              let operation = operations[id],
              operation.inProgressRecoveryActions == [actionID],
              operation.availableActions.count == 1,
              operation.availableActions.first?.command.actionID == actionID else {
            throw FileOperationFailure(
                code: .controlRejected, operationID: id, itemID: itemID,
                diagnostic: "recovery invocation lost its exclusive lease",
                retryable: false
            )
        }
        guard let itemID else { return }
        guard operation.items.contains(where: { $0.id == itemID }) else {
            throw FileOperationFailure(
                code: .controlRejected, operationID: id, itemID: itemID,
                diagnostic: "recovery item no longer belongs to the operation",
                retryable: false
            )
        }
        guard let effect else { return }
        guard let attempt = operation.recoveryEffectAttempts[actionID]?[itemID],
              attempt.effect == effect,
              effectID == nil || attempt.effectID == effectID else {
            throw FileOperationFailure(
                code: .controlRejected, operationID: id, itemID: itemID,
                diagnostic: "recovery effect no longer matches its durable intent",
                retryable: false
            )
        }
    }

    /// Repairs only the operation-level half of a recovery projection when
    /// durable per-item facts already prove the selected command completed.
    /// Unresolved (`result == nil`) and merely inspected-not-performed attempts
    /// never authorize convergence.
    func repairRecoveryProjectionIfPossible(id: OperationID,
                                            action: RecoveryAction) throws {
        guard let operation = operations[id],
              operation.inProgressRecoveryActions == [action.command.actionID],
              operation.availableActions == [action] else { return }
        let attempts = operation.recoveryEffectAttempts[action.command.actionID] ?? [:]
        func completedAttempt(_ itemID: OperationItemID,
                              effect: ExecutionRecoveryEffect) -> Bool {
            guard let attempt = attempts[itemID] else { return false }
            return attempt.effect == effect && attempt.result == .completed
        }
        func operationIsOneOf(_ states: Set<OperationState>) -> Bool {
            states.contains(operation.state)
        }

        switch action {
        case .rollbackCommittedDestination, .restoreBackup:
            let committedItemIDs = Set(operation.committedEffects.keys)
            if committedItemIDs.isEmpty {
                guard !attempts.isEmpty,
                      attempts.values.allSatisfy({
                          $0.effect == .cleanupStaging && $0.result == .completed
                      }),
                      operation.items.allSatisfy({
                          $0.state == .cancelled || $0.state == .skipped
                      }),
                      operationIsOneOf([.recoveryRequired, .cleanupRequired]) else { return }
                operations[id]?.terminalFailure = nil
                if operation.state == .recoveryRequired {
                    try transitionOperation(id: id, to: .cleanupRequired)
                }
                try transitionOperation(id: id, to: .cancelled)
                return
            }
            guard attempts.count >= committedItemIDs.count,
                  committedItemIDs.allSatisfy({
                      completedAttempt($0, effect: .rollbackCommittedDestination)
                  }),
                  attempts.allSatisfy({ itemID, attempt in
                      if committedItemIDs.contains(itemID) {
                          return attempt.effect == .rollbackCommittedDestination &&
                              attempt.result == .completed
                      }
                      return attempt.effect == .cleanupStaging &&
                          attempt.result == .completed
                  }),
                  operation.items.allSatisfy({ item in
                      committedItemIDs.contains(item.id)
                          ? item.state == .rolledBack
                          : item.state == .cancelled || item.state == .skipped
                  }),
                  operationIsOneOf([.failedRecoverable, .recoveryRequired,
                                    .cleanupRequired]) else { return }
            operations[id]?.terminalFailure = nil
            operations[id]?.sourceRetained = false
            try transitionOperation(id: id, to: .rolledBack)

        case .finalizeKnownCommit:
            let committedItemIDs = Set(operation.committedEffects.keys)
            if committedItemIDs.isEmpty {
                guard !attempts.isEmpty,
                      attempts.values.allSatisfy({
                          $0.effect == .cleanupStaging && $0.result == .completed
                      }),
                      operation.items.allSatisfy({
                          $0.state == .cancelled || $0.state == .skipped
                      }),
                      operationIsOneOf([.recoveryRequired, .cleanupRequired]) else { return }
                operations[id]?.terminalFailure = nil
                if operation.state == .recoveryRequired {
                    try transitionOperation(id: id, to: .cleanupRequired)
                }
                try transitionOperation(id: id, to: .cancelled)
                return
            }
            guard !committedItemIDs.isEmpty,
                  attempts.count >= committedItemIDs.count,
                  committedItemIDs.allSatisfy({
                      completedAttempt($0, effect: .finalizeKnownCommit)
                  }),
                  attempts.allSatisfy({ itemID, attempt in
                      if committedItemIDs.contains(itemID) {
                          return attempt.effect == .finalizeKnownCommit &&
                              attempt.result == .completed
                      }
                      return attempt.effect == .cleanupStaging &&
                          attempt.result == .completed
                  }),
                  operation.items.allSatisfy({
                      $0.state == .completed || $0.state == .skipped
                  }),
                  operationIsOneOf([.preflight, .failedRecoverable,
                                    .recoveryRequired]) else { return }
            operations[id]?.terminalFailure = nil
            let terminal: OperationState = operation.items.contains { $0.state == .skipped }
                ? .completedWithSkips : .completed
            try transitionOperation(id: id, to: terminal)

        case .retrySourceCleanup:
            let cleanupCompleted = operation.items.contains { item in
                item.state == .completed && item.receipt?.sourceCleanupPending == false &&
                    completedAttempt(item.id, effect: .cleanupSource)
            }
            guard attempts.count == 1,
                  attempts.values.allSatisfy({
                      $0.effect == .cleanupSource && $0.result == .completed
                  }), cleanupCompleted,
                  operation.items.allSatisfy({
                      $0.state == .completed || $0.state == .skipped
                  }),
                  operationIsOneOf([.cleaningSource, .cleanupRequired,
                                    .recoveryRequired]) else { return }
            operations[id]?.terminalFailure = nil
            let terminal: OperationState = operation.items.contains { $0.state == .skipped }
                ? .completedWithSkips : .completed
            try transitionOperation(id: id, to: terminal)

        case .retainSource:
            let retainedReceiptIsDurable = operation.items.contains { item in
                item.state == .completed && item.receipt?.sourceCleanupPending == false
            }
            guard attempts.isEmpty, operation.sourceRetained, retainedReceiptIsDurable,
                  operation.items.allSatisfy({
                      $0.state == .completed || $0.state == .cancelled || $0.state == .skipped
                  }),
                  operationIsOneOf([.committedAwaitingCleanup, .cleanupRequired,
                                    .recoveryRequired]) else { return }
            operations[id]?.terminalFailure = nil
            try transitionOperation(id: id, to: .completedWithSourceRetained)

        case .discardKnownStaging:
            let discardedItemIDs = Set(operation.items.compactMap { item in
                completedAttempt(item.id, effect: .cleanupStaging) ? item.id : nil
            })
            guard !discardedItemIDs.isEmpty,
                  attempts.values.allSatisfy({
                      $0.effect == .cleanupStaging && $0.result == .completed
                  }),
                  operationIsOneOf([.cleanupRequired, .recoveryRequired]) else { return }
            if operation.items.allSatisfy({ $0.state == .cancelled }) {
                try transitionOperation(id: id, to: .cancelled)
            } else if operation.hasPartialCommit,
                      operation.items.contains(where: {
                          discardedItemIDs.contains($0.id) && $0.state == .failedRecoverable
                      }) {
                try transitionOperation(id: id, to: .failedRecoverable)
            }

        case .resumeFromVerifiedStage:
            return
        }
    }

    func recoveryProjectionIsConverged(id: OperationID,
                                       action: RecoveryAction) -> Bool {
        guard let operation = operations[id] else { return false }
        switch action {
        case .rollbackCommittedDestination, .restoreBackup:
            return operation.state == .rolledBack ||
                (operation.state == .cancelled && operation.committedEffects.isEmpty)
        case .finalizeKnownCommit:
            return [.completed, .completedWithSkips].contains(operation.state) ||
                (operation.state == .cancelled && operation.committedEffects.isEmpty)
        case .retrySourceCleanup:
            return [.completed, .completedWithSkips,
                    .completedWithSourceRetained].contains(operation.state)
        case .retainSource:
            return operation.state == .completedWithSourceRetained
        case .discardKnownStaging:
            return operation.state == .cancelled ||
                (operation.state == .failedRecoverable && operation.hasPartialCommit)
        case .resumeFromVerifiedStage:
            return [.planned, .preflight, .waitingForDecision, .staging, .paused,
                    .metadata, .verifying, .completed,
                    .completedWithSkips, .completedWithSourceRetained].contains(operation.state)
        }
    }

    func completeRecoveryCommand(id: OperationID, actionID: UUID) throws {
        guard let current = operations[id],
              !current.completedRecoveryActions.contains(actionID) else { return }
        let completedDiscard = current.availableActions.contains {
            guard $0.command.actionID == actionID else { return false }
            if case .discardKnownStaging = $0 { return true }
            return false
        }
        try commitEvent(id: id, itemID: nil) { candidate, sequence in
            candidate.inProgressRecoveryActions.remove(actionID)
            candidate.completedRecoveryActions.insert(actionID)
            // The selected capability and its siblings are stale once this
            // convergence event is durable. Any successor capability is bound
            // to the new sequence and can be recovered by replay consumers.
            if completedDiscard, candidate.state == .failedRecoverable,
               candidate.hasPartialCommit,
               let item = candidate.items.first(where: { $0.state == .failedRecoverable }) {
                let partial = FileOperationFailure(
                    code: .partialCommit, operationID: id, itemID: item.id,
                    phase: candidate.state,
                    diagnostic: "one or more prior items are durably committed",
                    retryable: false
                )
                candidate.terminalFailure = partial
                candidate.availableActions = [
                    .rollbackCommittedDestination(RecoveryCommand(
                        actionID: dependencies.ids.actionID(), expectedSequence: sequence
                    )),
                    .finalizeKnownCommit(RecoveryCommand(
                        actionID: dependencies.ids.actionID(), expectedSequence: sequence
                    ))
                ]
            } else if completedDiscard, candidate.state == .failedRecoverable,
                      candidate.items.contains(where: {
                          $0.state == .failedRecoverable && $0.failure != nil
                      }) {
                candidate.availableActions = [
                    .resumeFromVerifiedStage(RecoveryCommand(
                        actionID: dependencies.ids.actionID(), expectedSequence: sequence
                    ))
                ]
            } else {
                candidate.availableActions.removeAll()
            }
            return .recoveryConverged(
                completedActionID: actionID,
                availableActions: candidate.availableActions
            )
        }
        recomputeRecoveryModeAfterDurableCheckpoint()
    }

    func convergeRolledBack(id: OperationID) async throws {
        guard let operation = operations[id] else { return }
        func completedStagingCleanup(_ itemID: OperationItemID) -> Bool {
            operation.recoveryEffectAttempts.values.contains { attempts in
                guard let attempt = attempts[itemID] else { return false }
                return attempt.effect == .cleanupStaging && attempt.result == .completed
            }
        }
        for index in operation.items.indices {
            let item = operations[id]!.items[index]
            let hadCommittedEffect = operations[id]!.committedEffects[item.id] != nil
            if hadCommittedEffect {
                switch item.state {
                case .completed, .failedRecoverable, .recoveryRequired:
                    try transitionItem(id: id, index: index, to: .rolledBack) {
                        $0.failure = nil
                    }
                case .rolledBack:
                    break
                default:
                    throw FileOperationFailure(
                        code: .invariantViolation, operationID: id, itemID: item.id,
                        phase: operations[id]?.state,
                        diagnostic: "receipt-backed rollback has incompatible item state",
                        retryable: false
                    )
                }
            } else {
                switch item.state {
                case .pending:
                    try transitionItem(id: id, index: index, to: .cancelled) {
                        $0.failure = nil
                    }
                case .failedRecoverable, .cleanupRequired, .recoveryRequired:
                    guard completedStagingCleanup(item.id) else {
                        throw FileOperationFailure(
                            code: .invariantViolation, operationID: id,
                            itemID: item.id, phase: operations[id]?.state,
                            diagnostic: "receipt-free rollback lacks confirmed staging cleanup",
                            retryable: false
                        )
                    }
                    try transitionItem(id: id, index: index, to: .cancelled) {
                        $0.failure = nil
                    }
                case .cancelled, .skipped:
                    break
                default:
                    throw FileOperationFailure(
                        code: .invariantViolation, operationID: id, itemID: item.id,
                        phase: operations[id]?.state,
                        diagnostic: "receipt-free item cannot claim rollback",
                        retryable: false
                    )
                }
            }
        }
        var cleaned = operations[id]!
        // Commit receipts are an append-only audit ledger. A rollback changes
        // the operation outcome; it must not erase proof that the original
        // external effect existed and was the target of the rollback action.
        cleaned.terminalFailure = nil
        cleaned.sourceRetained = false
        do {
            try dependencies.journal.checkpoint(cleaned.journalOperation)
            operations[id] = cleaned
        } catch {
            enterSafeMode(error)
            throw FileOperationFailure(
                code: .journalFailure, operationID: id,
                diagnostic: String(describing: error), retryable: false
            )
        }
        await dependencies.failpoints.hit(
            .recoveryItemProjectionConverged, operationID: id
        )
        try Task.checkCancellation()
        try transitionOperation(id: id, to: .rolledBack)
    }

    /// Converges an ambiguous operation only after every inspected active item
    /// has a durable completed staging-cleanup result and no commit receipt
    /// exists. Pending items never started, so they can be cancelled directly.
    func convergeConfirmedNoCommit(id: OperationID) async throws {
        guard let operation = operations[id], operation.committedEffects.isEmpty else {
            throw FileOperationFailure(
                code: .invariantViolation, operationID: id,
                diagnostic: "no-commit convergence conflicts with a durable receipt",
                retryable: false
            )
        }
        func completedStagingCleanup(_ itemID: OperationItemID) -> Bool {
            operation.recoveryEffectAttempts.values.contains { attempts in
                guard let attempt = attempts[itemID] else { return false }
                return attempt.effect == .cleanupStaging && attempt.result == .completed
            }
        }
        operations[id]?.terminalFailure = nil
        if operations[id]?.state == .recoveryRequired {
            try transitionOperation(id: id, to: .cleanupRequired)
        }
        for index in operation.items.indices {
            let item = operations[id]!.items[index]
            switch item.state {
            case .pending:
                try transitionItem(id: id, index: index, to: .cancelled)
            case .failedRecoverable, .cleanupRequired, .recoveryRequired:
                guard completedStagingCleanup(item.id) else {
                    throw FileOperationFailure(
                        code: .invariantViolation, operationID: id, itemID: item.id,
                        phase: operations[id]?.state,
                        diagnostic: "cancelled projection lacks confirmed staging cleanup",
                        retryable: false
                    )
                }
                try transitionItem(id: id, index: index, to: .cancelled) {
                    $0.failure = nil
                }
            case .cancelled, .skipped:
                break
            default:
                throw FileOperationFailure(
                    code: .invariantViolation, operationID: id, itemID: item.id,
                    phase: operations[id]?.state,
                    diagnostic: "no-commit convergence has incompatible item state",
                    retryable: false
                )
            }
        }
        await dependencies.failpoints.hit(
            .recoveryItemProjectionConverged, operationID: id
        )
        try Task.checkCancellation()
        guard operations[id]?.state == .cleanupRequired else {
            throw FileOperationFailure(
                code: .invariantViolation, operationID: id,
                diagnostic: "no-commit convergence lacks cleanup barrier",
                retryable: false
            )
        }
        try transitionOperation(id: id, to: .cancelled)
    }

    func convergeFinalizedPartialCommit(id: OperationID) async throws {
        guard let operation = operations[id] else { return }
        if operation.state == .recoveryRequired {
            try transitionOperation(id: id, to: .failedRecoverable)
        }
        if operations[id]?.state == .failedRecoverable {
            try transitionOperation(id: id, to: .preflight)
        }
        for index in operation.items.indices {
            var item = operations[id]!.items[index]
            if let receipt = item.receipt {
                guard !receipt.sourceCleanupPending else {
                    throw FileOperationFailure(
                        code: .recoveryRequired, operationID: id, itemID: item.id,
                        diagnostic: "known commit still requires source cleanup",
                        retryable: false
                    )
                }
                if item.state == .recoveryRequired {
                    try transitionItem(id: id, index: index, to: .failedRecoverable) {
                        $0.failure = nil
                    }
                }
                if operations[id]?.items[index].state == .failedRecoverable {
                    try transitionItem(id: id, index: index, to: .preflight) {
                        $0.failure = nil
                    }
                }
                item = operations[id]!.items[index]
                if [.preflight, .staging, .metadata, .verifying, .committing]
                    .contains(item.state) {
                    try projectDurableCommitIntent(
                        id: id, itemIndex: index, receipt: receipt
                    )
                }
                if operations[id]?.items[index].state == .committing {
                    try transitionItem(id: id, index: index, to: .committed)
                }
                if operations[id]?.items[index].state == .committed {
                    try transitionItem(id: id, index: index, to: .completed)
                }
                guard operations[id]?.items[index].state == .completed else {
                    throw FileOperationFailure(
                        code: .invariantViolation, operationID: id, itemID: item.id,
                        diagnostic: "finalize projection did not reach completed",
                        retryable: false
                    )
                }
            } else {
                if item.state == .recoveryRequired {
                    try transitionItem(id: id, index: index, to: .failedRecoverable) {
                        $0.failure = nil
                    }
                }
                if operations[id]?.items[index].state == .failedRecoverable {
                    try transitionItem(id: id, index: index, to: .preflight) {
                        $0.failure = nil
                    }
                }
                if operations[id]?.items[index].state == .pending ||
                    operations[id]?.items[index].state == .preflight {
                    try transitionItem(id: id, index: index, to: .skipped)
                }
            }
            let hasRemaining = operations[id]!.items[(index + 1)...].contains {
                ![.completed, .skipped, .cancelled, .rolledBack].contains($0.state)
            }
            if hasRemaining, operations[id]?.state == .committing {
                try transitionOperation(id: id, to: .preflight)
            }
        }
        operations[id]?.terminalFailure = nil
        let hasSkips = operations[id]!.items.contains { $0.state == .skipped }
        await dependencies.failpoints.hit(
            .recoveryItemProjectionConverged, operationID: id
        )
        try Task.checkCancellation()
        try transitionOperation(id: id, to: hasSkips ? .completedWithSkips : .completed)
    }

    func convergeRecoveredStagingCleanup(id: OperationID, itemIndex: Int) async throws {
        let partial = operations[id]?.items.contains { item in
            item.id != operations[id]?.items[itemIndex].id && item.receipt != nil
        } == true
        let failedPrecommit = operations[id]?.items[itemIndex].failure != nil
        if operations[id]?.state == .recoveryRequired {
            try transitionOperation(id: id, to: .cleanupRequired)
        }
        if partial || failedPrecommit {
            try transitionItem(id: id, index: itemIndex, to: .failedRecoverable)
            if partial { try cancelRemainingPending(id: id) }
            await dependencies.failpoints.hit(
                .recoveryItemProjectionConverged, operationID: id
            )
            try Task.checkCancellation()
            try transitionOperation(id: id, to: .failedRecoverable)
        } else {
            try transitionItem(id: id, index: itemIndex, to: .cancelled)
            try cancelRemainingPending(id: id)
            await dependencies.failpoints.hit(
                .recoveryItemProjectionConverged, operationID: id
            )
            try Task.checkCancellation()
            try transitionOperation(id: id, to: .cancelled)
        }
    }

    func rejectKnownControl(_ id: OperationID, command: String) {
        guard normalWritesAllowed else {
            rejectControlForServiceMode(id, command: command)
            return
        }
        do {
            try commitEvent(id: id, itemID: nil) { operation, _ in
                let failure = FileOperationFailure(code: .controlRejected, operationID: id,
                                                   phase: operation.state,
                                                   diagnostic: "\(command) rejected in \(operation.state.rawValue)",
                                                   retryable: false)
                return .failure(failure)
            }
        } catch { enterSafeMode(error) }
    }

    func rejectControlForServiceMode(_ id: OperationID, command: String) {
        dependencies.diagnostics.record(.controlRejected(
            operationID: id, command: command,
            reason: "file operation service is not in normal mode"
        ))
    }

    func rejectControlAfterAwait(_ id: OperationID, command: String) {
        if normalWritesAllowed {
            rejectKnownControl(id, command: command)
        } else {
            rejectControlForServiceMode(id, command: command)
        }
    }

    func requireNormalServiceMode(command: String) throws {
        guard normalWritesAllowed else {
            throw FileOperationFailure(
                code: .serviceSafeMode,
                diagnostic: "\(command) requires normal service mode",
                retryable: false
            )
        }
    }

    func requireNormalOwnership(id: OperationID, command: String,
                                expectedStates: Set<OperationState>) throws {
        guard normalWritesAllowed else {
            throw FileOperationFailure(
                code: .serviceSafeMode, operationID: id,
                diagnostic: "\(command) lost normal service-mode authorization",
                retryable: false
            )
        }
        guard activeID == id, let operation = operations[id],
              expectedStates.contains(operation.state) else {
            throw FileOperationFailure(
                code: .controlRejected, operationID: id,
                diagnostic: "\(command) lost active operation ownership",
                retryable: false
            )
        }
    }

    func handleAutomaticRecoveryFailure(_ error: Error, id: OperationID) {
        if error is CancellationError { return }
        if let failure = error as? FileOperationFailure {
            switch failure.code {
            case .journalFailure, .invariantViolation:
                if !fatalModeActive { enterSafeMode(failure) }
            default:
                dependencies.diagnostics.record(.controlRejected(
                    operationID: id, command: "cancel-recovery",
                    reason: failure.diagnostic
                ))
            }
            return
        }
        enterSafeMode(error)
    }

    func activeItemIndex(_ operation: ManagedOperation) -> Int? {
        operation.items.firstIndex { ![.pending, .completed, .skipped, .cancelled, .rolledBack].contains($0.state) }
    }
}

// MARK: - Pull-based replay and bounded live handoff

private extension FileOperationService {
    func nextEvent(subscriberID: UUID) async -> OperationEvent? {
        guard var subscriber = subscribers[subscriberID] else { return nil }
        if subscriber.invalid {
            subscribers.removeValue(forKey: subscriberID)
            return nil
        }
        if !subscriber.replayPage.isEmpty {
            let event = subscriber.replayPage.removeFirst()
            subscriber.replayCursor[event.operationID] = event.sequence
            subscribers[subscriberID] = subscriber
            return event
        }
        while subscriber.replayIndex < subscriber.replayOrder.count {
            let operationID = subscriber.replayOrder[subscriber.replayIndex]
            let after = subscriber.replayCursor[operationID] ?? 0
            let watermark = subscriber.watermarks[operationID] ?? 0
            do {
                let page = try dependencies.journal.replay(operationID: operationID, after: after,
                                                           through: watermark,
                                                           limit: dependencies.replayPageSize)
                if let first = page.first {
                    subscriber.replayPage = Array(page.dropFirst())
                    subscriber.replayCursor[operationID] = first.sequence
                    subscribers[subscriberID] = subscriber
                    return first
                }
            } catch {
                subscriber.invalid = true
                subscribers[subscriberID] = subscriber
                dependencies.diagnostics.record(.subscriberInvalidated(subscriberID))
                return nil
            }
            subscriber.replayIndex += 1
        }
        guard !subscriber.live.isEmpty else {
            subscribers[subscriberID] = subscriber
            return await withCheckedContinuation { continuation in
                guard var current = subscribers[subscriberID], !current.invalid else {
                    continuation.resume(returning: nil)
                    return
                }
                current.waiter = continuation
                subscribers[subscriberID] = current
            }
        }
        let event = subscriber.live.removeFirst()
        subscribers[subscriberID] = subscriber
        return event
    }

    func removeSubscriber(_ id: UUID) {
        let waiter = subscribers.removeValue(forKey: id)?.waiter
        waiter?.resume(returning: nil)
    }

    func broadcast(_ event: OperationEvent) {
        for id in Array(subscribers.keys) {
            guard var subscriber = subscribers[id], !subscriber.invalid,
                  event.sequence > (subscriber.watermarks[event.operationID] ?? 0) else { continue }
            if let waiter = subscriber.waiter, subscriber.replayIndex >= subscriber.replayOrder.count,
               subscriber.replayPage.isEmpty {
                subscriber.waiter = nil
                subscribers[id] = subscriber
                waiter.resume(returning: event)
                continue
            }
            if case .progress = event.payload,
               let tail = subscriber.live.last,
               tail.operationID == event.operationID,
               tail.itemID == event.itemID,
               case .progress = tail.payload {
                // Coalesce only the contiguous tail. Replacing an older
                // progress entry across a later state/control event would put
                // the new sequence before an older sequence in the stream.
                subscriber.live[subscriber.live.count - 1] = event
            } else if subscriber.live.count >= dependencies.liveBufferLimit {
                subscriber.invalid = true
                subscriber.live.removeAll()
                let waiter = subscriber.waiter
                subscriber.waiter = nil
                dependencies.diagnostics.record(.subscriberInvalidated(id))
                waiter?.resume(returning: nil)
            } else {
                subscriber.live.append(event)
            }
            subscribers[id] = subscriber
        }
    }

    func enterSafeMode(_ error: Error) {
        var reasons: Set<FatalServiceReason> = [
            .journalMutationFailure(String(describing: error))
        ]
        if case let .fatal(existing) = serviceMode {
            reasons.formUnion(existing)
        }
        serviceMode = .fatal(reasons)
        dependencies.diagnostics.record(.journalFailure(String(describing: error)))
    }

    var normalWritesAllowed: Bool {
        if case .normal = serviceMode { return true }
        return false
    }

    var fatalModeActive: Bool {
        if case .fatal = serviceMode { return true }
        return false
    }

    func markRecoveryRequired(_ reason: RecoveryRequiredReason) {
        switch serviceMode {
        case .fatal:
            return
        case .normal:
            serviceMode = .recoveryRequired([reason])
        case var .recoveryRequired(reasons):
            reasons.insert(reason)
            serviceMode = .recoveryRequired(reasons)
        }
    }

    func recoveryModeAllowsSelection(for id: OperationID) -> Bool {
        guard case let .recoveryRequired(reasons) = serviceMode else { return true }
        return reasons.allSatisfy { reason in
            switch reason {
            case let .durableCommand(operationID),
                 let .unresolvedEffect(operationID),
                 let .unexplainedFilesystemEffect(operationID):
                return operationID == id
            }
        }
    }

    func recomputeRecoveryModeAfterDurableCheckpoint() {
        guard !fatalModeActive else { return }
        var reasons: Set<RecoveryRequiredReason> = []
        for operation in operations.values {
            if !operation.inProgressRecoveryActions.isEmpty {
                reasons.insert(.durableCommand(operation.id))
            }
            if operation.hasUnresolvedRecoveryEffects {
                reasons.insert(.unresolvedEffect(operation.id))
            }
            if operation.hasUnexplainedFilesystemEffect {
                reasons.insert(.unexplainedFilesystemEffect(operation.id))
            }
            if operation.state == .recoveryRequired {
                reasons.insert(.unexplainedFilesystemEffect(operation.id))
            }
            if operation.hasPendingStagingRecovery {
                reasons.insert(.unexplainedFilesystemEffect(operation.id))
            }
            if operation.hasInterruptedPrecommit {
                reasons.insert(.unexplainedFilesystemEffect(operation.id))
            }
        }
        serviceMode = reasons.isEmpty ? .normal : .recoveryRequired(reasons)
    }

    func checkedSuccessor(_ value: UInt64) -> UInt64 {
        let (next, overflow) = value.addingReportingOverflow(1)
        return overflow ? UInt64.max : next
    }
}
