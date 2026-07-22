import Foundation
import XCTest
@testable import RascalFileOperations
import RascalFileOperationsTestSupport

final class EventStreamIntegrationTests: XCTestCase {
    func testTwoSubscribersReceiveIndependentIdenticalBroadcasts() async throws {
        let harness = try ServiceTestHarness(liveBufferLimit: 128)
        let firstStream = await harness.service.events()
        let secondStream = await harness.service.events()
        let id = try await harness.service.submit(copyRequest())

        async let first = collectUntilCompleted(firstStream, operationID: id)
        async let second = collectUntilCompleted(secondStream, operationID: id)
        let (firstEvents, secondEvents) = try await (first, second)

        XCTAssertFalse(firstEvents.isEmpty)
        XCTAssertEqual(firstEvents.map(\.sequence), secondEvents.map(\.sequence))
        XCTAssertEqual(firstEvents.map(\.itemID), secondEvents.map(\.itemID))
        assertStrictlyIncreasing(firstEvents.map(\.sequence))
    }

    func testLongReplayIsPagedOutsideBoundedLiveQueue() async throws {
        let journal = InMemoryOperationJournal()
        var operationIDs: [OperationID] = []
        for index in 0..<5 {
            let id = OperationID(rawValue: UUID(uuidString: String(
                format: "10000000-0000-0000-0000-%012x", index + 1
            ))!)
            let itemID = OperationItemID(rawValue: UUID(uuidString: String(
                format: "20000000-0000-0000-0000-%012x", index + 1
            ))!)
            try journal.seedCompletedHistory(operationID: id, itemID: itemID, eventCount: 12)
            operationIDs.append(id)
        }

        let replay = try ServiceTestHarness(journal: journal,
                                            idGenerator: idsGeneratorAfter(operationIDs.count),
                                            replayPageSize: 1, liveBufferLimit: 2)
        let stream = await replay.service.events()
        let expectedOperationCount = operationIDs.count
        let (completed, byOperation) = try await withTestDeadline("long paged replay") {
            var completed: Set<OperationID> = []
            var byOperation: [OperationID: [UInt64]] = [:]
            for await event in stream {
                byOperation[event.operationID, default: []].append(event.sequence)
                if case .completed = event.payload { completed.insert(event.operationID) }
                if completed.count == expectedOperationCount { return (completed, byOperation) }
            }
            throw AsyncTestDeadline.exceeded("replay stream ended before all completions")
        }

        XCTAssertEqual(completed, Set(operationIDs))
        for id in operationIDs {
            let sequences = try XCTUnwrap(byOperation[id])
            XCTAssertGreaterThan(sequences.count, 2)
            assertStrictlyIncreasing(sequences)
        }
    }

    func testReplayThenConcurrentLiveHandoffHasNoMarkerDuplicateOrReordering() async throws {
        let harness = try ServiceTestHarness(replayPageSize: 1, liveBufferLimit: 128)
        let historyID = try await harness.service.submit(copyRequest(source: "/source/history"))
        _ = try await waitForState(.completed, id: historyID, service: harness.service)

        let stream = await harness.service.events()
        let liveID = try await harness.service.submit(copyRequest(source: "/source/live"))
        _ = try await waitForState(.completed, id: liveID, service: harness.service)
        let events = try await collectUntilCompleted(stream, operationID: liveID)

        let historyIndexes = events.indices.filter { events[$0].operationID == historyID }
        let liveIndexes = events.indices.filter { events[$0].operationID == liveID }
        XCTAssertFalse(historyIndexes.isEmpty)
        XCTAssertFalse(liveIndexes.isEmpty)
        XCTAssertLessThan(try XCTUnwrap(historyIndexes.last), try XCTUnwrap(liveIndexes.first))
        let identities = events.map { "\($0.operationID.rawValue):\($0.sequence)" }
        XCTAssertEqual(Set(identities).count, identities.count)
    }

    func testProgressCoalescesPerItemWithoutOverwritingAnotherItem() async throws {
        let executor = FakeOperationExecutor()
        await executor.setProgressSteps([1, 2, 3])
        let harness = try ServiceTestHarness(executor: executor, liveBufferLimit: 128)
        let stream = await harness.service.events()
        let id = try await harness.service.submit(copyRequest())
        _ = try await harness.journal.waitForState(.completed, operationID: id)
        let events = try await collectUntilCompleted(stream, operationID: id)
        let progress = events.filter { if case .progress = $0.payload { return true }; return false }
        XCTAssertEqual(progress.count, 1)
        if case let .progress(value) = try XCTUnwrap(progress.first).payload {
            XCTAssertEqual(value.bytesCompleted, 3)
        } else {
            XCTFail("expected progress payload")
        }

        let multiExecutor = FakeOperationExecutor()
        await multiExecutor.setProgressSteps([1, 2])
        let multiHarness = try ServiceTestHarness(executor: multiExecutor, liveBufferLimit: 128)
        let multiStream = await multiHarness.service.events()
        let multiID = try await multiHarness.service.submit(OperationRequest(
            kind: .copy, sources: [fileURL("/source/a"), fileURL("/source/b")],
            destination: fileURL("/target"), destinationMode: .container
        ))
        _ = try await multiHarness.journal.waitForState(.completed, operationID: multiID)
        let multiEvents = try await collectUntilCompleted(multiStream, operationID: multiID)
        let itemProgress = multiEvents.filter {
            if case .progress = $0.payload { return true }
            return false
        }
        XCTAssertEqual(itemProgress.count, 2)
        XCTAssertEqual(Set(itemProgress.compactMap(\.itemID)).count, 2)
    }

    func testProgressCoalescingNeverCrossesInterveningStateEvents() async throws {
        let interleaveGate = ContinuationGate()
        let executor = FakeOperationExecutor()
        await executor.setProgressSteps([1, 2, 3])
        await executor.setProgressGate(interleaveGate, afterStep: 0)
        let harness = try ServiceTestHarness(executor: executor, liveBufferLimit: 128)
        let stream = await harness.service.events()
        let id = try await harness.service.submit(copyRequest())
        try await interleaveGate.waitUntilEntered()

        await harness.service.pause(id)
        let paused = try await harness.service.snapshot(id)
        XCTAssertEqual(paused.state, .paused)
        await harness.service.resume(id)
        await interleaveGate.release()
        _ = try await waitForState(.completed, id: id, service: harness.service)
        let events = try await collectUntilCompleted(stream, operationID: id)
        for event in events where event.operationID == id {
            print([
                "M1_EVENT_TRACE", "case=M1-EVENT-001",
                "operation=\(event.operationID.rawValue.uuidString)",
                "item=\(event.itemID?.rawValue.uuidString ?? "-")",
                "sequence=\(event.sequence)", "durability=\(event.durability.rawValue)",
                "payload=\(tracePayload(event.payload))"
            ].joined(separator: "\t"))
        }
        assertStrictlyIncreasing(events.filter { $0.operationID == id }.map(\.sequence))

        let itemProgress = events.filter { event in
            event.operationID == id && {
                if case .progress = event.payload { return true }
                return false
            }()
        }
        XCTAssertEqual(itemProgress.count, 2)
        let completedBytes = itemProgress.compactMap { event -> Int64? in
            if case let .progress(value) = event.payload { return value.bytesCompleted }
            return nil
        }
        XCTAssertEqual(completedBytes, [1, 3])
        let firstProgressIndex = try XCTUnwrap(events.firstIndex {
            if case .progress = $0.payload { return $0.operationID == id }
            return false
        })
        let lastProgressIndex = try XCTUnwrap(events.lastIndex {
            if case .progress = $0.payload { return $0.operationID == id }
            return false
        })
        XCTAssertTrue(events[(firstProgressIndex + 1)..<lastProgressIndex].contains { event in
            if case .stateChanged = event.payload { return true }
            if case .itemStateChanged = event.payload { return true }
            return false
        })
    }

    func testSlowSubscriberOverflowEndsOnlyThatStreamAndResubscribeConverges() async throws {
        let harness = try ServiceTestHarness(replayPageSize: 1, liveBufferLimit: 2)
        let slow = await harness.service.events()
        let id = try await harness.service.submit(copyRequest())
        _ = try await harness.journal.waitForState(.completed, operationID: id)

        let slowNext = try await withTestDeadline("overflowed subscriber EOF") {
            var iterator = slow.makeAsyncIterator()
            return await iterator.next()
        }
        XCTAssertNil(slowNext)
        let snapshot = try await harness.service.snapshot(id)
        XCTAssertEqual(snapshot.state, .completed)

        let replacement = await harness.service.events()
        let replacementEvents = try await collectUntilCompleted(replacement, operationID: id)
        XCTAssertFalse(replacementEvents.isEmpty)
        XCTAssertEqual(replacementEvents.last?.operationID, id)
    }

    func testReservedGapSurvivesRestartAndProgressNeverMovesBackward() async throws {
        let journal = InMemoryOperationJournal()
        let ids = DeterministicOperationIDGenerator()
        let executor = FakeOperationExecutor(modes: [.copy: .failed(.noSpace)])
        await executor.setProgressSteps([1, 2, 3])
        let harness = try ServiceTestHarness(journal: journal, executor: executor,
                                             idGenerator: ids, liveBufferLimit: 128)
        let id = try await harness.service.submit(copyRequest())
        let failed = try await waitForState(.failedRecoverable, id: id, service: harness.service)
        let emittedBeforeCrash = failed.latestSequence
        try journal.simulateReservedGap(operationID: id, count: 16)
        let reservedBeforeCrash = try XCTUnwrap(journal.storedSequences(id)?.reserved)
        XCTAssertGreaterThan(reservedBeforeCrash, emittedBeforeCrash)

        await executor.setMode(.committed, for: .copy)
        let restarted = try ServiceTestHarness(journal: journal, executor: executor,
                                               idGenerator: ids, liveBufferLimit: 128)
        let restartedSnapshot = try await restarted.service.snapshot(id)
        XCTAssertEqual(restartedSnapshot.latestSequence, emittedBeforeCrash)
        XCTAssertLessThan(restartedSnapshot.latestSequence, reservedBeforeCrash)
        try await restarted.service.retry(id)
        let completed = try await waitForState(.completed, id: id, service: restarted.service)
        XCTAssertGreaterThan(completed.latestSequence, reservedBeforeCrash)
    }

    func testSequenceExhaustionFailsClosedWithoutWrapping() async throws {
        let journal = InMemoryOperationJournal()
        let ids = DeterministicOperationIDGenerator()
        let executor = FakeOperationExecutor(modes: [.copy: .failed(.noSpace)])
        let harness = try ServiceTestHarness(journal: journal, executor: executor, idGenerator: ids)
        let id = try await harness.service.submit(copyRequest())
        _ = try await waitForState(.failedRecoverable, id: id, service: harness.service)
        journal.forceReservedThrough(UInt64.max, operationID: id)

        let restarted = try ServiceTestHarness(journal: journal, executor: executor, idGenerator: ids)
        await assertFailure(.serviceSafeMode) {
            _ = try await restarted.service.submit(copyRequest(source: "/source/after-overflow"))
        }
    }

    func testZZCancellingAnIdleSubscriptionFinishesItsPendingPull() async throws {
        let harness = try ServiceTestHarness()
        let stream = await harness.service.events()
        let waiting = Task { () -> OperationEvent? in
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        waiting.cancel()
        let cancelledValue = try await withTestDeadline("cancelled subscription completion") {
            await waiting.value
        }
        XCTAssertNil(cancelledValue)
    }

    private func collectUntilCompleted(_ stream: AsyncStream<OperationEvent>,
                                       operationID: OperationID) async throws -> [OperationEvent] {
        try await withTestDeadline("completion event for \(operationID.rawValue)") {
            var events: [OperationEvent] = []
            for await event in stream {
                events.append(event)
                if event.operationID == operationID, case .completed = event.payload { return events }
            }
            throw FileOperationFailure(code: .invariantViolation, operationID: operationID,
                                       diagnostic: "stream ended before completion", retryable: false)
        }
    }

    private func waitForState(_ state: OperationState, id: OperationID,
                              service: FileOperationService) async throws -> OperationSnapshot {
        try await withTestDeadline("state \(state) for \(id.rawValue)") {
            let stream = await service.events()
            let current = try await service.snapshot(id)
            if current.state == state { return current }
            for await event in stream where event.operationID == id {
                let snapshot = try await service.snapshot(id)
                if snapshot.state == state { return snapshot }
            }
            throw FileOperationFailure(code: .invariantViolation, operationID: id,
                                       diagnostic: "stream ended before \(state)", retryable: false)
        }
    }

    private func assertStrictlyIncreasing(_ values: [UInt64],
                                          file: StaticString = #filePath, line: UInt = #line) {
        for (left, right) in zip(values, values.dropFirst()) {
            XCTAssertLessThan(left, right, file: file, line: line)
        }
        XCTAssertEqual(Set(values).count, values.count, file: file, line: line)
    }

    private func assertFailure(_ expected: FileOperationErrorCode,
                               operation: () async throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await operation()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let failure as FileOperationFailure {
            XCTAssertEqual(failure.code, expected, file: file, line: line)
        } catch {
            XCTFail("wrong error: \(error)", file: file, line: line)
        }
    }

    private func copyRequest(source: String = "/source/a") -> OperationRequest {
        OperationRequest(kind: .copy, sources: [fileURL(source)], destination: fileURL("/target"),
                         destinationMode: .container)
    }

    private func fileURL(_ path: String) -> URL { URL(fileURLWithPath: path) }

    private func idsGeneratorAfter(_ operationCount: Int) -> DeterministicOperationIDGenerator {
        // Each single-item operation consumes one operation ID and one item ID.
        DeterministicOperationIDGenerator(startingAt: UInt64(operationCount * 2 + 1))
    }

    private func tracePayload(_ payload: OperationEventPayload) -> String {
        switch payload {
        case let .stateChanged(from, to): return "state:\(from.rawValue)->\(to.rawValue)"
        case let .itemStateChanged(from, to): return "item:\(from.rawValue)->\(to.rawValue)"
        case let .progress(value): return "progress:\(value.bytesCompleted)"
        case .decisionRequired: return "decisionRequired"
        case .decisionResolved: return "decisionResolved"
        case let .failure(failure): return "failure:\(failure.code.rawValue)"
        case let .receiptRecorded(receipt):
            return "receipt:cleanupPending=\(receipt.sourceCleanupPending)"
        case .recoveryAvailable: return "recoveryAvailable"
        case .completed: return "completed"
        }
    }
}

private enum AsyncTestDeadline: Error, Sendable {
    case exceeded(String)
}

private func withTestDeadline<T: Sendable>(
    _ description: String,
    nanoseconds: UInt64 = 5_000_000_000,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: nanoseconds)
            throw AsyncTestDeadline.exceeded(description)
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw AsyncTestDeadline.exceeded(description)
        }
        return result
    }
}
