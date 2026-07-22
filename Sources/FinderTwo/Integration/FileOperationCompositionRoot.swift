import Foundation
import RascalFileOperations

@MainActor
final class FileOperationBridge {
    let service: FileOperationService
    private var eventTask: Task<Void, Never>?
    private(set) var snapshots: [OperationID: OperationSnapshot] = [:]

    init(service: FileOperationService) {
        self.service = service
        eventTask = Task { [weak self, service] in
            while !Task.isCancelled {
                let stream = await service.events()
                for await event in stream {
                    guard !Task.isCancelled else { return }
                    if let snapshot = try? await service.snapshot(event.operationID) {
                        self?.snapshots[event.operationID] = snapshot
                    }
                }
                // EOF means overflow/resync, never a successful completion marker.
                self?.snapshots.removeAll()
            }
        }
    }

    deinit { eventTask?.cancel() }
}

@MainActor
final class FileOperationCompositionRoot {
    let service: FileOperationService
    let bridge: FileOperationBridge

    init() throws {
        let service = try FileOperationService(configuration: .default)
        self.service = service
        self.bridge = FileOperationBridge(service: service)
    }
}
