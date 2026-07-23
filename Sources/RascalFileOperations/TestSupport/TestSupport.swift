import Foundation
import RascalFileOperations

public struct FatalRecoveryStartupFixture: Sendable {
    public let recoveryOperationID: OperationID
    public let recoveryItemID: OperationItemID
    public let action: RecoveryAction
}

public final class InMemoryOperationJournal: @unchecked Sendable, OperationJournal {
    private struct StateWaiter {
        let id: UUID
        let state: OperationState
        let continuation: CheckedContinuation<OperationSnapshot, Error>
    }
    private let lock = NSLock()
    private var operations: [OperationID: JournalOperation] = [:]
    private var events: [OperationID: [OperationEvent]] = [:]
    private var ordinal: UInt64 = 0
    private var failNextWrite = false
    private var stateWaiters: [OperationID: [StateWaiter]] = [:]
    package let isWritable = true

    public init() {}

    public func injectNextWriteFailure() {
        lock.withLock { failNextWrite = true }
    }

    public func operationCount() -> Int { lock.withLock { operations.count } }
    public func eventCount(operationID: OperationID) -> Int {
        lock.withLock { events[operationID, default: []].count }
    }
    public func storedOperation(_ id: OperationID) -> OperationSnapshot? {
        lock.withLock { operations[id]?.snapshot }
    }
    public func durableCommitReceipt(operationID: OperationID,
                                     itemID: OperationItemID) -> OperationReceiptSummary? {
        lock.withLock { operations[operationID]?.committedEffects[itemID] }
    }
    public func durableRecoveryEffectItems(operationID: OperationID,
                                           actionID: UUID) -> Set<OperationItemID> {
        lock.withLock {
            let attempts = operations[operationID]?.recoveryEffectAttempts[actionID] ?? [:]
            return Set(attempts.compactMap { itemID, attempt in
                attempt.result == .completed ? itemID : nil
            })
        }
    }
    public func durableRecoveryAttempt(operationID: OperationID, actionID: UUID,
                                       itemID: OperationItemID) -> (UUID, String?)? {
        lock.withLock {
            guard let attempt = operations[operationID]?
                .recoveryEffectAttempts[actionID]?[itemID] else { return nil }
            return (attempt.effectID, attempt.result?.rawValue)
        }
    }
    public func recoveryActionCompleted(operationID: OperationID, actionID: UUID) -> Bool {
        lock.withLock { operations[operationID]?.completedRecoveryActions.contains(actionID) == true }
    }
    public func durableCommitEffectCount(operationID: OperationID) -> Int {
        lock.withLock { operations[operationID]?.committedEffects.count ?? 0 }
    }
    public func storedSequences(_ id: OperationID) -> (durable: UInt64, emitted: UInt64, reserved: UInt64)? {
        lock.withLock {
            guard let operation = operations[id] else { return nil }
            return (operation.latestDurableSequence, operation.latestEmittedSequence,
                    operation.reservedThrough)
        }
    }
    public func simulateReservedGap(operationID: OperationID, count: UInt64) throws {
        _ = try reserveSequences(for: operationID, count: count)
    }
    public func forceReservedThrough(_ value: UInt64, operationID: OperationID) {
        lock.withLock {
            guard var operation = operations[operationID] else { return }
            operation.reservedThrough = value
            operations[operationID] = operation
        }
    }
    /// Seeds both startup hazards without exercising service scheduling. The
    /// load order is the variable under test: fatal sequence exhaustion must
    /// dominate a recoverable unresolved command in either order.
    public func seedFatalAndRecoveryStartup(
        fatalFirst: Bool, recoveryOperationID recoveryID: OperationID,
        recoveryItemID: OperationItemID, actionID: UUID, action: RecoveryAction
    ) -> FatalRecoveryStartupFixture {
        lock.withLock {
            let fatalID = OperationID(rawValue: UUID())
            let fatalItemID = OperationItemID(rawValue: UUID())
            let request = OperationRequest(
                kind: .copy, sources: [URL(fileURLWithPath: "/fixture/source")],
                destination: URL(fileURLWithPath: "/fixture/target"),
                destinationMode: .container
            )
            let progress = OperationProgress(
                bytesCompleted: 1, bytesTotal: 1, itemsCompleted: 1, itemsTotal: 1
            )
            let fatalItem = OperationItemSnapshot(
                id: fatalItemID, source: request.sources[0], destination: request.destination,
                state: .completed, progress: progress, metadata: nil, verification: nil,
                receipt: nil, failure: nil
            )
            let fatalSnapshot = OperationSnapshot(
                schemaVersion: 1, id: fatalID, kind: .copy, state: .completed,
                latestSequence: 1, request: request,
                effectiveMetadataPolicy: request.metadataPolicy,
                effectiveVerificationPolicy: request.verificationPolicy,
                progress: progress, items: [fatalItem], pendingDecision: nil,
                terminalFailure: nil, availableActions: [], hasPartialCommit: false,
                sourceRetained: false
            )
            let receipt = OperationReceiptSummary(
                committedIdentityDigest: "fixture-commit", backupURL: nil,
                quarantineURL: nil, sourceCleanupPending: false
            )
            let recoveryFailure = FileOperationFailure(
                code: .recoveryRequired, operationID: recoveryID,
                itemID: recoveryItemID, diagnostic: "fixture unresolved effect",
                retryable: false
            )
            let recoveryItem = OperationItemSnapshot(
                id: recoveryItemID, source: request.sources[0], destination: request.destination,
                state: .recoveryRequired, progress: progress, metadata: nil,
                verification: nil, receipt: receipt, failure: recoveryFailure
            )
            let recoverySnapshot = OperationSnapshot(
                schemaVersion: 1, id: recoveryID, kind: .copy, state: .recoveryRequired,
                latestSequence: 1, request: request,
                effectiveMetadataPolicy: request.metadataPolicy,
                effectiveVerificationPolicy: request.verificationPolicy,
                progress: progress, items: [recoveryItem], pendingDecision: nil,
                terminalFailure: recoveryFailure, availableActions: [action],
                hasPartialCommit: true, sourceRetained: false
            )
            let fatalOrdinal: UInt64 = fatalFirst ? 1 : 2
            let recoveryOrdinal: UInt64 = fatalFirst ? 2 : 1
            operations[fatalID] = JournalOperation(
                snapshot: fatalSnapshot, submissionOrdinal: fatalOrdinal,
                latestDurableSequence: 1, latestEmittedSequence: 1,
                reservedThrough: UInt64.max
            )
            operations[recoveryID] = JournalOperation(
                snapshot: recoverySnapshot, submissionOrdinal: recoveryOrdinal,
                latestDurableSequence: 1, latestEmittedSequence: 1,
                reservedThrough: 1,
                inProgressRecoveryActions: [actionID],
                recoveryEffectAttempts: [actionID: [
                    recoveryItemID: RecoveryEffectAttempt(
                        effectID: UUID(), effect: .rollbackCommittedDestination
                    )
                ]],
                committedEffects: [recoveryItemID: receipt]
            )
            ordinal = 2
            return FatalRecoveryStartupFixture(
                recoveryOperationID: recoveryID,
                recoveryItemID: recoveryItemID,
                action: action
            )
        }
    }
    /// Models a restart where the external commit receipt is durable but the
    /// resumable projection asks the service to execute the item again. This is
    /// intentionally a test-only corruption/fault seam; the receipt ledger must
    /// suppress a second commit effect.
    public func simulateRecoverableProjection(
        operationID: OperationID,
        operationState: OperationState = .failedRecoverable,
        itemState: OperationItemState = .failedRecoverable
    ) throws {
        try lock.withLock {
            guard var operation = operations[operationID],
                  let index = operation.snapshot.items.firstIndex(where: {
                      operation.committedEffects[$0.id] != nil
                  }) else {
                throw FileOperationFailure(
                    code: .invariantViolation, operationID: operationID,
                    diagnostic: "no durable committed effect to project", retryable: false
                )
            }
            let old = operation.snapshot
            let oldItem = old.items[index]
            let injectedFailure: FileOperationFailure? =
                itemState == .failedRecoverable
                ? FileOperationFailure(
                    code: .destinationChanged, operationID: operationID,
                    itemID: oldItem.id, diagnostic: "injected recoverable projection",
                    retryable: true
                )
                : nil
            var items = old.items
            items[index] = OperationItemSnapshot(
                id: oldItem.id, source: oldItem.source, destination: oldItem.destination,
                state: itemState, progress: oldItem.progress,
                metadata: oldItem.metadata, verification: oldItem.verification,
                receipt: oldItem.receipt,
                failure: injectedFailure
            )
            operation.snapshot = OperationSnapshot(
                schemaVersion: old.schemaVersion, id: old.id, kind: old.kind,
                state: operationState, latestSequence: old.latestSequence,
                request: old.request,
                effectiveMetadataPolicy: old.effectiveMetadataPolicy,
                effectiveVerificationPolicy: old.effectiveVerificationPolicy,
                progress: old.progress, items: items, pendingDecision: nil,
                terminalFailure: injectedFailure, availableActions: [],
                hasPartialCommit: false, sourceRetained: old.sourceRetained
            )
            operations[operationID] = operation
        }
    }

    /// Models a crash after finalizeKnownCommit's external recovery effect is
    /// durable but while its receipt-backed item projection is between phase
    /// checkpoints. The original capability remains selected so a rebuilt
    /// service must finish the projection through `recover`, not scheduler IO.
    public func simulateFinalizeRecoveryProjection(
        operationID: OperationID,
        action: RecoveryAction,
        actionID: UUID,
        operationState: OperationState,
        itemState: OperationItemState
    ) throws {
        try lock.withLock {
            guard case .finalizeKnownCommit = action,
                  var operation = operations[operationID],
                  operation.snapshot.items.count == 1,
                  let oldItem = operation.snapshot.items.first,
                  oldItem.verification != nil else {
                throw FileOperationFailure(
                    code: .invariantViolation, operationID: operationID,
                    diagnostic: "finalize projection fixture lacks one verified item",
                    retryable: false
                )
            }
            let receipt = OperationReceiptSummary(
                committedIdentityDigest: "injected-finalize-commit",
                backupURL: nil, quarantineURL: nil,
                sourceCleanupPending: false
            )
            let projectedItem = OperationItemSnapshot(
                id: oldItem.id, source: oldItem.source, destination: oldItem.destination,
                state: itemState, progress: oldItem.progress,
                metadata: oldItem.metadata, verification: oldItem.verification,
                receipt: receipt, failure: nil
            )
            let old = operation.snapshot
            operation.snapshot = OperationSnapshot(
                schemaVersion: old.schemaVersion, id: old.id, kind: old.kind,
                state: operationState, latestSequence: old.latestSequence,
                request: old.request,
                effectiveMetadataPolicy: old.effectiveMetadataPolicy,
                effectiveVerificationPolicy: old.effectiveVerificationPolicy,
                progress: old.progress, items: [projectedItem], pendingDecision: nil,
                terminalFailure: old.terminalFailure, availableActions: [action],
                hasPartialCommit: true, sourceRetained: false
            )
            operation.committedEffects[oldItem.id] = receipt
            operation.inProgressRecoveryActions = [actionID]
            operation.completedRecoveryActions.remove(actionID)
            operation.recoveryEffectAttempts[actionID] = [
                oldItem.id: RecoveryEffectAttempt(
                    effectID: UUID(), effect: .finalizeKnownCommit,
                    result: .completed
                )
            ]
            operations[operationID] = operation
        }
    }
    public func hasDurableDecision(for itemID: OperationItemID, operationID: OperationID) -> Bool {
        lock.withLock { operations[operationID]?.priorDecisions[itemID] != nil }
    }
    /// Models a crash after the decision event is durable but before the
    /// service can transition waitingForDecision back to preflight.
    public func simulateDurableResolvedDecision(operationID: OperationID,
                                                decision: OperationDecision) throws {
        guard var stored = lock.withLock({ operations[operationID] }),
              let request = stored.snapshot.pendingDecision else {
            throw FileOperationFailure(
                code: .invariantViolation, operationID: operationID,
                diagnostic: "operation has no pending decision to resolve", retryable: false
            )
        }
        let reservation = try reserveSequences(for: operationID, count: 1)
        let sequence = reservation.lowerBound
        stored.priorDecisions[request.itemID] = decision
        if decision.scope == .remainingItems { stored.remainingDecision = decision }
        let old = stored.snapshot
        stored.latestDurableSequence = sequence
        stored.latestEmittedSequence = sequence
        stored.reservedThrough = reservation.upperBound
        stored.snapshot = OperationSnapshot(
            schemaVersion: old.schemaVersion, id: old.id, kind: old.kind,
            state: old.state, latestSequence: sequence, request: old.request,
            effectiveMetadataPolicy: old.effectiveMetadataPolicy,
            effectiveVerificationPolicy: old.effectiveVerificationPolicy,
            progress: old.progress, items: old.items, pendingDecision: nil,
            terminalFailure: old.terminalFailure, availableActions: old.availableActions,
            hasPartialCommit: old.hasPartialCommit, sourceRetained: old.sourceRetained
        )
        try commit(stored, event: OperationEvent(
            operationID: operationID, itemID: request.itemID, sequence: sequence,
            timestamp: Date(), durability: .durable, payload: .decisionResolved(request.token)
        ))
    }
    public func waitForState(_ state: OperationState, operationID: OperationID,
                             timeoutNanoseconds: UInt64 = 5_000_000_000) async throws
        -> OperationSnapshot {
        if let snapshot = lock.withLock({ operations[operationID]?.snapshot }), snapshot.state == state {
            return snapshot
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<OperationSnapshot, Error>) in
                var immediate: Result<OperationSnapshot, Error>?
                lock.withLock {
                    if Task.isCancelled {
                        immediate = .failure(CancellationError())
                    } else if let snapshot = operations[operationID]?.snapshot,
                              snapshot.state == state {
                        immediate = .success(snapshot)
                    } else {
                        stateWaiters[operationID, default: []].append(
                            StateWaiter(id: waiterID, state: state, continuation: continuation)
                        )
                    }
                }
                if let immediate { continuation.resume(with: immediate) }
                else {
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                        self?.expireStateWaiter(waiterID, operationID: operationID, state: state)
                    }
                }
            }
        } onCancel: {
            cancelStateWaiter(waiterID, operationID: operationID)
        }
    }
    public func seedCompletedHistory(operationID: OperationID, itemID: OperationItemID,
                                     eventCount: Int) throws {
        precondition(eventCount > 0)
        let request = OperationRequest(
            kind: .copy, sources: [URL(fileURLWithPath: "/seed/\(operationID.rawValue)")],
            destination: URL(fileURLWithPath: "/seed-target"), destinationMode: .container
        )
        let receipt = OperationReceiptSummary(
            committedIdentityDigest: "seed-\(operationID.rawValue)", backupURL: nil,
            quarantineURL: nil, sourceCleanupPending: false
        )
        let item = OperationItemSnapshot(
            id: itemID, source: request.sources[0],
            destination: URL(fileURLWithPath: "/seed-target/item"), state: .completed,
            progress: OperationProgress(bytesCompleted: 1, bytesTotal: 1,
                                        itemsCompleted: 1, itemsTotal: 1),
            metadata: nil, verification: nil, receipt: receipt, failure: nil
        )
        func snapshot(sequence: UInt64) -> OperationSnapshot {
            OperationSnapshot(
                schemaVersion: 1, id: operationID, kind: .copy, state: .completed,
                latestSequence: sequence, request: request,
                effectiveMetadataPolicy: .finderCompatible,
                effectiveVerificationPolicy: .structural,
                progress: item.progress, items: [item], pendingDecision: nil,
                terminalFailure: nil, availableActions: [], hasPartialCommit: false,
                sourceRetained: false
            )
        }
        var stored = try admit(
            snapshot(sequence: 0), at: Date(timeIntervalSince1970: 0)
        ).operation
        for index in 1..<eventCount {
            let reservation = try reserveSequences(for: operationID, count: 1)
            let sequence = reservation.lowerBound
            stored.snapshot = snapshot(sequence: sequence)
            stored.latestDurableSequence = sequence
            stored.latestEmittedSequence = sequence
            stored.reservedThrough = reservation.upperBound
            let payload: OperationEventPayload = index == eventCount - 1
                ? .completed(stored.snapshot)
                : .failure(FileOperationFailure(
                    code: .controlRejected, operationID: operationID,
                    diagnostic: "seed replay event \(index)", retryable: false
                ))
            try commit(stored, event: OperationEvent(
                operationID: operationID, itemID: index == eventCount - 1 ? nil : itemID,
                sequence: sequence, timestamp: Date(timeIntervalSince1970: Double(index)),
                durability: .durable, payload: payload
            ))
        }
    }

    package func loadOperations() throws -> [JournalOperation] {
        lock.withLock { operations.values.sorted { $0.submissionOrdinal < $1.submissionOrdinal } }
    }

    package func admit(_ snapshot: OperationSnapshot, at timestamp: Date) throws -> JournalAdmission {
        try lock.withLock {
            try checkFailure()
            guard operations[snapshot.id] == nil else {
                throw FileOperationFailure(code: .journalFailure, operationID: snapshot.id,
                                           diagnostic: "duplicate operation ID", retryable: false)
            }
            let (nextOrdinal, overflow) = ordinal.addingReportingOverflow(1)
            guard !overflow else {
                throw FileOperationFailure(code: .journalFailure,
                                           diagnostic: "submission ordinal exhausted", retryable: false)
            }
            ordinal = nextOrdinal
            let sequence: EventSequence = 1
            let admittedSnapshot = OperationSnapshot(
                schemaVersion: snapshot.schemaVersion, id: snapshot.id, kind: snapshot.kind,
                state: snapshot.state, latestSequence: sequence, request: snapshot.request,
                effectiveMetadataPolicy: snapshot.effectiveMetadataPolicy,
                effectiveVerificationPolicy: snapshot.effectiveVerificationPolicy,
                progress: snapshot.progress, items: snapshot.items,
                pendingDecision: snapshot.pendingDecision,
                terminalFailure: snapshot.terminalFailure,
                availableActions: snapshot.availableActions,
                hasPartialCommit: snapshot.hasPartialCommit,
                sourceRetained: snapshot.sourceRetained
            )
            let operation = JournalOperation(
                snapshot: admittedSnapshot, submissionOrdinal: ordinal,
                latestDurableSequence: sequence, latestEmittedSequence: sequence,
                reservedThrough: sequence
            )
            let event = OperationEvent(
                operationID: snapshot.id, itemID: nil, sequence: sequence,
                timestamp: timestamp, durability: .durable,
                payload: .admitted(admittedSnapshot)
            )
            operations[snapshot.id] = operation
            events[snapshot.id, default: []].append(event)
            return JournalAdmission(operation: operation, event: event)
        }
    }

    package func reserveSequences(for id: OperationID, count: UInt64) throws -> ClosedRange<EventSequence> {
        try lock.withLock {
            try checkFailure()
            guard var operation = operations[id], count > 0 else {
                throw FileOperationFailure(code: .journalFailure, operationID: id,
                                           diagnostic: "cannot reserve sequence", retryable: false)
            }
            let (start, startOverflow) = operation.reservedThrough.addingReportingOverflow(1)
            let (end, endOverflow) = start.addingReportingOverflow(count - 1)
            guard !startOverflow, !endOverflow else {
                throw FileOperationFailure(code: .journalFailure, operationID: id,
                                           diagnostic: "event sequence space exhausted", retryable: false)
            }
            operation.reservedThrough = end
            operations[id] = operation
            return start...end
        }
    }

    package func commit(_ operation: JournalOperation, event: OperationEvent) throws {
        try lock.withLock {
            try checkFailure()
            guard event.sequence <= operation.reservedThrough,
                  event.sequence > (events[event.operationID]?.last?.sequence ?? 0) else {
                throw FileOperationFailure(code: .journalFailure, operationID: event.operationID,
                                           diagnostic: "non-monotonic event", retryable: false)
            }
            operations[event.operationID] = operation
            events[event.operationID, default: []].append(event)
        }
        resumeStateWaiters(operationID: event.operationID)
    }

    package func checkpoint(_ operation: JournalOperation) throws {
        try lock.withLock {
            try checkFailure()
            operations[operation.snapshot.id] = operation
        }
        resumeStateWaiters(operationID: operation.snapshot.id)
    }

    package func replay(operationID: OperationID, after sequence: EventSequence,
                        through watermark: EventSequence, limit: Int) throws -> [OperationEvent] {
        lock.withLock {
            Array(events[operationID, default: []]
                .filter { $0.sequence > sequence && $0.sequence <= watermark }
                .prefix(limit))
        }
    }

    private func checkFailure() throws {
        if failNextWrite {
            failNextWrite = false
            throw FileOperationFailure(code: .journalFailure,
                                       diagnostic: "injected journal failure", retryable: false)
        }
    }

    private func resumeStateWaiters(operationID: OperationID) {
        let ready: [(CheckedContinuation<OperationSnapshot, Error>, OperationSnapshot)] = lock.withLock {
            guard let snapshot = operations[operationID]?.snapshot,
                  let waiters = stateWaiters[operationID] else { return [] }
            var pending: [StateWaiter] = []
            var ready: [(CheckedContinuation<OperationSnapshot, Error>, OperationSnapshot)] = []
            for waiter in waiters {
                if waiter.state == snapshot.state { ready.append((waiter.continuation, snapshot)) }
                else { pending.append(waiter) }
            }
            stateWaiters[operationID] = pending.isEmpty ? nil : pending
            return ready
        }
        ready.forEach { $0.0.resume(returning: $0.1) }
    }

    private func expireStateWaiter(_ waiterID: UUID, operationID: OperationID,
                                   state: OperationState) {
        let continuation: CheckedContinuation<OperationSnapshot, Error>? = lock.withLock {
            guard var waiters = stateWaiters[operationID],
                  let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return nil }
            let waiter = waiters.remove(at: index)
            stateWaiters[operationID] = waiters.isEmpty ? nil : waiters
            return waiter.continuation
        }
        continuation?.resume(throwing: FileOperationFailure(
            code: .invariantViolation, operationID: operationID,
            diagnostic: "timed out waiting for journal state \(state)", retryable: false
        ))
    }

    private func cancelStateWaiter(_ waiterID: UUID, operationID: OperationID) {
        let continuation: CheckedContinuation<OperationSnapshot, Error>? = lock.withLock {
            guard var waiters = stateWaiters[operationID],
                  let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return nil }
            let waiter = waiters.remove(at: index)
            stateWaiters[operationID] = waiters.isEmpty ? nil : waiters
            return waiter.continuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}

public enum FakePreflight: Sendable {
    case ready
    case conflict
    case metadataLoss(Set<MetadataField>)
    case skipAfterDecision
    case failure(FileOperationErrorCode)
}

public enum FakeNameEquivalence: Sendable {
    case exact
    case caseInsensitive
    case unknown
}

public actor FakeFileSystemAdapter: FileSystemAdapter {
    private var plans: [OperationKind: FakePreflight]
    private var preflightCalls = 0
    private var nameEquivalence: FakeNameEquivalence = .exact
    private var moveTopology: MoveTopology = .unknown
    private var preflightGate: ContinuationGate?
    private var activePreflights = 0
    private var maximumActivePreflights = 0
    private var stagingRecoveryModes: [FakeRecoveryMode] = []
    private var stagingRecoveryResults: [UUID: FakeRecoveryInspection] = [:]
    private var stagingInspectionOverride: FakeRecoveryInspection?
    private var stagingRecoveryAttempts: [FakeRecoveryAttempt] = []
    private var stagingRecoveryEffects: [FakeRecoveryAttempt] = []
    private var stagingRecoveryInspections: [FakeRecoveryAttempt] = []
    private var stagingRecoveryInspectionResults: [FakeRecoveryInspection] = []
    private var stagingRecoveryPostEffectGates: [Int: ContinuationGate] = [:]

    public init(plans: [OperationKind: FakePreflight] = [:]) { self.plans = plans }

    public func setPlan(_ plan: FakePreflight, for kind: OperationKind) { plans[kind] = plan }
    public func setNameEquivalence(_ value: FakeNameEquivalence) { nameEquivalence = value }
    package func setMoveTopology(_ value: MoveTopology) { moveTopology = value }
    public func setPreflightGate(_ gate: ContinuationGate?) { preflightGate = gate }
    public func counts() -> (preflight: Int, cleanup: Int) {
        (preflightCalls, stagingRecoveryEffects.count)
    }
    public func maximumPreflightConcurrency() -> Int { maximumActivePreflights }
    public func setStagingRecoveryModes(_ modes: [FakeRecoveryMode]) {
        stagingRecoveryModes = modes
    }
    public func setStagingRecoveryInspection(_ inspection: FakeRecoveryInspection?) {
        stagingInspectionOverride = inspection
    }
    public func setStagingRecoveryPostEffectGate(_ gate: ContinuationGate?,
                                                 ordinal: Int) {
        stagingRecoveryPostEffectGates[ordinal] = gate
    }
    public func stagingRecoveryAttemptHistory() -> [FakeRecoveryAttempt] {
        stagingRecoveryAttempts
    }
    public func stagingRecoveryEffectHistory() -> [FakeRecoveryAttempt] {
        stagingRecoveryEffects
    }
    public func stagingRecoveryInspectionHistory() -> [FakeRecoveryAttempt] {
        stagingRecoveryInspections
    }
    public func stagingRecoveryInspectionResultHistory() -> [FakeRecoveryInspection] {
        stagingRecoveryInspectionResults
    }

    package func preflight(operationID: OperationID, request: OperationRequest, itemIndex: Int,
                           priorDecision: OperationDecision?,
                           controls: ExecutionControls) async throws -> PreflightDisposition {
        _ = operationID
        preflightCalls += 1
        activePreflights += 1
        maximumActivePreflights = max(maximumActivePreflights, activePreflights)
        defer { activePreflights -= 1 }
        if let preflightGate { await preflightGate.wait() }
        if await controls.isCancelled() { throw CancellationError() }
        let destinations = request.destination.map { destination in
            request.destinationMode == .exact
                ? request.sources.map { _ in Optional(destination) }
                : request.sources.map { Optional(destination.appendingPathComponent($0.lastPathComponent)) }
        } ?? Array(repeating: nil, count: request.sources.count)
        if request.sources.count > 1, request.destinationMode != .exact {
            if case .unknown = nameEquivalence {
                return .failure(FileOperationFailure(
                    code: .destinationChanged,
                    diagnostic: "fake destination name equivalence is unknown",
                    retryable: false
                ))
            }
            let projectedNames = request.sources.map { source -> String in
                switch nameEquivalence {
                case .exact: return source.lastPathComponent
                case .caseInsensitive: return source.lastPathComponent.lowercased()
                case .unknown: return source.lastPathComponent
                }
            }
            if Set(projectedNames).count != projectedNames.count, priorDecision == nil {
                return .decision(PreflightDecision(
                    allowed: [.skip(scope: .item), .skip(scope: .remainingItems),
                              .keepBoth(scope: .item), .keepBoth(scope: .remainingItems), .stop],
                    identityDigest: "fake-projected-name-collision"
                ))
            }
        }
        if let priorDecision {
            switch priorDecision {
            case .skip: return .skip
            case .stop: return .failure(FileOperationFailure(
                code: .destinationChanged, diagnostic: "fake preflight stopped", retryable: false
            ))
            case .cancel: return .failure(FileOperationFailure(
                code: .controlRejected, diagnostic: "cancel must be handled by service", retryable: false
            ))
            default: break
            }
        }
        switch plans[request.kind] ?? .ready {
        case .ready: return .ready(destinations: destinations, moveTopology: moveTopology)
        case .conflict:
            if priorDecision != nil {
                return .ready(destinations: destinations, moveTopology: moveTopology)
            }
            return .decision(PreflightDecision(
                allowed: [.skip(scope: .item), .skip(scope: .remainingItems),
                          .keepBoth(scope: .item), .keepBoth(scope: .remainingItems), .stop],
                identityDigest: "fake-conflict"
            ))
        case let .metadataLoss(losses):
            if priorDecision != nil {
                return .ready(destinations: destinations, moveTopology: moveTopology)
            }
            return .decision(PreflightDecision(
                allowed: [.approvePortable(losses: losses, scope: .item),
                          .approvePortable(losses: losses, scope: .remainingItems), .cancel],
                metadataLosses: losses, identityDigest: "fake-metadata"
            ))
        case .skipAfterDecision:
            if priorDecision != nil { return .skip }
            return .decision(PreflightDecision(allowed: [.skip(scope: .item)],
                                               identityDigest: "fake-skip"))
        case let .failure(code):
            return .failure(FileOperationFailure(code: code, diagnostic: "fake preflight failure",
                                                 retryable: true))
        }
    }

    package func recoverOwnedStaging(operationID: OperationID, itemID: OperationItemID,
                                     effectID: UUID) async -> ExecutionRecoveryOutcome {
        let attempt = FakeRecoveryAttempt(
            operationID: operationID, itemID: itemID,
            effect: ExecutionRecoveryEffect.cleanupStaging.rawValue,
            effectID: effectID
        )
        stagingRecoveryAttempts.append(attempt)
        let mode = stagingRecoveryModes.isEmpty ? .completed : stagingRecoveryModes.removeFirst()
        if mode != .failed {
            stagingRecoveryEffects.append(attempt)
            let ordinal = stagingRecoveryEffects.count
            switch mode {
            case .completed, .ambiguousCompleted:
                stagingRecoveryResults[effectID] = .completed
            case .recoveryRequired:
                stagingRecoveryResults[effectID] = .unknown
            case .failed:
                break
            }
            if let gate = stagingRecoveryPostEffectGates[ordinal] {
                await gate.wait()
            }
        } else {
            stagingRecoveryResults[effectID] = .notPerformed
        }
        switch mode {
        case .completed:
            return .completed
        case .failed:
            return .failedBeforeEffect(FileOperationFailure(
                code: .permissionDenied, operationID: operationID, itemID: itemID,
                diagnostic: "fake staging cleanup failed before effect", retryable: true
            ))
        case .ambiguousCompleted, .recoveryRequired:
            return .ambiguous(FileOperationFailure(
                code: .recoveryRequired, operationID: operationID, itemID: itemID,
                diagnostic: "fake staging cleanup outcome is ambiguous", retryable: false
            ))
        }
    }

    package func inspectOwnedStaging(operationID: OperationID, itemID: OperationItemID,
                                     effectID: UUID) async -> ExecutionRecoveryInspection {
        let attempt = FakeRecoveryAttempt(
            operationID: operationID, itemID: itemID,
            effect: ExecutionRecoveryEffect.cleanupStaging.rawValue,
            effectID: effectID
        )
        stagingRecoveryInspections.append(attempt)
        if let owner = stagingRecoveryEffects.first(where: { $0.effectID == effectID }),
           owner.operationID != operationID || owner.itemID != itemID {
            return .unknown(FileOperationFailure(
                code: .recoveryRequired, operationID: operationID, itemID: itemID,
                diagnostic: "staging recovery effect ownership mismatch", retryable: false
            ))
        }
        let result = stagingInspectionOverride ?? stagingRecoveryResults[effectID] ?? .notPerformed
        stagingRecoveryInspectionResults.append(result)
        switch result {
        case .completed:
            return .completed
        case .notPerformed:
            return .notPerformed
        case .unknown:
            return .unknown(FileOperationFailure(
                code: .recoveryRequired, operationID: operationID, itemID: itemID,
                diagnostic: "staging recovery effect remains unknown", retryable: false
            ))
        }
    }
}

public actor ContinuationGate {
    private struct GateWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }
    private struct EntryWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var open = false
    private var entered = false
    private var waiters: [GateWaiter] = []
    private var entryWaiters: [EntryWaiter] = []
    public init() {}
    public func wait(timeoutNanoseconds: UInt64 = 10_000_000_000) async {
        entered = true
        let observers = entryWaiters
        entryWaiters.removeAll()
        observers.forEach { $0.continuation.resume() }
        guard !open else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || open { continuation.resume(); return }
                waiters.append(GateWaiter(id: waiterID, continuation: continuation))
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    await self?.expireGateWaiter(waiterID)
                }
            }
        } onCancel: {
            Task { await self.cancelGateWaiter(waiterID) }
        }
    }
    /// Executor tests need a gate that remains responsive to the service's
    /// pause/cancel handshake. A plain continuation cannot observe either
    /// control while suspended, so this bounded polling loop is reserved for
    /// the fake executor and never participates in production execution.
    package func wait(controls: ExecutionControls,
                      timeoutNanoseconds: UInt64 = 10_000_000_000) async -> Bool {
        entered = true
        let observers = entryWaiters
        entryWaiters.removeAll()
        observers.forEach { $0.continuation.resume() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .nanoseconds(Int64(timeoutNanoseconds)))
        while !open, clock.now < deadline {
            if await controls.isCancelled() { return false }
            await controls.checkpoint()
            if await controls.isCancelled() { return false }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return open
    }
    public func waitUntilEntered(timeoutNanoseconds: UInt64 = 5_000_000_000) async throws {
        guard !entered else { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if entered { continuation.resume(); return }
                entryWaiters.append(EntryWaiter(id: waiterID, continuation: continuation))
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    await self?.expireEntryWaiter(waiterID)
                }
            }
        } onCancel: {
            Task { await self.cancelEntryWaiter(waiterID) }
        }
    }
    public func release() {
        open = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.continuation.resume() }
    }
    private func expireGateWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume()
    }
    private func cancelGateWaiter(_ id: UUID) {
        expireGateWaiter(id)
    }
    private func expireEntryWaiter(_ id: UUID) {
        guard let index = entryWaiters.firstIndex(where: { $0.id == id }) else { return }
        entryWaiters.remove(at: index).continuation.resume(throwing: FileOperationFailure(
            code: .invariantViolation, diagnostic: "timed out waiting for gate entry",
            retryable: false
        ))
    }
    private func cancelEntryWaiter(_ id: UUID) {
        guard let index = entryWaiters.firstIndex(where: { $0.id == id }) else { return }
        entryWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

public enum FakeExecutionMode: Sendable {
    case committed
    case committedAwaitingCleanup
    case failed(FileOperationErrorCode)
    case ambiguous
    case illegalSourceCleanupPlan
    case receiptMismatch
}

public enum FakeExecutionPhase: String, Sendable, CaseIterable {
    case staging
    case metadata
    case verification
    case commit
    case sourceCleanup

    fileprivate init(_ phase: ExecutionPhase) {
        self = FakeExecutionPhase(rawValue: phase.rawValue)!
    }
}

public enum FakeCommitInspection: Sendable {
    case committed
    case notCommitted
    case unknown
}

public enum FakeSourceInspection: Sendable {
    case sourcePresentMatching
    case sourceAbsent
    case sourceChanged
    case unknown
}

public enum FakeRecoveryMode: Sendable {
    case completed
    /// Typed guarantee that no external mutation began.
    case failed
    /// The effect happened, but the immediate outcome is ambiguous; inspection
    /// can later prove completion without replaying the effect.
    case ambiguousCompleted
    /// The effect happened and remains unknowable to the inspector.
    case recoveryRequired
}

public enum FakeRecoveryInspection: Sendable, Equatable {
    case completed
    case notPerformed
    case unknown
}

public struct FakeExecutionAttempt: Sendable, Equatable {
    public let operationID: OperationID
    public let itemID: OperationItemID
    public let phase: FakeExecutionPhase
    public let metadataPolicy: MetadataPolicy
    public let verificationPolicy: VerificationPolicy
    public let sourceCleanupRequired: Bool
}

public struct FakeExecutionEffect: Sendable, Equatable {
    public let operationID: OperationID
    public let itemID: OperationItemID
    public let phase: FakeExecutionPhase
}

public struct FakeRecoveryAttempt: Sendable, Equatable {
    public let operationID: OperationID
    public let itemID: OperationItemID
    public let effect: String
    public let effectID: UUID
}

public actor FakeOperationExecutor: OperationExecutor {
    private var modes: [OperationKind: FakeExecutionMode]
    private var modeSequences: [OperationKind: [FakeExecutionMode]] = [:]
    private var phaseGates: [FakeExecutionPhase: ContinuationGate] = [:]
    private var postEffectGates: [FakeExecutionPhase: ContinuationGate] = [:]
    private var planGate: ContinuationGate?
    private var selectedModes: [String: FakeExecutionMode] = [:]
    private var attempts: [FakeExecutionAttempt] = []
    private var effects: [FakeExecutionEffect] = []
    private var recoveryAttempts: [FakeRecoveryAttempt] = []
    private var recoveryEffects: [FakeRecoveryAttempt] = []
    private var recoveryInspections: [FakeRecoveryAttempt] = []
    private var recoveryModes: [FakeRecoveryMode] = []
    private var recoveryInspectionResults: [UUID: FakeRecoveryInspection] = [:]
    private var recoveryInspectionOverride: FakeRecoveryInspection?
    private var recoveryPostEffectGates: [Int: ContinuationGate] = [:]
    private var committedReceipts: [String: OperationReceiptSummary] = [:]
    private var inspectionOverrides: [OperationKind: FakeCommitInspection] = [:]
    private var sourceInspectionOverride: FakeSourceInspection?
    private var sourceCleanedKeys: Set<String> = []
    private var sourceInspectionCalls = 0
    private var remainingSourceCleanupFailures = 0
    private var progressSteps: [Int64] = [1]
    private var progressGates: [Int: ContinuationGate] = [:]
    private var starts: [OperationID] = []
    private var planStarts: [OperationID] = []
    private var activeExecutions = 0
    private var maximumConcurrentExecutions = 0

    public init(modes: [OperationKind: FakeExecutionMode] = [:], startGate: ContinuationGate? = nil) {
        self.modes = modes
        if let startGate { phaseGates[.staging] = startGate }
    }
    public func setMode(_ mode: FakeExecutionMode, for kind: OperationKind) { modes[kind] = mode }
    public func setModeSequence(_ sequence: [FakeExecutionMode], for kind: OperationKind) {
        modeSequences[kind] = sequence
    }
    public func setStartGate(_ gate: ContinuationGate?) { phaseGates[.staging] = gate }
    public func setGate(_ gate: ContinuationGate?, for phase: FakeExecutionPhase) {
        phaseGates[phase] = gate
    }
    public func setPostEffectGate(_ gate: ContinuationGate?, for phase: FakeExecutionPhase) {
        postEffectGates[phase] = gate
    }
    public func setPlanGate(_ gate: ContinuationGate?) { planGate = gate }
    public func setCommitInspection(_ result: FakeCommitInspection,
                                    for kind: OperationKind) {
        inspectionOverrides[kind] = result
    }
    public func setSourceInspection(_ result: FakeSourceInspection) {
        sourceInspectionOverride = result
    }
    public func sourceInspectionCount() -> Int { sourceInspectionCalls }
    public func setSourceCleanupFailures(_ count: Int) {
        remainingSourceCleanupFailures = max(0, count)
    }
    public func setProgressSteps(_ steps: [Int64]) { progressSteps = steps }
    public func setProgressGate(_ gate: ContinuationGate?, afterStep index: Int) {
        progressGates[index] = gate
    }
    public func effectCount(operationID: OperationID, itemID: OperationItemID) -> Int {
        effects.filter {
            $0.operationID == operationID && $0.itemID == itemID && $0.phase == .commit
        }.count
    }
    public func effectCount(operationID: OperationID, itemID: OperationItemID,
                            phase: FakeExecutionPhase) -> Int {
        effects.filter {
            $0.operationID == operationID && $0.itemID == itemID && $0.phase == phase
        }.count
    }
    public func rawAttemptHistory() -> [FakeExecutionAttempt] { attempts }
    public func actualEffectHistory() -> [FakeExecutionEffect] { effects }
    public func recoveryAttemptHistory() -> [FakeRecoveryAttempt] { recoveryAttempts }
    public func recoveryEffectHistory() -> [FakeRecoveryAttempt] { recoveryEffects }
    public func recoveryInspectionHistory() -> [FakeRecoveryAttempt] { recoveryInspections }
    public func setRecoveryModes(_ modes: [FakeRecoveryMode]) { recoveryModes = modes }
    public func setRecoveryInspection(_ result: FakeRecoveryInspection?) {
        recoveryInspectionOverride = result
    }
    public func setRecoveryPostEffectGate(_ gate: ContinuationGate?, afterEffect ordinal: Int) {
        recoveryPostEffectGates[ordinal] = gate
    }
    public func startedOperations() -> [OperationID] { starts }
    public func plannedOperations() -> [OperationID] { planStarts }
    public func maximumConcurrency() -> Int { maximumConcurrentExecutions }
    public func activeExecutionCount() -> Int { activeExecutions }

    package func plan(_ context: ExecutionContext,
                      controls: ExecutionControls) async throws -> ExecutionPlan {
        planStarts.append(context.operationID)
        activeExecutions += 1
        maximumConcurrentExecutions = max(maximumConcurrentExecutions, activeExecutions)
        defer { activeExecutions -= 1 }
        if let planGate {
            guard await planGate.wait(controls: controls) else {
                throw CancellationError()
            }
            await controls.checkpoint()
        }
        if await controls.isCancelled() { throw CancellationError() }
        let mode: FakeExecutionMode
        if var sequence = modeSequences[context.request.kind], !sequence.isEmpty {
            mode = sequence.removeFirst()
            modeSequences[context.request.kind] = sequence
        } else {
            mode = modes[context.request.kind] ?? .committed
        }
        selectedModes[key(context)] = mode
        let sourceDisposition: ExecutionSourceDisposition
        if case .illegalSourceCleanupPlan = mode {
            sourceDisposition = .cleanupRequired
        } else {
            switch mode {
            case .committedAwaitingCleanup, .receiptMismatch:
                sourceDisposition = context.request.kind == .move ? .cleanupRequired : .noCleanup
            default:
                sourceDisposition = .noCleanup
            }
        }
        return ExecutionPlan(sourceDisposition: sourceDisposition)
    }

    package func perform(_ phase: ExecutionPhase, context: ExecutionContext, plan: ExecutionPlan,
                         controls: ExecutionControls,
                         progress: @escaping @Sendable (OperationProgress) async -> Void) async
        -> ExecutionPhaseOutcome {
        let fakePhase = FakeExecutionPhase(phase)
        attempts.append(FakeExecutionAttempt(
            operationID: context.operationID, itemID: context.itemID, phase: fakePhase,
            metadataPolicy: context.metadataPolicy,
            verificationPolicy: context.verificationPolicy,
            sourceCleanupRequired: plan.sourceDisposition == .cleanupRequired
        ))
        if phase == .staging { starts.append(context.operationID) }
        activeExecutions += 1
        maximumConcurrentExecutions = max(maximumConcurrentExecutions, activeExecutions)
        defer { activeExecutions -= 1 }
        if let gate = phaseGates[fakePhase] {
            guard await gate.wait(controls: controls) else { return .cancelled }
            await controls.checkpoint()
            if await controls.isCancelled() { return .cancelled }
        }
        await controls.checkpoint()
        if await controls.isCancelled() {
            return .cancelled
        }
        if phase == .staging {
            for (index, step) in progressSteps.enumerated() {
                await controls.checkpoint()
                if await controls.isCancelled() { return .cancelled }
                await progress(OperationProgress(bytesCompleted: step, bytesTotal: progressSteps.last,
                                                 itemsCompleted: context.itemIndex,
                                                 itemsTotal: context.request.sources.count))
                await controls.checkpoint()
                if await controls.isCancelled() { return .cancelled }
                if let gate = progressGates[index] {
                    guard await gate.wait(controls: controls) else { return .cancelled }
                    await controls.checkpoint()
                    if await controls.isCancelled() { return .cancelled }
                }
            }
        }
        let selected = selectedModes[key(context)] ?? .committed
        if phase == .staging, case let .failed(code) = selected {
            selectedModes[key(context)] = nil
            // Model a real mid-file failure: partial operation-owned staging
            // exists before ENOSPC/EACCES is reported. The service must route
            // through its durable cleanup ledger before exposing retry.
            recordEffect(phase: fakePhase, context: context)
            return .failed(FileOperationFailure(code: code, operationID: context.operationID,
                                                itemID: context.itemID,
                                                diagnostic: "fake executor failure", retryable: true))
        }

        switch phase {
        case .staging:
            recordEffect(phase: fakePhase, context: context)
            guard await waitAfterEffect(fakePhase, controls: controls) else {
                return .cancelled
            }
            return .staged
        case .metadata:
            recordEffect(phase: fakePhase, context: context)
            guard await waitAfterEffect(fakePhase, controls: controls) else {
                return .cancelled
            }
            return .metadataApplied(nil)
        case .verification:
            return .verified(VerificationOutcome(
                policy: context.verificationPolicy, sourceDigest: nil, stagedDigest: nil,
                manifestDigest: "fake-manifest"
            ))
        case .commit:
            if let durableReceipt = plan.durableCommitReceipt {
                return .committed(durableReceipt)
            }
            recordEffect(phase: fakePhase, context: context)
            guard await waitAfterEffect(fakePhase, controls: controls) else {
                return .cancelled
            }
            let receipt = OperationReceiptSummary(
                committedIdentityDigest: "fake-\(key(context))", backupURL: nil,
                quarantineURL: nil,
                sourceCleanupPending: {
                    if case .receiptMismatch = selected { return false }
                    return plan.sourceDisposition == .cleanupRequired
                }()
            )
            committedReceipts[key(context)] = receipt
            if case .ambiguous = selected {
                selectedModes[key(context)] = nil
                return .recoveryRequired(FileOperationFailure(
                    code: .recoveryRequired, operationID: context.operationID,
                    itemID: context.itemID, diagnostic: "fake ambiguous effect", retryable: false
                ))
            }
            if plan.sourceDisposition == .noCleanup { selectedModes[key(context)] = nil }
            return .committed(receipt)
        case .sourceCleanup:
            recordEffect(phase: fakePhase, context: context)
            guard await waitAfterEffect(fakePhase, controls: controls) else {
                return .cancelled
            }
            if remainingSourceCleanupFailures > 0 {
                remainingSourceCleanupFailures -= 1
                return .failed(FileOperationFailure(
                    code: .permissionDenied, operationID: context.operationID,
                    itemID: context.itemID, diagnostic: "fake source cleanup failure",
                    retryable: true
                ))
            }
            sourceCleanedKeys.insert(key(context))
            selectedModes[key(context)] = nil
            return .sourceCleaned
        }
    }

    package func recover(_ effect: ExecutionRecoveryEffect, effectID: UUID,
                         context: ExecutionContext,
                         receipt: OperationReceiptSummary) async -> ExecutionRecoveryOutcome {
        _ = receipt
        let attempt = FakeRecoveryAttempt(
            operationID: context.operationID, itemID: context.itemID,
            effect: effect.rawValue, effectID: effectID
        )
        recoveryAttempts.append(attempt)
        let mode = recoveryModes.isEmpty ? .completed : recoveryModes.removeFirst()
        switch mode {
        case .completed:
            await recordRecoveryEffect(attempt, effect: effect, context: context,
                                       inspection: .completed)
            return .completed
        case .failed:
            recoveryInspectionResults[effectID] = .notPerformed
            return .failedBeforeEffect(FileOperationFailure(
                code: .permissionDenied, operationID: context.operationID,
                itemID: context.itemID,
                diagnostic: "fake recovery effect failed before mutation",
                retryable: true
            ))
        case .ambiguousCompleted:
            await recordRecoveryEffect(attempt, effect: effect, context: context,
                                       inspection: .completed)
            return .ambiguous(FileOperationFailure(
                code: .recoveryRequired, operationID: context.operationID,
                itemID: context.itemID,
                diagnostic: "fake recovery completed with ambiguous ACK",
                retryable: false
            ))
        case .recoveryRequired:
            await recordRecoveryEffect(attempt, effect: effect, context: context,
                                       inspection: .unknown)
            return .ambiguous(FileOperationFailure(
                code: .recoveryRequired, operationID: context.operationID,
                itemID: context.itemID,
                diagnostic: "fake recovery outcome is ambiguous",
                retryable: false
            ))
        }
    }

    package func inspectRecoveryEffect(
        _ effect: ExecutionRecoveryEffect, effectID: UUID,
        context: ExecutionContext, receipt: OperationReceiptSummary
    ) async -> ExecutionRecoveryInspection {
        _ = receipt
        let inspection = FakeRecoveryAttempt(
            operationID: context.operationID, itemID: context.itemID,
            effect: effect.rawValue, effectID: effectID
        )
        recoveryInspections.append(inspection)
        switch recoveryInspectionOverride ?? recoveryInspectionResults[effectID] ?? .notPerformed {
        case .completed:
            return .completed
        case .notPerformed:
            return .notPerformed
        case .unknown:
            return .unknown(FileOperationFailure(
                code: .recoveryRequired, operationID: context.operationID,
                itemID: context.itemID,
                diagnostic: "fake recovery inspection remains unknown",
                retryable: false
            ))
        }
    }

    package func inspectCommit(_ context: ExecutionContext) async -> ExecutionCommitInspection {
        switch inspectionOverrides[context.request.kind] {
        case .committed:
            let receipt = committedReceipts[key(context)] ?? OperationReceiptSummary(
                committedIdentityDigest: "inspected-\(key(context))", backupURL: nil,
                quarantineURL: nil, sourceCleanupPending: false
            )
            return .committed(receipt)
        case .notCommitted:
            return .notCommitted
        case .unknown:
            return .unknown(FileOperationFailure(
                code: .recoveryRequired, operationID: context.operationID,
                itemID: context.itemID, diagnostic: "fake commit remains ambiguous",
                retryable: false
            ))
        case nil:
            if let receipt = committedReceipts[key(context)] { return .committed(receipt) }
            return .notCommitted
        }
    }

    package func inspectSourceBeforeCleanup(
        _ context: ExecutionContext,
        receipt: OperationReceiptSummary
    ) async -> ExecutionSourceInspection {
        _ = receipt
        sourceInspectionCalls += 1
        let inspection = sourceInspectionOverride ??
            (sourceCleanedKeys.contains(key(context)) ? .sourceAbsent : .sourcePresentMatching)
        switch inspection {
        case .sourcePresentMatching:
            return .sourcePresentMatching
        case .sourceAbsent:
            return .sourceAbsent
        case .sourceChanged:
            return .sourceChanged(FileOperationFailure(
                code: .sourceChanged, operationID: context.operationID,
                itemID: context.itemID,
                diagnostic: "fake source identity changed before cleanup",
                retryable: false
            ))
        case .unknown:
            return .unknown(FileOperationFailure(
                code: .recoveryRequired, operationID: context.operationID,
                itemID: context.itemID,
                diagnostic: "fake source identity remains unknown",
                retryable: false
            ))
        }
    }

    private func key(_ context: ExecutionContext) -> String {
        "\(context.operationID.rawValue):\(context.itemID.rawValue)"
    }

    private func recordEffect(phase: FakeExecutionPhase, context: ExecutionContext) {
        effects.append(FakeExecutionEffect(operationID: context.operationID,
                                           itemID: context.itemID, phase: phase))
    }

    private func recordRecoveryEffect(
        _ attempt: FakeRecoveryAttempt, effect: ExecutionRecoveryEffect,
        context: ExecutionContext, inspection: FakeRecoveryInspection
    ) async {
        recoveryEffects.append(attempt)
        recoveryInspectionResults[attempt.effectID] = inspection
        if effect == .cleanupSource { sourceCleanedKeys.insert(key(context)) }
        if let gate = recoveryPostEffectGates[recoveryEffects.count] {
            await gate.wait()
        }
    }

    private func waitAfterEffect(_ phase: FakeExecutionPhase,
                                 controls: ExecutionControls) async -> Bool {
        if let gate = postEffectGates[phase] {
            guard await gate.wait(controls: controls) else { return false }
            await controls.checkpoint()
        }
        return !(await controls.isCancelled())
    }
}

public actor FakeFailpointController: FailpointController {
    private var gates: [Failpoint: ContinuationGate] = [:]
    public init() {}
    package func setGate(_ gate: ContinuationGate, for point: Failpoint) { gates[point] = gate }
    package func hit(_ point: Failpoint, operationID: OperationID) async {
        if let gate = gates[point] { await gate.wait() }
    }
}

public final class DiagnosticRecorder: @unchecked Sendable, ServiceDiagnosticSink {
    private let lock = NSLock()
    private var storage: [ServiceDiagnostic] = []
    public init() {}
    package func record(_ diagnostic: ServiceDiagnostic) { lock.withLock { storage.append(diagnostic) } }
    package func diagnostics() -> [ServiceDiagnostic] { lock.withLock { storage } }
    public func count() -> Int { lock.withLock { storage.count } }
    public func containsUnknownControl(for id: OperationID, command: String) -> Bool {
        lock.withLock {
            storage.contains(.unknownControl(operationID: id, command: command))
        }
    }
}

public final class DeterministicOperationIDGenerator: @unchecked Sendable, OperationIDGenerator {
    private let lock = NSLock()
    private var next: UInt64
    public init(startingAt: UInt64 = 1) { next = startingAt }
    private func uuid() -> UUID {
        lock.withLock {
            defer { next += 1 }
            return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llx", next))!
        }
    }
    package func operationID() -> OperationID { OperationID(rawValue: uuid()) }
    package func itemID() -> OperationItemID { OperationItemID(rawValue: uuid()) }
    package func decisionToken() -> DecisionToken { DecisionToken(rawValue: uuid()) }
    package func actionID() -> UUID { uuid() }
}

private struct FixedClock: OperationClock {
    package func now() -> Date { Date(timeIntervalSince1970: 1_700_000_000) }
}

private struct FakeDigest: DigestProvider {
    package func digest(_ data: Data) throws -> String { "bytes-\(data.count)" }
}

public struct ServiceTestHarness: Sendable {
    public let service: FileOperationService
    public let journal: InMemoryOperationJournal
    public let fileSystem: FakeFileSystemAdapter
    public let executor: FakeOperationExecutor
    public let failpoints: FakeFailpointController
    public let diagnostics: DiagnosticRecorder

    public init(journal: InMemoryOperationJournal = InMemoryOperationJournal(),
                fileSystem: FakeFileSystemAdapter = FakeFileSystemAdapter(),
                executor: FakeOperationExecutor = FakeOperationExecutor(),
                idGenerator: DeterministicOperationIDGenerator = DeterministicOperationIDGenerator(),
                replayPageSize: Int = 2, liveBufferLimit: Int = 64) throws {
        self.journal = journal
        self.fileSystem = fileSystem
        self.executor = executor
        self.failpoints = FakeFailpointController()
        self.diagnostics = DiagnosticRecorder()
        self.service = try FileOperationService(dependencies: ServiceDependencies(
            journal: journal, fileSystem: fileSystem, clock: FixedClock(),
            ids: idGenerator, digest: FakeDigest(), failpoints: failpoints,
            executor: executor, diagnostics: diagnostics,
            replayPageSize: replayPageSize, liveBufferLimit: liveBufferLimit
        ))
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
