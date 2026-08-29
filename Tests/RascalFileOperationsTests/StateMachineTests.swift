import Foundation
import XCTest
@testable import RascalFileOperations

final class StateMachineTests: XCTestCase {
    private let expectedItemTransitions: [OperationItemState: Set<OperationItemState>] = [
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

    private let expectedOperationTransitions: [OperationState: Set<OperationState>] = [
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

    func testItemTransitionCartesianProductMatchesNormativeTable() {
        XCTAssertEqual(Set(expectedItemTransitions.keys), Set(OperationItemState.allCases))
        for from in OperationItemState.allCases {
            for to in OperationItemState.allCases {
                let expected = expectedItemTransitions[from, default: []].contains(to)
                do {
                    try ItemStateMachine.validate(from: from, to: to)
                    XCTAssertTrue(expected, "unexpected legal item edge \(from) -> \(to)")
                } catch let failure as FileOperationFailure {
                    XCTAssertFalse(expected, "declared item edge rejected: \(from) -> \(to)")
                    XCTAssertEqual(failure.code, .invariantViolation)
                } catch {
                    XCTFail("wrong error type for \(from) -> \(to): \(error)")
                }
            }
        }
    }

    func testOperationTransitionCartesianProductMatchesNormativeGraph() {
        XCTAssertEqual(Set(expectedOperationTransitions.keys), Set(OperationState.allCases))
        for from in OperationState.allCases {
            for to in OperationState.allCases {
                let expected = expectedOperationTransitions[from, default: []].contains(to)
                do {
                    try OperationStateMachine.validate(from: from, to: to)
                    XCTAssertTrue(expected, "unexpected legal operation edge \(from) -> \(to)")
                } catch let failure as FileOperationFailure {
                    XCTAssertFalse(expected, "declared operation edge rejected: \(from) -> \(to)")
                    XCTAssertEqual(failure.code, .invariantViolation)
                } catch {
                    XCTFail("wrong error type for \(from) -> \(to): \(error)")
                }
            }
        }
    }

    func testIllegalTransitionCarriesTypedContext() {
        let operationID = OperationID(rawValue: UUID())
        let itemID = OperationItemID(rawValue: UUID())
        XCTAssertThrowsError(try ItemStateMachine.validate(
            from: .staging, to: .committing, operationID: operationID, itemID: itemID
        )) { error in
            guard let failure = error as? FileOperationFailure else { return XCTFail("wrong error") }
            XCTAssertEqual(failure.code, .invariantViolation)
            XCTAssertEqual(failure.operationID, operationID)
            XCTAssertEqual(failure.itemID, itemID)
        }
    }

    func testLatePauseIsWithdrawnWhenPhaseQuiesces() async throws {
        let controls = ExecutionControls()
        await controls.beginPhase()
        let pause = Task { await controls.requestPauseAndWait() }
        await Task.yield()
        await controls.endPhase()
        let result = await pause.value
        guard case .quiescent = result else {
            return XCTFail("late pause must resolve as quiescent")
        }

        // A stale pause would suspend this checkpoint forever. Keeping this in
        // the structured test task makes the suite-level deadline authoritative.
        await controls.beginPhase()
        await controls.checkpoint()
        await controls.endPhase()
    }

    func testAggregateTerminalStatesAreUnambiguous() {
        XCTAssertEqual(aggregate([.completed]), .completed)
        XCTAssertEqual(aggregate([.completed, .skipped]), .completedWithSkips)
        XCTAssertEqual(aggregate([.cancelled, .cancelled]), .cancelled)
        XCTAssertEqual(aggregate([.completed, .cancelled]), .failedRecoverable)
        XCTAssertEqual(aggregate([.failedRecoverable]), .failedRecoverable)
        XCTAssertEqual(aggregate([.cleanupRequired]), .cleanupRequired)
        XCTAssertEqual(aggregate([.recoveryRequired]), .recoveryRequired)
        XCTAssertEqual(aggregate([.rolledBack, .cancelled]), .rolledBack)
        XCTAssertEqual(aggregate([.pending]), nil)
        XCTAssertEqual(aggregate([.completed, .cancelled], sourceRetained: true), .completedWithSourceRetained)
        XCTAssertEqual(aggregate([.recoveryRequired], sourceRetained: true), .recoveryRequired)
        XCTAssertEqual(aggregate([.completed], rollbackCompleted: true), .rolledBack)
        XCTAssertEqual(aggregate([.cancelled], forceReceipt: true), .failedRecoverable)
        XCTAssertEqual(aggregate([.pending], sourceRetained: true, forceReceipt: true), nil)
        XCTAssertEqual(aggregate([.completed], sourceRetained: true, forceReceipt: false),
                       .recoveryRequired)
    }

    private func aggregate(_ states: [OperationItemState], sourceRetained: Bool = false,
                           rollbackCompleted: Bool = false,
                           forceReceipt: Bool? = nil) -> OperationState? {
        OperationAggregator.terminalState(
            items: states.enumerated().map { index, state in
                OperationItemSnapshot(
                    id: OperationItemID(rawValue: UUID()),
                    source: URL(fileURLWithPath: "/source/\(index)"), destination: nil,
                    state: state, progress: .zero, metadata: nil, verification: nil,
                    receipt: (forceReceipt ?? (state == .completed)) ? OperationReceiptSummary(
                        committedIdentityDigest: "id-\(index)", backupURL: nil,
                        quarantineURL: nil, sourceCleanupPending: false
                    ) : nil,
                    failure: nil
                )
            },
            sourceRetained: sourceRetained,
            rollbackCompleted: rollbackCompleted
        )
    }
}
