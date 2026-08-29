import Foundation

package enum RecoveryEffectResult: String, Sendable {
    case completed
    /// A read-only inspector durably proved that the write-ahead intent did
    /// not reach the external effect. The same effect ID may be retried after
    /// the record is checkpointed back to an unresolved intent.
    case notPerformed
}

/// Durable per-item write-ahead record for a recovery filesystem effect.
/// `result == nil` means the intent is durable but the outcome must be
/// inspected before the same stable effect ID may be attempted again.
package struct RecoveryEffectAttempt: Sendable, Equatable {
    package let effectID: UUID
    package let effect: ExecutionRecoveryEffect
    package var result: RecoveryEffectResult?

    package init(effectID: UUID, effect: ExecutionRecoveryEffect,
                 result: RecoveryEffectResult? = nil) {
        self.effectID = effectID
        self.effect = effect
        self.result = result
    }
}

/// A resolved prompt is only valid for the filesystem identity that produced
/// it. The optional remains for journal schema compatibility, but adapters
/// must reject `nil` when applying a decision to any concrete item, including
/// a `remainingItems` policy projected onto the next item.
package struct ResolvedOperationDecision: Sendable, Equatable {
    package let decision: OperationDecision
    package let identityDigest: String?

    package init(decision: OperationDecision, identityDigest: String?) {
        self.decision = decision
        self.identityDigest = identityDigest
    }
}

package struct JournalOperation: Sendable {
    package var snapshot: OperationSnapshot
    package var submissionOrdinal: UInt64
    package var latestDurableSequence: EventSequence
    package var latestEmittedSequence: EventSequence
    package var reservedThrough: EventSequence
    /// M1 keeps these command ledgers in the journal abstraction so a service
    /// restart cannot forget a consumed decision or re-run a completed
    /// recovery command. M3 maps the same fields to normalized SQLite tables.
    package var priorDecisions: [OperationItemID: ResolvedOperationDecision]
    package var remainingDecision: ResolvedOperationDecision?
    package var itemMetadataPolicies: [OperationItemID: MetadataPolicy]
    package var remainingMetadataPolicy: MetadataPolicy?
    package var completedRecoveryActions: Set<UUID>
    package var inProgressRecoveryActions: Set<UUID>
    /// Per-action, per-item write-ahead records. M3 maps these to durable
    /// recovery_effect rows keyed by (action_id, item_id, effect_id).
    package var recoveryEffectAttempts: [UUID: [OperationItemID: RecoveryEffectAttempt]]
    /// Durable filesystem-effect ledger. The fake journal stores this beside
    /// the snapshot; M3 maps it to append-only operation_effect rows.
    package var committedEffects: [OperationItemID: OperationReceiptSummary]

    package init(snapshot: OperationSnapshot, submissionOrdinal: UInt64,
                 latestDurableSequence: EventSequence, latestEmittedSequence: EventSequence,
                 reservedThrough: EventSequence,
                 priorDecisions: [OperationItemID: ResolvedOperationDecision] = [:],
                 remainingDecision: ResolvedOperationDecision? = nil,
                 itemMetadataPolicies: [OperationItemID: MetadataPolicy] = [:],
                 remainingMetadataPolicy: MetadataPolicy? = nil,
                 completedRecoveryActions: Set<UUID> = [],
                 inProgressRecoveryActions: Set<UUID> = [],
                 recoveryEffectAttempts: [UUID: [OperationItemID: RecoveryEffectAttempt]] = [:],
                 committedEffects: [OperationItemID: OperationReceiptSummary] = [:]) {
        self.snapshot = snapshot
        self.submissionOrdinal = submissionOrdinal
        self.latestDurableSequence = latestDurableSequence
        self.latestEmittedSequence = latestEmittedSequence
        self.reservedThrough = reservedThrough
        self.priorDecisions = priorDecisions
        self.remainingDecision = remainingDecision
        self.itemMetadataPolicies = itemMetadataPolicies
        self.remainingMetadataPolicy = remainingMetadataPolicy
        self.completedRecoveryActions = completedRecoveryActions
        self.inProgressRecoveryActions = inProgressRecoveryActions
        self.recoveryEffectAttempts = recoveryEffectAttempts
        self.committedEffects = committedEffects
    }
}

package struct JournalAdmission: Sendable {
    package let operation: JournalOperation
    package let event: OperationEvent
    package init(operation: JournalOperation, event: OperationEvent) {
        self.operation = operation
        self.event = event
    }
}

/// Synchronous by design: FileOperationService is the sole owner and never holds
/// a journal transaction across an await. M3 supplies the SQLite implementation.
package protocol OperationJournal: Sendable {
    var isWritable: Bool { get }
    func loadOperations() throws -> [JournalOperation]
    /// Atomically admits the operation, allocates its first durable sequence,
    /// and appends the discovery event. A queued operation must be discoverable
    /// after restart even if it never becomes the active operation.
    func admit(_ snapshot: OperationSnapshot, at timestamp: Date) throws -> JournalAdmission
    func reserveSequences(for id: OperationID, count: UInt64) throws -> ClosedRange<EventSequence>
    func commit(_ operation: JournalOperation, event: OperationEvent) throws
    func checkpoint(_ operation: JournalOperation) throws
    func replay(operationID: OperationID, after sequence: EventSequence,
                through watermark: EventSequence, limit: Int) throws -> [OperationEvent]
}

package protocol OperationClock: Sendable {
    func now() -> Date
}

package protocol OperationIDGenerator: Sendable {
    func operationID() -> OperationID
    func itemID() -> OperationItemID
    func decisionToken() -> DecisionToken
    func actionID() -> UUID
}

package protocol DigestProvider: Sendable {
    func digest(_ data: Data) throws -> String
}

package enum Failpoint: String, Sendable {
    case plannedPersisted
    case decisionResolved
    case preflightReadyBeforePlan
    case stagingStarted
    case committedAwaitingCleanup
    case recoveryRequired
    case phaseBeganBeforeAuthorization
    case recoveryEffectIntentPersisted
    case recoveryEffectResultPersisted
    /// Stable crash boundary after per-item recovery projection is durable but
    /// before the operation-level terminal projection is durable.
    case recoveryItemProjectionConverged
    case recoveryProjectionConverged
}

package protocol FailpointController: Sendable {
    func hit(_ point: Failpoint, operationID: OperationID) async
}

package enum ServiceDiagnostic: Sendable, Equatable {
    case unknownControl(operationID: OperationID, command: String)
    case controlRejected(operationID: OperationID, command: String, reason: String)
    case journalFailure(String)
    case subscriberInvalidated(UUID)
}

package protocol ServiceDiagnosticSink: Sendable {
    func record(_ diagnostic: ServiceDiagnostic)
}

package enum MoveTopology: Sendable {
    case sameVolume
    case crossVolume
    /// M1 has no native volume adapter yet. Unknown therefore receives the
    /// conservative cross-volume verification policy instead of being called
    /// same-volume by assumption.
    case unknown
}

package enum PreflightDisposition: Sendable {
    case ready(destinations: [URL?], moveTopology: MoveTopology)
    case decision(PreflightDecision)
    case skip
    case failure(FileOperationFailure)
}

package struct PreflightDecision: Sendable {
    package let allowed: [OperationDecision]
    package let metadataLosses: Set<MetadataField>
    package let identityDigest: String

    package init(allowed: [OperationDecision], metadataLosses: Set<MetadataField> = [],
                 identityDigest: String) {
        self.allowed = allowed
        self.metadataLosses = metadataLosses
        self.identityDigest = identityDigest
    }
}

/// M1 intentionally exposes no source-delete primitive. Native source cleanup is
/// introduced behind a separately reviewed M3 interface.
package protocol FileSystemAdapter: Sendable {
    func preflight(operationID: OperationID, itemID: OperationItemID,
                   request: OperationRequest, itemIndex: Int,
                   priorDecision: ResolvedOperationDecision?,
                   controls: ExecutionControls) async throws -> PreflightDisposition
    /// Recovery cleanup is keyed by the same stable effect ID recorded in the
    /// journal. Implementations must bind that ID to operation and item
    /// ownership before mutating or reporting a prior completion.
    func recoverOwnedStaging(operationID: OperationID, itemID: OperationItemID,
                             effectID: UUID) async -> ExecutionRecoveryOutcome
    func inspectOwnedStaging(operationID: OperationID, itemID: OperationItemID,
                             effectID: UUID) async -> ExecutionRecoveryInspection
}

package enum ExecutionSourceDisposition: String, Sendable {
    case noCleanup
    case cleanupRequired
}

package struct ExecutionPlan: Sendable {
    package let sourceDisposition: ExecutionSourceDisposition
    package let durableCommitReceipt: OperationReceiptSummary?

    package init(sourceDisposition: ExecutionSourceDisposition,
                 durableCommitReceipt: OperationReceiptSummary? = nil) {
        self.sourceDisposition = sourceDisposition
        self.durableCommitReceipt = durableCommitReceipt
    }
}

package enum ExecutionPhase: String, Sendable, CaseIterable {
    case staging
    case metadata
    case verification
    case commit
    case sourceCleanup
}

package enum ExecutionPhaseOutcome: Sendable {
    case staged
    case metadataApplied(MetadataOutcome?)
    case verified(VerificationOutcome)
    case committed(OperationReceiptSummary)
    /// A keep-both exclusive commit may advance to a later suffix after a
    /// last-moment destination race. Core records that proven final URL before
    /// it records the receipt, keeping snapshots and UI refreshes truthful.
    case committedAt(OperationReceiptSummary, URL)
    case sourceCleaned
    case cancelled
    case failed(FileOperationFailure)
    case recoveryRequired(FileOperationFailure)
}

/// Synchronous mirror read by native callbacks that cannot `await` the
/// ExecutionControls actor (notably copyfile's C callback). The actor remains
/// authoritative; this object only lets a callback stop at the next safe point.
package final class ExecutionSignal: @unchecked Sendable {
    package struct Snapshot: Sendable {
        package let paused: Bool
        package let cancelled: Bool
    }

    private let lock = NSLock()
    private var paused = false
    private var cancelled = false

    package func update(paused: Bool? = nil, cancelled: Bool? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let paused { self.paused = paused }
        if let cancelled { self.cancelled = cancelled }
    }

    package func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(paused: paused, cancelled: cancelled)
    }
}

package actor ExecutionControls {
    package enum PauseResult: Sendable { case paused, quiescent }

    private var paused = false
    private var cancelled = false
    private var phaseActive = false
    private var pauseAcknowledged = false
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []
    private var pauseWaiters: [CheckedContinuation<PauseResult, Never>] = []
    private var quiesceWaiters: [CheckedContinuation<Void, Never>] = []
    private let synchronousSignal = ExecutionSignal()

    package func callbackSignal() -> ExecutionSignal { synchronousSignal }

    package func beginPhase() {
        phaseActive = true
        pauseAcknowledged = false
    }
    package func endPhase() {
        phaseActive = false
        // A pause arriving after the final checkpoint belongs to the phase
        // that just quiesced. Atomically withdraw it so metadata/verification
        // cannot inherit a stale pause and wait forever.
        if !pauseAcknowledged { paused = false }
        pauseAcknowledged = false
        let pausePending = pauseWaiters
        pauseWaiters.removeAll()
        pausePending.forEach { $0.resume(returning: .quiescent) }
        let quiescePending = quiesceWaiters
        quiesceWaiters.removeAll()
        quiescePending.forEach { $0.resume() }
    }
    package func requestPauseAndWait() async -> PauseResult {
        paused = true
        synchronousSignal.update(paused: true)
        guard phaseActive else {
            paused = false
            synchronousSignal.update(paused: false)
            return .quiescent
        }
        if pauseAcknowledged { return .paused }
        return await withCheckedContinuation { pauseWaiters.append($0) }
    }
    package func requestResume() {
        paused = false
        synchronousSignal.update(paused: false)
        pauseAcknowledged = false
        let pending = resumeWaiters
        resumeWaiters.removeAll()
        pending.forEach { $0.resume() }
    }
    /// Revokes the current phase without waiting for it to quiesce. This is
    /// used from executor callbacks when journal durability is lost: waiting
    /// for `endPhase()` from inside that callback would deadlock the callback
    /// with its own caller. Pause callers are released as quiescent because a
    /// revoked phase can no longer acknowledge a useful pause.
    package func revoke() {
        cancelled = true
        paused = false
        synchronousSignal.update(paused: false, cancelled: true)
        pauseAcknowledged = false
        let resumePending = resumeWaiters
        resumeWaiters.removeAll()
        resumePending.forEach { $0.resume() }
        let pausePending = pauseWaiters
        pauseWaiters.removeAll()
        pausePending.forEach { $0.resume(returning: .quiescent) }
    }
    package func requestCancelAndWait() async {
        revoke()
        guard phaseActive else { return }
        await withCheckedContinuation { quiesceWaiters.append($0) }
    }
    package func isCancelled() -> Bool { cancelled }
    package func checkpoint() async {
        guard paused, !cancelled else { return }
        pauseAcknowledged = true
        let pending = pauseWaiters
        pauseWaiters.removeAll()
        pending.forEach { $0.resume(returning: .paused) }
        await withCheckedContinuation { resumeWaiters.append($0) }
    }
}

package struct ExecutionContext: Sendable {
    package let operationID: OperationID
    package let itemID: OperationItemID
    package let request: OperationRequest
    package let source: URL
    package let destination: URL?
    package let itemIndex: Int
    package let metadataPolicy: MetadataPolicy
    package let verificationPolicy: VerificationPolicy
}

package protocol OperationExecutor: Sendable {
    func plan(_ context: ExecutionContext, controls: ExecutionControls) async throws -> ExecutionPlan
    /// Implementations must call `controls.checkpoint()` and then inspect
    /// `isCancelled()` after every progress callback and every awaited gate,
    /// before starting another filesystem effect. A progress callback may
    /// discover a fatal journal failure and non-blockingly revoke the phase.
    func perform(_ phase: ExecutionPhase, context: ExecutionContext, plan: ExecutionPlan,
                 controls: ExecutionControls,
                 progress: @escaping @Sendable (OperationProgress) async -> Void) async
        -> ExecutionPhaseOutcome
    func recover(_ effect: ExecutionRecoveryEffect, effectID: UUID,
                 context: ExecutionContext,
                 receipt: OperationReceiptSummary) async -> ExecutionRecoveryOutcome
    func inspectRecoveryEffect(_ effect: ExecutionRecoveryEffect, effectID: UUID,
                               context: ExecutionContext,
                               receipt: OperationReceiptSummary) async
        -> ExecutionRecoveryInspection
    func inspectCommit(_ context: ExecutionContext) async -> ExecutionCommitInspection
    func inspectSourceBeforeCleanup(_ context: ExecutionContext,
                                    receipt: OperationReceiptSummary) async
        -> ExecutionSourceInspection
}

package enum ExecutionCommitInspection: Sendable {
    case committed(OperationReceiptSummary)
    case notCommitted
    case unknown(FileOperationFailure)
}

package enum ExecutionSourceInspection: Sendable {
    case sourcePresentMatching
    case sourceAbsent
    case sourceChanged(FileOperationFailure)
    case unknown(FileOperationFailure)
}

package enum ExecutionRecoveryEffect: String, Sendable {
    case rollbackCommittedDestination
    case finalizeKnownCommit
    case cleanupSource
    case cleanupStaging
}

package enum ExecutionRecoveryOutcome: Sendable {
    case completed
    /// The executor guarantees the external mutation did not begin. Only this
    /// outcome authorizes removal of a durable per-item intent.
    case failedBeforeEffect(FileOperationFailure)
    /// The effect may have happened. The intent remains durable and must be
    /// reconciled through `inspectRecoveryEffect` before any retry.
    case ambiguous(FileOperationFailure)
}

package enum ExecutionRecoveryInspection: Sendable {
    case completed
    case notPerformed
    case unknown(FileOperationFailure)
}

package struct ServiceDependencies: Sendable {
    package let journal: any OperationJournal
    package let fileSystem: any FileSystemAdapter
    package let clock: any OperationClock
    package let ids: any OperationIDGenerator
    package let digest: any DigestProvider
    package let failpoints: any FailpointController
    package let executor: any OperationExecutor
    package let diagnostics: any ServiceDiagnosticSink
    package let replayPageSize: Int
    package let liveBufferLimit: Int

    package init(journal: any OperationJournal, fileSystem: any FileSystemAdapter,
                 clock: any OperationClock, ids: any OperationIDGenerator,
                 digest: any DigestProvider, failpoints: any FailpointController,
                 executor: any OperationExecutor, diagnostics: any ServiceDiagnosticSink,
                 replayPageSize: Int = 32, liveBufferLimit: Int = 64) {
        self.journal = journal
        self.fileSystem = fileSystem
        self.clock = clock
        self.ids = ids
        self.digest = digest
        self.failpoints = failpoints
        self.executor = executor
        self.diagnostics = diagnostics
        self.replayPageSize = max(1, replayPageSize)
        self.liveBufferLimit = max(1, liveBufferLimit)
    }
}
