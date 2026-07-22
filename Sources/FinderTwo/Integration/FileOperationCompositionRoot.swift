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
            let clock = ContinuousClock()
            var consecutiveResyncs = 0
            while !Task.isCancelled {
                let subscriptionStartedAt = clock.now
                let stream = await service.events()
                for await event in stream {
                    guard !Task.isCancelled else { return }
                    if let snapshot = try? await service.snapshot(event.operationID) {
                        self?.snapshots[event.operationID] = snapshot
                    }
                }
                // Measure only the subscription lifetime. Snapshot rebuilding
                // can be slow and must not make an immediately failing stream
                // appear healthy or reset its failure budget.
                let subscriptionLifetime = subscriptionStartedAt.duration(to: clock.now)
                // EOF means overflow/resync, never a successful completion marker.
                let knownIDs = self.map { Set($0.snapshots.keys) } ?? Set<OperationID>()
                self?.snapshots.removeAll()
                for id in knownIDs {
                    guard !Task.isCancelled else { return }
                    if let snapshot = try? await service.snapshot(id) {
                        self?.snapshots[id] = snapshot
                    }
                }
                // Receiving one replay page is not evidence of a healthy
                // subscription: a journal that repeatedly fails on page two
                // must still back off. Only a stream that remained healthy for
                // a sustained interval resets the failure budget.
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
