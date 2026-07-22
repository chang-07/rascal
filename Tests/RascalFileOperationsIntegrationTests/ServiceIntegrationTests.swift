import Foundation
import XCTest
@testable import RascalFileOperations
import RascalFileOperationsTestSupport

final class ServiceIntegrationTests: XCTestCase {
    func testDefaultSafeModeValidatesBeforeRefusingAndCreatesNoOperation() async throws {
        let production = try FileOperationService()
        await assertFailure(.validation) {
            _ = try await production.submit(OperationRequest(
                kind: .copy, sources: [], destination: fileURL("/target"),
                destinationMode: .container
            ))
        }
        await assertFailure(.serviceSafeMode) {
            _ = try await production.submit(copyRequest())
        }

        let harness = try ServiceTestHarness()
        await assertFailure(.featureDisabled) {
            _ = try await harness.service.submit(OperationRequest(
                kind: .create, sources: [fileURL("/target/new")], destination: nil,
                destinationMode: nil, createDescriptor: .directory
            ))
        }
        XCTAssertEqual(harness.journal.operationCount(), 0)
    }

    func testSubmitReturnsOnlyAfterPlannedIntentIsDurable() async throws {
        let harness = try ServiceTestHarness()
        let gate = ContinuationGate()
        await harness.failpoints.setGate(gate, for: .plannedPersisted)
        let task = Task { try await harness.service.submit(copyRequest()) }
        try await gate.waitUntilEntered()

        XCTAssertEqual(harness.journal.operationCount(), 1)
        let expectedID = deterministicOperationID(1)
        XCTAssertEqual(harness.journal.storedOperation(expectedID)?.state, .planned)

        await gate.release()
        let id = try await withServiceTestDeadline("planned submit continuation") {
            try await task.value
        }
        XCTAssertEqual(id, expectedID)
        _ = try await waitForState(.completed, id: id, service: harness.service)
    }

    func testExecutableKindsCompleteAndMovePolicyIsRaisedToSHA256() async throws {
        let cases: [(OperationKind, OperationRequest)] = [
            (.copy, copyRequest()),
            (.move, OperationRequest(kind: .move, sources: [fileURL("/source/move")],
                                     destination: fileURL("/target"), destinationMode: .container)),
            (.rename, OperationRequest(kind: .rename, sources: [fileURL("/source/old")],
                                       destination: fileURL("/source/new"), destinationMode: .exact)),
            (.replace, OperationRequest(kind: .replace, sources: [fileURL("/source/new")],
                                        destination: fileURL("/target/existing"), destinationMode: .exact))
        ]
        for (kind, request) in cases {
            let harness = try ServiceTestHarness()
            let id = try await harness.service.submit(request)
            let snapshot = try await waitForState(.completed, id: id, service: harness.service)
            XCTAssertEqual(snapshot.kind, kind)
            XCTAssertNotNil(snapshot.items.first?.receipt)
            XCTAssertEqual(snapshot.effectiveVerificationPolicy,
                           kind == .move ? .sha256 : .structural)
        }
    }

    func testSingleActiveSchedulerPreservesSubmissionOrdinal() async throws {
        let gate = ContinuationGate()
        let executor = FakeOperationExecutor(startGate: gate)
        let harness = try ServiceTestHarness(executor: executor)
        let first = try await harness.service.submit(copyRequest(source: "/source/first"))
        try await gate.waitUntilEntered()
        let second = try await harness.service.submit(copyRequest(source: "/source/second"))

        let startsBeforeRelease = await executor.startedOperations()
        let secondBeforeRelease = try await harness.service.snapshot(second)
        XCTAssertEqual(startsBeforeRelease, [first])
        XCTAssertEqual(secondBeforeRelease.state, .planned)

        await gate.release()
        _ = try await waitForState(.completed, id: second, service: harness.service)
        let startsAfterRelease = await executor.startedOperations()
        let maxConcurrency = await executor.maximumConcurrency()
        XCTAssertEqual(startsAfterRelease, [first, second])
        XCTAssertEqual(maxConcurrency, 1)
    }

    func testPlanningCancellationQuiescesBeforeNextOperationStarts() async throws {
        let planGate = ContinuationGate()
        let executor = FakeOperationExecutor()
        await executor.setPlanGate(planGate)
        let harness = try ServiceTestHarness(executor: executor)
        let first = try await harness.service.submit(copyRequest(source: "/source/plan-first"))
        try await planGate.waitUntilEntered()
        let second = try await harness.service.submit(copyRequest(source: "/source/plan-second"))

        await harness.service.cancel(first)
        let cancelled = try await harness.service.snapshot(first)
        XCTAssertEqual(cancelled.state, .cancelled)
        await planGate.release()
        _ = try await waitForState(.completed, id: second, service: harness.service)

        let plans = await executor.plannedOperations()
        let starts = await executor.startedOperations()
        let maximumConcurrency = await executor.maximumConcurrency()
        XCTAssertEqual(plans, [first, second])
        XCTAssertEqual(starts, [second])
        XCTAssertEqual(maximumConcurrency, 1)
    }

    func testDecisionWaitingOccupiesActiveSlotAndDecisionLedgerIsDurable() async throws {
        let fileSystem = FakeFileSystemAdapter(plans: [.copy: .conflict])
        let harness = try ServiceTestHarness(fileSystem: fileSystem)
        let first = try await harness.service.submit(copyRequest(source: "/source/first"))
        let decisionSnapshot = try await waitForDecision(id: first, service: harness.service)
        let request = try XCTUnwrap(decisionSnapshot.pendingDecision)

        let second = try await harness.service.submit(OperationRequest(
            kind: .rename, sources: [fileURL("/source/old")],
            destination: fileURL("/source/new"), destinationMode: .exact
        ))
        let queued = try await harness.service.snapshot(second)
        let startsWhileWaiting = await harness.executor.startedOperations()
        XCTAssertEqual(queued.state, .planned)
        XCTAssertTrue(startsWhileWaiting.isEmpty)

        await assertFailure(.decisionExpired) {
            try await harness.service.resolve(DecisionToken(rawValue: UUID()),
                                              with: .keepBoth(scope: .item))
        }
        await assertFailure(.decisionExpired) {
            try await harness.service.resolve(request.token, with: .merge(scope: .item))
        }
        await harness.service.pause(first)
        let afterUnrelatedEvent = try await harness.service.snapshot(first)
        XCTAssertGreaterThan(afterUnrelatedEvent.latestSequence, request.expectedSequence)

        let persistGate = ContinuationGate()
        await harness.failpoints.setGate(persistGate, for: .decisionResolved)
        let resolveTask = Task {
            try await harness.service.resolve(request.token, with: .keepBoth(scope: .item))
        }
        try await persistGate.waitUntilEntered()
        XCTAssertTrue(harness.journal.hasDurableDecision(
            for: request.itemID, operationID: first
        ))
        let persisted = try await harness.service.snapshot(first)
        XCTAssertEqual(persisted.state, .waitingForDecision)
        XCTAssertNil(persisted.pendingDecision)

        await persistGate.release()
        try await withServiceTestDeadline("decision resolution continuation") {
            try await resolveTask.value
        }
        _ = try await waitForState(.completed, id: second, service: harness.service)
        await assertFailure(.decisionExpired) {
            try await harness.service.resolve(request.token, with: .keepBoth(scope: .item))
        }
    }

    func testWaitingCancellationDurablyClearsDecisionToken() async throws {
        let fileSystem = FakeFileSystemAdapter(plans: [.copy: .conflict])
        let harness = try ServiceTestHarness(fileSystem: fileSystem)
        let id = try await harness.service.submit(copyRequest())
        let waiting = try await waitForDecision(id: id, service: harness.service)
        let token = try XCTUnwrap(waiting.pendingDecision?.token)

        await harness.service.cancel(id)
        let cancelled = try await harness.service.snapshot(id)
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertNil(cancelled.pendingDecision)
        await assertFailure(.decisionExpired) {
            try await harness.service.resolve(token, with: .keepBoth(scope: .item))
        }
    }

    func testRestartResumesDecisionThatWasDurableBeforeStateTransition() async throws {
        let journal = InMemoryOperationJournal()
        let fileSystem = FakeFileSystemAdapter(plans: [.copy: .conflict])
        let original = try ServiceTestHarness(journal: journal, fileSystem: fileSystem)
        let id = try await original.service.submit(copyRequest())
        let waiting = try await waitForDecision(id: id, service: original.service)
        let request = try XCTUnwrap(waiting.pendingDecision)

        try journal.simulateDurableResolvedDecision(
            operationID: id, decision: .keepBoth(scope: .item)
        )
        XCTAssertTrue(journal.hasDurableDecision(for: request.itemID, operationID: id))

        let restarted = try ServiceTestHarness(journal: journal, fileSystem: fileSystem)
        let completed = try await waitForState(.completed, id: id, service: restarted.service)
        XCTAssertNil(completed.pendingDecision)
        let completedItemID = try XCTUnwrap(completed.items.first?.id)
        let effectCount = await restarted.executor.effectCount(
            operationID: id, itemID: completedItemID
        )
        XCTAssertEqual(effectCount, 1)
    }

    func testMetadataApprovalBindsLossesKindAndScope() async throws {
        let losses: Set<MetadataField> = [.acl, .extendedAttributes]
        let fileSystem = FakeFileSystemAdapter(plans: [.copy: .metadataLoss(losses)])
        let harness = try ServiceTestHarness(fileSystem: fileSystem)
        let id = try await harness.service.submit(copyRequest())
        let pendingSnapshot = try await waitForDecision(id: id, service: harness.service)
        let pending = try XCTUnwrap(pendingSnapshot.pendingDecision)

        await assertFailure(.decisionExpired) {
            try await harness.service.resolve(
                pending.token,
                with: .approvePortable(losses: [.acl], scope: .item)
            )
        }
        let itemStageGate = ContinuationGate()
        await harness.executor.setGate(itemStageGate, for: .staging)
        try await harness.service.resolve(
            pending.token,
            with: .approvePortable(losses: losses, scope: .item)
        )
        try await itemStageGate.waitUntilEntered()
        let active = try await harness.service.snapshot(id)
        guard case let .portable(activeApproval) = active.effectiveMetadataPolicy else {
            return XCTFail("active item policy was not observable while staging")
        }
        XCTAssertEqual(activeApproval.decisionID, pending.token.rawValue)
        await itemStageGate.release()
        let completed = try await waitForState(.completed, id: id, service: harness.service)
        XCTAssertEqual(completed.effectiveMetadataPolicy, .finderCompatible)
        let itemAttempts = await harness.executor.rawAttemptHistory()
        let itemAttempt = try XCTUnwrap(itemAttempts.first)
        guard case let .portable(approval) = itemAttempt.metadataPolicy else {
            return XCTFail("item-scoped approval was not supplied to the executor")
        }
        XCTAssertEqual(approval.decisionID, pending.token.rawValue)
        XCTAssertEqual(approval.approvedLosses, losses)

        let remainingFS = FakeFileSystemAdapter(plans: [.copy: .metadataLoss(losses)])
        let remainingHarness = try ServiceTestHarness(fileSystem: remainingFS)
        let remainingID = try await remainingHarness.service.submit(OperationRequest(
            kind: .copy,
            sources: [fileURL("/source/portable-a"), fileURL("/source/portable-b")],
            destination: fileURL("/target"), destinationMode: .container
        ))
        let remainingWaiting = try await waitForDecision(
            id: remainingID, service: remainingHarness.service
        )
        let remainingPending = try XCTUnwrap(remainingWaiting.pendingDecision)
        try await remainingHarness.service.resolve(
            remainingPending.token,
            with: .approvePortable(losses: losses, scope: .remainingItems)
        )
        let remainingCompleted = try await waitForState(
            .completed, id: remainingID, service: remainingHarness.service
        )
        guard case let .portable(remainingApproval) = remainingCompleted.effectiveMetadataPolicy else {
            return XCTFail("remaining-items approval was not reflected in operation policy")
        }
        XCTAssertEqual(remainingApproval.decisionID, remainingPending.token.rawValue)
        let allRemainingAttempts = await remainingHarness.executor.rawAttemptHistory()
        let remainingAttempts = allRemainingAttempts.filter {
            $0.phase == .staging
        }
        XCTAssertEqual(remainingAttempts.count, 2)
        XCTAssertTrue(remainingAttempts.allSatisfy { $0.metadataPolicy == remainingCompleted.effectiveMetadataPolicy })

        let moveFS = FakeFileSystemAdapter(plans: [.move: .metadataLoss(losses)])
        let moveHarness = try ServiceTestHarness(fileSystem: moveFS)
        let moveID = try await moveHarness.service.submit(OperationRequest(
            kind: .move, sources: [fileURL("/source/move")], destination: fileURL("/target"),
            destinationMode: .container
        ))
        let movePendingSnapshot = try await waitForDecision(id: moveID, service: moveHarness.service)
        let moveDecision = try XCTUnwrap(movePendingSnapshot.pendingDecision)
        await assertFailure(.unsupportedMetadata) {
            try await moveHarness.service.resolve(
                moveDecision.token,
                with: .approvePortable(losses: losses, scope: .item)
            )
        }
    }

    func testSkipReturnsThroughPreflightAndRemainingScopeAppliesToAllItems() async throws {
        let fileSystem = FakeFileSystemAdapter(plans: [.copy: .skipAfterDecision])
        let harness = try ServiceTestHarness(fileSystem: fileSystem)
        let request = OperationRequest(
            kind: .copy, sources: [fileURL("/source/a"), fileURL("/source/b")],
            destination: fileURL("/target"), destinationMode: .container
        )
        let id = try await harness.service.submit(request)
        let firstDecisionSnapshot = try await waitForDecision(id: id, service: harness.service)
        let pending = try XCTUnwrap(firstDecisionSnapshot.pendingDecision)
        // Fake skip plan only advertises item scope, so a forged broader scope is rejected.
        await assertFailure(.decisionExpired) {
            try await harness.service.resolve(pending.token, with: .skip(scope: .remainingItems))
        }
        try await harness.service.resolve(pending.token, with: .skip(scope: .item))
        let secondDecisionSnapshot = try await waitForDecision(id: id, service: harness.service)
        let second = try XCTUnwrap(secondDecisionSnapshot.pendingDecision)
        try await harness.service.resolve(second.token, with: .skip(scope: .item))
        let completed = try await waitForState(.completedWithSkips, id: id, service: harness.service)
        XCTAssertTrue(completed.items.allSatisfy { $0.state == .skipped })
        let counts = await fileSystem.counts()
        let starts = await harness.executor.startedOperations()
        XCTAssertGreaterThanOrEqual(counts.preflight, 4)
        XCTAssertTrue(starts.isEmpty)

        let remainingFS = FakeFileSystemAdapter(plans: [.copy: .conflict])
        let remainingHarness = try ServiceTestHarness(fileSystem: remainingFS)
        let remainingID = try await remainingHarness.service.submit(request)
        let remainingSnapshot = try await waitForDecision(
            id: remainingID, service: remainingHarness.service
        )
        let remainingRequest = try XCTUnwrap(remainingSnapshot.pendingDecision)
        try await remainingHarness.service.resolve(
            remainingRequest.token, with: .skip(scope: .remainingItems)
        )
        let allSkipped = try await waitForState(
            .completedWithSkips, id: remainingID, service: remainingHarness.service
        )
        XCTAssertTrue(allSkipped.items.allSatisfy { $0.state == .skipped })
        let remainingStarts = await remainingHarness.executor.startedOperations()
        XCTAssertTrue(remainingStarts.isEmpty)
    }

    func testProjectedNameCollisionAndUnknownEquivalenceStopBeforeEffects() async throws {
        let fileSystem = FakeFileSystemAdapter()
        await fileSystem.setNameEquivalence(.caseInsensitive)
        let harness = try ServiceTestHarness(fileSystem: fileSystem)
        let request = OperationRequest(
            kind: .copy, sources: [fileURL("/a/Report"), fileURL("/b/report")],
            destination: fileURL("/target"), destinationMode: .container
        )
        let id = try await harness.service.submit(request)
        let snapshot = try await waitForDecision(id: id, service: harness.service)
        XCTAssertEqual(snapshot.pendingDecision?.identityDigest, "fake-projected-name-collision")
        let collisionStarts = await harness.executor.startedOperations()
        XCTAssertTrue(collisionStarts.isEmpty)

        let unknownFS = FakeFileSystemAdapter()
        await unknownFS.setNameEquivalence(.unknown)
        let unknownHarness = try ServiceTestHarness(fileSystem: unknownFS)
        let unknownID = try await unknownHarness.service.submit(request)
        let failed = try await waitForState(.failedRecoverable, id: unknownID,
                                            service: unknownHarness.service)
        XCTAssertEqual(failed.terminalFailure?.code, .destinationChanged)
        let unknownStarts = await unknownHarness.executor.startedOperations()
        XCTAssertTrue(unknownStarts.isEmpty)
    }

    func testPrecommitCancellationUsesRecoveryLedgerForEveryCleanupOutcome() async throws {
        for (mode, expected): (FakeRecoveryMode, OperationState) in [
            (.completed, .cancelled),
            (.ambiguousCompleted, .recoveryRequired),
            (.recoveryRequired, .recoveryRequired)
        ] {
            let gate = ContinuationGate()
            let fileSystem = FakeFileSystemAdapter()
            await fileSystem.setStagingRecoveryModes([mode])
            let executor = FakeOperationExecutor(startGate: gate)
            let harness = try ServiceTestHarness(fileSystem: fileSystem, executor: executor)
            let id = try await harness.service.submit(copyRequest())
            try await gate.waitUntilEntered()
            await harness.service.cancel(id)
            let cancelled = try await harness.service.snapshot(id)
            let counts = await fileSystem.counts()
            XCTAssertEqual(cancelled.state, expected)
            XCTAssertEqual(counts.cleanup, 1)
            await gate.release()
        }
    }

    func testMetadataCancellationWaitsForExecutorQuiescenceAndStartsNoLaterPhase() async throws {
        let gate = ContinuationGate()
        let executor = FakeOperationExecutor()
        await executor.setGate(gate, for: .metadata)
        let harness = try ServiceTestHarness(executor: executor)
        let id = try await harness.service.submit(copyRequest())
        try await gate.waitUntilEntered()

        await harness.service.cancel(id)
        let cancelled = try await harness.service.snapshot(id)
        XCTAssertEqual(cancelled.state, .cancelled)
        let itemID = try XCTUnwrap(cancelled.items.first?.id)
        let allAttempts = await executor.rawAttemptHistory()
        let attempts = allAttempts.filter { $0.operationID == id }
        XCTAssertEqual(attempts.map(\.phase), [.staging, .metadata])
        let metadataEffects = await executor.effectCount(
            operationID: id, itemID: itemID, phase: .metadata
        )
        let commitEffects = await executor.effectCount(
            operationID: id, itemID: itemID, phase: .commit
        )
        XCTAssertEqual(metadataEffects, 0)
        XCTAssertEqual(commitEffects, 0)
        await gate.release()
    }

    func testPauseResumeAndCommittedAwaitingCleanupCancellation() async throws {
        let stageGate = ContinuationGate()
        let executor = FakeOperationExecutor(startGate: stageGate)
        let harness = try ServiceTestHarness(executor: executor)
        let id = try await harness.service.submit(copyRequest())
        try await stageGate.waitUntilEntered()
        await harness.service.pause(id)
        let paused = try await harness.service.snapshot(id)
        XCTAssertEqual(paused.state, .paused)
        await stageGate.release()
        await harness.service.resume(id)
        _ = try await waitForState(.completed, id: id, service: harness.service)

        let barrier = ContinuationGate()
        let moveExecutor = FakeOperationExecutor(modes: [.move: .committedAwaitingCleanup])
        let moveHarness = try ServiceTestHarness(executor: moveExecutor)
        await moveHarness.failpoints.setGate(barrier, for: .committedAwaitingCleanup)
        let moveID = try await moveHarness.service.submit(OperationRequest(
            kind: .move,
            sources: [fileURL("/source/a"), fileURL("/source/b")],
            destination: fileURL("/target"), destinationMode: .container
        ))
        try await barrier.waitUntilEntered()
        await moveHarness.service.cancel(moveID)
        let retained = try await moveHarness.service.snapshot(moveID)
        XCTAssertEqual(retained.state, .completedWithSourceRetained)
        XCTAssertTrue(retained.sourceRetained)
        XCTAssertTrue(retained.hasPartialCommit)
        XCTAssertEqual(retained.items.map(\.state), [.completed, .cancelled])
        await barrier.release()
    }

    func testCommitPhaseRejectsCancellationAndCompletesOneCommitEffect() async throws {
        let gate = ContinuationGate()
        let executor = FakeOperationExecutor()
        await executor.setGate(gate, for: .commit)
        let harness = try ServiceTestHarness(executor: executor)
        let id = try await harness.service.submit(copyRequest())
        try await gate.waitUntilEntered()
        let beforeCancel = try await harness.service.snapshot(id)
        XCTAssertEqual(beforeCancel.state, .committing)

        await harness.service.cancel(id)
        let afterCancel = try await harness.service.snapshot(id)
        XCTAssertEqual(afterCancel.state, .committing)
        await gate.release()
        let completed = try await waitForState(.completed, id: id, service: harness.service)
        let itemID = try XCTUnwrap(completed.items.first?.id)
        let commitEffects = await executor.effectCount(
            operationID: id, itemID: itemID, phase: .commit
        )
        XCTAssertEqual(commitEffects, 1)
    }

    func testJournalFailureBeforeCommitIntentPreventsCommitAndForcesSafeMode() async throws {
        let verificationGate = ContinuationGate()
        let executor = FakeOperationExecutor()
        await executor.setGate(verificationGate, for: .verification)
        let harness = try ServiceTestHarness(executor: executor)
        let id = try await harness.service.submit(copyRequest())
        try await verificationGate.waitUntilEntered()
        let verifying = try await harness.service.snapshot(id)
        XCTAssertEqual(verifying.state, .verifying)
        let itemID = try XCTUnwrap(verifying.items.first?.id)

        harness.journal.injectNextWriteFailure()
        await verificationGate.release()
        try await withServiceTestDeadline("safe mode after commit-intent journal failure") {
            while harness.diagnostics.count() == 0 {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
        let commitEffects = await executor.effectCount(
            operationID: id, itemID: itemID, phase: .commit
        )
        XCTAssertEqual(commitEffects, 0)
        await assertFailure(.serviceSafeMode) {
            _ = try await harness.service.submit(copyRequest(source: "/source/after-journal-failure"))
        }
    }

    func testJournalFailureAfterCommitEffectLeavesNoRetryableReceipt() async throws {
        let postCommit = ContinuationGate()
        let executor = FakeOperationExecutor()
        await executor.setPostEffectGate(postCommit, for: .commit)
        let harness = try ServiceTestHarness(executor: executor)
        let id = try await harness.service.submit(copyRequest(source: "/source/post-effect"))
        try await postCommit.waitUntilEntered()
        let committing = try await harness.service.snapshot(id)
        let itemID = try XCTUnwrap(committing.items.first?.id)
        XCTAssertEqual(committing.state, .committing)

        harness.journal.injectNextWriteFailure()
        await postCommit.release()
        for _ in 0..<200 where harness.diagnostics.count() == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertGreaterThan(harness.diagnostics.count(), 0)
        let stranded = try await harness.service.snapshot(id)
        XCTAssertEqual(stranded.state, .committing)
        XCTAssertNil(harness.journal.durableCommitReceipt(operationID: id, itemID: itemID))
        let postEffectCount = await executor.effectCount(
            operationID: id, itemID: itemID, phase: .commit
        )
        XCTAssertEqual(postEffectCount, 1)
        await assertFailure(.serviceSafeMode) {
            _ = try await harness.service.submit(copyRequest(source: "/source/no-auto-retry"))
        }
    }

    func testCleanupGuardsStopBeforeAndAfterUnsafeJournalChanges() async throws {
        let beforeBarrier = ContinuationGate()
        let beforeExecutor = FakeOperationExecutor(modes: [.move: .committedAwaitingCleanup])
        let before = try ServiceTestHarness(executor: beforeExecutor)
        await before.failpoints.setGate(beforeBarrier, for: .committedAwaitingCleanup)
        let beforeID = try await before.service.submit(moveRequest("/source/guard-before"))
        try await beforeBarrier.waitUntilEntered()
        before.journal.injectNextWriteFailure()
        await before.service.pause(beforeID)
        await beforeBarrier.release()
        for _ in 0..<200 where before.diagnostics.count() == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let beforeSnapshot = try await before.service.snapshot(beforeID)
        let beforeItem = try XCTUnwrap(beforeSnapshot.items.first?.id)
        XCTAssertEqual(beforeSnapshot.state, .committedAwaitingCleanup)
        let beforeCleanupEffects = await beforeExecutor.effectCount(
            operationID: beforeID, itemID: beforeItem, phase: .sourceCleanup
        )
        XCTAssertEqual(beforeCleanupEffects, 0)

        let afterBarrier = ContinuationGate()
        let afterExecutor = FakeOperationExecutor(modes: [.move: .committedAwaitingCleanup])
        await afterExecutor.setPostEffectGate(afterBarrier, for: .sourceCleanup)
        let after = try ServiceTestHarness(executor: afterExecutor)
        let afterID = try await after.service.submit(moveRequest("/source/guard-after"))
        try await afterBarrier.waitUntilEntered()
        after.journal.injectNextWriteFailure()
        await afterBarrier.release()
        for _ in 0..<200 where after.diagnostics.count() == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let afterSnapshot = try await after.service.snapshot(afterID)
        let afterItem = try XCTUnwrap(afterSnapshot.items.first?.id)
        XCTAssertEqual(afterSnapshot.state, .cleaningSource)
        XCTAssertTrue(afterSnapshot.items[0].receipt?.sourceCleanupPending == true)
        let afterCleanupEffects = await afterExecutor.effectCount(
            operationID: afterID, itemID: afterItem, phase: .sourceCleanup
        )
        XCTAssertEqual(afterCleanupEffects, 1)
    }

    func testCleanupRecoveryRetriesActualEffectAndIsIdempotent() async throws {
        let executor = FakeOperationExecutor(modes: [.move: .committedAwaitingCleanup])
        await executor.setSourceCleanupFailures(1)
        let harness = try ServiceTestHarness(executor: executor)
        let id = try await harness.service.submit(moveRequest("/source/cleanup-retry"))
        let failed = try await waitForState(.cleanupRequired, id: id, service: harness.service)
        let itemID = try XCTUnwrap(failed.items.first?.id)
        let retry = try XCTUnwrap(failed.availableActions.first {
            if case .retrySourceCleanup = $0 { return true }
            return false
        })
        XCTAssertEqual(failed.availableActions.count, 2)

        try await harness.service.recover(id, action: retry)
        let completed = try await harness.service.snapshot(id)
        XCTAssertEqual(completed.state, .completed)
        XCTAssertTrue(completed.items[0].receipt?.sourceCleanupPending == false)
        let cleanupEffects = await executor.effectCount(
            operationID: id, itemID: itemID, phase: .sourceCleanup
        )
        let recoveryCleanupEffects = await executor.recoveryEffectHistory().filter {
            $0.operationID == id && $0.itemID == itemID && $0.effect == "cleanupSource"
        }
        XCTAssertEqual(cleanupEffects, 1)
        XCTAssertEqual(recoveryCleanupEffects.count, 1)
        try await harness.service.recover(id, action: retry)
        let repeatedCleanupEffects = await executor.effectCount(
            operationID: id, itemID: itemID, phase: .sourceCleanup
        )
        let repeatedRecoveryEffects = await executor.recoveryEffectHistory().filter {
            $0.operationID == id && $0.itemID == itemID && $0.effect == "cleanupSource"
        }
        XCTAssertEqual(repeatedCleanupEffects, 1)
        XCTAssertEqual(repeatedRecoveryEffects.count, 1)
    }

    func testPartialCommitOffersFinalizeAndRollbackAndRollbackExecutes() async throws {
        let executor = FakeOperationExecutor()
        await executor.setModeSequence([.committed, .failed(.noSpace)], for: .copy)
        let harness = try ServiceTestHarness(executor: executor)
        let id = try await harness.service.submit(OperationRequest(
            kind: .copy,
            sources: [fileURL("/source/partial-a"), fileURL("/source/partial-b")],
            destination: fileURL("/target"), destinationMode: .container
        ))
        let failed = try await waitForState(.failedRecoverable, id: id,
                                            service: harness.service)
        XCTAssertTrue(failed.hasPartialCommit)
        XCTAssertEqual(failed.terminalFailure?.code, .partialCommit)
        XCTAssertEqual(failed.availableActions.count, 2)
        XCTAssertTrue(failed.availableActions.contains {
            if case .rollbackCommittedDestination = $0 { return true }
            return false
        })
        XCTAssertTrue(failed.availableActions.contains {
            if case .finalizeKnownCommit = $0 { return true }
            return false
        })
        let rollback = try XCTUnwrap(failed.availableActions.first {
            if case .rollbackCommittedDestination = $0 { return true }
            return false
        })
        try await harness.service.recover(id, action: rollback)
        let rolledBack = try await harness.service.snapshot(id)
        XCTAssertEqual(rolledBack.state, .rolledBack)
        XCTAssertEqual(rolledBack.items.map(\.state), [.rolledBack, .rolledBack])
        let rollbackEffects = await executor.recoveryEffectHistory()
        XCTAssertEqual(rollbackEffects.count, 1)
    }

    func testCopyAndMoveSourceCleanupPlansAndReceiptsAreConsistent() async throws {
        let copyHarness = try ServiceTestHarness()
        let copyID = try await copyHarness.service.submit(copyRequest())
        let copy = try await waitForState(.completed, id: copyID, service: copyHarness.service)
        let copyItemID = try XCTUnwrap(copy.items.first?.id)
        XCTAssertEqual(copy.items.first?.receipt?.sourceCleanupPending, false)
        let copyCleanupEffects = await copyHarness.executor.effectCount(
            operationID: copyID, itemID: copyItemID, phase: .sourceCleanup
        )
        XCTAssertEqual(copyCleanupEffects, 0)

        let illegalCopyExecutor = FakeOperationExecutor(modes: [.copy: .illegalSourceCleanupPlan])
        let illegalCopyHarness = try ServiceTestHarness(executor: illegalCopyExecutor)
        let illegalCopyID = try await illegalCopyHarness.service.submit(
            copyRequest(source: "/source/illegal-cleanup")
        )
        let rejectedCopy = try await waitForState(
            .failedRecoverable, id: illegalCopyID, service: illegalCopyHarness.service
        )
        XCTAssertEqual(rejectedCopy.terminalFailure?.code, .invariantViolation)
        let illegalCopyEffects = await illegalCopyExecutor.actualEffectHistory()
        XCTAssertTrue(illegalCopyEffects.isEmpty)

        let sameMoveHarness = try ServiceTestHarness()
        let sameMoveID = try await sameMoveHarness.service.submit(moveRequest("/source/same"))
        let sameMove = try await waitForState(
            .completed, id: sameMoveID, service: sameMoveHarness.service
        )
        let sameItemID = try XCTUnwrap(sameMove.items.first?.id)
        XCTAssertEqual(sameMove.items.first?.verification?.policy, .sha256)
        XCTAssertEqual(sameMove.items.first?.receipt?.sourceCleanupPending, false)
        let sameCleanupEffects = await sameMoveHarness.executor.effectCount(
            operationID: sameMoveID, itemID: sameItemID, phase: .sourceCleanup
        )
        XCTAssertEqual(sameCleanupEffects, 0)

        let crossExecutor = FakeOperationExecutor(modes: [.move: .committedAwaitingCleanup])
        let crossHarness = try ServiceTestHarness(executor: crossExecutor)
        let crossID = try await crossHarness.service.submit(moveRequest("/source/cross"))
        let cross = try await waitForState(.completed, id: crossID, service: crossHarness.service)
        let crossItemID = try XCTUnwrap(cross.items.first?.id)
        XCTAssertEqual(cross.items.first?.verification?.policy, .sha256)
        XCTAssertEqual(cross.items.first?.receipt?.sourceCleanupPending, false)
        let crossCleanupEffects = await crossExecutor.effectCount(
            operationID: crossID, itemID: crossItemID, phase: .sourceCleanup
        )
        let crossAttempts = await crossExecutor.rawAttemptHistory()
        XCTAssertEqual(crossCleanupEffects, 1)
        XCTAssertTrue(crossAttempts.allSatisfy {
            $0.sourceCleanupRequired && $0.verificationPolicy == .sha256
        })

        let mismatchExecutor = FakeOperationExecutor(modes: [.move: .receiptMismatch])
        let mismatchHarness = try ServiceTestHarness(executor: mismatchExecutor)
        let mismatchID = try await mismatchHarness.service.submit(moveRequest("/source/mismatch"))
        let mismatch = try await waitForState(
            .recoveryRequired, id: mismatchID, service: mismatchHarness.service
        )
        let mismatchItemID = try XCTUnwrap(mismatch.items.first?.id)
        XCTAssertEqual(mismatch.terminalFailure?.code, .invariantViolation)
        let mismatchCommitEffects = await mismatchExecutor.effectCount(
            operationID: mismatchID, itemID: mismatchItemID, phase: .commit
        )
        let mismatchCleanupEffects = await mismatchExecutor.effectCount(
            operationID: mismatchID, itemID: mismatchItemID, phase: .sourceCleanup
        )
        XCTAssertEqual(mismatchCommitEffects, 1)
        XCTAssertEqual(mismatchCleanupEffects, 0)
    }

    func testRetryProducesOneCommittedEffectAndCannotPreemptAnotherOperation() async throws {
        let executor = FakeOperationExecutor()
        await executor.setModeSequence([.failed(.noSpace), .committed], for: .copy)
        let harness = try ServiceTestHarness(executor: executor)
        let id = try await harness.service.submit(copyRequest())
        let failed = try await waitForState(.failedRecoverable, id: id, service: harness.service)
        let itemID = try XCTUnwrap(failed.items.first?.id)
        let effectsBeforeRetry = await executor.effectCount(operationID: id, itemID: itemID)
        XCTAssertEqual(effectsBeforeRetry, 0)
        try await harness.service.retry(id)
        _ = try await waitForState(.completed, id: id, service: harness.service)
        let effectsAfterRetry = await executor.effectCount(operationID: id, itemID: itemID)
        XCTAssertEqual(effectsAfterRetry, 1)
        await assertFailure(.controlRejected) { try await harness.service.retry(id) }
        let effectsAfterRejectedRetry = await executor.effectCount(operationID: id, itemID: itemID)
        XCTAssertEqual(effectsAfterRejectedRetry, 1)

        let blockingGate = ContinuationGate()
        let secondExecutor = FakeOperationExecutor(modes: [.copy: .failed(.noSpace)],
                                                   startGate: nil)
        let secondHarness = try ServiceTestHarness(executor: secondExecutor)
        let failedID = try await secondHarness.service.submit(copyRequest(source: "/source/fail"))
        _ = try await waitForState(.failedRecoverable, id: failedID, service: secondHarness.service)
        await secondExecutor.setStartGate(blockingGate)
        await secondExecutor.setMode(.committed, for: .rename)
        _ = try await secondHarness.service.submit(OperationRequest(
            kind: .rename, sources: [fileURL("/source/old")],
            destination: fileURL("/source/new"), destinationMode: .exact
        ))
        try await blockingGate.waitUntilEntered()
        await assertFailure(.controlRejected) { try await secondHarness.service.retry(failedID) }
        await blockingGate.release()
    }

    func testDurableEffectLedgerSuppressesCommitAcrossServiceRestart() async throws {
        let journal = InMemoryOperationJournal()
        let firstExecutor = FakeOperationExecutor()
        let first = try ServiceTestHarness(journal: journal, executor: firstExecutor)
        let id = try await first.service.submit(copyRequest(source: "/source/replayed-commit"))
        let completed = try await waitForState(.completed, id: id, service: first.service)
        let itemID = try XCTUnwrap(completed.items.first?.id)
        XCTAssertNotNil(journal.durableCommitReceipt(operationID: id, itemID: itemID))

        try journal.simulateRecoverableProjection(operationID: id)
        let secondExecutor = FakeOperationExecutor()
        let restarted = try ServiceTestHarness(journal: journal, executor: secondExecutor)
        try await restarted.service.retry(id)
        _ = try await waitForState(.completed, id: id, service: restarted.service)

        let firstAttempts = await firstExecutor.rawAttemptHistory().filter {
            $0.operationID == id && $0.itemID == itemID && $0.phase == .commit
        }
        let secondAttempts = await secondExecutor.rawAttemptHistory().filter {
            $0.operationID == id && $0.itemID == itemID && $0.phase == .commit
        }
        let firstEffects = await firstExecutor.effectCount(
            operationID: id, itemID: itemID, phase: .commit
        )
        let secondEffects = await secondExecutor.effectCount(
            operationID: id, itemID: itemID, phase: .commit
        )
        XCTAssertEqual(firstAttempts.count + secondAttempts.count, 2)
        XCTAssertEqual(firstEffects + secondEffects, 1)
    }

    func testRecoveryActionsAreBoundUniqueAndPersistAcrossRestart() async throws {
        let journal = InMemoryOperationJournal()
        let ids = DeterministicOperationIDGenerator()
        let executor = FakeOperationExecutor(modes: [.copy: .ambiguous])
        let harness = try ServiceTestHarness(journal: journal, executor: executor, idGenerator: ids)
        let id = try await harness.service.submit(copyRequest())
        let failed = try await waitForState(.recoveryRequired, id: id, service: harness.service)
        XCTAssertEqual(failed.availableActions.count, 2)
        XCTAssertEqual(Set(failed.availableActions.map { $0.command.actionID }).count, 2)
        let action = try XCTUnwrap(failed.availableActions.first {
            if case .finalizeKnownCommit = $0 { return true }
            return false
        })
        let forged = RecoveryAction.resumeFromVerifiedStage(RecoveryCommand(
            actionID: UUID(), expectedSequence: action.command.expectedSequence
        ))
        await assertFailure(.controlRejected) { try await harness.service.recover(id, action: forged) }

        let eventsBeforeRejectedPause = journal.eventCount(operationID: id)
        await harness.service.pause(id)
        let afterRejectedPause = try await harness.service.snapshot(id)
        XCTAssertEqual(afterRejectedPause.latestSequence, failed.latestSequence)
        XCTAssertEqual(journal.eventCount(operationID: id), eventsBeforeRejectedPause)

        try await harness.service.recover(id, action: action)
        let afterRecovery = try await harness.service.snapshot(id)
        XCTAssertEqual(afterRecovery.state, .completed)
        XCTAssertTrue(afterRecovery.availableActions.isEmpty)
        try await harness.service.recover(id, action: action)
        let effectsAfterRepeat = await executor.recoveryEffectHistory()
        XCTAssertEqual(effectsAfterRepeat.count, 1)

        let restarted = try ServiceTestHarness(journal: journal, executor: executor, idGenerator: ids)
        try await restarted.service.recover(id, action: action)
        let afterRestart = try await restarted.service.snapshot(id)
        XCTAssertEqual(afterRestart.state, .completed)
        let effectsAfterRestart = await executor.recoveryEffectHistory()
        XCTAssertEqual(effectsAfterRestart.count, 1)

        let unknownJournal = InMemoryOperationJournal()
        let unknownExecutor = FakeOperationExecutor(modes: [.copy: .ambiguous])
        await unknownExecutor.setCommitInspection(.unknown, for: .copy)
        let unknownHarness = try ServiceTestHarness(journal: unknownJournal,
                                                    executor: unknownExecutor)
        let unknownID = try await unknownHarness.service.submit(
            copyRequest(source: "/source/still-ambiguous")
        )
        let unknown = try await waitForState(.recoveryRequired, id: unknownID,
                                             service: unknownHarness.service)
        let unknownAction = try XCTUnwrap(unknown.availableActions.first)
        await assertFailure(.recoveryRequired) {
            try await unknownHarness.service.recover(unknownID, action: unknownAction)
        }
        let stillUnknown = try await unknownHarness.service.snapshot(unknownID)
        XCTAssertEqual(stillUnknown.state, .recoveryRequired)
        XCTAssertTrue(stillUnknown.availableActions.contains(unknownAction))

        let ambiguousJournal = InMemoryOperationJournal()
        let ambiguousExecutor = FakeOperationExecutor(modes: [.copy: .ambiguous])
        await ambiguousExecutor.setRecoveryModes([.recoveryRequired])
        let ambiguousHarness = try ServiceTestHarness(journal: ambiguousJournal,
                                                      executor: ambiguousExecutor)
        let ambiguousID = try await ambiguousHarness.service.submit(copyRequest(source: "/source/ambiguous"))
        let ambiguous = try await waitForState(.recoveryRequired, id: ambiguousID,
                                               service: ambiguousHarness.service)
        let interruptedAction = try XCTUnwrap(ambiguous.availableActions.first)
        await assertFailure(.recoveryRequired) {
            try await ambiguousHarness.service.recover(
                ambiguousID, action: interruptedAction
            )
        }
        let afterCrash = try ServiceTestHarness(
            journal: ambiguousJournal, executor: ambiguousExecutor
        )
        await assertFailure(.recoveryRequired) {
            try await afterCrash.service.recover(ambiguousID, action: interruptedAction)
        }
        let ambiguousEffects = await ambiguousExecutor.recoveryEffectHistory()
        XCTAssertEqual(ambiguousEffects.count, 1)
    }

    func testUnknownControlIsDiagnosticOnlyAndKnownRejectionFailureEntersSafeMode() async throws {
        let harness = try ServiceTestHarness()
        let unknown = OperationID(rawValue: UUID())
        await harness.service.pause(unknown)
        XCTAssertTrue(harness.diagnostics.containsUnknownControl(for: unknown, command: "pause"))
        XCTAssertEqual(harness.journal.operationCount(), 0)

        let durableGate = ContinuationGate()
        let durable = try ServiceTestHarness()
        await durable.failpoints.setGate(durableGate, for: .plannedPersisted)
        let durableSubmit = Task { try await durable.service.submit(copyRequest()) }
        try await durableGate.waitUntilEntered()
        let durableID = deterministicOperationID(1)
        let before = try await durable.service.snapshot(durableID)
        let beforeEvents = durable.journal.eventCount(operationID: durableID)
        let beforeCounts = await durable.fileSystem.counts()
        await durable.service.pause(durableID)
        let after = try await durable.service.snapshot(durableID)
        let afterCounts = await durable.fileSystem.counts()
        XCTAssertEqual(after.state, before.state)
        XCTAssertEqual(after.availableActions, before.availableActions)
        XCTAssertGreaterThan(after.latestSequence, before.latestSequence)
        XCTAssertEqual(durable.journal.eventCount(operationID: durableID), beforeEvents + 1)
        XCTAssertEqual(beforeCounts.preflight, afterCounts.preflight)
        XCTAssertEqual(beforeCounts.cleanup, afterCounts.cleanup)
        await durableGate.release()
        _ = try await durableSubmit.value
        _ = try await waitForState(.completed, id: durableID, service: durable.service)

        let gate = ContinuationGate()
        await harness.failpoints.setGate(gate, for: .plannedPersisted)
        let submit = Task { try await harness.service.submit(copyRequest()) }
        try await gate.waitUntilEntered()
        let known = deterministicOperationID(1)
        harness.journal.injectNextWriteFailure()
        await harness.service.pause(known)
        let afterRejectedControl = try await harness.service.snapshot(known)
        XCTAssertEqual(afterRejectedControl.state, .planned)
        XCTAssertEqual(harness.journal.eventCount(operationID: known), 0)
        await gate.release()
        _ = try await withServiceTestDeadline("safe-mode submit continuation") {
            try await submit.value
        }
        await assertFailure(.serviceSafeMode) {
            _ = try await harness.service.submit(copyRequest(source: "/source/second"))
        }
    }

    private func waitForState(_ state: OperationState, id: OperationID,
                              service: FileOperationService) async throws -> OperationSnapshot {
        try await withServiceTestDeadline("state \(state) for \(id.rawValue)") {
            let stream = await service.events()
            let current = try await service.snapshot(id)
            if current.state == state { return current }
            for await event in stream where event.operationID == id {
                let snapshot = try await service.snapshot(id)
                if snapshot.state == state { return snapshot }
            }
            throw FileOperationFailure(code: .invariantViolation, operationID: id,
                                       diagnostic: "event stream ended before state \(state)",
                                       retryable: false)
        }
    }

    private func waitForDecision(id: OperationID,
                                 service: FileOperationService) async throws -> OperationSnapshot {
        try await withServiceTestDeadline("decision for \(id.rawValue)") {
            let stream = await service.events()
            let current = try await service.snapshot(id)
            if current.pendingDecision != nil { return current }
            for await event in stream where event.operationID == id {
                let snapshot = try await service.snapshot(id)
                if snapshot.pendingDecision != nil { return snapshot }
            }
            throw FileOperationFailure(code: .invariantViolation, operationID: id,
                                       diagnostic: "event stream ended before decision",
                                       retryable: false)
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

    private func copyRequest(source: String = "/source/a") -> OperationRequest {
        OperationRequest(kind: .copy, sources: [fileURL(source)], destination: fileURL("/target"),
                         destinationMode: .container)
    }

    private func moveRequest(_ source: String) -> OperationRequest {
        OperationRequest(kind: .move, sources: [fileURL(source)], destination: fileURL("/target"),
                         destinationMode: .container)
    }

    private func fileURL(_ path: String) -> URL { URL(fileURLWithPath: path) }

    private func deterministicOperationID(_ value: UInt64) -> OperationID {
        OperationID(rawValue: UUID(uuidString: String(
            format: "00000000-0000-0000-0000-%012llx", value
        ))!)
    }
}

private enum ServiceTestDeadline: Error, Sendable {
    case exceeded(String)
}

private func withServiceTestDeadline<T: Sendable>(
    _ description: String,
    nanoseconds: UInt64 = 5_000_000_000,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: nanoseconds)
            throw ServiceTestDeadline.exceeded(description)
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw ServiceTestDeadline.exceeded(description)
        }
        // Structured scope exit joins the cancelled loser. An uncooperative
        // task therefore cannot leak into a later test; the process-level lane
        // timeout remains the final deadlock guard.
        return result
    }
}
