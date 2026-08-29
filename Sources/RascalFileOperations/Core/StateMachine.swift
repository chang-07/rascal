import Foundation

package enum ItemStateMachine {
    package static let allowed: [OperationItemState: Set<OperationItemState>] = [
        .pending: [.preflight, .cancelled, .skipped],
        .preflight: [.waitingForDecision, .staging, .failedRecoverable, .cancelled, .skipped],
        .waitingForDecision: [.preflight, .cancelled],
        .staging: [.paused, .metadata, .failedRecoverable, .cancelled, .cleanupRequired, .recoveryRequired],
        .paused: [.staging, .cancelled, .cleanupRequired, .recoveryRequired],
        .metadata: [.verifying, .failedRecoverable, .cancelled, .cleanupRequired, .recoveryRequired],
        .verifying: [.committing, .failedRecoverable, .cancelled, .cleanupRequired, .recoveryRequired],
        .committing: [.committed, .recoveryRequired],
        .committed: [.completed, .committedAwaitingCleanup, .rolledBack, .failedRecoverable, .recoveryRequired],
        .committedAwaitingCleanup: [.completed, .sourceQuarantining, .failedRecoverable, .recoveryRequired],
        .sourceQuarantining: [.cleaningSource, .cleanupRequired, .recoveryRequired],
        .cleaningSource: [.completed, .cleanupRequired, .recoveryRequired],
        .failedRecoverable: [.preflight, .cancelled, .rolledBack, .recoveryRequired],
        .cleanupRequired: [.cancelled, .failedRecoverable, .sourceQuarantining, .cleaningSource, .recoveryRequired],
        .recoveryRequired: [.failedRecoverable, .cancelled, .rolledBack],
        .completed: [.rolledBack], .skipped: [], .cancelled: [], .rolledBack: []
    ]

    package static func validate(from: OperationItemState, to: OperationItemState,
                                 operationID: OperationID? = nil,
                                 itemID: OperationItemID? = nil) throws {
        guard allowed[from, default: []].contains(to) else {
            throw FileOperationFailure(
                code: .invariantViolation, operationID: operationID, itemID: itemID,
                diagnostic: "illegal item transition \(from.rawValue) -> \(to.rawValue)", retryable: false
            )
        }
    }
}

package enum OperationStateMachine {
    package static let allowed: [OperationState: Set<OperationState>] = [
        .planned: [.preflight, .cancelled],
        .preflight: [.waitingForDecision, .staging, .failedRecoverable, .cancelled, .completedWithSkips],
        .waitingForDecision: [.preflight, .cancelled, .failedRecoverable],
        .staging: [.paused, .metadata, .failedRecoverable, .cancelled, .cleanupRequired, .recoveryRequired],
        .paused: [.staging, .cancelled, .cleanupRequired, .recoveryRequired],
        .metadata: [.verifying, .failedRecoverable, .cancelled, .cleanupRequired, .recoveryRequired],
        .verifying: [.committing, .failedRecoverable, .cancelled, .cleanupRequired, .recoveryRequired],
        .committing: [.preflight, .completed, .completedWithSkips, .committedAwaitingCleanup, .recoveryRequired],
        .committedAwaitingCleanup: [.completed, .completedWithSourceRetained, .sourceQuarantining, .recoveryRequired],
        .sourceQuarantining: [.cleaningSource, .recoveryRequired],
        .cleaningSource: [.preflight, .completed, .completedWithSkips, .cleanupRequired, .recoveryRequired],
        .failedRecoverable: [.preflight, .rolledBack, .completed, .completedWithSkips],
        .recoveryRequired: [.rolledBack, .failedRecoverable, .sourceQuarantining, .cleanupRequired, .completed, .completedWithSkips, .completedWithSourceRetained],
        .cleanupRequired: [.sourceQuarantining, .cleaningSource, .cancelled, .failedRecoverable, .recoveryRequired, .rolledBack, .completed, .completedWithSourceRetained],
        .completed: [], .completedWithSkips: [], .completedWithSourceRetained: [],
        .cancelled: [], .rolledBack: []
    ]

    package static func validate(from: OperationState, to: OperationState,
                                 operationID: OperationID? = nil) throws {
        guard allowed[from, default: []].contains(to) else {
            throw FileOperationFailure(
                code: .invariantViolation, operationID: operationID, phase: from,
                diagnostic: "illegal operation transition \(from.rawValue) -> \(to.rawValue)", retryable: false
            )
        }
    }
}

package enum OperationAggregator {
    package static func terminalState(items: [OperationItemSnapshot], sourceRetained: Bool,
                                      rollbackCompleted: Bool = false) -> OperationState? {
        if rollbackCompleted { return .rolledBack }
        if items.contains(where: { $0.state == .recoveryRequired }) { return .recoveryRequired }
        if items.contains(where: { $0.state == .cleanupRequired }) { return .cleanupRequired }
        if items.contains(where: { $0.state == .failedRecoverable }) { return .failedRecoverable }
        let terminal = Set<OperationItemState>([.completed, .skipped, .cancelled, .rolledBack])
        guard items.allSatisfy({ terminal.contains($0.state) }) else { return nil }
        let hasDurableCommit = items.contains { $0.receipt != nil }
        if sourceRetained {
            // Source-retained is a successful post-commit barrier result, not
            // a flag that can turn an in-flight or receipt-free operation into
            // a terminal success.
            return hasDurableCommit ? .completedWithSourceRetained : .recoveryRequired
        }
        if items.allSatisfy({ $0.state == .cancelled }) {
            return hasDurableCommit ? .failedRecoverable : .cancelled
        }
        if items.contains(where: { $0.state == .skipped }) &&
            items.allSatisfy({ $0.state == .completed || $0.state == .skipped }) {
            return .completedWithSkips
        }
        if items.allSatisfy({ $0.state == .completed }) { return .completed }
        if items.allSatisfy({ $0.state == .rolledBack || $0.state == .cancelled }) { return .rolledBack }
        return .failedRecoverable
    }
}
