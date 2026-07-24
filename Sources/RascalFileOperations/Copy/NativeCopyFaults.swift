import Foundation

package enum NativeCopyFaultPoint: String, Sendable, Hashable {
    case enumerate
    case copyData
    case readData
    case writeData
    case applyMetadata
    case verify
    case commit
    case cleanup
}

package struct NativeCopyFaultRule: Sendable {
    package let point: NativeCopyFaultPoint
    package let pathSuffix: String?
    package let pathContains: String?
    package let call: Int?
    package let byte: Int64?
    package let code: FileOperationErrorCode
    package let systemCode: Int32?

    package init(
        point: NativeCopyFaultPoint,
        pathSuffix: String? = nil,
        pathContains: String? = nil,
        call: Int? = nil,
        byte: Int64? = nil,
        code: FileOperationErrorCode,
        systemCode: Int32? = nil
    ) {
        self.point = point
        self.pathSuffix = pathSuffix
        self.pathContains = pathContains
        self.call = call
        self.byte = byte
        self.code = code
        self.systemCode = systemCode
    }
}

package final class NativeCopyFaultController: @unchecked Sendable {
    private struct CounterKey: Hashable {
        let point: NativeCopyFaultPoint
        let path: String
    }

    private let lock = NSLock()
    private let rules: [NativeCopyFaultRule]
    private let beforeCommit: (@Sendable (URL) throws -> Void)?
    private let beforeVerify: (@Sendable (URL) throws -> Void)?
    private let beforeMetadata: (@Sendable (URL) throws -> Void)?
    private let beforeDataCopy: (@Sendable (URL) throws -> Void)?
    private let beforeStageRootCreate: (@Sendable () throws -> Void)?
    private let afterCommitParentOpen: (@Sendable (URL) throws -> Void)?
    private let beforeCleanupDelete: (@Sendable () throws -> Void)?
    private let beforeCommitRename: (@Sendable (URL) throws -> Void)?
    private let beforeCleanupNodeUnlink: (@Sendable (String, URL) throws -> Void)?
    private let afterVerify: (@Sendable () -> Void)?
    private let onDataProgress: (@Sendable (String, Int64) -> Void)?
    private let afterNodeCopied: (@Sendable (URL) -> Void)?
    package let copyCallbackDelayNanoseconds: UInt64
    package let metadataPhaseDelayNanoseconds: UInt64
    package let verificationPhaseDelayNanoseconds: UInt64
    package let postVerificationDelayNanoseconds: UInt64
    private var counters: [CounterKey: Int] = [:]
    private var ruleHits: [Int: Int] = [:]
    private var nativeSystemFailures: [NativeCopyFaultPoint: [Int32]] = [:]
    private var maxDataProgressByPath: [String: Int64] = [:]
    private var copiedNodeCounts: [String: Int] = [:]
    private var metadataCheckpointHits = 0

    package init(
        rules: [NativeCopyFaultRule] = [],
        copyCallbackDelayNanoseconds: UInt64 = 0,
        metadataPhaseDelayNanoseconds: UInt64 = 0,
        verificationPhaseDelayNanoseconds: UInt64 = 0,
        postVerificationDelayNanoseconds: UInt64 = 0,
        beforeCommit: (@Sendable (URL) throws -> Void)? = nil,
        beforeVerify: (@Sendable (URL) throws -> Void)? = nil,
        beforeMetadata: (@Sendable (URL) throws -> Void)? = nil,
        beforeDataCopy: (@Sendable (URL) throws -> Void)? = nil,
        beforeStageRootCreate: (@Sendable () throws -> Void)? = nil,
        afterCommitParentOpen: (@Sendable (URL) throws -> Void)? = nil,
        beforeCleanupDelete: (@Sendable () throws -> Void)? = nil,
        beforeCommitRename: (@Sendable (URL) throws -> Void)? = nil,
        beforeCleanupNodeUnlink: (@Sendable (String, URL) throws -> Void)? = nil,
        afterVerify: (@Sendable () -> Void)? = nil,
        onDataProgress: (@Sendable (String, Int64) -> Void)? = nil,
        afterNodeCopied: (@Sendable (URL) -> Void)? = nil
    ) {
        self.rules = rules
        self.copyCallbackDelayNanoseconds = copyCallbackDelayNanoseconds
        self.metadataPhaseDelayNanoseconds = metadataPhaseDelayNanoseconds
        self.verificationPhaseDelayNanoseconds = verificationPhaseDelayNanoseconds
        self.postVerificationDelayNanoseconds = postVerificationDelayNanoseconds
        self.beforeCommit = beforeCommit
        self.beforeVerify = beforeVerify
        self.beforeMetadata = beforeMetadata
        self.beforeDataCopy = beforeDataCopy
        self.beforeStageRootCreate = beforeStageRootCreate
        self.afterCommitParentOpen = afterCommitParentOpen
        self.beforeCleanupDelete = beforeCleanupDelete
        self.beforeCommitRename = beforeCommitRename
        self.beforeCleanupNodeUnlink = beforeCleanupNodeUnlink
        self.afterVerify = afterVerify
        self.onDataProgress = onDataProgress
        self.afterNodeCopied = afterNodeCopied
    }

    package func begin(_ point: NativeCopyFaultPoint, path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        let key = CounterKey(point: point, path: path)
        let next = counters[key, default: 0] + 1
        counters[key] = next
        return next
    }

    package func failure(
        _ point: NativeCopyFaultPoint,
        path: String,
        call: Int,
        byte: Int64?
    ) -> NativeFileError? {
        lock.lock(); defer { lock.unlock() }
        guard let index = rules.firstIndex(where: {
            $0.point == point &&
                ($0.pathSuffix == nil || path.hasSuffix($0.pathSuffix!)) &&
                ($0.pathContains == nil || path.contains($0.pathContains!)) &&
                ($0.call == nil || $0.call == call) &&
                ($0.byte == nil || (byte != nil && byte! >= $0.byte!))
        }) else { return nil }
        ruleHits[index, default: 0] += 1
        let rule = rules[index]
        return NativeFileError(
            code: rule.code,
            systemCode: rule.systemCode,
            message: "injected \(point.rawValue) failure for \(path) " +
                "at call \(call) byte \(byte.map(String.init) ?? "-")"
        )
    }

    package func hitCount(ruleIndex: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        return ruleHits[ruleIndex, default: 0]
    }

    package func runBeforeCommit(destination: URL) throws {
        try beforeCommit?(destination)
    }

    package func runBeforeVerify(source: URL) throws {
        try beforeVerify?(source)
    }

    package func runBeforeMetadata(staging: URL) throws {
        lock.withLock { metadataCheckpointHits += 1 }
        try beforeMetadata?(staging)
    }

    package func beforeMetadataHitCount() -> Int {
        lock.withLock { metadataCheckpointHits }
    }

    package func runBeforeDataCopy(destination: URL) throws {
        try beforeDataCopy?(destination)
    }

    package func runBeforeStageRootCreate() throws {
        try beforeStageRootCreate?()
    }

    package func runAfterCommitParentOpen(parent: URL) throws {
        try afterCommitParentOpen?(parent)
    }

    package func runBeforeCleanupDelete() throws {
        try beforeCleanupDelete?()
    }

    package func runBeforeCommitRename(staging: URL) throws {
        try beforeCommitRename?(staging)
    }

    package func runBeforeCleanupNodeUnlink(
        relativePath: String,
        node: URL
    ) throws {
        try beforeCleanupNodeUnlink?(relativePath, node)
    }

    package func recordDataProgress(path: String, bytes: Int64) {
        lock.withLock {
            maxDataProgressByPath[path] = max(maxDataProgressByPath[path, default: 0], bytes)
        }
        onDataProgress?(path, bytes)
    }

    package func maximumDataProgress(pathSuffix: String) -> Int64 {
        lock.withLock {
            maxDataProgressByPath
                .filter { $0.key.hasSuffix(pathSuffix) }
                .map(\.value)
                .max() ?? 0
        }
    }

    package func runAfterNodeCopied(source: URL) {
        lock.withLock {
            copiedNodeCounts[source.path, default: 0] += 1
        }
        afterNodeCopied?(source)
    }

    package func copiedNodeCount(pathSuffix: String) -> Int {
        lock.withLock {
            copiedNodeCounts
                .filter { $0.key.hasSuffix(pathSuffix) }
                .map(\.value)
                .reduce(0, +)
        }
    }

    package func recordNativeSystemFailure(
        _ point: NativeCopyFaultPoint,
        systemCode: Int32
    ) {
        lock.withLock {
            nativeSystemFailures[point, default: []].append(systemCode)
        }
    }

    package func nativeSystemFailureCodes(
        at point: NativeCopyFaultPoint
    ) -> [Int32] {
        lock.withLock { nativeSystemFailures[point, default: []] }
    }

    package func runAfterVerify() {
        afterVerify?()
    }
}
