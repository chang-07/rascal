import Foundation

package struct UnavailableOperationJournal: OperationJournal {
    package let isWritable = false
    package init() {}

    package func loadOperations() throws -> [JournalOperation] { [] }
    package func admit(_ snapshot: OperationSnapshot, at timestamp: Date) throws -> JournalAdmission {
        throw unavailable()
    }
    package func reserveSequences(for id: OperationID, count: UInt64) throws -> ClosedRange<EventSequence> { throw unavailable() }
    package func commit(_ operation: JournalOperation, event: OperationEvent) throws { throw unavailable() }
    package func checkpoint(_ operation: JournalOperation) throws { throw unavailable() }
    package func replay(operationID: OperationID, after sequence: EventSequence,
                        through watermark: EventSequence, limit: Int) throws -> [OperationEvent] { [] }

    private func unavailable() -> FileOperationFailure {
        FileOperationFailure(code: .serviceSafeMode,
                             diagnostic: "Durable operation journal is unavailable until M3",
                             retryable: false)
    }
}

package struct SystemOperationClock: OperationClock {
    package func now() -> Date { Date() }
}

package struct RandomOperationIDGenerator: OperationIDGenerator {
    package func operationID() -> OperationID { OperationID(rawValue: UUID()) }
    package func itemID() -> OperationItemID { OperationItemID(rawValue: UUID()) }
    package func decisionToken() -> DecisionToken { DecisionToken(rawValue: UUID()) }
    package func actionID() -> UUID { UUID() }
}

package struct UnavailableFileSystemAdapter: FileSystemAdapter {
    package func preflight(operationID: OperationID, request: OperationRequest, itemIndex: Int,
                           priorDecision: OperationDecision?,
                           controls: ExecutionControls) async throws -> PreflightDisposition {
        _ = operationID
        _ = controls
        return .failure(FileOperationFailure(
            code: .serviceSafeMode,
            diagnostic: "Native file adapter is unavailable until M2",
            retryable: false
        ))
    }
    package func recoverOwnedStaging(operationID: OperationID, itemID: OperationItemID,
                                     effectID: UUID) async -> ExecutionRecoveryOutcome {
        _ = effectID
        return .failedBeforeEffect(FileOperationFailure(
            code: .serviceSafeMode, operationID: operationID, itemID: itemID,
            diagnostic: "Staging recovery is unavailable until M2", retryable: false
        ))
    }

    package func inspectOwnedStaging(operationID: OperationID, itemID: OperationItemID,
                                     effectID: UUID) async -> ExecutionRecoveryInspection {
        _ = effectID
        return .unknown(FileOperationFailure(
            code: .recoveryRequired, operationID: operationID, itemID: itemID,
            diagnostic: "Staging recovery inspection is unavailable until M2",
            retryable: false
        ))
    }
}

package struct UnavailableExecutor: OperationExecutor {
    package func plan(_ context: ExecutionContext,
                      controls: ExecutionControls) async throws -> ExecutionPlan {
        throw FileOperationFailure(code: .serviceSafeMode, operationID: context.operationID,
                                   itemID: context.itemID,
                                   diagnostic: "Operation executor is unavailable until M2",
                                   retryable: false)
    }

    package func perform(_ phase: ExecutionPhase, context: ExecutionContext, plan: ExecutionPlan,
                         controls: ExecutionControls,
                         progress: @escaping @Sendable (OperationProgress) async -> Void) async
        -> ExecutionPhaseOutcome {
        .failed(FileOperationFailure(code: .serviceSafeMode, operationID: context.operationID,
                                     itemID: context.itemID,
                                     diagnostic: "Operation executor is unavailable until M2",
                                     retryable: false))
    }

    package func recover(_ effect: ExecutionRecoveryEffect, effectID: UUID,
                         context: ExecutionContext,
                         receipt: OperationReceiptSummary) async -> ExecutionRecoveryOutcome {
        _ = effectID
        return .failedBeforeEffect(FileOperationFailure(
            code: .serviceSafeMode, operationID: context.operationID, itemID: context.itemID,
            diagnostic: "Operation recovery executor is unavailable until M3", retryable: false
        ))
    }

    package func inspectRecoveryEffect(
        _ effect: ExecutionRecoveryEffect, effectID: UUID,
        context: ExecutionContext, receipt: OperationReceiptSummary
    ) async -> ExecutionRecoveryInspection {
        _ = effect
        _ = effectID
        _ = receipt
        return .unknown(FileOperationFailure(
            code: .recoveryRequired, operationID: context.operationID,
            itemID: context.itemID,
            diagnostic: "Recovery effect inspection is unavailable until M3",
            retryable: false
        ))
    }

    package func inspectCommit(_ context: ExecutionContext) async -> ExecutionCommitInspection {
        .unknown(FileOperationFailure(
            code: .recoveryRequired, operationID: context.operationID, itemID: context.itemID,
            diagnostic: "No production commit inspector is installed", retryable: false
        ))
    }


    package func inspectSourceBeforeCleanup(
        _ context: ExecutionContext,
        receipt: OperationReceiptSummary
    ) async -> ExecutionSourceInspection {
        _ = receipt
        return .unknown(FileOperationFailure(
            code: .recoveryRequired, operationID: context.operationID,
            itemID: context.itemID,
            diagnostic: "Source cleanup inspection is unavailable until M3",
            retryable: false
        ))
    }
}

package struct NoopDigestProvider: DigestProvider {
    package func digest(_ data: Data) throws -> String { "unavailable" }
}

package struct NoopFailpointController: FailpointController {
    package func hit(_ point: Failpoint, operationID: OperationID) async {}
}

package struct NoopDiagnosticSink: ServiceDiagnosticSink {
    package func record(_ diagnostic: ServiceDiagnostic) {}
}
