import Foundation
import XCTest
@testable import RascalFileOperations
import RascalFileOperationsTestSupport

final class RecoverySafetyTests: XCTestCase {
    func testQueuedPlannedOperationCanBeCancelledWithoutReleasingActiveSlot() async throws {
        let gate = ContinuationGate()
        let fileSystem = FakeFileSystemAdapter()
        await fileSystem.setPreflightGate(gate)
        let harness = try ServiceTestHarness(fileSystem: fileSystem)
        let first = try await harness.service.submit(copyRequest("/source/active"))
        try await gate.waitUntilEntered()
        let queued = try await harness.service.submit(copyRequest("/source/queued"))

        await harness.service.cancel(queued)
        let queuedSnapshot = try await harness.service.snapshot(queued)
        let firstSnapshot = try await harness.service.snapshot(first)
        let maximumConcurrency = await fileSystem.maximumPreflightConcurrency()
        XCTAssertEqual(queuedSnapshot.state, .cancelled)
        XCTAssertEqual(firstSnapshot.state, .preflight)
        XCTAssertEqual(maximumConcurrency, 1)

        await gate.release()
        _ = try await waitForState(.completed, id: first, service: harness.service)
    }

    func testQueuedAdmissionIsReplayDiscoverableBeforeExecutionStarts() async throws {
        let gate = ContinuationGate()
        let fileSystem = FakeFileSystemAdapter()
        await fileSystem.setPreflightGate(gate)
        let harness = try ServiceTestHarness(fileSystem: fileSystem)
        _ = try await harness.service.submit(copyRequest("/source/active-discovery"))
        try await gate.waitUntilEntered()
        let queued = try await harness.service.submit(copyRequest("/source/queued-discovery"))

        let discovered = try await withDeadline("queued admission replay") {
            let stream = await harness.service.events()
            for await event in stream where event.operationID == queued {
                if case .admitted = event.payload { return event }
            }
            throw TestDeadline.exceeded("event stream ended")
        }
        XCTAssertEqual(discovered.sequence, 1)
        XCTAssertEqual(discovered.durability, .durable)
        let queuedSnapshot = try await harness.service.snapshot(queued)
        XCTAssertEqual(queuedSnapshot.state, .planned)

        await harness.service.cancel(queued)
        await gate.release()
    }

    func testPreflightCancellationKeepsActiveSlotUntilAdapterQuiesces() async throws {
        let gate = ContinuationGate()
        let fileSystem = FakeFileSystemAdapter()
        await fileSystem.setPreflightGate(gate)
        let harness = try ServiceTestHarness(fileSystem: fileSystem)
        let first = try await harness.service.submit(copyRequest("/source/first"))
        try await gate.waitUntilEntered()

        let cancelling = Task { await harness.service.cancel(first) }
        let second = try await harness.service.submit(copyRequest("/source/second"))
        for _ in 0..<50 {
            if await harness.fileSystem.counts().preflight == 1 { break }
            await Task.yield()
        }
        let secondWhileBlocked = try await harness.service.snapshot(second)
        let blockedMaximum = await fileSystem.maximumPreflightConcurrency()
        XCTAssertEqual(secondWhileBlocked.state, .planned)
        XCTAssertEqual(blockedMaximum, 1)

        await gate.release()
        await cancelling.value
        let cancelledFirst = try await harness.service.snapshot(first)
        XCTAssertEqual(cancelledFirst.state, .cancelled)
        _ = try await waitForState(.completed, id: second, service: harness.service)
        let finalMaximum = await fileSystem.maximumPreflightConcurrency()
        XCTAssertEqual(finalMaximum, 1)
    }

    func testInitialCleanupInspectionHandlesAllOutcomesWithoutGuessing() async throws {
        for (inspection, expectedState, expectedEffects):
            (FakeSourceInspection, OperationState, Int) in [
                (.sourcePresentMatching, .completed, 1),
                (.sourceAbsent, .completed, 0),
                (.sourceChanged, .recoveryRequired, 0),
                (.unknown, .recoveryRequired, 0)
            ] {
            let executor = FakeOperationExecutor(modes: [.move: .committedAwaitingCleanup])
            await executor.setSourceInspection(inspection)
            let harness = try ServiceTestHarness(executor: executor)
            let id = try await harness.service.submit(moveRequest("/source/\(inspection)"))
            let snapshot = try await waitForState(expectedState, id: id, service: harness.service)
            let itemID = try XCTUnwrap(snapshot.items.first?.id)
            XCTAssertEqual(snapshot.items.first?.state,
                           expectedState == .recoveryRequired ? .recoveryRequired : .completed)
            let cleanupEffects = await executor.effectCount(
                operationID: id, itemID: itemID, phase: .sourceCleanup
            )
            XCTAssertEqual(cleanupEffects, expectedEffects)
            if expectedState == .recoveryRequired {
                XCTAssertEqual(snapshot.availableActions.count, 2)
                XCTAssertTrue(snapshot.items.first?.receipt?.sourceCleanupPending == true)
            } else {
                XCTAssertTrue(snapshot.items.first?.receipt?.sourceCleanupPending == false)
            }
        }
    }

    func testCleanupRetryReinspectsIdentityAndKeepsChangedOrUnknownTokenLiveAcrossRestart()
        async throws {
        for inspection in [FakeSourceInspection.sourceChanged, .unknown] {
            let journal = InMemoryOperationJournal()
            let executor = FakeOperationExecutor(modes: [.move: .committedAwaitingCleanup])
            await executor.setSourceCleanupFailures(1)
            let first = try ServiceTestHarness(journal: journal, executor: executor)
            let id = try await first.service.submit(moveRequest("/source/reinspect-\(inspection)"))
            let failed = try await waitForState(.cleanupRequired, id: id, service: first.service)
            let itemID = try XCTUnwrap(failed.items.first?.id)
            let action = try XCTUnwrap(failed.availableActions.first {
                if case .retrySourceCleanup = $0 { return true }
                return false
            })
            await executor.setSourceInspection(inspection)

            await assertFailure(inspection == .sourceChanged ? .sourceChanged : .recoveryRequired) {
                try await first.service.recover(id, action: action)
            }
            let afterFirst = try await first.service.snapshot(id)
            XCTAssertEqual(afterFirst.state, .cleanupRequired)
            XCTAssertTrue(afterFirst.availableActions.contains(action))
            let effectsAfterFirst = await executor.effectCount(
                operationID: id, itemID: itemID, phase: .sourceCleanup
            )
            XCTAssertEqual(effectsAfterFirst, 1)

            let restarted = try ServiceTestHarness(journal: journal, executor: executor)
            await assertFailure(inspection == .sourceChanged ? .sourceChanged : .recoveryRequired) {
                try await restarted.service.recover(id, action: action)
            }
            let afterRestart = try await restarted.service.snapshot(id)
            XCTAssertTrue(afterRestart.availableActions.contains(action))
            let effectsAfterRestart = await executor.effectCount(
                operationID: id, itemID: itemID, phase: .sourceCleanup
            )
            XCTAssertEqual(effectsAfterRestart, 1)
        }
    }

    func testCleanupRetryAndRetainConvergeFromConfirmedSourceStateAndAreRestartIdempotent()
        async throws {
        let retryJournal = InMemoryOperationJournal()
        let retryExecutor = FakeOperationExecutor(modes: [.move: .committedAwaitingCleanup])
        await retryExecutor.setSourceCleanupFailures(1)
        let retryHarness = try ServiceTestHarness(journal: retryJournal, executor: retryExecutor)
        let retryID = try await retryHarness.service.submit(moveRequest("/source/retry"))
        let retryFailed = try await waitForState(
            .cleanupRequired, id: retryID, service: retryHarness.service
        )
        let retryItem = try XCTUnwrap(retryFailed.items.first?.id)
        let retryAction = try XCTUnwrap(retryFailed.availableActions.first {
            if case .retrySourceCleanup = $0 { return true }
            return false
        })
        try await retryHarness.service.recover(retryID, action: retryAction)
        let retried = try await retryHarness.service.snapshot(retryID)
        let retryEffects = await retryExecutor.effectCount(
            operationID: retryID, itemID: retryItem, phase: .sourceCleanup
        )
        let retryRecoveryEffects = await retryExecutor.recoveryEffectHistory().filter {
            $0.operationID == retryID && $0.itemID == retryItem &&
                $0.effect == "cleanupSource"
        }.count
        XCTAssertEqual(retried.state, .completed)
        XCTAssertEqual(retryEffects, 1)
        XCTAssertEqual(retryRecoveryEffects, 1)
        let retryRestart = try ServiceTestHarness(journal: retryJournal, executor: retryExecutor)
        try await retryRestart.service.recover(retryID, action: retryAction)
        let retryEffectsAfterRestart = await retryExecutor.effectCount(
            operationID: retryID, itemID: retryItem, phase: .sourceCleanup
        )
        let retryRecoveryEffectsAfterRestart = await retryExecutor.recoveryEffectHistory().filter {
            $0.operationID == retryID && $0.itemID == retryItem &&
                $0.effect == "cleanupSource"
        }.count
        XCTAssertEqual(retryEffectsAfterRestart, 1)
        XCTAssertEqual(retryRecoveryEffectsAfterRestart, 1)

        let retainJournal = InMemoryOperationJournal()
        let retainExecutor = FakeOperationExecutor(modes: [.move: .committedAwaitingCleanup])
        await retainExecutor.setSourceCleanupFailures(1)
        let retainHarness = try ServiceTestHarness(journal: retainJournal, executor: retainExecutor)
        let retainID = try await retainHarness.service.submit(moveRequest("/source/retain"))
        let retainFailed = try await waitForState(
            .cleanupRequired, id: retainID, service: retainHarness.service
        )
        let retainItem = try XCTUnwrap(retainFailed.items.first?.id)
        let retainAction = try XCTUnwrap(retainFailed.availableActions.first {
            if case .retainSource = $0 { return true }
            return false
        })
        try await retainHarness.service.recover(retainID, action: retainAction)
        let retained = try await retainHarness.service.snapshot(retainID)
        XCTAssertEqual(retained.state, .completedWithSourceRetained)
        XCTAssertTrue(retained.sourceRetained)
        let retainRestart = try ServiceTestHarness(journal: retainJournal, executor: retainExecutor)
        try await retainRestart.service.recover(retainID, action: retainAction)
        let retainEffectsAfterRestart = await retainExecutor.effectCount(
            operationID: retainID, itemID: retainItem, phase: .sourceCleanup
        )
        XCTAssertEqual(retainEffectsAfterRestart, 1)
    }

    func testRestartFailsClosedForUnexplainedCommitAndCleanupEffects() async throws {
        let commitJournal = InMemoryOperationJournal()
        let commitGate = ContinuationGate()
        let commitExecutor = FakeOperationExecutor()
        await commitExecutor.setPostEffectGate(commitGate, for: .commit)
        let commitHarness = try ServiceTestHarness(journal: commitJournal, executor: commitExecutor)
        let commitID = try await commitHarness.service.submit(copyRequest("/source/commit-crash"))
        try await commitGate.waitUntilEntered()
        commitJournal.injectNextWriteFailure()
        await commitGate.release()
        try await waitForDiagnostic(commitHarness.diagnostics)
        let strandedCommit = try await commitHarness.service.snapshot(commitID)
        XCTAssertEqual(strandedCommit.state, .committing)
        let commitRestart = try ServiceTestHarness(journal: commitJournal)
        await assertFailure(.serviceSafeMode) {
            _ = try await commitRestart.service.submit(copyRequest("/source/blocked-after-commit"))
        }

        let cleanupJournal = InMemoryOperationJournal()
        let cleanupGate = ContinuationGate()
        let cleanupExecutor = FakeOperationExecutor(modes: [.move: .committedAwaitingCleanup])
        await cleanupExecutor.setPostEffectGate(cleanupGate, for: .sourceCleanup)
        let cleanupHarness = try ServiceTestHarness(
            journal: cleanupJournal, executor: cleanupExecutor
        )
        let cleanupID = try await cleanupHarness.service.submit(moveRequest("/source/cleanup-crash"))
        try await cleanupGate.waitUntilEntered()
        cleanupJournal.injectNextWriteFailure()
        await cleanupGate.release()
        try await waitForDiagnostic(cleanupHarness.diagnostics)
        let strandedCleanup = try await cleanupHarness.service.snapshot(cleanupID)
        XCTAssertEqual(strandedCleanup.state, .cleaningSource)
        let cleanupRestart = try ServiceTestHarness(journal: cleanupJournal)
        await assertFailure(.serviceSafeMode) {
            _ = try await cleanupRestart.service.submit(moveRequest("/source/blocked-after-cleanup"))
        }
    }

    func testPhaseAuthorizationIsRecheckedAfterActorReentrancyWindow() async throws {
        let authorizationGate = ContinuationGate()
        let executor = FakeOperationExecutor()
        let harness = try ServiceTestHarness(executor: executor)
        await harness.failpoints.setGate(
            authorizationGate, for: .phaseBeganBeforeAuthorization
        )
        let id = try await harness.service.submit(copyRequest("/source/authorization-window"))
        try await authorizationGate.waitUntilEntered()
        let staging = try await harness.service.snapshot(id)
        let itemID = try XCTUnwrap(staging.items.first?.id)
        XCTAssertEqual(staging.state, .staging)

        harness.journal.injectNextWriteFailure()
        await harness.service.resume(id)
        await authorizationGate.release()
        try await waitForDiagnostic(harness.diagnostics)
        let stagingEffects = await executor.effectCount(
            operationID: id, itemID: itemID, phase: .staging
        )
        XCTAssertEqual(stagingEffects, 0)
        await assertFailure(.serviceSafeMode) {
            _ = try await harness.service.submit(copyRequest("/source/blocked"))
        }
    }

    func testMoveVerificationUsesKnownTopologyAndFailsClosedWhenUnknown() async throws {
        for (topology, requested, expected): (MoveTopology, VerificationPolicy, VerificationPolicy) in [
            (.sameVolume, .structural, .structural),
            (.sameVolume, .sha256, .sha256),
            (.crossVolume, .structural, .sha256),
            (.unknown, .structural, .sha256)
        ] {
            let fileSystem = FakeFileSystemAdapter()
            await fileSystem.setMoveTopology(topology)
            let harness = try ServiceTestHarness(fileSystem: fileSystem)
            let request = OperationRequest(
                kind: .move, sources: [fileURL("/source/\(topology)-\(requested)")],
                destination: fileURL("/target"), destinationMode: .container,
                verificationPolicy: requested
            )
            let id = try await harness.service.submit(request)
            let completed = try await waitForState(.completed, id: id, service: harness.service)
            XCTAssertEqual(completed.effectiveVerificationPolicy, expected)
            XCTAssertEqual(completed.items.first?.verification?.policy, expected)
        }
    }

    func testResumeFromVerifiedStageExecutesAndIsDurablyIdempotentAcrossRestart() async throws {
        let journal = InMemoryOperationJournal()
        let executor = FakeOperationExecutor()
        await executor.setModeSequence([.failed(.noSpace), .committed], for: .copy)
        let harness = try ServiceTestHarness(journal: journal, executor: executor)
        let id = try await harness.service.submit(copyRequest("/source/resume-action"))
        _ = try await waitForState(.failedRecoverable, id: id, service: harness.service)
        let failed = try await waitForRecoveryAction(id: id, service: harness.service) {
            if case .resumeFromVerifiedStage = $0 { return true }
            return false
        }
        let itemID = try XCTUnwrap(failed.items.first?.id)
        let initialStagingEffects = await executor.effectCount(
            operationID: id, itemID: itemID, phase: .staging
        )
        let stagingCleanupEffects = await harness.fileSystem.stagingRecoveryEffectHistory()
        XCTAssertEqual(initialStagingEffects, 1)
        XCTAssertEqual(stagingCleanupEffects.count, 1)
        XCTAssertEqual(stagingCleanupEffects.first?.operationID, id)
        XCTAssertEqual(stagingCleanupEffects.first?.itemID, itemID)
        let action = try XCTUnwrap(failed.availableActions.first {
            if case .resumeFromVerifiedStage = $0 { return true }
            return false
        })

        try await harness.service.recover(id, action: action)
        let completed = try await waitForState(.completed, id: id, service: harness.service)
        XCTAssertNil(completed.terminalFailure)
        XCTAssertTrue(journal.recoveryActionCompleted(
            operationID: id, actionID: action.command.actionID
        ))
        let effectsAfterResume = await executor.effectCount(
            operationID: id, itemID: itemID, phase: .commit
        )
        XCTAssertEqual(effectsAfterResume, 1)

        try await harness.service.recover(id, action: action)
        let restarted = try ServiceTestHarness(journal: journal, executor: executor)
        try await restarted.service.recover(id, action: action)
        let effectsAfterRestart = await executor.effectCount(
            operationID: id, itemID: itemID, phase: .commit
        )
        XCTAssertEqual(effectsAfterRestart, 1)
        let cleanupEffectsAfterRetry = await harness.fileSystem.stagingRecoveryEffectHistory()
        XCTAssertEqual(cleanupEffectsAfterRetry.count, 1)
    }

    func testMultiItemRollbackResumesFromDurablePerItemLedgerAfterRestart() async throws {
        let journal = InMemoryOperationJournal()
        let executor = FakeOperationExecutor()
        await executor.setModeSequence(
            [.committed, .committed, .failed(.noSpace)], for: .copy
        )
        let harness = try ServiceTestHarness(journal: journal, executor: executor)
        let id = try await harness.service.submit(OperationRequest(
            kind: .copy,
            sources: [fileURL("/source/rollback-a"), fileURL("/source/rollback-b"),
                      fileURL("/source/rollback-c")],
            destination: fileURL("/target"), destinationMode: .container
        ))
        _ = try await waitForState(.failedRecoverable, id: id, service: harness.service)
        let failed = try await waitForRecoveryAction(id: id, service: harness.service) {
            if case .rollbackCommittedDestination = $0 { return true }
            return false
        }
        let action = try XCTUnwrap(failed.availableActions.first {
            if case .rollbackCommittedDestination = $0 { return true }
            return false
        })
        await executor.setRecoveryModes([.completed, .failed])
        await assertFailure(.permissionDenied) {
            try await harness.service.recover(id, action: action)
        }
        let durableItems = journal.durableRecoveryEffectItems(
            operationID: id, actionID: action.command.actionID
        )
        XCTAssertEqual(durableItems.count, 1)
        let firstRecoveryEffects = await executor.recoveryEffectHistory()
        XCTAssertEqual(firstRecoveryEffects.count, 1)

        await executor.setRecoveryModes([.completed])
        let restarted = try ServiceTestHarness(journal: journal, executor: executor)
        try await restarted.service.recover(id, action: action)
        let rolledBack = try await restarted.service.snapshot(id)
        XCTAssertEqual(rolledBack.state, .rolledBack)
        XCTAssertEqual(rolledBack.items.map(\.state), [.rolledBack, .rolledBack, .cancelled])
        XCTAssertFalse(rolledBack.hasPartialCommit)
        XCTAssertTrue(rolledBack.items.allSatisfy { $0.failure == nil })
        XCTAssertEqual(rolledBack.items.compactMap(\.receipt).count, 2)
        XCTAssertNil(rolledBack.terminalFailure)
        XCTAssertEqual(journal.durableCommitEffectCount(operationID: id), 2)
        XCTAssertTrue(journal.recoveryActionCompleted(
            operationID: id, actionID: action.command.actionID
        ))
        let completedEffects = await executor.recoveryEffectHistory()
        XCTAssertEqual(completedEffects.count, 2)

        try await restarted.service.recover(id, action: action)
        let secondRestart = try ServiceTestHarness(journal: journal, executor: executor)
        try await secondRestart.service.recover(id, action: action)
        let effectsAfterSecondRestart = await executor.recoveryEffectHistory()
        XCTAssertEqual(effectsAfterSecondRestart.count, 2)
    }

    func testNotCommittedInspectionDurablyCleansStagingBeforeRollbackCancellation()
        async throws {
        let journal = InMemoryOperationJournal()
        let fileSystem = FakeFileSystemAdapter()
        await fileSystem.setStagingRecoveryModes([.ambiguousCompleted])
        let executor = FakeOperationExecutor()
        await executor.setModeSequence([.committed, .ambiguous], for: .copy)
        await executor.setCommitInspection(.notCommitted, for: .copy)
        let first = try ServiceTestHarness(
            journal: journal, fileSystem: fileSystem, executor: executor
        )
        let id = try await first.service.submit(OperationRequest(
            kind: .copy,
            sources: [fileURL("/source/not-committed-a"),
                      fileURL("/source/not-committed-b")],
            destination: fileURL("/target"), destinationMode: .container
        ))
        let recovery = try await waitForRecoveryAction(id: id, service: first.service) {
            if case .rollbackCommittedDestination = $0 { return true }
            return false
        }
        let action = try XCTUnwrap(recovery.availableActions.first {
            if case .rollbackCommittedDestination = $0 { return true }
            return false
        })
        let ambiguousItem = try XCTUnwrap(recovery.items.last)

        await assertFailure(.recoveryRequired) {
            try await first.service.recover(id, action: action)
        }
        let durableCleanup = try XCTUnwrap(journal.durableRecoveryAttempt(
            operationID: id, actionID: action.command.actionID,
            itemID: ambiguousItem.id
        ))
        XCTAssertNil(durableCleanup.1)
        let cleanupEffectsBeforeRestart = await fileSystem.stagingRecoveryEffectHistory()
        XCTAssertEqual(cleanupEffectsBeforeRestart.count, 1)
        XCTAssertEqual(cleanupEffectsBeforeRestart.first?.effectID, durableCleanup.0)

        await fileSystem.setStagingRecoveryInspection(.completed)
        let restarted = try ServiceTestHarness(
            journal: journal, fileSystem: fileSystem, executor: executor
        )
        try await restarted.service.recover(id, action: action)
        let rolledBack = try await restarted.service.snapshot(id)
        XCTAssertEqual(rolledBack.state, .rolledBack)
        XCTAssertEqual(rolledBack.items.map(\.state), [.rolledBack, .cancelled])
        XCTAssertFalse(rolledBack.hasPartialCommit)

        let cleanupEffectsAfterRestart = await fileSystem.stagingRecoveryEffectHistory()
        let cleanupInspections = await fileSystem.stagingRecoveryInspectionHistory()
        XCTAssertEqual(cleanupEffectsAfterRestart.count, 1)
        XCTAssertEqual(cleanupInspections.count, 1)
        XCTAssertEqual(cleanupInspections.first?.effectID, durableCleanup.0)
        XCTAssertEqual(journal.durableRecoveryAttempt(
            operationID: id, actionID: action.command.actionID,
            itemID: ambiguousItem.id
        )?.1, "completed")
        let rollbackEffects = await executor.recoveryEffectHistory()
        XCTAssertEqual(rollbackEffects.map(\.effect), ["rollbackCommittedDestination"])
    }

    func testFinalizeCommittedItemsExecutesOnceAndClearsTerminalFailure() async throws {
        let journal = InMemoryOperationJournal()
        let executor = FakeOperationExecutor()
        await executor.setModeSequence([.committed, .failed(.noSpace)], for: .copy)
        let harness = try ServiceTestHarness(journal: journal, executor: executor)
        let id = try await harness.service.submit(OperationRequest(
            kind: .copy,
            sources: [fileURL("/source/finalize-a"), fileURL("/source/finalize-b")],
            destination: fileURL("/target"), destinationMode: .container
        ))
        let failed = try await waitForRecoveryAction(id: id, service: harness.service) {
            if case .rollbackCommittedDestination = $0 { return true }
            return false
        }
        let action = try XCTUnwrap(failed.availableActions.first {
            if case .finalizeKnownCommit = $0 { return true }
            return false
        })
        try await harness.service.recover(id, action: action)
        let finalized = try await harness.service.snapshot(id)
        XCTAssertEqual(finalized.state, .completedWithSkips)
        XCTAssertEqual(finalized.items.map(\.state), [.completed, .skipped])
        XCTAssertNil(finalized.terminalFailure)
        XCTAssertEqual(journal.durableCommitEffectCount(operationID: id), 1)
        let effects = await executor.recoveryEffectHistory()
        XCTAssertEqual(effects.map(\.effect), ["finalizeKnownCommit"])

        try await harness.service.recover(id, action: action)
        let restarted = try ServiceTestHarness(journal: journal, executor: executor)
        try await restarted.service.recover(id, action: action)
        let effectsAfterFinalizeRestart = await executor.recoveryEffectHistory()
        XCTAssertEqual(effectsAfterFinalizeRestart.count, 1)
    }

    func testCleanupRecoveryTreatsConfirmedAbsentSourceAsCompletedWithoutDelete() async throws {
        let journal = InMemoryOperationJournal()
        let executor = FakeOperationExecutor(modes: [.move: .committedAwaitingCleanup])
        await executor.setSourceCleanupFailures(1)
        let harness = try ServiceTestHarness(journal: journal, executor: executor)
        let id = try await harness.service.submit(moveRequest("/source/already-absent"))
        let failed = try await waitForState(.cleanupRequired, id: id, service: harness.service)
        let itemID = try XCTUnwrap(failed.items.first?.id)
        let action = try XCTUnwrap(failed.availableActions.first {
            if case .retrySourceCleanup = $0 { return true }
            return false
        })
        await executor.setSourceInspection(.sourceAbsent)
        try await harness.service.recover(id, action: action)
        let completed = try await harness.service.snapshot(id)
        XCTAssertEqual(completed.state, .completed)
        XCTAssertFalse(completed.sourceRetained)
        XCTAssertTrue(completed.items.first?.receipt?.sourceCleanupPending == false)
        let effects = await executor.effectCount(
            operationID: id, itemID: itemID, phase: .sourceCleanup
        )
        XCTAssertEqual(effects, 1)

        let restarted = try ServiceTestHarness(journal: journal, executor: executor)
        try await restarted.service.recover(id, action: action)
        let effectsAfterAbsentRestart = await executor.effectCount(
            operationID: id, itemID: itemID, phase: .sourceCleanup
        )
        XCTAssertEqual(effectsAfterAbsentRestart, 1)
    }

    func testAmbiguousRecoveryEffectIsInspectedAndNeverReplayed() async throws {
        let journal = InMemoryOperationJournal()
        let executor = FakeOperationExecutor(modes: [.copy: .ambiguous])
        await executor.setRecoveryModes([.ambiguousCompleted])
        let harness = try ServiceTestHarness(journal: journal, executor: executor)
        let id = try await harness.service.submit(copyRequest("/source/ambiguous-recovery"))
        let failed = try await waitForState(.recoveryRequired, id: id, service: harness.service)
        let itemID = try XCTUnwrap(failed.items.first?.id)
        let action = try XCTUnwrap(failed.availableActions.first {
            if case .rollbackCommittedDestination = $0 { return true }
            return false
        })

        await assertFailure(.recoveryRequired) {
            try await harness.service.recover(id, action: action)
        }
        let unresolved = try XCTUnwrap(journal.durableRecoveryAttempt(
            operationID: id, actionID: action.command.actionID, itemID: itemID
        ))
        XCTAssertNil(unresolved.1)
        let effectsAfterAmbiguousACK = await executor.recoveryEffectHistory()
        XCTAssertEqual(effectsAfterAmbiguousACK.count, 1)

        try await harness.service.recover(id, action: action)
        let rolledBack = try await harness.service.snapshot(id)
        let effectsAfterInspection = await executor.recoveryEffectHistory()
        XCTAssertEqual(rolledBack.state, .rolledBack)
        XCTAssertEqual(effectsAfterInspection.count, 1)
        await executor.setMode(.committed, for: .copy)
        let resumedWrites = try await harness.service.submit(
            copyRequest("/source/after-recovery-converged")
        )
        _ = try await waitForState(.completed, id: resumedWrites, service: harness.service)

        let restarted = try ServiceTestHarness(journal: journal, executor: executor)
        try await restarted.service.recover(id, action: action)
        let effectsAfterRestart = await executor.recoveryEffectHistory()
        XCTAssertEqual(effectsAfterRestart.count, 1)
    }

    func testRecoveryResultCheckpointFailureInspectsWithoutSecondEffect() async throws {
        let journal = InMemoryOperationJournal()
        let executor = FakeOperationExecutor(modes: [.copy: .ambiguous])
        let postEffect = ContinuationGate()
        await executor.setRecoveryPostEffectGate(postEffect, afterEffect: 1)
        let harness = try ServiceTestHarness(journal: journal, executor: executor)
        let id = try await harness.service.submit(copyRequest("/source/result-checkpoint"))
        let failed = try await waitForState(.recoveryRequired, id: id, service: harness.service)
        let itemID = try XCTUnwrap(failed.items.first?.id)
        let action = try XCTUnwrap(failed.availableActions.first {
            if case .rollbackCommittedDestination = $0 { return true }
            return false
        })

        let recovering = Task { try await harness.service.recover(id, action: action) }
        try await postEffect.waitUntilEntered()
        journal.injectNextWriteFailure()
        await postEffect.release()
        await assertFailure(.journalFailure) { try await recovering.value }
        let effectsAfterCheckpointFailure = await executor.recoveryEffectHistory()
        XCTAssertEqual(effectsAfterCheckpointFailure.count, 1)
        let unresolved = try XCTUnwrap(journal.durableRecoveryAttempt(
            operationID: id, actionID: action.command.actionID, itemID: itemID
        ))
        XCTAssertNil(unresolved.1)

        // A journal write failure is fatal and sticky for this service
        // instance. Only a fresh service may use the durable intent to inspect.
        await assertFailure(.serviceSafeMode) {
            try await harness.service.recover(id, action: action)
        }
        let effectsAfterSameProcessRejection = await executor.recoveryEffectHistory()
        XCTAssertEqual(effectsAfterSameProcessRejection.count, 1)
        let restarted = try ServiceTestHarness(journal: journal, executor: executor)
        try await restarted.service.recover(id, action: action)
        let effectsAfterResultRestart = await executor.recoveryEffectHistory()
        XCTAssertEqual(effectsAfterResultRestart.count, 1)
    }

    func testTwoItemRecoveryPersistsEachIntentAndInspectsOnlyAmbiguousSecondItem()
        async throws {
        let journal = InMemoryOperationJournal()
        let executor = FakeOperationExecutor()
        await executor.setModeSequence(
            [.committed, .committed, .failed(.noSpace)], for: .copy
        )
        let secondEffect = ContinuationGate()
        await executor.setRecoveryPostEffectGate(secondEffect, afterEffect: 2)
        let harness = try ServiceTestHarness(journal: journal, executor: executor)
        let id = try await harness.service.submit(OperationRequest(
            kind: .copy,
            sources: [fileURL("/source/two-item-a"), fileURL("/source/two-item-b"),
                      fileURL("/source/two-item-fail")],
            destination: fileURL("/target"), destinationMode: .container
        ))
        let failed = try await waitForRecoveryAction(id: id, service: harness.service) {
            if case .rollbackCommittedDestination = $0 { return true }
            return false
        }
        let committedItems = failed.items.filter { $0.receipt != nil }.map(\.id)
        XCTAssertEqual(committedItems.count, 2)
        let action = try XCTUnwrap(failed.availableActions.first {
            if case .rollbackCommittedDestination = $0 { return true }
            return false
        })

        let recovering = Task { try await harness.service.recover(id, action: action) }
        try await secondEffect.waitUntilEntered()
        journal.injectNextWriteFailure()
        await secondEffect.release()
        await assertFailure(.journalFailure) { try await recovering.value }
        let effectsAtCrash = await executor.recoveryEffectHistory()
        XCTAssertEqual(effectsAtCrash.count, 2)
        XCTAssertEqual(journal.durableRecoveryEffectItems(
            operationID: id, actionID: action.command.actionID
        ), Set([committedItems[0]]))
        let ambiguousSecond = try XCTUnwrap(journal.durableRecoveryAttempt(
            operationID: id, actionID: action.command.actionID,
            itemID: committedItems[1]
        ))
        XCTAssertNil(ambiguousSecond.1)

        let restarted = try ServiceTestHarness(journal: journal, executor: executor)
        try await restarted.service.recover(id, action: action)
        let rolledBack = try await restarted.service.snapshot(id)
        let effectsAfterRestart = await executor.recoveryEffectHistory()
        XCTAssertEqual(rolledBack.state, .rolledBack)
        XCTAssertEqual(effectsAfterRestart.count, 2)
        let inspected = await executor.recoveryInspectionHistory()
        XCTAssertEqual(inspected.map(\.itemID), [committedItems[1]])
    }

    func testIntentBeforeEffectCrashReusesStableEffectIDAfterNotPerformedInspection()
        async throws {
        let journal = InMemoryOperationJournal()
        let executor = FakeOperationExecutor(modes: [.copy: .ambiguous])
        let intentGate = ContinuationGate()
        let harness = try ServiceTestHarness(journal: journal, executor: executor)
        await harness.failpoints.setGate(intentGate, for: .recoveryEffectIntentPersisted)
        let id = try await harness.service.submit(copyRequest("/source/intent-before-effect"))
        let failed = try await waitForState(.recoveryRequired, id: id, service: harness.service)
        let itemID = try XCTUnwrap(failed.items.first?.id)
        let action = try XCTUnwrap(failed.availableActions.first {
            if case .rollbackCommittedDestination = $0 { return true }
            return false
        })

        let recovering = Task { try await harness.service.recover(id, action: action) }
        try await intentGate.waitUntilEntered()
        let durableIntent = try XCTUnwrap(journal.durableRecoveryAttempt(
            operationID: id, actionID: action.command.actionID, itemID: itemID
        ))
        XCTAssertNil(durableIntent.1)
        recovering.cancel()
        await intentGate.release()
        do {
            try await recovering.value
            XCTFail("expected cancellation before recovery effect")
        } catch is CancellationError {
            // A process exit at this point leaves only the durable intent.
        }
        let effectsBeforeRestart = await executor.recoveryEffectHistory()
        XCTAssertTrue(effectsBeforeRestart.isEmpty)

        let restarted = try ServiceTestHarness(journal: journal, executor: executor)
        try await restarted.service.recover(id, action: action)
        let effects = await executor.recoveryEffectHistory()
        let inspections = await executor.recoveryInspectionHistory()
        XCTAssertEqual(effects.count, 1)
        XCTAssertEqual(effects.first?.effectID, durableIntent.0)
        XCTAssertEqual(inspections.count, 1)
        XCTAssertEqual(inspections.first?.operationID, id)
        XCTAssertEqual(inspections.first?.itemID, itemID)
        XCTAssertEqual(inspections.first?.effect, "rollbackCommittedDestination")
        XCTAssertEqual(inspections.first?.effectID, durableIntent.0)
        let completed = try XCTUnwrap(journal.durableRecoveryAttempt(
            operationID: id, actionID: action.command.actionID, itemID: itemID
        ))
        XCTAssertEqual(completed.0, durableIntent.0)
        XCTAssertEqual(completed.1, "completed")
    }

    func testFinalRecoveryCommandCheckpointCanBeCompletedAfterRestartWithoutEffectReplay()
        async throws {
        let journal = InMemoryOperationJournal()
        let executor = FakeOperationExecutor(modes: [.copy: .ambiguous])
        let finalGate = ContinuationGate()
        let harness = try ServiceTestHarness(journal: journal, executor: executor)
        await harness.failpoints.setGate(finalGate, for: .recoveryProjectionConverged)
        let id = try await harness.service.submit(copyRequest("/source/final-marker"))
        let failed = try await waitForState(.recoveryRequired, id: id, service: harness.service)
        let action = try XCTUnwrap(failed.availableActions.first {
            if case .rollbackCommittedDestination = $0 { return true }
            return false
        })

        let recovering = Task { try await harness.service.recover(id, action: action) }
        try await finalGate.waitUntilEntered()
        journal.injectNextWriteFailure()
        await finalGate.release()
        await assertFailure(.journalFailure) { try await recovering.value }
        let convergedBeforeMarker = try await harness.service.snapshot(id)
        XCTAssertEqual(convergedBeforeMarker.state, .rolledBack)
        XCTAssertFalse(journal.recoveryActionCompleted(
            operationID: id, actionID: action.command.actionID
        ))
        let effectsBeforeMarkerRestart = await executor.recoveryEffectHistory()
        XCTAssertEqual(effectsBeforeMarkerRestart.count, 1)

        let restarted = try ServiceTestHarness(journal: journal, executor: executor)
        try await restarted.service.recover(id, action: action)
        XCTAssertTrue(journal.recoveryActionCompleted(
            operationID: id, actionID: action.command.actionID
        ))
        let effectsAfterMarkerRestart = await executor.recoveryEffectHistory()
        XCTAssertEqual(effectsAfterMarkerRestart.count, 1)
    }

    func testRecoveryCleanupReceiptFailureRestartsWithoutSecondCleanup() async throws {
        let journal = InMemoryOperationJournal()
        let executor = FakeOperationExecutor(modes: [.move: .committedAwaitingCleanup])
        await executor.setSourceCleanupFailures(1)
        let resultGate = ContinuationGate()
        let harness = try ServiceTestHarness(journal: journal, executor: executor)
        await harness.failpoints.setGate(resultGate, for: .recoveryEffectResultPersisted)
        let id = try await harness.service.submit(moveRequest("/source/cleanup-receipt"))
        let failed = try await waitForState(.cleanupRequired, id: id, service: harness.service)
        let itemID = try XCTUnwrap(failed.items.first?.id)
        let action = try XCTUnwrap(failed.availableActions.first {
            if case .retrySourceCleanup = $0 { return true }
            return false
        })

        let recovering = Task { try await harness.service.recover(id, action: action) }
        try await resultGate.waitUntilEntered()
        journal.injectNextWriteFailure()
        await resultGate.release()
        await assertFailure(.journalFailure) { try await recovering.value }
        let cleaning = try await harness.service.snapshot(id)
        XCTAssertEqual(cleaning.state, .cleaningSource)
        let cleanupEffects = await executor.recoveryEffectHistory().filter {
            $0.operationID == id && $0.itemID == itemID && $0.effect == "cleanupSource"
        }
        XCTAssertEqual(cleanupEffects.count, 1)
        let durableResult = try XCTUnwrap(journal.durableRecoveryAttempt(
            operationID: id, actionID: action.command.actionID, itemID: itemID
        ))
        XCTAssertEqual(durableResult.1, "completed")

        let restarted = try ServiceTestHarness(journal: journal, executor: executor)
        try await restarted.service.recover(id, action: action)
        let completed = try await restarted.service.snapshot(id)
        XCTAssertEqual(completed.state, .completed)
        let effectsAfterRestart = await executor.recoveryEffectHistory().filter {
            $0.operationID == id && $0.itemID == itemID && $0.effect == "cleanupSource"
        }
        XCTAssertEqual(effectsAfterRestart.count, 1)
    }

    func testUnknownRecoveryInspectionPreservesIntentAndTokenWithoutNewMutation()
        async throws {
        let journal = InMemoryOperationJournal()
        let executor = FakeOperationExecutor(modes: [.copy: .ambiguous])
        await executor.setRecoveryModes([.recoveryRequired])
        let harness = try ServiceTestHarness(journal: journal, executor: executor)
        let id = try await harness.service.submit(copyRequest("/source/unknown-recovery"))
        let failed = try await waitForState(.recoveryRequired, id: id, service: harness.service)
        let itemID = try XCTUnwrap(failed.items.first?.id)
        let action = try XCTUnwrap(failed.availableActions.first {
            if case .rollbackCommittedDestination = $0 { return true }
            return false
        })

        await assertFailure(.recoveryRequired) {
            try await harness.service.recover(id, action: action)
        }
        await assertFailure(.serviceSafeMode) {
            _ = try await harness.service.submit(copyRequest("/source/blocked-unknown-same"))
        }
        let intent = try XCTUnwrap(journal.durableRecoveryAttempt(
            operationID: id, actionID: action.command.actionID, itemID: itemID
        ))
        XCTAssertNil(intent.1)
        await assertFailure(.recoveryRequired) {
            try await harness.service.recover(id, action: action)
        }
        let effectsAfterUnknownInspection = await executor.recoveryEffectHistory()
        XCTAssertEqual(effectsAfterUnknownInspection.count, 1)

        let restarted = try ServiceTestHarness(journal: journal, executor: executor)
        await assertFailure(.serviceSafeMode) {
            _ = try await restarted.service.submit(copyRequest("/source/blocked-unknown-restart"))
        }
        await assertFailure(.recoveryRequired) {
            try await restarted.service.recover(id, action: action)
        }
        let afterRestart = try await restarted.service.snapshot(id)
        XCTAssertTrue(afterRestart.availableActions.contains(action))
        let effectsAfterUnknownRestart = await executor.recoveryEffectHistory()
        XCTAssertEqual(effectsAfterUnknownRestart.count, 1)
        let durableIntent = try XCTUnwrap(journal.durableRecoveryAttempt(
            operationID: id, actionID: action.command.actionID, itemID: itemID
        ))
        XCTAssertEqual(durableIntent.0, intent.0)
        XCTAssertNil(durableIntent.1)
    }

    func testConcurrentSameRecoveryActionHasOneLeaseAndOneEffect() async throws {
        let journal = InMemoryOperationJournal()
        let executor = FakeOperationExecutor(modes: [.copy: .ambiguous])
        let intentGate = ContinuationGate()
        let harness = try ServiceTestHarness(journal: journal, executor: executor)
        await harness.failpoints.setGate(intentGate, for: .recoveryEffectIntentPersisted)
        let id = try await harness.service.submit(copyRequest("/source/concurrent-recovery"))
        let failed = try await waitForState(.recoveryRequired, id: id, service: harness.service)
        let action = try XCTUnwrap(failed.availableActions.first {
            if case .rollbackCommittedDestination = $0 { return true }
            return false
        })

        let first = Task { try await harness.service.recover(id, action: action) }
        try await intentGate.waitUntilEntered()
        await assertFailure(.controlRejected) {
            try await harness.service.recover(id, action: action)
        }
        await intentGate.release()
        try await first.value
        let concurrentEffects = await executor.recoveryEffectHistory()
        XCTAssertEqual(concurrentEffects.count, 1)
    }

    func testDurableRecoveryChoiceRejectsSiblingInProcessAndAfterRestart() async throws {
        let journal = InMemoryOperationJournal()
        let executor = FakeOperationExecutor()
        await executor.setModeSequence([.committed, .failed(.noSpace)], for: .copy)
        await executor.setRecoveryModes([.recoveryRequired])
        let harness = try ServiceTestHarness(journal: journal, executor: executor)
        let id = try await harness.service.submit(OperationRequest(
            kind: .copy,
            sources: [fileURL("/source/sibling-a"), fileURL("/source/sibling-b")],
            destination: fileURL("/target"), destinationMode: .container
        ))
        let failed = try await waitForRecoveryAction(id: id, service: harness.service) {
            if case .rollbackCommittedDestination = $0 { return true }
            return false
        }
        let rollback = try XCTUnwrap(failed.availableActions.first {
            if case .rollbackCommittedDestination = $0 { return true }
            return false
        })
        let finalize = try XCTUnwrap(failed.availableActions.first {
            if case .finalizeKnownCommit = $0 { return true }
            return false
        })

        await assertFailure(.recoveryRequired) {
            try await harness.service.recover(id, action: rollback)
        }
        let selected = try await harness.service.snapshot(id)
        XCTAssertEqual(selected.availableActions.map(\.command.actionID),
                       [rollback.command.actionID])
        await assertFailure(.controlRejected) {
            try await harness.service.recover(id, action: finalize)
        }
        let restarted = try ServiceTestHarness(journal: journal, executor: executor)
        await assertFailure(.controlRejected) {
            try await restarted.service.recover(id, action: finalize)
        }
        let siblingEffects = await executor.recoveryEffectHistory()
        XCTAssertEqual(siblingEffects.count, 1)
    }

    func testFatalStartupDominatesRecoverableStateInBothLoadOrders() async throws {
        for fatalFirst in [true, false] {
            let journal = InMemoryOperationJournal()
            let recoveryID = OperationID(rawValue: UUID())
            let recoveryItemID = OperationItemID(rawValue: UUID())
            let actionID = UUID()
            let action = RecoveryAction.rollbackCommittedDestination(RecoveryCommand(
                actionID: actionID, expectedSequence: 1
            ))
            let fixture = journal.seedFatalAndRecoveryStartup(
                fatalFirst: fatalFirst, recoveryOperationID: recoveryID,
                recoveryItemID: recoveryItemID, actionID: actionID, action: action
            )
            let executor = FakeOperationExecutor()
            let fileSystem = FakeFileSystemAdapter()
            let harness = try ServiceTestHarness(
                journal: journal, fileSystem: fileSystem, executor: executor
            )

            await assertFailure(.serviceSafeMode) {
                try await harness.service.recover(
                    fixture.recoveryOperationID, action: fixture.action
                )
            }
            await assertFailure(.serviceSafeMode) {
                _ = try await harness.service.submit(copyRequest("/source/fatal-blocked"))
            }
            let executorInspections = await executor.recoveryInspectionHistory()
            let executorEffects = await executor.recoveryEffectHistory()
            let stagingInspections = await fileSystem.stagingRecoveryInspectionHistory()
            let stagingEffects = await fileSystem.stagingRecoveryEffectHistory()
            XCTAssertTrue(executorInspections.isEmpty)
            XCTAssertTrue(executorEffects.isEmpty)
            XCTAssertTrue(stagingInspections.isEmpty)
            XCTAssertTrue(stagingEffects.isEmpty)
        }
    }

    func testRecoveryModeGuardsAllControlsWithoutMutatingSiblingOperations() async throws {
        let journal = InMemoryOperationJournal()
        let executor = FakeOperationExecutor()
        await executor.setModeSequence([.failed(.noSpace), .ambiguous], for: .copy)
        let harness = try ServiceTestHarness(journal: journal, executor: executor)
        let failedID = try await harness.service.submit(copyRequest("/source/control-failed"))
        // A failed pre-commit attempt first exposes discardKnownStaging, then
        // durably converges that cleanup into a sequence-bound resume action.
        // Capture the settled projection so this test isolates the guarded
        // controls instead of racing the legitimate convergence event.
        let failedBefore = try await waitForRecoveryAction(
            id: failedID, service: harness.service
        ) {
            if case .resumeFromVerifiedStage = $0 { return true }
            return false
        }
        let recoveryID = try await harness.service.submit(copyRequest("/source/control-recovery"))
        let recoveryBefore = try await waitForState(
            .recoveryRequired, id: recoveryID, service: harness.service
        )
        let recoveryAction = try XCTUnwrap(recoveryBefore.availableActions.first {
            if case .rollbackCommittedDestination = $0 { return true }
            return false
        })
        let failedEvents = journal.eventCount(operationID: failedID)
        let recoveryEvents = journal.eventCount(operationID: recoveryID)
        let startsBefore = await executor.startedOperations()

        await assertFailure(.serviceSafeMode) {
            try await harness.service.resolve(
                DecisionToken(rawValue: UUID()), with: .skip(scope: .item)
            )
        }
        await assertFailure(.serviceSafeMode) {
            try await harness.service.retry(failedID)
        }
        await harness.service.pause(failedID)
        await harness.service.resume(failedID)
        await harness.service.cancel(failedID)
        await harness.service.pause(recoveryID)
        await harness.service.resume(recoveryID)
        await harness.service.cancel(recoveryID)

        let failedAfter = try await harness.service.snapshot(failedID)
        let recoveryAfter = try await harness.service.snapshot(recoveryID)
        assertDurableSnapshotUnchanged(failedBefore, failedAfter)
        assertDurableSnapshotUnchanged(recoveryBefore, recoveryAfter)
        XCTAssertEqual(journal.eventCount(operationID: failedID), failedEvents)
        XCTAssertEqual(journal.eventCount(operationID: recoveryID), recoveryEvents)
        let startsAfter = await executor.startedOperations()
        XCTAssertEqual(startsAfter, startsBefore)

        try await harness.service.recover(recoveryID, action: recoveryAction)
        let recovered = try await harness.service.snapshot(recoveryID)
        XCTAssertEqual(recovered.state, .rolledBack)
    }

    func testFatalModeControlsProduceNoJournalMutationOrFilesystemEffect() async throws {
        let journal = InMemoryOperationJournal()
        let recoveryID = OperationID(rawValue: UUID())
        let itemID = OperationItemID(rawValue: UUID())
        let actionID = UUID()
        let action = RecoveryAction.rollbackCommittedDestination(RecoveryCommand(
            actionID: actionID, expectedSequence: 1
        ))
        let fixture = journal.seedFatalAndRecoveryStartup(
            fatalFirst: false, recoveryOperationID: recoveryID,
            recoveryItemID: itemID, actionID: actionID, action: action
        )
        let executor = FakeOperationExecutor()
        let fileSystem = FakeFileSystemAdapter()
        let harness = try ServiceTestHarness(
            journal: journal, fileSystem: fileSystem, executor: executor
        )
        let before = try await harness.service.snapshot(fixture.recoveryOperationID)
        let beforeEvents = journal.eventCount(operationID: fixture.recoveryOperationID)

        await assertFailure(.serviceSafeMode) {
            try await harness.service.resolve(
                DecisionToken(rawValue: UUID()), with: .skip(scope: .item)
            )
        }
        await assertFailure(.serviceSafeMode) {
            try await harness.service.retry(fixture.recoveryOperationID)
        }
        await harness.service.pause(fixture.recoveryOperationID)
        await harness.service.resume(fixture.recoveryOperationID)
        await harness.service.cancel(fixture.recoveryOperationID)
        await assertFailure(.serviceSafeMode) {
            try await harness.service.recover(
                fixture.recoveryOperationID, action: fixture.action
            )
        }

        let after = try await harness.service.snapshot(fixture.recoveryOperationID)
        assertDurableSnapshotUnchanged(before, after)
        XCTAssertEqual(
            journal.eventCount(operationID: fixture.recoveryOperationID), beforeEvents
        )
        let executorEffects = await executor.recoveryEffectHistory()
        let executorInspections = await executor.recoveryInspectionHistory()
        let stagingEffects = await fileSystem.stagingRecoveryEffectHistory()
        let stagingInspections = await fileSystem.stagingRecoveryInspectionHistory()
        XCTAssertTrue(executorEffects.isEmpty)
        XCTAssertTrue(executorInspections.isEmpty)
        XCTAssertTrue(stagingEffects.isEmpty)
        XCTAssertTrue(stagingInspections.isEmpty)
    }

    func testProgressJournalFailureRevokesPhaseBeforeAnyFilesystemEffect() async throws {
        let journal = InMemoryOperationJournal()
        let executor = FakeOperationExecutor()
        let progressGate = ContinuationGate()
        await executor.setProgressSteps([1, 2])
        await executor.setProgressGate(progressGate, afterStep: 0)
        let harness = try ServiceTestHarness(journal: journal, executor: executor)
        let id = try await harness.service.submit(copyRequest("/source/progress-fatal"))
        try await progressGate.waitUntilEntered()

        journal.injectNextWriteFailure()
        await progressGate.release()
        try await waitForDiagnostic(harness.diagnostics)
        try await withDeadline("revoked phase quiescence") {
            while await executor.activeExecutionCount() != 0 {
                try Task.checkCancellation()
                await Task.yield()
            }
        }

        let stranded = try await harness.service.snapshot(id)
        let effects = await executor.actualEffectHistory()
        XCTAssertEqual(stranded.state, .staging)
        XCTAssertTrue(effects.isEmpty)
        await assertFailure(.serviceSafeMode) {
            _ = try await harness.service.submit(copyRequest("/source/progress-fatal-blocked"))
        }
    }

    func testRestartTreatsInterruptedPrecommitAsRecoveryRequiredWithoutAction() async throws {
        let journal = InMemoryOperationJournal()
        let stagingGate = ContinuationGate()
        let executor = FakeOperationExecutor(startGate: stagingGate)
        let first = try ServiceTestHarness(journal: journal, executor: executor)
        let id = try await first.service.submit(copyRequest("/source/interrupted-precommit"))
        try await stagingGate.waitUntilEntered()
        let durable = try XCTUnwrap(journal.storedOperation(id))
        XCTAssertEqual(durable.state, .staging)
        XCTAssertTrue(durable.availableActions.isEmpty)

        let restarted = try ServiceTestHarness(journal: journal)
        await assertFailure(.serviceSafeMode) {
            _ = try await restarted.service.submit(copyRequest("/source/interrupted-blocked"))
        }

        let cancelling = Task { await first.service.cancel(id) }
        await stagingGate.release()
        await cancelling.value
    }

    func testDiscardProjectionRepairsAfterItemTerminalCheckpointFailure() async throws {
        let journal = InMemoryOperationJournal()
        let fileSystem = FakeFileSystemAdapter()
        let stagingGate = ContinuationGate()
        let projectionGate = ContinuationGate()
        let executor = FakeOperationExecutor(startGate: stagingGate)
        let first = try ServiceTestHarness(
            journal: journal, fileSystem: fileSystem, executor: executor
        )
        await first.failpoints.setGate(
            projectionGate, for: .recoveryItemProjectionConverged
        )
        let id = try await first.service.submit(copyRequest("/source/discard-projection"))
        try await stagingGate.waitUntilEntered()
        let cancelling = Task { await first.service.cancel(id) }
        try await projectionGate.waitUntilEntered()
        let stranded = try await first.service.snapshot(id)
        let itemID = try XCTUnwrap(stranded.items.first?.id)
        let action = try XCTUnwrap(stranded.availableActions.first)
        XCTAssertEqual(stranded.state, .cleanupRequired)
        XCTAssertEqual(stranded.items.first?.state, .cancelled)
        XCTAssertEqual(journal.durableRecoveryAttempt(
            operationID: id, actionID: action.command.actionID, itemID: itemID
        )?.1, "completed")

        journal.injectNextWriteFailure()
        await projectionGate.release()
        await stagingGate.release()
        await cancelling.value
        try await waitForDiagnostic(first.diagnostics)
        let effectsBeforeRestart = await fileSystem.stagingRecoveryEffectHistory().count
        XCTAssertEqual(effectsBeforeRestart, 1)

        let restarted = try ServiceTestHarness(
            journal: journal, fileSystem: fileSystem, executor: executor
        )
        try await restarted.service.recover(id, action: action)
        let repaired = try await restarted.service.snapshot(id)
        let effectsAfterRestart = await fileSystem.stagingRecoveryEffectHistory().count
        XCTAssertEqual(repaired.state, .cancelled)
        XCTAssertEqual(effectsAfterRestart, effectsBeforeRestart)
    }

    func testRollbackProjectionRepairsAfterItemsTerminalCheckpointFailure() async throws {
        let journal = InMemoryOperationJournal()
        let executor = FakeOperationExecutor()
        await executor.setModeSequence([.committed, .failed(.noSpace)], for: .copy)
        let first = try ServiceTestHarness(journal: journal, executor: executor)
        let id = try await first.service.submit(OperationRequest(
            kind: .copy,
            sources: [fileURL("/source/rollback-window-a"),
                      fileURL("/source/rollback-window-b")],
            destination: fileURL("/target"), destinationMode: .container
        ))
        _ = try await waitForState(.failedRecoverable, id: id, service: first.service)
        let failed = try await waitForRecoveryAction(id: id, service: first.service) {
            if case .rollbackCommittedDestination = $0 { return true }
            return false
        }
        let action = try XCTUnwrap(failed.availableActions.first {
            if case .rollbackCommittedDestination = $0 { return true }
            return false
        })
        let projectionGate = ContinuationGate()
        await first.failpoints.setGate(
            projectionGate, for: .recoveryItemProjectionConverged
        )
        let recovering = Task { try await first.service.recover(id, action: action) }
        try await projectionGate.waitUntilEntered()
        let stranded = try await first.service.snapshot(id)
        XCTAssertEqual(stranded.state, .failedRecoverable)
        XCTAssertEqual(stranded.items.map(\.state), [.rolledBack, .cancelled])
        XCTAssertEqual(journal.durableCommitEffectCount(operationID: id), 1)

        journal.injectNextWriteFailure()
        await projectionGate.release()
        await assertFailure(.journalFailure) { try await recovering.value }
        let effectsBeforeRestart = await executor.recoveryEffectHistory().count
        XCTAssertEqual(effectsBeforeRestart, 1)

        let restarted = try ServiceTestHarness(journal: journal, executor: executor)
        try await restarted.service.recover(id, action: action)
        let repaired = try await restarted.service.snapshot(id)
        let effectsAfterRestart = await executor.recoveryEffectHistory().count
        XCTAssertEqual(repaired.state, .rolledBack)
        XCTAssertEqual(effectsAfterRestart, effectsBeforeRestart)
    }

    func testFinalizeProjectionRepairsAfterItemsTerminalCheckpointFailure() async throws {
        let journal = InMemoryOperationJournal()
        let executor = FakeOperationExecutor()
        await executor.setModeSequence([.committed, .failed(.noSpace)], for: .copy)
        let first = try ServiceTestHarness(journal: journal, executor: executor)
        let id = try await first.service.submit(OperationRequest(
            kind: .copy,
            sources: [fileURL("/source/finalize-window-a"),
                      fileURL("/source/finalize-window-b")],
            destination: fileURL("/target"), destinationMode: .container
        ))
        _ = try await waitForState(.failedRecoverable, id: id, service: first.service)
        let failed = try await waitForRecoveryAction(id: id, service: first.service) {
            if case .finalizeKnownCommit = $0 { return true }
            return false
        }
        let action = try XCTUnwrap(failed.availableActions.first {
            if case .finalizeKnownCommit = $0 { return true }
            return false
        })
        let projectionGate = ContinuationGate()
        await first.failpoints.setGate(
            projectionGate, for: .recoveryItemProjectionConverged
        )
        let recovering = Task { try await first.service.recover(id, action: action) }
        try await projectionGate.waitUntilEntered()
        let stranded = try await first.service.snapshot(id)
        XCTAssertEqual(stranded.state, .preflight)
        XCTAssertEqual(stranded.items.map(\.state), [.completed, .skipped])

        journal.injectNextWriteFailure()
        await projectionGate.release()
        await assertFailure(.journalFailure) { try await recovering.value }
        let effectsBeforeRestart = await executor.recoveryEffectHistory().count
        XCTAssertEqual(effectsBeforeRestart, 1)

        let restarted = try ServiceTestHarness(journal: journal, executor: executor)
        try await restarted.service.recover(id, action: action)
        let repaired = try await restarted.service.snapshot(id)
        let effectsAfterRestart = await executor.recoveryEffectHistory().count
        XCTAssertEqual(repaired.state, .completedWithSkips)
        XCTAssertEqual(effectsAfterRestart, effectsBeforeRestart)

        let interruptedPairs: [(OperationState, OperationItemState)] = [
            (.preflight, .staging),
            (.staging, .staging), (.staging, .metadata),
            (.metadata, .metadata), (.metadata, .verifying),
            (.verifying, .verifying), (.verifying, .committing),
            (.committing, .committing), (.committing, .committed),
            (.committing, .completed)
        ]
        for (pairIndex, pair) in interruptedPairs.enumerated() {
            let replayJournal = InMemoryOperationJournal()
            let replayExecutor = FakeOperationExecutor(modes: [.copy: .ambiguous])
            let original = try ServiceTestHarness(
                journal: replayJournal, executor: replayExecutor
            )
            let replayID = try await original.service.submit(copyRequest(
                "/source/finalize-projection-\(pairIndex)"
            ))
            let recovery = try await waitForRecoveryAction(
                id: replayID, service: original.service
            ) {
                if case .finalizeKnownCommit = $0 { return true }
                return false
            }
            let finalize = try XCTUnwrap(recovery.availableActions.first {
                if case .finalizeKnownCommit = $0 { return true }
                return false
            })
            try replayJournal.simulateFinalizeRecoveryProjection(
                operationID: replayID,
                action: finalize,
                actionID: finalize.command.actionID,
                operationState: pair.0,
                itemState: pair.1
            )

            let resumed = try ServiceTestHarness(
                journal: replayJournal, executor: replayExecutor
            )
            try await resumed.service.recover(replayID, action: finalize)
            let completed = try await resumed.service.snapshot(replayID)
            XCTAssertEqual(
                completed.state, .completed,
                "finalize checkpoint pair \(pair.0)/\(pair.1)"
            )
        }
    }

    func testCleanupProjectionRepairsAfterItemTerminalCheckpointFailure() async throws {
        let journal = InMemoryOperationJournal()
        let executor = FakeOperationExecutor(modes: [.move: .committedAwaitingCleanup])
        await executor.setSourceCleanupFailures(1)
        let first = try ServiceTestHarness(journal: journal, executor: executor)
        let id = try await first.service.submit(moveRequest("/source/cleanup-window"))
        let failed = try await waitForState(.cleanupRequired, id: id, service: first.service)
        let action = try XCTUnwrap(failed.availableActions.first {
            if case .retrySourceCleanup = $0 { return true }
            return false
        })
        let projectionGate = ContinuationGate()
        await first.failpoints.setGate(
            projectionGate, for: .recoveryItemProjectionConverged
        )
        let recovering = Task { try await first.service.recover(id, action: action) }
        try await projectionGate.waitUntilEntered()
        let stranded = try await first.service.snapshot(id)
        XCTAssertEqual(stranded.state, .cleanupRequired)
        XCTAssertEqual(stranded.items.first?.state, .completed)
        XCTAssertEqual(stranded.items.first?.receipt?.sourceCleanupPending, false)

        journal.injectNextWriteFailure()
        await projectionGate.release()
        await assertFailure(.journalFailure) { try await recovering.value }
        let effectsBeforeRestart = await executor.recoveryEffectHistory().count
        XCTAssertEqual(effectsBeforeRestart, 1)

        let restarted = try ServiceTestHarness(journal: journal, executor: executor)
        try await restarted.service.recover(id, action: action)
        let repaired = try await restarted.service.snapshot(id)
        let effectsAfterRestart = await executor.recoveryEffectHistory().count
        XCTAssertEqual(repaired.state, .completed)
        XCTAssertEqual(effectsAfterRestart, effectsBeforeRestart)
    }

    func testRetainProjectionRepairsAfterItemTerminalCheckpointFailure() async throws {
        let journal = InMemoryOperationJournal()
        let executor = FakeOperationExecutor(modes: [.move: .committedAwaitingCleanup])
        await executor.setSourceCleanupFailures(1)
        let first = try ServiceTestHarness(journal: journal, executor: executor)
        let id = try await first.service.submit(moveRequest("/source/retain-window"))
        let failed = try await waitForState(.cleanupRequired, id: id, service: first.service)
        let action = try XCTUnwrap(failed.availableActions.first {
            if case .retainSource = $0 { return true }
            return false
        })
        let projectionGate = ContinuationGate()
        await first.failpoints.setGate(
            projectionGate, for: .recoveryItemProjectionConverged
        )
        let recovering = Task { try await first.service.recover(id, action: action) }
        try await projectionGate.waitUntilEntered()
        let stranded = try await first.service.snapshot(id)
        XCTAssertEqual(stranded.state, .committedAwaitingCleanup)
        XCTAssertEqual(stranded.items.first?.state, .completed)
        XCTAssertEqual(stranded.items.first?.receipt?.sourceCleanupPending, false)
        XCTAssertTrue(stranded.sourceRetained)

        journal.injectNextWriteFailure()
        await projectionGate.release()
        await assertFailure(.journalFailure) { try await recovering.value }
        let cleanupEffectsBeforeRestart = await executor.actualEffectHistory().filter {
            $0.operationID == id && $0.phase == .sourceCleanup
        }.count
        XCTAssertEqual(cleanupEffectsBeforeRestart, 1)

        let restarted = try ServiceTestHarness(journal: journal, executor: executor)
        try await restarted.service.recover(id, action: action)
        let repaired = try await restarted.service.snapshot(id)
        let cleanupEffectsAfterRestart = await executor.actualEffectHistory().filter {
            $0.operationID == id && $0.phase == .sourceCleanup
        }.count
        XCTAssertEqual(repaired.state, .completedWithSourceRetained)
        XCTAssertTrue(repaired.sourceRetained)
        XCTAssertEqual(cleanupEffectsAfterRestart, cleanupEffectsBeforeRestart)
    }

    func testInitialStagingCancelIntentBeforeEffectRestartsWithSameEffectIDOnce()
        async throws {
        let journal = InMemoryOperationJournal()
        let fileSystem = FakeFileSystemAdapter()
        let executionGate = ContinuationGate()
        let intentGate = ContinuationGate()
        let executor = FakeOperationExecutor(startGate: executionGate)
        let harness = try ServiceTestHarness(
            journal: journal, fileSystem: fileSystem, executor: executor
        )
        await harness.failpoints.setGate(intentGate, for: .recoveryEffectIntentPersisted)
        let id = try await harness.service.submit(copyRequest("/source/initial-intent"))
        try await executionGate.waitUntilEntered()
        let cancelling = Task { await harness.service.cancel(id) }
        try await intentGate.waitUntilEntered()
        let interrupted = try await harness.service.snapshot(id)
        let itemID = try XCTUnwrap(interrupted.items.first?.id)
        let action = try XCTUnwrap(interrupted.availableActions.first {
            if case .discardKnownStaging = $0 { return true }
            return false
        })
        let durableIntent = try XCTUnwrap(journal.durableRecoveryAttempt(
            operationID: id, actionID: action.command.actionID, itemID: itemID
        ))
        XCTAssertNil(durableIntent.1)
        let effectsBeforeRestart = await fileSystem.stagingRecoveryEffectHistory()
        XCTAssertTrue(effectsBeforeRestart.isEmpty)

        cancelling.cancel()
        await intentGate.release()
        await executionGate.release()
        await cancelling.value

        let restarted = try ServiceTestHarness(
            journal: journal, fileSystem: fileSystem, executor: executor
        )
        try await restarted.service.recover(id, action: action)
        let effectsAfterRestart = await fileSystem.stagingRecoveryEffectHistory()
        let inspections = await fileSystem.stagingRecoveryInspectionHistory()
        XCTAssertEqual(effectsAfterRestart.count, 1)
        XCTAssertEqual(effectsAfterRestart.first?.operationID, id)
        XCTAssertEqual(effectsAfterRestart.first?.itemID, itemID)
        XCTAssertEqual(effectsAfterRestart.first?.effect, "cleanupStaging")
        XCTAssertEqual(effectsAfterRestart.first?.effectID, durableIntent.0)
        XCTAssertEqual(inspections.count, 1)
        XCTAssertEqual(inspections.first?.operationID, id)
        XCTAssertEqual(inspections.first?.itemID, itemID)
        XCTAssertEqual(inspections.first?.effect, "cleanupStaging")
        XCTAssertEqual(inspections.first?.effectID, durableIntent.0)
        let inspectionResults = await fileSystem.stagingRecoveryInspectionResultHistory()
        XCTAssertEqual(inspectionResults, [.notPerformed])
        let durableResult = try XCTUnwrap(journal.durableRecoveryAttempt(
            operationID: id, actionID: action.command.actionID, itemID: itemID
        ))
        XCTAssertEqual(durableResult.0, durableIntent.0)
        XCTAssertEqual(durableResult.1, "completed")
        let recovered = try await restarted.service.snapshot(id)
        XCTAssertEqual(recovered.state, .cancelled)
    }

    func testInitialStagingCancelAmbiguousSurvivesRestartAndConvergesByInspection()
        async throws {
        let journal = InMemoryOperationJournal()
        let fileSystem = FakeFileSystemAdapter()
        await fileSystem.setStagingRecoveryModes([.recoveryRequired])
        let executionGate = ContinuationGate()
        let executor = FakeOperationExecutor(startGate: executionGate)
        let harness = try ServiceTestHarness(
            journal: journal, fileSystem: fileSystem, executor: executor
        )
        let id = try await harness.service.submit(copyRequest("/source/initial-ambiguous"))
        try await executionGate.waitUntilEntered()
        await harness.service.cancel(id)
        await executionGate.release()
        let failed = try await harness.service.snapshot(id)
        let itemID = try XCTUnwrap(failed.items.first?.id)
        XCTAssertEqual(failed.state, .recoveryRequired)
        let action = try XCTUnwrap(failed.availableActions.first {
            if case .discardKnownStaging = $0 { return true }
            return false
        })
        let durableIntent = try XCTUnwrap(journal.durableRecoveryAttempt(
            operationID: id, actionID: action.command.actionID, itemID: itemID
        ))
        XCTAssertNil(durableIntent.1)
        let initialEffects = await fileSystem.stagingRecoveryEffectHistory()
        XCTAssertEqual(initialEffects.count, 1)
        XCTAssertEqual(initialEffects.first?.operationID, id)
        XCTAssertEqual(initialEffects.first?.itemID, itemID)
        XCTAssertEqual(initialEffects.first?.effect, "cleanupStaging")
        XCTAssertEqual(initialEffects.first?.effectID, durableIntent.0)

        let restarted = try ServiceTestHarness(
            journal: journal, fileSystem: fileSystem, executor: executor
        )
        await assertFailure(.recoveryRequired) {
            try await restarted.service.recover(id, action: action)
        }
        let firstInspectionHistory = await fileSystem.stagingRecoveryInspectionHistory()
        let firstInspection = try XCTUnwrap(firstInspectionHistory.first)
        XCTAssertEqual(firstInspection.operationID, id)
        XCTAssertEqual(firstInspection.itemID, itemID)
        XCTAssertEqual(firstInspection.effect, "cleanupStaging")
        XCTAssertEqual(firstInspection.effectID, durableIntent.0)
        let effectsAfterUnknown = await fileSystem.stagingRecoveryEffectHistory()
        XCTAssertEqual(effectsAfterUnknown.count, 1)

        await fileSystem.setStagingRecoveryInspection(.completed)
        try await restarted.service.recover(id, action: action)
        let recovered = try await restarted.service.snapshot(id)
        XCTAssertEqual(recovered.state, .cancelled)
        let effectsAfterConvergence = await fileSystem.stagingRecoveryEffectHistory()
        let inspectionHistory = await fileSystem.stagingRecoveryInspectionHistory()
        XCTAssertEqual(effectsAfterConvergence.count, 1)
        XCTAssertEqual(inspectionHistory.count, 2)
        for inspection in inspectionHistory {
            XCTAssertEqual(inspection.operationID, id)
            XCTAssertEqual(inspection.itemID, itemID)
            XCTAssertEqual(inspection.effect, "cleanupStaging")
            XCTAssertEqual(inspection.effectID, durableIntent.0)
        }
        let durableResult = try XCTUnwrap(journal.durableRecoveryAttempt(
            operationID: id, actionID: action.command.actionID, itemID: itemID
        ))
        XCTAssertEqual(durableResult.0, durableIntent.0)
        XCTAssertEqual(durableResult.1, "completed")
    }

    func testInitialStagingCancelResultJournalFailureRestartsWithoutSecondEffect()
        async throws {
        let journal = InMemoryOperationJournal()
        let fileSystem = FakeFileSystemAdapter()
        await fileSystem.setStagingRecoveryModes([.completed])
        let executionGate = ContinuationGate()
        let postEffect = ContinuationGate()
        await fileSystem.setStagingRecoveryPostEffectGate(postEffect, ordinal: 1)
        let executor = FakeOperationExecutor(startGate: executionGate)
        let harness = try ServiceTestHarness(
            journal: journal, fileSystem: fileSystem, executor: executor
        )
        let id = try await harness.service.submit(copyRequest("/source/initial-result-failure"))
        try await executionGate.waitUntilEntered()
        let cancelling = Task { await harness.service.cancel(id) }
        try await postEffect.waitUntilEntered()
        let interrupted = try await harness.service.snapshot(id)
        let itemID = try XCTUnwrap(interrupted.items.first?.id)
        let action = try XCTUnwrap(interrupted.availableActions.first {
            if case .discardKnownStaging = $0 { return true }
            return false
        })
        journal.injectNextWriteFailure()
        await postEffect.release()
        await executionGate.release()
        await cancelling.value
        let unresolved = try XCTUnwrap(journal.durableRecoveryAttempt(
            operationID: id, actionID: action.command.actionID, itemID: itemID
        ))
        XCTAssertNil(unresolved.1)
        let effectsAfterFailure = await fileSystem.stagingRecoveryEffectHistory()
        XCTAssertEqual(effectsAfterFailure.count, 1)
        XCTAssertEqual(effectsAfterFailure.first?.operationID, id)
        XCTAssertEqual(effectsAfterFailure.first?.itemID, itemID)
        XCTAssertEqual(effectsAfterFailure.first?.effect, "cleanupStaging")
        XCTAssertEqual(effectsAfterFailure.first?.effectID, unresolved.0)

        let restarted = try ServiceTestHarness(
            journal: journal, fileSystem: fileSystem, executor: executor
        )
        try await restarted.service.recover(id, action: action)
        let effectsAfterRestart = await fileSystem.stagingRecoveryEffectHistory()
        let inspections = await fileSystem.stagingRecoveryInspectionHistory()
        let recovered = try await restarted.service.snapshot(id)
        XCTAssertEqual(effectsAfterRestart.count, 1)
        XCTAssertEqual(inspections.last?.operationID, id)
        XCTAssertEqual(inspections.last?.itemID, itemID)
        XCTAssertEqual(inspections.last?.effect, "cleanupStaging")
        XCTAssertEqual(inspections.last?.effectID, unresolved.0)
        XCTAssertEqual(recovered.state, .cancelled)
        let durableResult = try XCTUnwrap(journal.durableRecoveryAttempt(
            operationID: id, actionID: action.command.actionID, itemID: itemID
        ))
        XCTAssertEqual(durableResult.1, "completed")
    }

    private func waitForState(_ state: OperationState, id: OperationID,
                              service: FileOperationService) async throws -> OperationSnapshot {
        try await withDeadline("state \(state.rawValue)") {
            let stream = await service.events()
            if try await service.snapshot(id).state == state { return try await service.snapshot(id) }
            for await event in stream where event.operationID == id {
                let snapshot = try await service.snapshot(id)
                if snapshot.state == state { return snapshot }
            }
            throw TestDeadline.exceeded("event stream ended")
        }
    }

    private func assertDurableSnapshotUnchanged(
        _ before: OperationSnapshot, _ after: OperationSnapshot,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(after.state, before.state, file: file, line: line)
        XCTAssertEqual(after.latestSequence, before.latestSequence, file: file, line: line)
        XCTAssertEqual(after.items.map(\.state), before.items.map(\.state), file: file, line: line)
        XCTAssertEqual(after.items.map { $0.receipt?.committedIdentityDigest },
                       before.items.map { $0.receipt?.committedIdentityDigest },
                       file: file, line: line)
        XCTAssertEqual(after.availableActions.map(\.command.actionID),
                       before.availableActions.map(\.command.actionID),
                       file: file, line: line)
        XCTAssertEqual(after.terminalFailure?.code, before.terminalFailure?.code,
                       file: file, line: line)
    }

    private func waitForDiagnostic(_ diagnostics: DiagnosticRecorder) async throws {
        try await withDeadline("diagnostic") {
            while diagnostics.count() == 0 {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
    }

    private func waitForRecoveryAction(
        id: OperationID, service: FileOperationService,
        matching predicate: @escaping @Sendable (RecoveryAction) -> Bool
    ) async throws -> OperationSnapshot {
        try await withDeadline("recovery action") {
            let stream = await service.events()
            var snapshot = try await service.snapshot(id)
            if snapshot.availableActions.contains(where: predicate) { return snapshot }
            for await event in stream where event.operationID == id {
                snapshot = try await service.snapshot(id)
                if snapshot.availableActions.contains(where: predicate) { return snapshot }
            }
            throw TestDeadline.exceeded("event stream ended")
        }
    }

    private func assertFailure(
        _ expected: FileOperationErrorCode,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let failure as FileOperationFailure {
            XCTAssertEqual(failure.code, expected, file: file, line: line)
        } catch {
            XCTFail("wrong error type: \(error)", file: file, line: line)
        }
    }

    private func copyRequest(_ source: String) -> OperationRequest {
        OperationRequest(kind: .copy, sources: [fileURL(source)],
                         destination: fileURL("/target"), destinationMode: .container)
    }

    private func moveRequest(_ source: String) -> OperationRequest {
        OperationRequest(kind: .move, sources: [fileURL(source)],
                         destination: fileURL("/target"), destinationMode: .container)
    }

    private func fileURL(_ path: String) -> URL { URL(fileURLWithPath: path) }
}

private enum TestDeadline: Error, Sendable { case exceeded(String) }

private func withDeadline<T: Sendable>(
    _ description: String,
    nanoseconds: UInt64 = 5_000_000_000,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: nanoseconds)
            throw TestDeadline.exceeded(description)
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw TestDeadline.exceeded(description) }
        return result
    }
}
