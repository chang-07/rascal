import Foundation

/// Process-local journal used only by the M2 debug vertical slice.
///
/// It preserves the service's ordering, event replay, and effect-ledger
/// invariants while the process is alive, but intentionally provides no crash
/// durability. M3 replaces this implementation with SQLite before the native
/// engine can become a release capability.
package final class VolatileOperationJournal: @unchecked Sendable, OperationJournal {
    private let lock = NSLock()
    private var operations: [OperationID: JournalOperation] = [:]
    private var events: [OperationID: [OperationEvent]] = [:]
    private var ordinal: UInt64 = 0

    package let isWritable = true

    package init() {}

    package func loadOperations() throws -> [JournalOperation] {
        lock.lock(); defer { lock.unlock() }
        return operations.values.sorted { $0.submissionOrdinal < $1.submissionOrdinal }
    }

    package func admit(_ snapshot: OperationSnapshot, at timestamp: Date) throws -> JournalAdmission {
        lock.lock(); defer { lock.unlock() }
        guard operations[snapshot.id] == nil else {
            throw failure(snapshot.id, "duplicate operation ID")
        }
        let (nextOrdinal, overflow) = ordinal.addingReportingOverflow(1)
        guard !overflow else { throw failure(nil, "submission ordinal exhausted") }
        ordinal = nextOrdinal

        let sequence: EventSequence = 1
        let admitted = snapshot.replacingLatestSequence(sequence)
        let operation = JournalOperation(
            snapshot: admitted,
            submissionOrdinal: ordinal,
            latestDurableSequence: sequence,
            latestEmittedSequence: sequence,
            reservedThrough: sequence
        )
        let event = OperationEvent(
            operationID: snapshot.id,
            itemID: nil,
            sequence: sequence,
            timestamp: timestamp,
            durability: .durable,
            payload: .admitted(admitted)
        )
        operations[snapshot.id] = operation
        events[snapshot.id] = [event]
        return JournalAdmission(operation: operation, event: event)
    }

    package func reserveSequences(
        for id: OperationID, count: UInt64
    ) throws -> ClosedRange<EventSequence> {
        lock.lock(); defer { lock.unlock() }
        guard count > 0, var operation = operations[id] else {
            throw failure(id, "cannot reserve sequence")
        }
        let (start, startOverflow) = operation.reservedThrough.addingReportingOverflow(1)
        let (end, endOverflow) = start.addingReportingOverflow(count - 1)
        guard !startOverflow, !endOverflow else {
            throw failure(id, "event sequence space exhausted")
        }
        operation.reservedThrough = end
        operations[id] = operation
        return start...end
    }

    package func commit(_ operation: JournalOperation, event: OperationEvent) throws {
        lock.lock(); defer { lock.unlock() }
        guard operations[event.operationID] != nil,
              event.sequence <= operation.reservedThrough,
              event.sequence > (events[event.operationID]?.last?.sequence ?? 0) else {
            throw failure(event.operationID, "non-monotonic or unreserved event")
        }
        operations[event.operationID] = operation
        events[event.operationID, default: []].append(event)
    }

    package func checkpoint(_ operation: JournalOperation) throws {
        lock.lock(); defer { lock.unlock() }
        guard operations[operation.snapshot.id] != nil else {
            throw failure(operation.snapshot.id, "checkpoint for unknown operation")
        }
        operations[operation.snapshot.id] = operation
    }

    package func replay(
        operationID: OperationID,
        after sequence: EventSequence,
        through watermark: EventSequence,
        limit: Int
    ) throws -> [OperationEvent] {
        lock.lock(); defer { lock.unlock() }
        return Array(events[operationID, default: []]
            .filter { $0.sequence > sequence && $0.sequence <= watermark }
            .prefix(max(1, limit)))
    }

    private func failure(_ id: OperationID?, _ diagnostic: String) -> FileOperationFailure {
        FileOperationFailure(
            code: .journalFailure,
            operationID: id,
            diagnostic: diagnostic,
            retryable: false
        )
    }
}

private extension OperationSnapshot {
    func replacingLatestSequence(_ sequence: EventSequence) -> OperationSnapshot {
        OperationSnapshot(
            schemaVersion: schemaVersion,
            id: id,
            kind: kind,
            state: state,
            latestSequence: sequence,
            request: request,
            effectiveMetadataPolicy: effectiveMetadataPolicy,
            effectiveVerificationPolicy: effectiveVerificationPolicy,
            progress: progress,
            items: items,
            pendingDecision: pendingDecision,
            terminalFailure: terminalFailure,
            availableActions: availableActions,
            hasPartialCommit: hasPartialCommit,
            sourceRetained: sourceRetained
        )
    }
}
