import AppKit
import RascalFileOperations

enum NativeCopyRoute: String, CaseIterable, Sendable {
    case paste, listDrag, iconDrag, paneToPane, dropStack, duplicate
}

struct NativeCopySubmissionTrace: Equatable, Sendable {
    let route: NativeCopyRoute
    let operationID: OperationID
}

private final class NativeCopySubmissionTraceStore: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [NativeCopySubmissionTrace] = []

    func append(_ entry: NativeCopySubmissionTrace) {
        lock.lock(); defer { lock.unlock() }
        entries.append(entry)
    }

    func snapshot() -> [NativeCopySubmissionTrace] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }
}

/// Main-actor adapter between AppKit entry points and the actor-isolated file
/// operation service. It never falls back to a legacy mutation after submit.
@MainActor
final class FileOperationBridge {
    let service: FileOperationService
    let nativeCopyEnabled: Bool
    private let presentsAlerts: Bool
    private var eventTask: Task<Void, Never>?
    private(set) var snapshots: [OperationID: OperationSnapshot] = [:]
    private var refreshHandlers: [OperationID: @MainActor () -> Void] = [:]
    private var resolvedDecisionTokens: Set<DecisionToken> = []
    private var presentedFailures: Set<OperationID> = []
    private var didPresentFailureAlert = false
    private var failureAlert: NSAlert?
    private let submissionTraceStore = NativeCopySubmissionTraceStore()
    var submissionTrace: [NativeCopySubmissionTrace] { submissionTraceStore.snapshot() }

    init(
        service: FileOperationService,
        nativeCopyEnabled: Bool = false,
        presentsAlerts: Bool = true
    ) {
        self.service = service
        self.nativeCopyEnabled = nativeCopyEnabled
        self.presentsAlerts = presentsAlerts
        eventTask = Task { [weak self, service] in
            let clock = ContinuousClock()
            var consecutiveResyncs = 0
            while !Task.isCancelled {
                let subscriptionStartedAt = clock.now
                let stream = await service.events()
                for await event in stream {
                    guard !Task.isCancelled else { return }
                    guard let snapshot = try? await service.snapshot(event.operationID) else {
                        continue
                    }
                    self?.consume(snapshot)
                }
                let subscriptionLifetime = subscriptionStartedAt.duration(to: clock.now)
                let knownIDs = self.map { Set($0.snapshots.keys) } ?? Set<OperationID>()
                self?.snapshots.removeAll()
                for id in knownIDs {
                    guard !Task.isCancelled else { return }
                    if let snapshot = try? await service.snapshot(id) {
                        self?.consume(snapshot)
                    }
                }
                if subscriptionLifetime >= .seconds(5) {
                    consecutiveResyncs = 0
                } else {
                    consecutiveResyncs = min(consecutiveResyncs + 1, 6)
                }
                let delay = UInt64(25_000_000) << UInt64(consecutiveResyncs)
                try? await Task.sleep(nanoseconds: min(delay, 1_000_000_000))
            }
        }
    }

    deinit { eventTask?.cancel() }

    @discardableResult
    func submitCopy(
        sources: [URL],
        destination: URL,
        destinationMode: DestinationMode = .container,
        conflictPolicy: ConflictPolicy = .ask,
        route: NativeCopyRoute,
        refresh: (@MainActor () -> Void)? = nil
    ) -> Bool {
        guard nativeCopyEnabled, !sources.isEmpty else { return false }
        let request = OperationRequest(
            kind: .copy,
            sources: sources,
            destination: destination,
            destinationMode: destinationMode,
            conflictPolicy: conflictPolicy,
            verificationPolicy: .structural
        )
        let traceStore = submissionTraceStore
        // Do not inherit the main actor here. Besides keeping large admission
        // bursts off AppKit, this lets nested run-loop based UI tests observe
        // progress instead of starving the task until the test method returns.
        Task.detached(priority: .userInitiated) { [weak self, service, refresh, traceStore] in
            do {
                let id = try await service.submit(request)
                traceStore.append(.init(route: route, operationID: id))
                await self?.didSubmit(id, refresh: refresh)
            } catch let failure as FileOperationFailure {
                await self?.present(failure)
            } catch {
                await self?.present(FileOperationFailure(
                    code: .invariantViolation,
                    diagnostic: String(describing: error),
                    retryable: false
                ))
            }
        }
        return true
    }

    private func didSubmit(
        _ id: OperationID,
        refresh: (@MainActor () -> Void)?
    ) {
        if let refresh { refreshHandlers[id] = refresh }
    }

    private func consume(_ snapshot: OperationSnapshot) {
        snapshots[snapshot.id] = snapshot
        if let decision = snapshot.pendingDecision,
           resolvedDecisionTokens.insert(decision.token).inserted {
            present(decision)
        }
        switch snapshot.state {
        case .completed, .completedWithSkips, .completedWithSourceRetained:
            refreshHandlers.removeValue(forKey: snapshot.id)?()
        case .failedRecoverable, .recoveryRequired, .cleanupRequired:
            refreshHandlers.removeValue(forKey: snapshot.id)
            if let failure = snapshot.terminalFailure,
               presentedFailures.insert(snapshot.id).inserted {
                present(failure)
            }
        case .cancelled, .rolledBack:
            refreshHandlers.removeValue(forKey: snapshot.id)
        default:
            break
        }
    }

    private func present(_ request: DecisionRequest) {
        guard presentsAlerts else {
            Task { [service] in try? await service.resolve(request.token, with: .stop) }
            return
        }
        if !request.metadataLosses.isEmpty {
            presentMetadataDecision(request)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "A file already exists"
        alert.informativeText = "Choose how this copy should continue. Replace and Merge remain disabled."
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Stop")
        let resolve: (NSApplication.ModalResponse) -> Void = { [service] response in
            let decision: OperationDecision
            switch response {
            case .alertFirstButtonReturn: decision = .keepBoth(scope: .item)
            case .alertSecondButtonReturn: decision = .skip(scope: .item)
            default: decision = .stop
            }
            Task { try? await service.resolve(request.token, with: decision) }
        }
        if let window = NSApp.keyWindow, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: resolve)
        } else {
            resolve(alert.runModal())
        }
    }

    private func presentMetadataDecision(_ request: DecisionRequest) {
        let approval = request.allowed.first { decision in
            if case let .approvePortable(losses, _) = decision {
                return losses == request.metadataLosses
            }
            return false
        }
        guard let approval else {
            present(FileOperationFailure(
                code: .unsupportedMetadata,
                operationID: request.operationID,
                itemID: request.itemID,
                diagnostic: "Metadata fidelity is unavailable and no valid portable decision exists.",
                retryable: false
            ))
            return
        }
        let fields = request.metadataLosses.map(\.rawValue).sorted().joined(separator: ", ")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Some Finder metadata cannot be preserved"
        alert.informativeText = "Copy without these fields: \(fields)?"
        alert.addButton(withTitle: "Copy Anyway")
        alert.addButton(withTitle: "Stop")
        let resolve: (NSApplication.ModalResponse) -> Void = { [service] response in
            let decision = response == .alertFirstButtonReturn ? approval : .stop
            Task { try? await service.resolve(request.token, with: decision) }
        }
        if let window = NSApp.keyWindow, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: resolve)
        } else {
            resolve(alert.runModal())
        }
    }

    private func present(_ failure: FileOperationFailure) {
        // A burst of independent items can fail on the same unavailable
        // capability. Present one actionable summary for this app session;
        // per-operation typed failures remain available in snapshots without
        // queueing sheets or nested modal loops.
        guard presentsAlerts, !didPresentFailureAlert else { return }
        didPresentFailureAlert = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "File operation failed"
        alert.informativeText = failure.diagnostic +
            "\n\nFurther file-operation failures will not open additional dialogs during this app session."
        alert.addButton(withTitle: "OK")
        failureAlert = alert
        if let window = NSApp.keyWindow, window.attachedSheet == nil {
            alert.beginSheetModal(for: window) { [weak self, weak alert] _ in
                if self?.failureAlert === alert { self?.failureAlert = nil }
            }
        } else {
            alert.runModal()
            failureAlert = nil
        }
    }
}
