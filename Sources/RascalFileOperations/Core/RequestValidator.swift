import Foundation

package enum RequestValidator {
    package static func validate(_ request: OperationRequest) throws {
        guard request.schemaVersion == 1 else { throw failure("unsupported request schema") }
        guard !request.sources.isEmpty else { throw failure("sources must not be empty") }
        for source in request.sources {
            guard source.isFileURL, source.path.hasPrefix("/") else {
                throw failure("sources must be absolute file URLs")
            }
        }
        if let destination = request.destination {
            guard destination.isFileURL, destination.path.hasPrefix("/") else {
                throw failure("destination must be an absolute file URL")
            }
        }

        let sourcePaths = request.sources.map(normalizedPath)
        guard Set(sourcePaths).count == sourcePaths.count else {
            throw failure("duplicate normalized source URL")
        }

        switch request.kind {
        case .copy:
            try requireDestination(request, modes: [.container, .exact])
            if request.destinationMode == .exact && request.sources.count != 1 {
                throw failure("exact copy requires one source")
            }
            guard request.createDescriptor == nil else { throw failure("copy cannot include create descriptor") }
        case .move:
            try requireDestination(request, modes: [.container, .exact])
            if request.destinationMode == .exact && request.sources.count != 1 {
                throw failure("exact move requires one source")
            }
            guard request.createDescriptor == nil else { throw failure("move cannot include create descriptor") }
        case .rename, .replace:
            try requireDestination(request, modes: [.exact])
            guard request.sources.count == 1 else { throw failure("rename/replace requires one source") }
            guard request.createDescriptor == nil else { throw failure("rename/replace cannot include create descriptor") }
            if request.kind == .rename, let destination = request.destination,
               normalizedPath(request.sources[0].deletingLastPathComponent()) !=
                normalizedPath(destination.deletingLastPathComponent()) {
                throw failure("rename requires source and destination in the same parent directory")
            }
        case .merge:
            try requireDestination(request, modes: [.exactDirectory])
            guard request.createDescriptor == nil else { throw failure("merge cannot include create descriptor") }
        case .trash:
            guard request.destination == nil, request.destinationMode == nil,
                  request.createDescriptor == nil else { throw failure("trash does not accept destination") }
        case .create:
            guard request.destination == nil, request.destinationMode == nil,
                  request.createDescriptor != nil else { throw failure("create requires descriptor and no destination") }
        }

        // Portable policy is a service-issued capability, never a caller-selectable request.
        if case .portable = request.metadataPolicy { throw failure("portable policy requires a decision approval") }

        if let destination = request.destination {
            let projected = projectedDestinations(request).compactMap { $0 }.map(normalizedPath)
            let targetPaths = request.destinationMode == .container
                ? projected : [normalizedPath(destination)]
            for src in sourcePaths {
                for target in targetPaths {
                    // Container copy into the source's current parent initially
                    // projects to the same path. Conflict preflight must decide
                    // keep-both/skip/stop before staging; it is not a recursive
                    // descendant copy and must remain available for Duplicate.
                    if src == target, request.destinationMode == .container { continue }
                    if src == target || isAncestor(src, of: target) ||
                        isAncestor(target, of: src) {
                        throw failure("source and destination overlap")
                    }
                }
            }
        }
    }

    package static func projectedDestinations(_ request: OperationRequest) -> [URL?] {
        guard let destination = request.destination else { return Array(repeating: nil, count: request.sources.count) }
        if request.destinationMode == .exact { return [destination] }
        return request.sources.map { destination.appendingPathComponent($0.lastPathComponent) }
    }

    private static func requireDestination(_ request: OperationRequest, modes: Set<DestinationMode>) throws {
        guard request.destination != nil, let mode = request.destinationMode, modes.contains(mode) else {
            throw failure("operation requires a valid destination mode")
        }
    }

    private static func normalizedPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func isAncestor(_ candidate: String, of path: String) -> Bool {
        candidate == "/" ? path != "/" : path.hasPrefix(candidate + "/")
    }

    private static func failure(_ diagnostic: String) -> FileOperationFailure {
        FileOperationFailure(code: .validation, diagnostic: diagnostic, retryable: false)
    }
}
