import Foundation

public struct OperationID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public struct OperationItemID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public typealias EventSequence = UInt64

public enum OperationKind: String, Codable, Sendable, CaseIterable {
    case copy, move, rename, replace, merge, trash, create
}

public enum DestinationMode: String, Codable, Sendable {
    case container, exact, exactDirectory
}

public enum ConflictPolicy: String, Codable, Sendable {
    case ask, skip, keepBoth, replace, merge, stop
}

public enum VerificationPolicy: String, Codable, Sendable {
    case structural, sha256
}

public enum CreateDescriptor: Codable, Sendable, Equatable {
    case file(initialContents: Data?)
    case directory
    case symbolicLink(target: String)
}

public enum MetadataField: String, Codable, Sendable, Hashable, CaseIterable {
    case posixMode, modificationTime, creationTime, addedTime
    case extendedAttributes, finderInfo, finderTags, resourceFork, acl
    case bsdFlags, symlinkMetadata, hardLinkTopology, sparseTopology
}

public struct PortableApproval: Codable, Sendable, Hashable {
    public let decisionID: UUID
    public let approvedLosses: Set<MetadataField>

    // Only FileOperationService may turn a resolved decision into an approval.
    init(decisionID: UUID, approvedLosses: Set<MetadataField>) {
        self.decisionID = decisionID
        self.approvedLosses = approvedLosses
    }
}

public enum MetadataPolicy: Codable, Sendable, Equatable {
    case finderCompatible
    case portable(PortableApproval)
}

public struct OperationRequest: Codable, Sendable {
    public let schemaVersion: UInt16
    public let kind: OperationKind
    public let sources: [URL]
    public let destination: URL?
    public let destinationMode: DestinationMode?
    public let createDescriptor: CreateDescriptor?
    public let conflictPolicy: ConflictPolicy
    public let metadataPolicy: MetadataPolicy
    public let verificationPolicy: VerificationPolicy

    public init(
        kind: OperationKind,
        sources: [URL],
        destination: URL?,
        destinationMode: DestinationMode?,
        createDescriptor: CreateDescriptor? = nil,
        conflictPolicy: ConflictPolicy = .ask,
        metadataPolicy: MetadataPolicy = .finderCompatible,
        verificationPolicy: VerificationPolicy = .structural
    ) {
        self.schemaVersion = 1
        self.kind = kind
        self.sources = sources
        self.destination = destination
        self.destinationMode = destinationMode
        self.createDescriptor = createDescriptor
        self.conflictPolicy = conflictPolicy
        self.metadataPolicy = metadataPolicy
        self.verificationPolicy = verificationPolicy
    }
}

public enum OperationState: String, Codable, Sendable, CaseIterable {
    case planned, preflight, waitingForDecision, staging, paused, metadata, verifying
    case committing, committedAwaitingCleanup, sourceQuarantining, cleaningSource
    case completed, completedWithSkips, completedWithSourceRetained, cancelled
    case failedRecoverable, recoveryRequired, cleanupRequired, rolledBack
}

public enum OperationItemState: String, Codable, Sendable, CaseIterable {
    case pending, preflight, waitingForDecision, staging, paused, metadata, verifying
    case committing, committed, committedAwaitingCleanup, sourceQuarantining
    case cleaningSource, completed, skipped, cancelled
    case failedRecoverable, recoveryRequired, cleanupRequired, rolledBack
}

public struct OperationProgress: Codable, Sendable, Equatable {
    public let bytesCompleted: Int64
    public let bytesTotal: Int64?
    public let itemsCompleted: Int
    public let itemsTotal: Int

    public init(bytesCompleted: Int64, bytesTotal: Int64?, itemsCompleted: Int, itemsTotal: Int) {
        self.bytesCompleted = bytesCompleted
        self.bytesTotal = bytesTotal
        self.itemsCompleted = itemsCompleted
        self.itemsTotal = itemsTotal
    }

    public static let zero = OperationProgress(bytesCompleted: 0, bytesTotal: nil, itemsCompleted: 0, itemsTotal: 0)
}

public struct MetadataOutcome: Codable, Sendable, Equatable {
    public let preserved: Set<MetadataField>
    public let degraded: Set<MetadataField>
    public let unknown: Set<MetadataField>

    public init(preserved: Set<MetadataField>, degraded: Set<MetadataField>, unknown: Set<MetadataField>) {
        self.preserved = preserved
        self.degraded = degraded
        self.unknown = unknown
    }
}

public struct VerificationOutcome: Codable, Sendable, Equatable {
    public let policy: VerificationPolicy
    public let sourceDigest: String?
    public let stagedDigest: String?
    public let manifestDigest: String

    public init(policy: VerificationPolicy, sourceDigest: String?, stagedDigest: String?, manifestDigest: String) {
        self.policy = policy
        self.sourceDigest = sourceDigest
        self.stagedDigest = stagedDigest
        self.manifestDigest = manifestDigest
    }
}

public struct OperationReceiptSummary: Codable, Sendable, Equatable {
    public let committedIdentityDigest: String
    public let backupURL: URL?
    public let quarantineURL: URL?
    public let sourceCleanupPending: Bool

    public init(committedIdentityDigest: String, backupURL: URL?, quarantineURL: URL?, sourceCleanupPending: Bool) {
        self.committedIdentityDigest = committedIdentityDigest
        self.backupURL = backupURL
        self.quarantineURL = quarantineURL
        self.sourceCleanupPending = sourceCleanupPending
    }
}

public struct OperationItemSnapshot: Codable, Sendable {
    public let id: OperationItemID
    public let source: URL
    public let destination: URL?
    public let state: OperationItemState
    public let progress: OperationProgress
    public let metadata: MetadataOutcome?
    public let verification: VerificationOutcome?
    public let receipt: OperationReceiptSummary?
    public let failure: FileOperationFailure?

    package init(id: OperationItemID, source: URL, destination: URL?, state: OperationItemState,
                 progress: OperationProgress, metadata: MetadataOutcome?,
                 verification: VerificationOutcome?, receipt: OperationReceiptSummary?,
                 failure: FileOperationFailure?) {
        self.id = id
        self.source = source
        self.destination = destination
        self.state = state
        self.progress = progress
        self.metadata = metadata
        self.verification = verification
        self.receipt = receipt
        self.failure = failure
    }
}

public struct OperationSnapshot: Codable, Sendable {
    public let schemaVersion: UInt16
    public let id: OperationID
    public let kind: OperationKind
    public let state: OperationState
    public let latestSequence: EventSequence
    public let request: OperationRequest
    public let effectiveMetadataPolicy: MetadataPolicy
    public let effectiveVerificationPolicy: VerificationPolicy
    public let progress: OperationProgress
    public let items: [OperationItemSnapshot]
    public let pendingDecision: DecisionRequest?
    public let terminalFailure: FileOperationFailure?
    public let availableActions: [RecoveryAction]
    public let hasPartialCommit: Bool
    public let sourceRetained: Bool

    package init(schemaVersion: UInt16, id: OperationID, kind: OperationKind,
                 state: OperationState, latestSequence: EventSequence,
                 request: OperationRequest, effectiveMetadataPolicy: MetadataPolicy,
                 effectiveVerificationPolicy: VerificationPolicy, progress: OperationProgress,
                 items: [OperationItemSnapshot], pendingDecision: DecisionRequest?,
                 terminalFailure: FileOperationFailure?, availableActions: [RecoveryAction],
                 hasPartialCommit: Bool, sourceRetained: Bool) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.kind = kind
        self.state = state
        self.latestSequence = latestSequence
        self.request = request
        self.effectiveMetadataPolicy = effectiveMetadataPolicy
        self.effectiveVerificationPolicy = effectiveVerificationPolicy
        self.progress = progress
        self.items = items
        self.pendingDecision = pendingDecision
        self.terminalFailure = terminalFailure
        self.availableActions = availableActions
        self.hasPartialCommit = hasPartialCommit
        self.sourceRetained = sourceRetained
    }
}

public struct DecisionToken: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public enum DecisionScope: String, Codable, Sendable, Equatable {
    case item, remainingItems
}

public enum OperationDecision: Codable, Sendable, Equatable {
    case skip(scope: DecisionScope)
    case keepBoth(scope: DecisionScope)
    case replace(scope: DecisionScope)
    case merge(scope: DecisionScope)
    case stop
    case approvePortable(losses: Set<MetadataField>, scope: DecisionScope)
    case cancel

    package var scope: DecisionScope? {
        switch self {
        case let .skip(scope), let .keepBoth(scope), let .replace(scope), let .merge(scope),
             let .approvePortable(_, scope):
            return scope
        case .stop, .cancel:
            return nil
        }
    }
}

public struct DecisionRequest: Codable, Sendable {
    public let token: DecisionToken
    public let operationID: OperationID
    public let itemID: OperationItemID
    public let expectedSequence: EventSequence
    public let allowed: [OperationDecision]
    public let metadataLosses: Set<MetadataField>
    public let identityDigest: String

    init(token: DecisionToken, operationID: OperationID, itemID: OperationItemID,
         expectedSequence: EventSequence, allowed: [OperationDecision],
         metadataLosses: Set<MetadataField>, identityDigest: String) {
        self.token = token
        self.operationID = operationID
        self.itemID = itemID
        self.expectedSequence = expectedSequence
        self.allowed = allowed
        self.metadataLosses = metadataLosses
        self.identityDigest = identityDigest
    }
}

public struct RecoveryCommand: Codable, Sendable, Hashable {
    public let actionID: UUID
    public let expectedSequence: EventSequence

    init(actionID: UUID, expectedSequence: EventSequence) {
        self.actionID = actionID
        self.expectedSequence = expectedSequence
    }
}

public enum RecoveryAction: Codable, Sendable, Hashable {
    case resumeFromVerifiedStage(RecoveryCommand)
    case retrySourceCleanup(RecoveryCommand)
    case retainSource(RecoveryCommand)
    case rollbackCommittedDestination(RecoveryCommand)
    case restoreBackup(RecoveryCommand)
    case finalizeKnownCommit(RecoveryCommand)
    case discardKnownStaging(RecoveryCommand)

    var command: RecoveryCommand {
        switch self {
        case let .resumeFromVerifiedStage(c), let .retrySourceCleanup(c), let .retainSource(c),
             let .rollbackCommittedDestination(c), let .restoreBackup(c),
             let .finalizeKnownCommit(c), let .discardKnownStaging(c): return c
        }
    }
}

public enum FileOperationErrorCode: String, Codable, Sendable {
    case validation, featureDisabled, sourceChanged, destinationChanged
    case permissionDenied, noSpace, volumeDisconnected, unsupportedMetadata
    case verificationMismatch, partialCommit, journalFailure, recoveryRequired
    case controlRejected, decisionExpired, invariantViolation, serviceSafeMode
}

public struct FileOperationFailure: Error, Codable, Sendable {
    public let code: FileOperationErrorCode
    public let operationID: OperationID?
    public let itemID: OperationItemID?
    public let phase: OperationState?
    public let systemCode: Int32?
    public let diagnostic: String
    public let retryable: Bool

    public init(code: FileOperationErrorCode, operationID: OperationID? = nil,
                itemID: OperationItemID? = nil, phase: OperationState? = nil,
                systemCode: Int32? = nil, diagnostic: String, retryable: Bool) {
        self.code = code
        self.operationID = operationID
        self.itemID = itemID
        self.phase = phase
        self.systemCode = systemCode
        self.diagnostic = diagnostic
        self.retryable = retryable
    }
}

public enum EventDurability: String, Codable, Sendable {
    case durable, transient
}

public enum OperationEventPayload: Codable, Sendable {
    case admitted(OperationSnapshot)
    case stateChanged(from: OperationState, to: OperationState)
    case itemStateChanged(from: OperationItemState, to: OperationItemState)
    case progress(OperationProgress)
    case decisionRequired(DecisionRequest)
    case decisionResolved(DecisionToken)
    case failure(FileOperationFailure)
    case receiptRecorded(OperationReceiptSummary)
    case recoveryAvailable([RecoveryAction])
    case recoveryConverged(completedActionID: UUID, availableActions: [RecoveryAction])
    case completed(OperationSnapshot)
}

public struct OperationEvent: Codable, Sendable {
    public let operationID: OperationID
    public let itemID: OperationItemID?
    public let sequence: EventSequence
    public let timestamp: Date
    public let durability: EventDurability
    public let payload: OperationEventPayload

    package init(operationID: OperationID, itemID: OperationItemID?, sequence: EventSequence,
                 timestamp: Date, durability: EventDurability,
                 payload: OperationEventPayload) {
        self.operationID = operationID
        self.itemID = itemID
        self.sequence = sequence
        self.timestamp = timestamp
        self.durability = durability
        self.payload = payload
    }
}

public struct ServiceConfiguration: Sendable {
    public static let `default` = ServiceConfiguration(journalURL: defaultJournalURL)
    public let journalURL: URL

    private init(journalURL: URL) { self.journalURL = journalURL }

    private static var defaultJournalURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rascal/Operations/operations.sqlite")
    }
}
