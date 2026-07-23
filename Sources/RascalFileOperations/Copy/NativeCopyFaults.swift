import Foundation

package enum NativeCopyFaultPoint: String, Sendable, Hashable {
    case enumerate
    case copyData
    case readData
    case writeData
    case applyMetadata
    case verify
    case commit
}

package struct NativeCopyFaultRule: Sendable {
    package let point: NativeCopyFaultPoint
    package let pathSuffix: String?
    package let call: Int?
    package let byte: Int64?
    package let code: FileOperationErrorCode
    package let systemCode: Int32?

    package init(
        point: NativeCopyFaultPoint,
        pathSuffix: String? = nil,
        call: Int? = nil,
        byte: Int64? = nil,
        code: FileOperationErrorCode,
        systemCode: Int32? = nil
    ) {
        self.point = point
        self.pathSuffix = pathSuffix
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
    package let copyCallbackDelayNanoseconds: UInt64
    package let metadataPhaseDelayNanoseconds: UInt64
    package let verificationPhaseDelayNanoseconds: UInt64
    private var counters: [CounterKey: Int] = [:]

    package init(
        rules: [NativeCopyFaultRule] = [],
        copyCallbackDelayNanoseconds: UInt64 = 0,
        metadataPhaseDelayNanoseconds: UInt64 = 0,
        verificationPhaseDelayNanoseconds: UInt64 = 0,
        beforeCommit: (@Sendable (URL) throws -> Void)? = nil,
        beforeVerify: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.rules = rules
        self.copyCallbackDelayNanoseconds = copyCallbackDelayNanoseconds
        self.metadataPhaseDelayNanoseconds = metadataPhaseDelayNanoseconds
        self.verificationPhaseDelayNanoseconds = verificationPhaseDelayNanoseconds
        self.beforeCommit = beforeCommit
        self.beforeVerify = beforeVerify
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
        guard let rule = rules.first(where: {
            $0.point == point &&
                ($0.pathSuffix == nil || path.hasSuffix($0.pathSuffix!)) &&
                ($0.call == nil || $0.call == call) &&
                ($0.byte == nil || (byte != nil && byte! >= $0.byte!))
        }) else { return nil }
        return NativeFileError(
            code: rule.code,
            systemCode: rule.systemCode,
            message: "injected \(point.rawValue) failure for \(path) " +
                "at call \(call) byte \(byte.map(String.init) ?? "-")"
        )
    }

    package func runBeforeCommit(destination: URL) throws {
        try beforeCommit?(destination)
    }

    package func runBeforeVerify(source: URL) throws {
        try beforeVerify?(source)
    }
}
