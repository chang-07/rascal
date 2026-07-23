import Foundation
import RascalFileOperations

enum NativeCopyFeatureGate {
    static var enabled: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment["RASCAL_ENABLE_M2_NATIVE_COPY"] == "1"
#else
        false
#endif
    }
}

@MainActor
final class FileOperationCompositionRoot {
    let service: FileOperationService
    let bridge: FileOperationBridge

    init() throws {
        let enabled = NativeCopyFeatureGate.enabled
        let service: FileOperationService
        if enabled, let native = try? FileOperationService.makeVolatileNativeCopy() {
            service = native
        } else {
            // If native construction itself fails, retain the enabled bridge
            // over the unavailable graph so the UI reports a typed failure and
            // cannot silently fall back to legacy copy.
            service = try FileOperationService(configuration: .default)
        }
        self.service = service
        self.bridge = FileOperationBridge(
            service: service,
            nativeCopyEnabled: enabled
        )
    }
}
