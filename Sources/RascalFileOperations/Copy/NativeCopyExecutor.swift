import Foundation
import Darwin

private enum NativeCopyInterruption: Error {
    case paused
    case cancelled
}

private struct NativeCommitFailure: Error {
    let underlying: NativeFileError
    let renameCompleted: Bool
}

private final class CopyfileCallbackContext: @unchecked Sendable {
    let signal: ExecutionSignal
    let faults: NativeCopyFaultController
    let path: String
    let call: Int
    private let lock = NSLock()
    private var copied: Int64 = 0
    private var fault: NativeFileError?

    init(
        signal: ExecutionSignal,
        faults: NativeCopyFaultController,
        path: String,
        call: Int
    ) {
        self.signal = signal
        self.faults = faults
        self.path = path
        self.call = call
    }

    func update(copied: Int64) {
        if faults.copyCallbackDelayNanoseconds > 0 {
            var delay = timespec(
                tv_sec: Int(faults.copyCallbackDelayNanoseconds / 1_000_000_000),
                tv_nsec: Int(faults.copyCallbackDelayNanoseconds % 1_000_000_000)
            )
            nanosleep(&delay, nil)
        }
        lock.lock(); defer { lock.unlock() }
        self.copied = max(self.copied, copied)
        if fault == nil {
            fault = faults.failure(.readData, path: path, call: call, byte: self.copied)
                ?? faults.failure(.writeData, path: path, call: call, byte: self.copied)
                ?? faults.failure(.copyData, path: path, call: call, byte: self.copied)
        }
    }

    func snapshot() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return copied
    }

    func injectedFault() -> NativeFileError? {
        lock.lock(); defer { lock.unlock() }
        return fault
    }
}

private let nativeCopyfileCallback: copyfile_callback_t = {
    _, _, state, _, _, context in
    guard let context else { return COPYFILE_QUIT }
    let bridge = Unmanaged<CopyfileCallbackContext>.fromOpaque(context).takeUnretainedValue()
    if let state {
        var copied: off_t = 0
        if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 {
            bridge.update(copied: copied)
        }
    }
    let signal = bridge.signal.snapshot()
    return signal.paused || signal.cancelled || bridge.injectedFault() != nil
        ? COPYFILE_QUIT : COPYFILE_CONTINUE
}

private final class NativeCopyIOQueue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Rascal.NativeCopy.IO", qos: .userInitiated)

    func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

private final class CopyTraversalState {
    var completed: Int64 = 0
    var hardLinks: [String: URL] = [:]
}

package final class NativeCopyExecutor: @unchecked Sendable, OperationExecutor {
    private struct ItemState: Sendable {
        let sourceIdentity: NativeCompositeIdentity
        let staging: URL
        var destination: URL
        var sourceManifest: NativeTreeManifest?
        var stagedManifest: NativeTreeManifest?
    }

    private let registry: NativeCopyWorkspaceRegistry
    private let faults: NativeCopyFaultController
    private let queue = NativeCopyIOQueue()
    private let lock = NSLock()
    private var states: [NativeCopyWorkspaceRegistry.Key: ItemState] = [:]

    package init(
        registry: NativeCopyWorkspaceRegistry,
        faults: NativeCopyFaultController = NativeCopyFaultController()
    ) {
        self.registry = registry
        self.faults = faults
    }

    package func plan(
        _ context: ExecutionContext,
        controls: ExecutionControls
    ) async throws -> ExecutionPlan {
        guard context.request.kind == .copy, let destination = context.destination else {
            throw FileOperationFailure(
                code: .featureDisabled,
                operationID: context.operationID,
                itemID: context.itemID,
                diagnostic: "M2 executor only plans copy requests",
                retryable: false
            )
        }
        await controls.checkpoint()
        guard !(await controls.isCancelled()) else {
            throw FileOperationFailure(
                code: .controlRejected,
                operationID: context.operationID,
                itemID: context.itemID,
                diagnostic: "copy was cancelled before planning",
                retryable: false
            )
        }

        do {
            let sourceIdentity = try NativePathInspector.identity(at: context.source)
            let stage = stagingURL(context: context, destination: destination)
            guard !lstatExists(stage) else {
                throw NativeFileError(
                    code: .recoveryRequired,
                    systemCode: EEXIST,
                    message: "operation staging path already exists"
                )
            }
            let key = key(for: context)
            let item = ItemState(
                sourceIdentity: sourceIdentity,
                staging: stage,
                destination: destination,
                sourceManifest: nil,
                stagedManifest: nil
            )
            try registry.register(.init(
                source: context.source,
                destination: destination,
                staging: stage,
                stagingIdentity: nil,
                committedIdentity: nil,
                commitKnownNotPerformed: false
            ), for: key)
            withStateLock { states[key] = item }
            return ExecutionPlan(sourceDisposition: .noCleanup)
        } catch let native as NativeFileError {
            throw native.failure(
                operationID: context.operationID,
                itemID: context.itemID,
                phase: .preflight
            )
        }
    }

    package func perform(
        _ phase: ExecutionPhase,
        context: ExecutionContext,
        plan: ExecutionPlan,
        controls: ExecutionControls,
        progress: @escaping @Sendable (OperationProgress) async -> Void
    ) async -> ExecutionPhaseOutcome {
        _ = plan
        do {
            switch phase {
            case .staging:
                return try await stage(
                    context: context, controls: controls, progress: progress
                )
            case .metadata:
                return try await verifyMetadata(context: context, controls: controls)
            case .verification:
                return try await verify(context: context, controls: controls)
            case .commit:
                return try await commit(context: context, controls: controls)
            case .sourceCleanup:
                return .failed(FileOperationFailure(
                    code: .invariantViolation,
                    operationID: context.operationID,
                    itemID: context.itemID,
                    diagnostic: "copy executor was asked to clean its source",
                    retryable: false
                ))
            }
        } catch NativeCopyInterruption.cancelled {
            captureStageIdentityIfPresent(context)
            return .cancelled
        } catch NativeCopyInterruption.paused {
            return .failed(FileOperationFailure(
                code: .invariantViolation,
                operationID: context.operationID,
                itemID: context.itemID,
                diagnostic: "pause escaped the staging retry loop",
                retryable: false
            ))
        } catch let native as NativeFileError {
            captureStageIdentityIfPresent(context)
            return .failed(native.failure(
                operationID: context.operationID,
                itemID: context.itemID,
                phase: operationState(for: phase),
                retryable: [.permissionDenied, .noSpace, .volumeDisconnected].contains(native.code)
            ))
        } catch let failure as FileOperationFailure {
            captureStageIdentityIfPresent(context)
            return .failed(failure)
        } catch {
            captureStageIdentityIfPresent(context)
            return .failed(FileOperationFailure(
                code: .invariantViolation,
                operationID: context.operationID,
                itemID: context.itemID,
                phase: operationState(for: phase),
                diagnostic: String(describing: error),
                retryable: false
            ))
        }
    }

    package func recover(
        _ effect: ExecutionRecoveryEffect,
        effectID: UUID,
        context: ExecutionContext,
        receipt: OperationReceiptSummary
    ) async -> ExecutionRecoveryOutcome {
        _ = effectID
        _ = receipt
        return .failedBeforeEffect(FileOperationFailure(
            code: .featureDisabled,
            operationID: context.operationID,
            itemID: context.itemID,
            diagnostic: "M2 volatile copy does not authorize committed-effect recovery",
            retryable: false
        ))
    }

    package func inspectRecoveryEffect(
        _ effect: ExecutionRecoveryEffect,
        effectID: UUID,
        context: ExecutionContext,
        receipt: OperationReceiptSummary
    ) async -> ExecutionRecoveryInspection {
        _ = effect
        _ = effectID
        _ = receipt
        return .unknown(FileOperationFailure(
            code: .recoveryRequired,
            operationID: context.operationID,
            itemID: context.itemID,
            diagnostic: "M2 recovery effect cannot be proven after process loss",
            retryable: false
        ))
    }

    package func inspectCommit(_ context: ExecutionContext) async -> ExecutionCommitInspection {
        guard let state = state(for: context),
              let record = registry.record(for: key(for: context)) else {
            return .unknown(FileOperationFailure(
                code: .recoveryRequired,
                operationID: context.operationID,
                itemID: context.itemID,
                diagnostic: "copy workspace state is unavailable",
                retryable: false
            ))
        }
        let stageExists = lstatExists(state.staging)
        let destinationExists = lstatExists(state.destination)
        if record.commitKnownNotPerformed { return .notCommitted }
        if stageExists, !destinationExists { return .notCommitted }
        if !stageExists, destinationExists,
           let expected = record.committedIdentity,
           let identity = try? NativePathInspector.identity(at: state.destination),
           identity == expected {
            return .committed(receipt(identity: expected))
        }
        return .unknown(FileOperationFailure(
            code: .recoveryRequired,
            operationID: context.operationID,
            itemID: context.itemID,
            diagnostic: "commit paths do not identify a unique outcome",
            retryable: false
        ))
    }

    package func inspectSourceBeforeCleanup(
        _ context: ExecutionContext,
        receipt: OperationReceiptSummary
    ) async -> ExecutionSourceInspection {
        _ = receipt
        guard let expected = state(for: context)?.sourceIdentity else {
            return .unknown(FileOperationFailure(
                code: .recoveryRequired,
                operationID: context.operationID,
                itemID: context.itemID,
                diagnostic: "source identity is unavailable",
                retryable: false
            ))
        }
        do {
            return try NativePathInspector.identity(at: context.source) == expected
                ? .sourcePresentMatching
                : .sourceChanged(FileOperationFailure(
                    code: .sourceChanged,
                    operationID: context.operationID,
                    itemID: context.itemID,
                    diagnostic: "source changed after copy",
                    retryable: false
                ))
        } catch {
            return .unknown(FileOperationFailure(
                code: .recoveryRequired,
                operationID: context.operationID,
                itemID: context.itemID,
                diagnostic: String(describing: error),
                retryable: false
            ))
        }
    }

    private func stage(
        context: ExecutionContext,
        controls: ExecutionControls,
        progress: @escaping @Sendable (OperationProgress) async -> Void
    ) async throws -> ExecutionPhaseOutcome {
        while true {
            guard let initial = state(for: context) else {
                throw NativeFileError(
                    code: .invariantViolation,
                    systemCode: nil,
                    message: "copy item was not planned"
                )
            }
            let includeDigests = context.verificationPolicy == .sha256
            let sourceManifest = try NativeTreeManifest.capture(
                root: context.source,
                includeContentDigests: includeDigests
            )
            updateState(context) { $0.sourceManifest = sourceManifest }

            do {
                try await copyTree(
                    source: context.source,
                    destination: initial.staging,
                    totalBytes: sourceManifest.totalRegularBytes,
                    controls: controls,
                    progress: progress
                )
                let stagedIdentity = try NativePathInspector.identity(at: initial.staging)
                registry.updateStageIdentity(stagedIdentity, for: key(for: context))
                let finalProgress = OperationProgress(
                    bytesCompleted: sourceManifest.totalRegularBytes,
                    bytesTotal: sourceManifest.totalRegularBytes,
                    itemsCompleted: 0,
                    itemsTotal: 1
                )
                await progress(finalProgress)
                return .staged
            } catch NativeCopyInterruption.paused {
                try removeOwnedStageForPause(context)
                await controls.checkpoint()
                if await controls.isCancelled() { throw NativeCopyInterruption.cancelled }
                continue
            }
        }
    }

    private func verifyMetadata(
        context: ExecutionContext,
        controls: ExecutionControls
    ) async throws -> ExecutionPhaseOutcome {
        if faults.metadataPhaseDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: faults.metadataPhaseDelayNanoseconds)
        }
        await controls.checkpoint()
        if await controls.isCancelled() { return .cancelled }
        guard let state = state(for: context), let sourceManifest = state.sourceManifest else {
            throw NativeFileError(
                code: .invariantViolation,
                systemCode: nil,
                message: "metadata phase lacks a source manifest"
            )
        }
        let staged = try NativeTreeManifest.capture(
            root: state.staging,
            includeContentDigests: context.verificationPolicy == .sha256
        )
        updateState(context) { $0.stagedManifest = staged }
        let metadataCall = faults.begin(.applyMetadata, path: state.staging.path)
        if let fault = faults.failure(
            .applyMetadata, path: state.staging.path, call: metadataCall, byte: nil
        ) { throw fault }
        if let mismatch = sourceManifest.firstMismatch(
            against: staged,
            policy: context.verificationPolicy
        ) {
            return .failed(FileOperationFailure(
                code: .unsupportedMetadata,
                operationID: context.operationID,
                itemID: context.itemID,
                phase: .metadata,
                diagnostic: mismatch,
                retryable: false
            ))
        }
        return .metadataApplied(MetadataOutcome(
            preserved: Set(MetadataField.allCases),
            degraded: [],
            unknown: []
        ))
    }

    private func verify(
        context: ExecutionContext,
        controls: ExecutionControls
    ) async throws -> ExecutionPhaseOutcome {
        if faults.verificationPhaseDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: faults.verificationPhaseDelayNanoseconds)
        }
        await controls.checkpoint()
        if await controls.isCancelled() { return .cancelled }
        guard let state = state(for: context) else {
            throw NativeFileError(
                code: .invariantViolation,
                systemCode: nil,
                message: "verification phase lacks copy state"
            )
        }
        try faults.runBeforeVerify(source: context.source)
        let includeDigests = context.verificationPolicy == .sha256
        let source = try NativeTreeManifest.capture(
            root: context.source,
            includeContentDigests: includeDigests
        )
        let staged = try NativeTreeManifest.capture(
            root: state.staging,
            includeContentDigests: includeDigests
        )
        let verifyCall = faults.begin(.verify, path: state.staging.path)
        if let fault = faults.failure(
            .verify, path: state.staging.path, call: verifyCall, byte: nil
        ) { throw fault }
        if let mismatch = source.firstMismatch(against: staged, policy: context.verificationPolicy) {
            return .failed(FileOperationFailure(
                code: .verificationMismatch,
                operationID: context.operationID,
                itemID: context.itemID,
                phase: .verifying,
                diagnostic: mismatch,
                retryable: false
            ))
        }
        guard try NativePathInspector.identity(at: context.source) == state.sourceIdentity else {
            return .failed(FileOperationFailure(
                code: .sourceChanged,
                operationID: context.operationID,
                itemID: context.itemID,
                phase: .verifying,
                diagnostic: "source identity changed during staged copy",
                retryable: true
            ))
        }
        updateState(context) {
            $0.sourceManifest = source
            $0.stagedManifest = staged
        }
        return .verified(VerificationOutcome(
            policy: context.verificationPolicy,
            sourceDigest: includeDigests ? source.digest : nil,
            stagedDigest: includeDigests ? staged.digest : nil,
            manifestDigest: source.digest
        ))
    }

    private func commit(
        context: ExecutionContext,
        controls: ExecutionControls
    ) async throws -> ExecutionPhaseOutcome {
        if await controls.isCancelled() {
            // Core normally rejects cancel once commit begins; this guard keeps
            // the executor from starting the rename if authorization vanished.
            return .cancelled
        }
        guard let state = state(for: context) else {
            throw NativeFileError(
                code: .invariantViolation,
                systemCode: nil,
                message: "commit phase lacks copy state"
            )
        }
        let commitCall = faults.begin(.commit, path: state.destination.path)
        if let fault = faults.failure(
            .commit, path: state.destination.path, call: commitCall, byte: nil
        ) {
            return cleanupBeforeCommitFailure(fault, context: context)
        }
        do {
            try faults.runBeforeCommit(destination: state.destination)
        } catch let native as NativeFileError {
            return cleanupBeforeCommitFailure(native, context: context)
        } catch {
            return cleanupBeforeCommitFailure(
                NativeFileError(
                    code: .invariantViolation,
                    systemCode: nil,
                    message: "before-commit hook failed: \(error)"
                ),
                context: context
            )
        }
        var finalDestination = state.destination
        while true {
            do {
                try await performExclusiveCommit(
                    staging: state.staging,
                    destination: finalDestination
                )
                break
            } catch let failure as NativeCommitFailure {
                if failure.renameCompleted {
                    if let identity = try? NativePathInspector.identity(at: finalDestination) {
                        registry.markCommitted(identity, for: key(for: context))
                    }
                    return .recoveryRequired(failure.underlying.failure(
                        operationID: context.operationID,
                        itemID: context.itemID,
                        phase: .committing,
                        retryable: false
                    ))
                }
                if context.request.conflictPolicy == .keepBoth &&
                    (failure.underlying.systemCode == EEXIST ||
                     failure.underlying.systemCode == ENOTEMPTY) {
                    let bases = RequestValidator.projectedDestinations(context.request)
                    guard bases.indices.contains(context.itemIndex),
                          let base = bases[context.itemIndex] else {
                        return cleanupBeforeCommitFailure(failure.underlying, context: context)
                    }
                    finalDestination = nextKeepBothDestination(for: base)
                    updateState(context) { $0.destination = finalDestination }
                    registry.updateDestination(finalDestination, for: key(for: context))
                    continue
                }
                return cleanupBeforeCommitFailure(failure.underlying, context: context)
            }
        }
        let identity = try NativePathInspector.identity(at: finalDestination)
        registry.markCommitted(identity, for: key(for: context))
        let result = receipt(identity: identity)
        return finalDestination == context.destination
            ? .committed(result)
            : .committedAt(result, finalDestination)
    }

    private func performExclusiveCommit(staging: URL, destination: URL) async throws {
        try await queue.run {
            var renameCompleted = false
            do {
                try Self.fsyncTree(staging)
                let parent = destination.deletingLastPathComponent()
                guard staging.deletingLastPathComponent().standardizedFileURL ==
                        parent.standardizedFileURL else {
                    throw NativeFileError(
                        code: .invariantViolation,
                        systemCode: nil,
                        message: "staging and destination must share one commit directory"
                    )
                }
                let parentHandle = try NativeDirectoryHandle.openAnchored(parent)
                let parentFD = parentHandle.fileDescriptor
                guard renameatx_np(
                    parentFD, staging.lastPathComponent,
                    parentFD, destination.lastPathComponent,
                    UInt32(RENAME_EXCL)
                ) == 0 else {
                    throw NativeFileError.fromErrno(
                        errno,
                        path: destination.path,
                        operation: "exclusive commit rename"
                    )
                }
                renameCompleted = true
                guard fsync(parentFD) == 0 else {
                    throw NativeFileError.fromErrno(
                        errno, path: parent.path, operation: "fsync commit parent"
                    )
                }
            } catch let native as NativeFileError {
                throw NativeCommitFailure(
                    underlying: native,
                    renameCompleted: renameCompleted
                )
            }
        }
    }

    private func nextKeepBothDestination(for base: URL) -> URL {
        let parent = base.deletingLastPathComponent()
        let extensionName = base.pathExtension
        let stem = extensionName.isEmpty
            ? base.lastPathComponent
            : base.deletingPathExtension().lastPathComponent
        for suffix in 1...10_000 {
            let label = suffix == 1 ? "\(stem) copy" : "\(stem) copy \(suffix)"
            let candidate = parent.appendingPathComponent(label)
                .appendingPathExtension(extensionName)
            if !lstatExists(candidate) { return candidate }
        }
        return parent.appendingPathComponent("\(stem) copy \(UUID().uuidString)")
            .appendingPathExtension(extensionName)
    }

    private func cleanupBeforeCommitFailure(
        _ failure: NativeFileError,
        context: ExecutionContext
    ) -> ExecutionPhaseOutcome {
        do {
            try removeOwnedStage(context)
            return .recoveryRequired(failure.failure(
                operationID: context.operationID,
                itemID: context.itemID,
                phase: .committing,
                retryable: [
                    FileOperationErrorCode.permissionDenied,
                    .noSpace,
                    .volumeDisconnected,
                    .destinationChanged
                ].contains(failure.code)
            ))
        } catch let cleanup as NativeFileError {
            return .recoveryRequired(cleanup.failure(
                operationID: context.operationID,
                itemID: context.itemID,
                phase: .committing,
                retryable: false
            ))
        } catch {
            return .recoveryRequired(FileOperationFailure(
                code: .recoveryRequired,
                operationID: context.operationID,
                itemID: context.itemID,
                phase: .committing,
                diagnostic: "commit failed and staging cleanup could not be proven: \(error)",
                retryable: false
            ))
        }
    }

    private func copyTree(
        source: URL,
        destination: URL,
        totalBytes: Int64,
        controls: ExecutionControls,
        progress: @escaping @Sendable (OperationProgress) async -> Void
    ) async throws {
        let traversal = CopyTraversalState()
        try await copyNode(
            source: source,
            destination: destination,
            totalBytes: totalBytes,
            traversal: traversal,
            controls: controls,
            progress: progress
        )
    }

    private func copyNode(
        source: URL,
        destination: URL,
        totalBytes: Int64,
        traversal: CopyTraversalState,
        controls: ExecutionControls,
        progress: @escaping @Sendable (OperationProgress) async -> Void
    ) async throws {
        await controls.checkpoint()
        let signal = await controls.callbackSignal()
        let signalState = signal.snapshot()
        if signalState.cancelled { throw NativeCopyInterruption.cancelled }
        if signalState.paused { throw NativeCopyInterruption.paused }

        var info = stat()
        guard lstat(source.path, &info) == 0 else {
            throw NativeFileError.fromErrno(errno, path: source.path, operation: "copy lstat")
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            let enumerateCall = faults.begin(.enumerate, path: source.path)
            if let fault = faults.failure(
                .enumerate, path: source.path, call: enumerateCall, byte: nil
            ) { throw fault }
            try await queue.run {
                let entry = try NativeAnchoredEntry.openParent(of: destination)
                guard mkdirat(entry.parent.fileDescriptor, entry.name, 0o700) == 0 else {
                    throw NativeFileError.fromErrno(
                        errno, path: destination.path, operation: "create staging directory"
                    )
                }
            }
            let names = try FileManager.default.contentsOfDirectory(atPath: source.path)
                .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            for name in names {
                try await copyNode(
                    source: source.appendingPathComponent(name),
                    destination: destination.appendingPathComponent(name),
                    totalBytes: totalBytes,
                    traversal: traversal,
                    controls: controls,
                    progress: progress
                )
            }
            try await copyWithCopyfile(
                source: source,
                destination: destination,
                flags: copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW),
                signal: signal,
                baseCompleted: traversal.completed,
                totalBytes: totalBytes,
                progress: progress
            )
        case S_IFREG:
            let hardLinkKey = "\(info.st_dev):\(info.st_ino)"
            if info.st_nlink > 1, let leader = traversal.hardLinks[hardLinkKey] {
                try await queue.run {
                    let sourceEntry = try NativeAnchoredEntry.openParent(of: leader)
                    let destinationEntry = try NativeAnchoredEntry.openParent(of: destination)
                    guard linkat(
                        sourceEntry.parent.fileDescriptor, sourceEntry.name,
                        destinationEntry.parent.fileDescriptor, destinationEntry.name,
                        0
                    ) == 0 else {
                        throw NativeFileError.fromErrno(
                            errno, path: destination.path, operation: "preserve hard link"
                        )
                    }
                }
            } else {
                try await copyWithCopyfile(
                    source: source,
                    destination: destination,
                    flags: copyfile_flags_t(
                        COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW | COPYFILE_DATA_SPARSE
                    ),
                    signal: signal,
                    baseCompleted: traversal.completed,
                    totalBytes: totalBytes,
                    progress: progress
                )
                if info.st_nlink > 1 { traversal.hardLinks[hardLinkKey] = destination }
            }
            traversal.completed += info.st_size
            await progress(OperationProgress(
                bytesCompleted: traversal.completed,
                bytesTotal: totalBytes,
                itemsCompleted: 0,
                itemsTotal: 1
            ))
        case S_IFLNK:
            try await copyWithCopyfile(
                source: source,
                destination: destination,
                flags: copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW),
                signal: signal,
                baseCompleted: traversal.completed,
                totalBytes: totalBytes,
                progress: progress
            )
        default:
            throw NativeFileError(
                code: .featureDisabled,
                systemCode: nil,
                message: "unsupported filesystem node at \(source.path)"
            )
        }
    }

    private func copyWithCopyfile(
        source: URL,
        destination: URL,
        flags: copyfile_flags_t,
        signal: ExecutionSignal,
        baseCompleted: Int64,
        totalBytes: Int64,
        progress: @escaping @Sendable (OperationProgress) async -> Void
    ) async throws {
        let copyCall = faults.begin(.copyData, path: source.path)
        if let fault = faults.failure(
            .copyData, path: source.path, call: copyCall, byte: nil
        ) { throw fault }
        let callbackContext = CopyfileCallbackContext(
            signal: signal, faults: faults, path: source.path, call: copyCall
        )
        let monitor = Task {
            while !Task.isCancelled {
                await progress(OperationProgress(
                    bytesCompleted: min(totalBytes, baseCompleted + callbackContext.snapshot()),
                    bytesTotal: totalBytes,
                    itemsCompleted: 0,
                    itemsTotal: 1
                ))
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        defer { monitor.cancel() }

        do {
            try await queue.run {
                guard let state = copyfile_state_alloc() else {
                    throw NativeFileError(
                        code: .invariantViolation,
                        systemCode: nil,
                        message: "copyfile_state_alloc failed"
                    )
                }
                defer { copyfile_state_free(state) }
                // copyfile_state_set stores the callback's function-pointer
                // value. Passing `&callback` would store a temporary stack
                // address and crash when libcopyfile invokes it later.
                let callbackPointer = unsafeBitCast(
                    nativeCopyfileCallback, to: UnsafeRawPointer.self
                )
                let callbackStatus = copyfile_state_set(
                    state, UInt32(COPYFILE_STATE_STATUS_CB), callbackPointer
                )
                guard callbackStatus == 0 else {
                    throw NativeFileError.fromErrno(
                        errno, path: source.path, operation: "configure copyfile callback"
                    )
                }
                let opaque = Unmanaged.passUnretained(callbackContext).toOpaque()
                guard copyfile_state_set(
                    state, UInt32(COPYFILE_STATE_STATUS_CTX), opaque
                ) == 0 else {
                    throw NativeFileError.fromErrno(
                        errno, path: source.path, operation: "configure copyfile context"
                    )
                }
                let sourceInfo = try NativePathInspector.identity(at: source)
                let copyStatus: Int32
                if sourceInfo.mode & UInt32(S_IFMT) == UInt32(S_IFREG) {
                    let sourceEntry = try NativeAnchoredEntry.openParent(of: source)
                    let destinationEntry = try NativeAnchoredEntry.openParent(of: destination)
                    let sourceFD = openat(
                        sourceEntry.parent.fileDescriptor,
                        sourceEntry.name,
                        O_RDONLY | O_NOFOLLOW
                    )
                    guard sourceFD >= 0 else {
                        throw NativeFileError.fromErrno(
                            errno, path: source.path, operation: "open anchored copy source"
                        )
                    }
                    defer { close(sourceFD) }
                    let destinationFD = openat(
                        destinationEntry.parent.fileDescriptor,
                        destinationEntry.name,
                        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                        mode_t(0o600)
                    )
                    guard destinationFD >= 0 else {
                        throw NativeFileError.fromErrno(
                            errno, path: destination.path,
                            operation: "open exclusive anchored staging file"
                        )
                    }
                    defer { close(destinationFD) }
                    var openedSource = stat()
                    guard fstat(sourceFD, &openedSource) == 0 else {
                        throw NativeFileError.fromErrno(
                            errno, path: source.path, operation: "fstat anchored copy source"
                        )
                    }
                    guard UInt64(openedSource.st_dev) == sourceInfo.device,
                          UInt64(openedSource.st_ino) == sourceInfo.inode,
                          UInt32(openedSource.st_mode) == sourceInfo.mode else {
                        throw NativeFileError(
                            code: .sourceChanged,
                            systemCode: nil,
                            message: "source changed while opening anchored copy descriptor"
                        )
                    }
                    let descriptorFlags = flags & ~copyfile_flags_t(COPYFILE_EXCL)
                    copyStatus = fcopyfile(sourceFD, destinationFD, state, descriptorFlags)
                } else {
                    copyStatus = copyfile(source.path, destination.path, state, flags)
                }
                guard copyStatus == 0 else {
                    if let fault = callbackContext.injectedFault() { throw fault }
                    let state = signal.snapshot()
                    if state.cancelled { throw NativeCopyInterruption.cancelled }
                    if state.paused { throw NativeCopyInterruption.paused }
                    throw NativeFileError.fromErrno(
                        errno, path: source.path, operation: "copyfile"
                    )
                }
                try Self.applyCreationTime(source: source, destination: destination)
            }
        } catch {
            throw error
        }
    }

    private func removeOwnedStageForPause(_ context: ExecutionContext) throws {
        try removeOwnedStage(context)
    }

    private func removeOwnedStage(_ context: ExecutionContext) throws {
        guard let state = state(for: context) else { return }
        guard lstatExists(state.staging) else {
            registry.updateStageIdentity(nil, for: key(for: context))
            return
        }
        let actual = try NativePathInspector.identity(at: state.staging)
        if let expected = registry.record(for: key(for: context))?.stagingIdentity,
           actual != expected {
            throw NativeFileError(
                code: .recoveryRequired,
                systemCode: nil,
                message: "staging identity changed before cleanup"
            )
        }
        try FileManager.default.removeItem(at: state.staging)
        guard !lstatExists(state.staging) else {
            throw NativeFileError(
                code: .recoveryRequired,
                systemCode: nil,
                message: "staging still exists after cleanup"
            )
        }
        registry.updateStageIdentity(nil, for: key(for: context))
        registry.markCommitNotPerformed(for: key(for: context))
    }

    private func captureStageIdentityIfPresent(_ context: ExecutionContext) {
        guard let stage = state(for: context)?.staging, lstatExists(stage),
              let identity = try? NativePathInspector.identity(at: stage) else { return }
        registry.updateStageIdentity(identity, for: key(for: context))
    }

    private func stagingURL(context: ExecutionContext, destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(
            ".rascal-stage-\(context.operationID.rawValue.uuidString.lowercased())-" +
            context.itemID.rawValue.uuidString.lowercased()
        )
    }

    private func key(for context: ExecutionContext) -> NativeCopyWorkspaceRegistry.Key {
        .init(operationID: context.operationID, itemID: context.itemID)
    }

    private func state(for context: ExecutionContext) -> ItemState? {
        withStateLock { states[key(for: context)] }
    }

    private func updateState(_ context: ExecutionContext, _ body: (inout ItemState) -> Void) {
        withStateLock {
            let key = key(for: context)
            guard var state = states[key] else { return }
            body(&state)
            states[key] = state
        }
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    private func receipt(identity: NativeCompositeIdentity) -> OperationReceiptSummary {
        OperationReceiptSummary(
            committedIdentityDigest: identity.digest,
            backupURL: nil,
            quarantineURL: nil,
            sourceCleanupPending: false
        )
    }

    private func operationState(for phase: ExecutionPhase) -> OperationState {
        switch phase {
        case .staging: return .staging
        case .metadata: return .metadata
        case .verification: return .verifying
        case .commit: return .committing
        case .sourceCleanup: return .cleaningSource
        }
    }

    private static func fsyncTree(_ root: URL) throws {
        var info = stat()
        guard lstat(root.path, &info) == 0 else {
            throw NativeFileError.fromErrno(errno, path: root.path, operation: "fsync lstat")
        }
        if (info.st_mode & S_IFMT) == S_IFDIR {
            for name in try FileManager.default.contentsOfDirectory(atPath: root.path) {
                try fsyncTree(root.appendingPathComponent(name))
            }
        }
        guard (info.st_mode & S_IFMT) != S_IFLNK else { return }
        let flags = (info.st_mode & S_IFMT) == S_IFDIR
            ? O_RDONLY | O_DIRECTORY | O_NOFOLLOW
            : O_RDONLY | O_NOFOLLOW
        let fd = open(root.path, flags)
        guard fd >= 0 else {
            throw NativeFileError.fromErrno(errno, path: root.path, operation: "fsync open")
        }
        defer { close(fd) }
        guard fsync(fd) == 0 else {
            throw NativeFileError.fromErrno(errno, path: root.path, operation: "fsync")
        }
    }

    /// copyfile preserves most stat metadata but does not reliably preserve
    /// APFS birth time when the destination object was newly created (or when
    /// directory metadata is applied to an existing staging directory).
    private static func applyCreationTime(source: URL, destination: URL) throws {
        var sourceInfo = stat()
        guard lstat(source.path, &sourceInfo) == 0 else {
            throw NativeFileError.fromErrno(
                errno, path: source.path, operation: "read creation time"
            )
        }
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
        var creation = sourceInfo.st_birthtimespec
        let options = (sourceInfo.st_mode & S_IFMT) == S_IFLNK
            ? UInt32(FSOPT_NOFOLLOW)
            : 0
        let result = withUnsafePointer(to: &creation) { pointer in
            setattrlist(
                destination.path,
                &attributes,
                UnsafeMutableRawPointer(mutating: pointer),
                MemoryLayout<timespec>.size,
                options
            )
        }
        guard result == 0 else {
            throw NativeFileError.fromErrno(
                errno, path: destination.path, operation: "apply creation time"
            )
        }
    }
}
