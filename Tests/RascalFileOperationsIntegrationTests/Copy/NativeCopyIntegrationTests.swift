import XCTest
import Foundation
import Darwin
@testable import RascalFileOperations
import RascalFileOperationsTestSupport

final class NativeCopyIntegrationTests: XCTestCase {
    func testConfiguredDistinctAPFSVolumeMatrix() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sourceMount = environment["RASCAL_M2_APFS_SOURCE"],
              let destinationMount = environment["RASCAL_M2_APFS_DESTINATION"] else {
            return
        }
        let sourceVolume = URL(fileURLWithPath: sourceMount, isDirectory: true)
        let destinationVolume = URL(fileURLWithPath: destinationMount, isDirectory: true)
        let metadataEvidenceDirectory = environment["RASCAL_M2_METADATA_EVIDENCE_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        let sourceUUID = try XCTUnwrap(
            sourceVolume.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        )
        let destinationUUID = try XCTUnwrap(
            destinationVolume.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        )
        XCTAssertNotEqual(sourceUUID, destinationUUID)

        let token = UUID().uuidString
        let sourceRoot = sourceVolume.appendingPathComponent("Rascal-M2-Source-\(token)")
        let sameVolumeDestination = sourceVolume.appendingPathComponent(
            "Rascal-M2-Same-Destination-\(token)"
        )
        let crossVolumeDestination = destinationVolume.appendingPathComponent(
            "Rascal-M2-Cross-Destination-\(token)"
        )
        defer {
            if metadataEvidenceDirectory == nil {
                try? FileManager.default.removeItem(at: sourceRoot)
                try? FileManager.default.removeItem(at: sameVolumeDestination)
                try? FileManager.default.removeItem(at: crossVolumeDestination)
            }
        }
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(
            at: sameVolumeDestination, withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: crossVolumeDestination, withIntermediateDirectories: false
        )

        let file = sourceRoot.appendingPathComponent("volume-file.bin")
        try Data(repeating: 0x91, count: 2 * 1024 * 1024).write(to: file)

        let tree = sourceRoot.appendingPathComponent("VolumeTree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
        let treeFile = tree.appendingPathComponent("leader.txt")
        try Data("cross-volume-tree".utf8).write(to: treeFile)
        XCTAssertEqual(chmod(treeFile.path, 0o640), 0)
        try setExtendedAttribute(
            "com.rascal.m2.volume",
            value: Data("preserved".utf8),
            at: treeFile
        )
        try setExtendedAttribute(
            "com.apple.FinderInfo",
            value: Data((0..<32).map { UInt8(31 - $0) }),
            at: treeFile
        )
        let volumeTags = try PropertyListSerialization.data(
            fromPropertyList: ["Cross Volume\n2", "M2\n6"],
            format: .binary,
            options: 0
        )
        try setExtendedAttribute(
            "com.apple.metadata:_kMDItemUserTags", value: volumeTags, at: treeFile
        )
        let volumeAddedTime = try PropertyListSerialization.data(
            fromPropertyList: Date(timeIntervalSince1970: 1_700_100_000),
            format: .binary,
            options: 0
        )
        try setExtendedAttribute(
            "com.apple.metadata:kMDItemDateAdded", value: volumeAddedTime, at: treeFile
        )
        try setExtendedAttribute(
            "com.apple.ResourceFork",
            value: Data("cross-volume-resource-fork".utf8),
            at: treeFile
        )
        XCTAssertEqual(chflags(treeFile.path, UInt32(UF_HIDDEN)), 0)
        try applyACL(to: treeFile)
        XCTAssertEqual(link(treeFile.path, tree.appendingPathComponent("follower.txt").path), 0)
        let volumeSymlink = tree.appendingPathComponent("link")
        XCTAssertEqual(symlink("leader.txt", volumeSymlink.path), 0)
        try setExtendedAttribute(
            "com.rascal.m2.symlink",
            value: Data("symlink-metadata".utf8),
            at: volumeSymlink,
            options: XATTR_NOFOLLOW
        )
        let sparse = tree.appendingPathComponent("sparse.bin")
        let sparseFD = open(sparse.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        XCTAssertGreaterThanOrEqual(sparseFD, 0)
        if sparseFD >= 0 {
            var marker: UInt8 = 1
            XCTAssertEqual(write(sparseFD, &marker, 1), 1)
            XCTAssertEqual(ftruncate(sparseFD, 4 * 1024 * 1024), 0)
            XCTAssertEqual(close(sparseFD), 0)
        }

        let package = sourceRoot.appendingPathComponent("Widget.bundle", isDirectory: true)
        let contents = package.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data("bundle-payload".utf8).write(to: contents.appendingPathComponent("Info.plist"))

        let sources = [file, tree, package]
        for destinationRoot in [sameVolumeDestination, crossVolumeDestination] {
            let service = try FileOperationService.makeVolatileNativeCopy()
            let id = try await service.submit(OperationRequest(
                kind: .copy,
                sources: sources,
                destination: destinationRoot,
                destinationMode: .container,
                conflictPolicy: .stop,
                verificationPolicy: .sha256
            ))
            let snapshot = try await waitForTerminal(
                id, service: service, timeout: .seconds(60)
            )

            XCTAssertEqual(snapshot.state, .completed, snapshot.terminalFailure?.diagnostic ?? "")
            for source in sources {
                let destination = destinationRoot.appendingPathComponent(source.lastPathComponent)
                let sourceManifest = try NativeTreeManifest.capture(
                    root: source, includeContentDigests: true
                )
                let destinationManifest = try NativeTreeManifest.capture(
                    root: destination, includeContentDigests: true
                )
                XCTAssertNil(
                    sourceManifest.firstMismatch(against: destinationManifest, policy: .sha256)
                )
                XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
            }
        }
        if let metadataEvidenceDirectory {
            try FileManager.default.createDirectory(
                at: metadataEvidenceDirectory,
                withIntermediateDirectories: true
            )
            let records = [
                ("same-file", file, sameVolumeDestination.appendingPathComponent(file.lastPathComponent)),
                ("same-tree", tree, sameVolumeDestination.appendingPathComponent(tree.lastPathComponent)),
                ("same-package", package, sameVolumeDestination.appendingPathComponent(package.lastPathComponent)),
                ("cross-file", file, crossVolumeDestination.appendingPathComponent(file.lastPathComponent)),
                ("cross-tree", tree, crossVolumeDestination.appendingPathComponent(tree.lastPathComponent)),
                ("cross-package", package, crossVolumeDestination.appendingPathComponent(package.lastPathComponent)),
            ]
            let lines = records.map { "\($0.0)\t\($0.1.path)\t\($0.2.path)" }
            try (lines.joined(separator: "\n") + "\n").write(
                to: metadataEvidenceDirectory.appendingPathComponent("metadata-paths.tsv"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    func testConfiguredRealAPFSNoSpaceLeavesNoPartialFinal() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RASCAL_M2_REAL_ENOSPC"] == "1",
              let sourceMount = environment["RASCAL_M2_APFS_SOURCE"],
              let destinationMount = environment["RASCAL_M2_APFS_DESTINATION"] else {
            return
        }
        let token = UUID().uuidString
        let sourceRoot = URL(fileURLWithPath: sourceMount, isDirectory: true)
            .appendingPathComponent("Rascal-M2-ENOSPC-Source-\(token)")
        let destinationRoot = URL(fileURLWithPath: destinationMount, isDirectory: true)
            .appendingPathComponent("Rascal-M2-ENOSPC-Destination-\(token)")
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: destinationRoot)
        }
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: false)

        let source = sourceRoot.appendingPathComponent("requires-space.bin")
        let sourceHandle = try FileHandle(forWritingTo: createEmptyFile(at: source))
        let sourceChunk = randomData(count: 1024 * 1024)
        for _ in 0..<24 { try sourceHandle.write(contentsOf: sourceChunk) }
        try sourceHandle.synchronize()
        try sourceHandle.close()

        let filler = destinationRoot.appendingPathComponent("filler.bin")
        let fillerHandle = try FileHandle(forWritingTo: createEmptyFile(at: filler))
        let fillerChunk = randomData(count: 1024 * 1024)
        let preflightHeadroom: Int64 = 40 * 1024 * 1024
        while try availableBytes(at: destinationRoot) > preflightHeadroom {
            let available = try self.availableBytes(at: destinationRoot)
            let count = min(
                fillerChunk.count,
                max(0, Int(available - preflightHeadroom))
            )
            guard count > 0 else { break }
            try fillerHandle.write(contentsOf: fillerChunk.prefix(count))
            if count < fillerChunk.count { break }
        }
        try fillerHandle.synchronize()
        try fillerHandle.close()

        let destination = destinationRoot.appendingPathComponent(source.lastPathComponent)
        let pressure = destinationRoot.appendingPathComponent("kernel-pressure.bin")
        let pressureReady = sourceRoot.appendingPathComponent("pressure-ready.txt")
        let faults = NativeCopyFaultController(beforeDataCopy: { stagedDestination in
            guard FileManager.default.fileExists(atPath: stagedDestination.path) else {
                throw NSError(
                    domain: "Rascal.M2.ENOSPC",
                    code: Int(ENOENT),
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "staging file was not created before kernel pressure"
                    ]
                )
            }
            let descriptor = open(
                pressure.path,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                mode_t(0o600)
            )
            guard descriptor >= 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            let available = try self.availableBytes(at: destinationRoot)
            // Keep enough room for APFS allocation metadata so preallocation
            // itself succeeds, but less than the 24 MiB source so fcopyfile is
            // the syscall that exhausts the volume.
            let retainedHeadroom: Int64 = 20 * 1024 * 1024
            let requested = max(0, available - retainedHeadroom)
            guard requested > 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
            }
            // F_PREALLOCATE consumes physical APFS blocks without a slow
            // write/fsync loop. Leave a bounded reserve so
            // preflight has already succeeded but the 24 MiB fcopyfile must
            // receive the real kernel ENOSPC.
            var store = fstore_t()
            store.fst_flags = UInt32(F_ALLOCATEALL)
            store.fst_posmode = Int32(F_PEOFPOSMODE)
            store.fst_offset = 0
            store.fst_length = off_t(requested)
            guard fcntl(descriptor, F_PREALLOCATE, &store) != -1 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            guard store.fst_bytesalloc >= off_t(requested),
                  ftruncate(descriptor, store.fst_bytesalloc) == 0 else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno == 0 ? EIO : errno)
                )
            }
            var logicalSize = store.fst_bytesalloc
            var increment: off_t = 4 * 1024 * 1024
            var attempts = 0
            while increment >= 4096 {
                attempts += 1
                guard attempts <= 128 else {
                    throw NSError(domain: "Rascal.M2.ENOSPC", code: Int(ELOOP))
                }
                var tail = fstore_t()
                tail.fst_flags = UInt32(F_ALLOCATEALL)
                tail.fst_posmode = Int32(F_PEOFPOSMODE)
                tail.fst_offset = 0
                tail.fst_length = increment
                if fcntl(descriptor, F_PREALLOCATE, &tail) == 0 {
                    guard tail.fst_bytesalloc > 0 else {
                        throw NSError(domain: "Rascal.M2.ENOSPC", code: Int(EIO))
                    }
                    logicalSize += tail.fst_bytesalloc
                    guard ftruncate(descriptor, logicalSize) == 0 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                    continue
                }
                guard errno == ENOSPC else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                increment = (increment / 2 / 4096) * 4096
            }
            // Keep the pressure descriptor open until this isolated XCTest
            // process exits. Closing it here can synchronously flush a nearly
            // full APFS image before fcopyfile gets a chance to observe the
            // reserved blocks; process teardown closes it before hdiutil detach.
            try Data("ready".utf8).write(to: pressureReady)
        })
        let service = try FileOperationService.makeVolatileNativeCopy(faults: faults)
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [source],
            destination: destinationRoot,
            destinationMode: .container,
            conflictPolicy: .stop,
            verificationPolicy: .sha256
        ))
        let snapshot = try await waitForTerminal(id, service: service, timeout: .seconds(60))

        XCTAssertEqual(
            snapshot.state,
            .failedRecoverable,
            snapshot.terminalFailure?.diagnostic ?? "missing terminal failure"
        )
        XCTAssertEqual(
            snapshot.terminalFailure?.code,
            .noSpace,
            snapshot.terminalFailure?.diagnostic ?? "missing terminal failure"
        )
        XCTAssertTrue(
            faults.nativeSystemFailureCodes(at: .copyData).contains(ENOSPC),
            "production fcopyfile must return its real kernel ENOSPC"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: pressureReady.path),
            "kernel pressure hook must complete before fcopyfile begins"
        )
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value,
                       24 * 1024 * 1024)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: destinationRoot.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".rascal-stage-") })
    }

    func testConfiguredDeferredVolumesRemainDisabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let caseSensitiveRoot = environment["RASCAL_M2_CASE_SENSITIVE_SOURCE"],
              let exfatRoot = environment["RASCAL_M2_EXFAT_SOURCE"] else {
            return
        }

        for (label, rootPath) in [
            ("case-sensitive-apfs", caseSensitiveRoot),
            ("exfat", exfatRoot),
        ] {
            let token = UUID().uuidString
            let source = URL(fileURLWithPath: rootPath, isDirectory: true)
                .appendingPathComponent("Rascal-M2-Deferred-\(token).txt")
            let destinationRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("Rascal-M2-Deferred-Destination-\(token)", isDirectory: true)
            let final = destinationRoot.appendingPathComponent(source.lastPathComponent)
            defer {
                try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: destinationRoot)
            }
            do {
                try Data(label.utf8).write(to: source)
                try FileManager.default.createDirectory(
                    at: destinationRoot, withIntermediateDirectories: false
                )
            } catch {
                XCTFail("\(label) fixture setup failed: \(error)")
                continue
            }

            let snapshot: OperationSnapshot
            do {
                let service = try FileOperationService.makeVolatileNativeCopy()
                let id = try await service.submit(OperationRequest(
                    kind: .copy,
                    sources: [source],
                    destination: destinationRoot,
                    destinationMode: .container,
                    conflictPolicy: .stop,
                    verificationPolicy: .structural
                ))
                snapshot = try await waitForTerminal(id, service: service)
            } catch {
                XCTFail("\(label) service execution failed: \(error)")
                continue
            }

            XCTAssertEqual(snapshot.state, .failedRecoverable, label)
            XCTAssertEqual(snapshot.terminalFailure?.code, .serviceSafeMode, label)
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), label)
            XCTAssertFalse(FileManager.default.fileExists(atPath: final.path), label)
        }
    }

    func testConfiguredOneGiBPerformanceProtocol() async throws {
        guard let rootPath = ProcessInfo.processInfo.environment["RASCAL_M2_PERF_ROOT"] else {
            return
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent("Rascal-M2-Perf-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard try availableBytes(at: root) >= 5 * 1024 * 1024 * 1024 else {
            throw XCTSkip("performance fixture requires at least 5 GiB free")
        }

        let source = root.appendingPathComponent("source-1gib.bin")
        let sourceHandle = try FileHandle(forWritingTo: createEmptyFile(at: source))
        let chunk = randomData(count: 1024 * 1024)
        for _ in 0..<1024 { try sourceHandle.write(contentsOf: chunk) }
        try sourceHandle.synchronize()
        try sourceHandle.close()

        _ = try await measureRascalCopy(
            source: source,
            destination: root.appendingPathComponent("warmup-rascal.bin")
        )
        _ = try measureSystemCopy(
            source: source,
            destination: root.appendingPathComponent("warmup-cp.bin")
        )

        var seed: UInt64 = 0x7261_7363_616c_4d32
        for round in 1...7 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            let rascalFirst = (seed & 1) == 0
            let order = rascalFirst ? ["rascal", "cp"] : ["cp", "rascal"]
            for engine in order {
                let destination = root.appendingPathComponent("round-\(round)-\(engine).bin")
                let sample: (seconds: Double, rssDelta: Int64)
                if engine == "rascal" {
                    sample = try await measureRascalCopy(
                        source: source,
                        destination: destination
                    )
                } else {
                    sample = try measureSystemCopy(source: source, destination: destination)
                }
                print(
                    "M2_PERF_SAMPLE engine=\(engine) round=\(round) " +
                    "order=\(rascalFirst ? "rascal-first" : "cp-first") " +
                    String(format: "seconds=%.6f", sample.seconds) +
                    " rss_delta_bytes=\(sample.rssDelta)"
                )
                try FileManager.default.removeItem(at: destination)
            }
        }
    }

    func testVolatileServiceCopiesFileWithoutMutatingSource() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("payload.bin")
        let destination = fixture.destination.appendingPathComponent("payload.bin")
        let payload = Data((0..<(256 * 1024)).map { UInt8($0 % 251) })
        try payload.write(to: source, options: .atomic)

        let service = try FileOperationService.makeVolatileNativeCopy()
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .stop,
            verificationPolicy: .sha256
        ))
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .completed, snapshot.terminalFailure?.diagnostic ?? "")
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertEqual(try Data(contentsOf: source), payload)
        XCTAssertNotNil(snapshot.items.first?.receipt)
        XCTAssertFalse(try fixture.containsStagingObject())
    }

    func testM2EvidenceEmitsEventTraceAndVolatileJournalDump() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("evidence.txt")
        let destination = fixture.destination.appendingPathComponent("evidence.txt")
        try Data("M2 machine-auditable evidence".utf8).write(to: source)

        let journal = VolatileOperationJournal()
        let registry = NativeCopyWorkspaceRegistry()
        let service = try FileOperationService(dependencies: ServiceDependencies(
            journal: journal,
            fileSystem: NativeCopyFileSystemAdapter(registry: registry),
            clock: SystemOperationClock(),
            ids: RandomOperationIDGenerator(),
            digest: CommonCryptoDigestProvider(),
            failpoints: NoopFailpointController(),
            executor: NativeCopyExecutor(registry: registry),
            diagnostics: NoopDiagnosticSink()
        ))
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .stop,
            verificationPolicy: .sha256
        ))
        let terminal = try await waitForTerminal(id, service: service)
        XCTAssertEqual(terminal.state, .completed)

        let operations = try journal.loadOperations()
        let operation = try XCTUnwrap(operations.first { $0.snapshot.id == id })
        let events = try journal.replay(
            operationID: id,
            after: 0,
            through: operation.latestDurableSequence,
            limit: Int.max
        )
        XCTAssertFalse(events.isEmpty)
        XCTAssertEqual(events.map(\.sequence), events.map(\.sequence).sorted())
        for event in events {
            print([
                "M2_EVENT_TRACE",
                "operation=\(event.operationID.rawValue.uuidString.lowercased())",
                "item=\(event.itemID?.rawValue.uuidString.lowercased() ?? "-")",
                "sequence=\(event.sequence)",
                "durability=\(event.durability.rawValue)",
                "payload=\(m2EvidencePayload(event.payload))"
            ].joined(separator: "\t"))
        }
        print([
            "M2_JOURNAL_DUMP",
            "operation=\(id.rawValue.uuidString.lowercased())",
            "schema=\(operation.snapshot.schemaVersion)",
            "state=\(operation.snapshot.state.rawValue)",
            "ordinal=\(operation.submissionOrdinal)",
            "latest_durable=\(operation.latestDurableSequence)",
            "latest_emitted=\(operation.latestEmittedSequence)",
            "reserved_through=\(operation.reservedThrough)",
            "items=\(operation.snapshot.items.count)",
            "committed_effects=\(operation.committedEffects.count)",
            "prior_decisions=\(operation.priorDecisions.count)"
        ].joined(separator: "\t"))
    }

    func testResolvedConflictDecisionExpiresWhenDestinationIdentityChanges() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("decision.txt")
        let destination = fixture.destination.appendingPathComponent("decision.txt")
        try Data("source".utf8).write(to: source)
        try Data("original destination".utf8).write(to: destination)

        let service = try FileOperationService.makeVolatileNativeCopy()
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .ask,
            verificationPolicy: .sha256
        ))
        let waiting = try await waitForState(
            id, service: service, states: [.waitingForDecision]
        )
        let token = try XCTUnwrap(waiting.pendingDecision?.token)
        try FileManager.default.removeItem(at: destination)
        try Data("replacement destination".utf8).write(to: destination)
        try await service.resolve(token, with: .keepBoth(scope: .item))
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .failedRecoverable)
        XCTAssertEqual(snapshot.terminalFailure?.code, .decisionExpired)
        XCTAssertEqual(try Data(contentsOf: destination), Data("replacement destination".utf8))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destination.appendingPathComponent("decision copy.txt").path
            )
        )
    }

    func testResolvedConflictDecisionExpiresWhenSourceIdentityChanges() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("source-decision.txt")
        let destination = fixture.destination.appendingPathComponent("source-decision.txt")
        try Data("original source".utf8).write(to: source)
        try Data("destination".utf8).write(to: destination)

        let service = try FileOperationService.makeVolatileNativeCopy()
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .ask,
            verificationPolicy: .sha256
        ))
        let waiting = try await waitForState(
            id, service: service, states: [.waitingForDecision]
        )
        let token = try XCTUnwrap(waiting.pendingDecision?.token)
        try FileManager.default.removeItem(at: source)
        try Data("replacement source".utf8).write(to: source)
        try await service.resolve(token, with: .keepBoth(scope: .item))
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .failedRecoverable)
        XCTAssertEqual(snapshot.terminalFailure?.code, .decisionExpired)
        XCTAssertEqual(try Data(contentsOf: destination), Data("destination".utf8))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destination.appendingPathComponent("source-decision copy.txt").path
            )
        )
    }

    func testDirectoryCopyPreservesMetadataLinksAndSparseTopology() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let tree = fixture.source.appendingPathComponent("Tree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
        let regular = tree.appendingPathComponent("regular.txt")
        try Data("metadata-payload".utf8).write(to: regular)
        XCTAssertEqual(chmod(regular.path, 0o640), 0)
        let xattr = Data("rascal-m2".utf8)
        try setExtendedAttribute("com.rascal.m2.fixture", value: xattr, at: regular)
        try setExtendedAttribute(
            "com.apple.FinderInfo",
            value: Data((0..<32).map { UInt8($0) }),
            at: regular
        )
        let tags = try PropertyListSerialization.data(
            fromPropertyList: ["Blue\n4", "Important\n6"],
            format: .binary,
            options: 0
        )
        try setExtendedAttribute("com.apple.metadata:_kMDItemUserTags", value: tags, at: regular)
        let addedTime = try PropertyListSerialization.data(
            fromPropertyList: Date(timeIntervalSince1970: 1_700_000_000),
            format: .binary,
            options: 0
        )
        try setExtendedAttribute("com.apple.metadata:kMDItemDateAdded", value: addedTime, at: regular)
        try setExtendedAttribute(
            "com.apple.ResourceFork",
            value: Data("resource-fork-payload".utf8),
            at: regular
        )
        XCTAssertEqual(chflags(regular.path, UInt32(UF_HIDDEN)), 0)
        try applyACL(to: regular)

        let linked = tree.appendingPathComponent("hard-link.txt")
        XCTAssertEqual(link(regular.path, linked.path), 0)
        let symbolic = tree.appendingPathComponent("symbolic-link")
        XCTAssertEqual(symlink("regular.txt", symbolic.path), 0)
        try setExtendedAttribute(
            "com.rascal.m2.symlink",
            value: Data("symlink-metadata".utf8),
            at: symbolic,
            options: XATTR_NOFOLLOW
        )

        let sparse = tree.appendingPathComponent("sparse.bin")
        let sparseFD = open(sparse.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        XCTAssertGreaterThanOrEqual(sparseFD, 0)
        if sparseFD >= 0 {
            var byte: UInt8 = 0x7f
            XCTAssertEqual(write(sparseFD, &byte, 1), 1)
            XCTAssertEqual(ftruncate(sparseFD, 8 * 1024 * 1024), 0)
            XCTAssertEqual(fsync(sparseFD), 0)
            XCTAssertEqual(close(sparseFD), 0)
        }

        let destination = fixture.destination.appendingPathComponent("Tree", isDirectory: true)
        let service = try FileOperationService.makeVolatileNativeCopy()
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [tree],
            destination: fixture.destination,
            destinationMode: .container,
            conflictPolicy: .stop,
            verificationPolicy: .sha256
        ))
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .completed, snapshot.terminalFailure?.diagnostic ?? "")
        let sourceManifest = try NativeTreeManifest.capture(
            root: tree, includeContentDigests: true
        )
        let destinationManifest = try NativeTreeManifest.capture(
            root: destination, includeContentDigests: true
        )
        XCTAssertNil(sourceManifest.firstMismatch(against: destinationManifest, policy: .sha256))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: symbolic.path),
                       try FileManager.default.destinationOfSymbolicLink(
                        atPath: destination.appendingPathComponent("symbolic-link").path
                       ))
        XCTAssertTrue(sourceManifest.entries.contains { $0.isSparse })
        XCTAssertFalse(try fixture.containsStagingObject())
    }

    func testSingleSelectedFileWithExternalHardLinkCopiesAsOrdinaryFile() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("selected.txt")
        let externalLink = fixture.source.appendingPathComponent("not-selected.txt")
        let destination = fixture.destination.appendingPathComponent("selected.txt")
        try Data("shared inode".utf8).write(to: source)
        XCTAssertEqual(link(source.path, externalLink.path), 0)

        let sourceManifest = try NativeTreeManifest.capture(
            root: source,
            includeContentDigests: true
        )
        XCTAssertNil(sourceManifest.entries.first?.hardLinkGroup)

        let service = try FileOperationService.makeVolatileNativeCopy()
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .stop,
            verificationPolicy: .sha256
        ))
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .completed, snapshot.terminalFailure?.diagnostic ?? "")
        XCTAssertEqual(try Data(contentsOf: destination), Data("shared inode".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalLink.path))
    }

    func testDanglingSymlinkVolumeIdentityUsesLinkContainerWithoutFollowingTarget() throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let linkURL = fixture.source.appendingPathComponent("dangling-link")
        XCTAssertEqual(symlink("/Volumes/definitely-not-mounted/target", linkURL.path), 0)

        XCTAssertEqual(
            try NativePathInspector.volumeUUIDString(for: linkURL),
            try NativePathInspector.volumeUUIDString(for: fixture.source)
        )
        XCTAssertEqual(
            try NativePathInspector.stableIdentity(at: linkURL).nodeType,
            UInt32(S_IFLNK)
        )
    }

    func testInjectedMidFileNoSpaceCleansStagingAndPreservesSource() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("big.bin")
        let destination = fixture.destination.appendingPathComponent("big.bin")
        let payload = Data(repeating: 0x5a, count: 4 * 1024 * 1024)
        try payload.write(to: source)
        let faults = NativeCopyFaultController(rules: [
            NativeCopyFaultRule(
                point: .writeData,
                pathSuffix: "big.bin",
                byte: 64 * 1024,
                code: .noSpace,
                systemCode: ENOSPC
            )
        ])
        let service = try FileOperationService.makeVolatileNativeCopy(faults: faults)
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .stop,
            verificationPolicy: .sha256
        ))
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .failedRecoverable)
        XCTAssertEqual(snapshot.terminalFailure?.code, .noSpace)
        XCTAssertGreaterThan(faults.hitCount(ruleIndex: 0), 0)
        XCTAssertEqual(try Data(contentsOf: source), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try fixture.containsStagingObject())
    }

    func testInjectedMidFileReadPermissionFailureCleansStaging() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("read-fault.bin")
        let destination = fixture.destination.appendingPathComponent("read-fault.bin")
        let payload = Data(repeating: 0x44, count: 4 * 1024 * 1024)
        try payload.write(to: source)
        let faults = NativeCopyFaultController(rules: [
            NativeCopyFaultRule(
                point: .readData,
                pathSuffix: "read-fault.bin",
                byte: 64 * 1024,
                code: .permissionDenied,
                systemCode: EACCES
            )
        ])
        let service = try FileOperationService.makeVolatileNativeCopy(faults: faults)
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .stop
        ))
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .failedRecoverable)
        XCTAssertEqual(snapshot.terminalFailure?.code, .permissionDenied)
        XCTAssertGreaterThan(faults.hitCount(ruleIndex: 0), 0)
        XCTAssertEqual(try Data(contentsOf: source), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try fixture.containsStagingObject())
    }

    func testInjectedMetadataFailureCleansStagingBeforeFinalIsVisible() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("metadata.txt")
        let destination = fixture.destination.appendingPathComponent("metadata.txt")
        try Data("metadata".utf8).write(to: source)
        let faults = NativeCopyFaultController(rules: [
            NativeCopyFaultRule(
                point: .applyMetadata,
                pathContains: ".rascal-stage-",
                call: 1,
                code: .permissionDenied,
                systemCode: EACCES
            )
        ])
        let service = try FileOperationService.makeVolatileNativeCopy(faults: faults)
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .stop
        ))
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .failedRecoverable)
        XCTAssertEqual(snapshot.terminalFailure?.code, .permissionDenied)
        XCTAssertGreaterThan(faults.hitCount(ruleIndex: 0), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try fixture.containsStagingObject())
    }

    func testInjectedCopyDataAndVerifyRulesUsePathCallSelectorsAndReportHits() async throws {
        for (label, rule, expectedState) in [
            (
                "copy-data",
                NativeCopyFaultRule(
                    point: .copyData,
                    pathSuffix: "copy-data.txt",
                    call: 1,
                    code: .permissionDenied,
                    systemCode: EACCES
                ),
                OperationState.failedRecoverable
            ),
            (
                "verify",
                NativeCopyFaultRule(
                    point: .verify,
                    pathContains: ".rascal-stage-",
                    call: 1,
                    code: .verificationMismatch,
                    systemCode: EIO
                ),
                OperationState.failedRecoverable
            ),
        ] {
            let fixture = try TemporaryCopyFixture()
            defer { fixture.cleanup() }
            let source = fixture.source.appendingPathComponent("\(label).txt")
            let destination = fixture.destination.appendingPathComponent("\(label).txt")
            try Data(label.utf8).write(to: source)
            let faults = NativeCopyFaultController(rules: [rule])
            let service = try FileOperationService.makeVolatileNativeCopy(faults: faults)
            let id = try await service.submit(OperationRequest(
                kind: .copy,
                sources: [source],
                destination: destination,
                destinationMode: .exact,
                conflictPolicy: .stop,
                verificationPolicy: .sha256
            ))
            let snapshot = try await waitForTerminal(id, service: service)

            XCTAssertEqual(snapshot.state, expectedState, label)
            XCTAssertGreaterThan(faults.hitCount(ruleIndex: 0), 0, label)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), label)
            XCTAssertFalse(try fixture.containsStagingObject(), label)
        }
    }

    func testInjectedNestedEnumerationRuleUsesPathAndCallSelectors() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let tree = fixture.source.appendingPathComponent("Root", isDirectory: true)
        let nested = tree.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("child".utf8).write(to: nested.appendingPathComponent("child.txt"))
        let faults = NativeCopyFaultController(rules: [
            NativeCopyFaultRule(
                point: .enumerate,
                pathSuffix: "Nested",
                call: 1,
                code: .permissionDenied,
                systemCode: EACCES
            )
        ])
        let service = try FileOperationService.makeVolatileNativeCopy(faults: faults)
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [tree],
            destination: fixture.destination,
            destinationMode: .container,
            conflictPolicy: .stop
        ))
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .failedRecoverable)
        XCTAssertGreaterThan(faults.hitCount(ruleIndex: 0), 0)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destination.appendingPathComponent("Root").path
            )
        )
        XCTAssertFalse(try fixture.containsStagingObject())
    }

    func testInjectedCleanupFailureLeavesOwnedStageForRecoveryAndReportsBothHits() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("cleanup-fault.txt")
        let destination = fixture.destination.appendingPathComponent("cleanup-fault.txt")
        try Data("payload".utf8).write(to: source)
        let faults = NativeCopyFaultController(rules: [
            NativeCopyFaultRule(
                point: .commit,
                pathSuffix: "cleanup-fault.txt",
                call: 1,
                code: .permissionDenied,
                systemCode: EACCES
            ),
            NativeCopyFaultRule(
                point: .cleanup,
                pathContains: ".rascal-stage-",
                call: 1,
                code: .volumeDisconnected,
                systemCode: ENODEV
            ),
        ])
        let service = try FileOperationService.makeVolatileNativeCopy(faults: faults)
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .stop,
            verificationPolicy: .sha256
        ))
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .recoveryRequired)
        XCTAssertEqual(snapshot.terminalFailure?.code, .volumeDisconnected)
        XCTAssertGreaterThan(faults.hitCount(ruleIndex: 0), 0)
        XCTAssertGreaterThan(faults.hitCount(ruleIndex: 1), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(try fixture.containsStagingObject())
    }

    func testSourceMutationBeforeVerificationBlocksCommitAndCleansStaging() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("source-race.txt")
        let destination = fixture.destination.appendingPathComponent("source-race.txt")
        try Data("before".utf8).write(to: source)
        let faults = NativeCopyFaultController(beforeVerify: { source in
            try Data("after".utf8).write(to: source)
        })
        let service = try FileOperationService.makeVolatileNativeCopy(faults: faults)
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .stop,
            verificationPolicy: .sha256
        ))
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .failedRecoverable)
        XCTAssertEqual(snapshot.terminalFailure?.code, .verificationMismatch)
        XCTAssertEqual(try Data(contentsOf: source), Data("after".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try fixture.containsStagingObject())
    }

    func testSameSizeStageDigestMutationFailsAsVerificationMismatch() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("same-size-digest.txt")
        let destination = fixture.destination.appendingPathComponent("same-size-digest.txt")
        let original = Data("ABCDEF".utf8)
        let replacement = Data("UVWXYZ".utf8)
        try original.write(to: source)
        var sourceInfo = stat()
        XCTAssertEqual(lstat(source.path, &sourceInfo), 0)
        let accessSeconds = sourceInfo.st_atimespec.tv_sec
        let accessNanoseconds = sourceInfo.st_atimespec.tv_nsec
        let modificationSeconds = sourceInfo.st_mtimespec.tv_sec
        let modificationNanoseconds = sourceInfo.st_mtimespec.tv_nsec
        let faults = NativeCopyFaultController(beforeMetadata: { staging in
            let descriptor = open(staging.path, O_WRONLY | O_NOFOLLOW)
            guard descriptor >= 0 else {
                throw NativeFileError.fromErrno(
                    errno, path: staging.path, operation: "open digest mutation stage"
                )
            }
            defer { close(descriptor) }
            let written = replacement.withUnsafeBytes { bytes in
                pwrite(descriptor, bytes.baseAddress, bytes.count, 0)
            }
            guard written == replacement.count else {
                throw NativeFileError.fromErrno(
                    errno, path: staging.path, operation: "write digest mutation"
                )
            }
            var times = [
                timespec(tv_sec: accessSeconds, tv_nsec: accessNanoseconds),
                timespec(tv_sec: modificationSeconds, tv_nsec: modificationNanoseconds),
            ]
            guard futimens(descriptor, &times) == 0, fsync(descriptor) == 0 else {
                throw NativeFileError.fromErrno(
                    errno, path: staging.path, operation: "restore digest mutation metadata"
                )
            }
        })
        let service = try FileOperationService.makeVolatileNativeCopy(faults: faults)
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .stop,
            verificationPolicy: .sha256
        ))
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .recoveryRequired)
        XCTAssertEqual(snapshot.terminalFailure?.code, .verificationMismatch)
        XCTAssertEqual(snapshot.terminalFailure?.phase, .verifying)
        XCTAssertEqual(faults.beforeMetadataHitCount(), 1)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(try fixture.containsStagingObject())
    }

    func testSourceReplacementAfterPreflightBeforePlanIsRejected() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("preflight-source.txt")
        let sourceBackup = fixture.source.appendingPathComponent("preflight-source.original")
        let destination = fixture.destination.appendingPathComponent("preflight-source.txt")
        try Data("trusted".utf8).write(to: source)
        let gate = ContinuationGate()
        let serviceFailpoints = FakeFailpointController()
        await serviceFailpoints.setGate(gate, for: .preflightReadyBeforePlan)
        let service = try FileOperationService.makeVolatileNativeCopy(
            serviceFailpoints: serviceFailpoints
        )
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .stop,
            verificationPolicy: .sha256
        ))
        try await gate.waitUntilEntered()
        try FileManager.default.moveItem(at: source, to: sourceBackup)
        try Data("replacement".utf8).write(to: source)
        await gate.release()
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .failedRecoverable)
        XCTAssertEqual(snapshot.terminalFailure?.code, .sourceChanged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: source), Data("replacement".utf8))
        XCTAssertEqual(try Data(contentsOf: sourceBackup), Data("trusted".utf8))
    }

    func testDestinationParentReplacementAfterPreflightBeforePlanIsRejected() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("preflight-parent.txt")
        let destination = fixture.destination.appendingPathComponent("preflight-parent.txt")
        let originalParent = fixture.destination
        let movedParent = fixture.root.appendingPathComponent(
            "destination-before-replacement",
            isDirectory: true
        )
        try Data("trusted".utf8).write(to: source)
        let gate = ContinuationGate()
        let serviceFailpoints = FakeFailpointController()
        await serviceFailpoints.setGate(gate, for: .preflightReadyBeforePlan)
        let service = try FileOperationService.makeVolatileNativeCopy(
            serviceFailpoints: serviceFailpoints
        )
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .stop,
            verificationPolicy: .sha256
        ))
        try await gate.waitUntilEntered()
        try FileManager.default.moveItem(at: originalParent, to: movedParent)
        try FileManager.default.createDirectory(
            at: originalParent,
            withIntermediateDirectories: false
        )
        await gate.release()
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .failedRecoverable)
        XCTAssertEqual(snapshot.terminalFailure?.code, .destinationChanged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try fixture.containsStagingObject())
    }

    func testDestinationParentReplacementAfterPlanBeforeStageCreationIsRejected() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("planned-parent.txt")
        let destination = fixture.destination.appendingPathComponent("planned-parent.txt")
        let originalParent = fixture.destination
        let movedParent = fixture.root.appendingPathComponent(
            "destination-after-plan",
            isDirectory: true
        )
        try Data("trusted".utf8).write(to: source)
        let faults = NativeCopyFaultController(beforeStageRootCreate: {
            try FileManager.default.moveItem(at: originalParent, to: movedParent)
            try FileManager.default.createDirectory(
                at: originalParent,
                withIntermediateDirectories: false
            )
        })
        let service = try FileOperationService.makeVolatileNativeCopy(faults: faults)
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .stop,
            verificationPolicy: .sha256
        ))
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .failedRecoverable)
        XCTAssertEqual(snapshot.terminalFailure?.code, .destinationChanged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: movedParent.appendingPathComponent(destination.lastPathComponent).path
            )
        )
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: originalParent.path)
                .contains { $0.hasPrefix(".rascal-stage-") }
        )
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: movedParent.path)
                .contains { $0.hasPrefix(".rascal-stage-") }
        )
    }

    func testResolvedDecisionWithoutIdentityDigestIsRejected() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("decision-source.txt")
        let destination = fixture.destination.appendingPathComponent("decision-target.txt")
        try Data("source".utf8).write(to: source)
        try Data("existing".utf8).write(to: destination)
        let adapter = NativeCopyFileSystemAdapter(registry: NativeCopyWorkspaceRegistry())
        let operationID = OperationID(rawValue: UUID())
        let itemID = OperationItemID(rawValue: UUID())
        let disposition = try await adapter.preflight(
            operationID: operationID,
            itemID: itemID,
            request: OperationRequest(
                kind: .copy,
                sources: [source],
                destination: destination,
                destinationMode: .exact,
                conflictPolicy: .stop,
                verificationPolicy: .sha256
            ),
            itemIndex: 0,
            priorDecision: ResolvedOperationDecision(
                decision: .skip(scope: .remainingItems),
                identityDigest: nil
            ),
            controls: ExecutionControls()
        )
        guard case let .failure(failure) = disposition else {
            return XCTFail("identity-less resolved decision must fail closed")
        }
        XCTAssertEqual(failure.code, .decisionExpired)
    }

    func testSourceChildMutationAfterVerificationWithRestoredMtimeBlocksCommit() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let tree = fixture.source.appendingPathComponent("SourceTree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
        let child = tree.appendingPathComponent("child.txt")
        try Data("trusted".utf8).write(to: child)
        var original = stat()
        XCTAssertEqual(lstat(child.path, &original), 0)
        let originalAccessTime = original.st_atimespec
        let originalModificationTime = original.st_mtimespec
        let destination = fixture.destination.appendingPathComponent("SourceTree")
        let faults = NativeCopyFaultController(beforeCommit: { _ in
            try Data("changed".utf8).write(to: child)
            let times = [originalAccessTime, originalModificationTime]
            let result = times.withUnsafeBufferPointer {
                utimensat(AT_FDCWD, child.path, $0.baseAddress, 0)
            }
            guard result == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        })
        let service = try FileOperationService.makeVolatileNativeCopy(faults: faults)
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [tree],
            destination: fixture.destination,
            destinationMode: .container,
            conflictPolicy: .stop,
            verificationPolicy: .structural
        ))
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .recoveryRequired)
        XCTAssertEqual(snapshot.terminalFailure?.code, .sourceChanged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try fixture.containsStagingObject())
    }

    func testStageRootReplacementAfterVerificationIsNeverCommittedOrDeleted() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("root-race.txt")
        let destination = fixture.destination.appendingPathComponent("root-race.txt")
        try Data("trusted".utf8).write(to: source)
        let stagingParent = fixture.destination
        let malicious = Data("malice!".utf8)
        let faults = NativeCopyFaultController(beforeCommit: { _ in
            let name = try FileManager.default.contentsOfDirectory(atPath: stagingParent.path)
                .first { $0.hasPrefix(".rascal-stage-") }
            guard let name else {
                throw NSError(domain: "Rascal.M2.StageRace", code: 1)
            }
            let staging = stagingParent.appendingPathComponent(name)
            try FileManager.default.removeItem(at: staging)
            try malicious.write(to: staging)
        })
        let service = try FileOperationService.makeVolatileNativeCopy(faults: faults)
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .stop,
            verificationPolicy: .sha256
        ))
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .recoveryRequired)
        XCTAssertEqual(snapshot.terminalFailure?.code, .recoveryRequired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let stageName = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(atPath: stagingParent.path)
                .first { $0.hasPrefix(".rascal-stage-") }
        )
        XCTAssertEqual(
            try Data(contentsOf: stagingParent.appendingPathComponent(stageName)),
            malicious
        )
    }

    func testStageChildMutationAfterVerificationIsNeverCommittedOrDeleted() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let tree = fixture.source.appendingPathComponent("StageTree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
        try Data("trusted".utf8).write(to: tree.appendingPathComponent("child.txt"))
        let destination = fixture.destination.appendingPathComponent("StageTree")
        let stagingParent = fixture.destination
        let malicious = Data("changed".utf8)
        let faults = NativeCopyFaultController(beforeCommit: { _ in
            let name = try FileManager.default.contentsOfDirectory(atPath: stagingParent.path)
                .first { $0.hasPrefix(".rascal-stage-") }
            guard let name else {
                throw NSError(domain: "Rascal.M2.StageChildRace", code: 1)
            }
            try malicious.write(
                to: stagingParent.appendingPathComponent(name)
                    .appendingPathComponent("child.txt")
            )
        })
        let service = try FileOperationService.makeVolatileNativeCopy(faults: faults)
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [tree],
            destination: fixture.destination,
            destinationMode: .container,
            conflictPolicy: .stop,
            verificationPolicy: .structural
        ))
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .recoveryRequired)
        XCTAssertEqual(snapshot.terminalFailure?.code, .recoveryRequired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let stageName = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(atPath: stagingParent.path)
                .first { $0.hasPrefix(".rascal-stage-") }
        )
        XCTAssertEqual(
            try Data(
                contentsOf: stagingParent.appendingPathComponent(stageName)
                    .appendingPathComponent("child.txt")
            ),
            malicious
        )
    }

    func testDestinationParentRelocationKeepsMovedStageRegisteredForRecovery() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("parent-relocation.txt")
        let destination = fixture.destination.appendingPathComponent("parent-relocation.txt")
        let originalParent = fixture.destination
        let movedParent = fixture.root.appendingPathComponent(
            "destination-relocated",
            isDirectory: true
        )
        try Data("trusted".utf8).write(to: source)
        let faults = NativeCopyFaultController(beforeCommit: { _ in
            try FileManager.default.moveItem(at: originalParent, to: movedParent)
            try FileManager.default.createDirectory(
                at: originalParent,
                withIntermediateDirectories: false
            )
        })
        let registry = NativeCopyWorkspaceRegistry()
        let adapter = NativeCopyFileSystemAdapter(registry: registry)
        let service = try FileOperationService(dependencies: ServiceDependencies(
            journal: VolatileOperationJournal(),
            fileSystem: adapter,
            clock: SystemOperationClock(),
            ids: RandomOperationIDGenerator(),
            digest: CommonCryptoDigestProvider(),
            failpoints: NoopFailpointController(),
            executor: NativeCopyExecutor(registry: registry, faults: faults),
            diagnostics: NoopDiagnosticSink()
        ))
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .stop,
            verificationPolicy: .sha256
        ))
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .recoveryRequired)
        XCTAssertEqual(snapshot.terminalFailure?.code, .recoveryRequired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let movedStageName = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(atPath: movedParent.path)
                .first { $0.hasPrefix(".rascal-stage-") }
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: movedParent.appendingPathComponent(movedStageName).path
            )
        )
        let itemID = try XCTUnwrap(snapshot.items.first?.id)
        let inspection = await adapter.inspectOwnedStaging(
            operationID: id,
            itemID: itemID,
            effectID: UUID()
        )
        if case .completed = inspection {
            XCTFail("relocated staging must not be reported as cleaned")
        }
        let recovery = await adapter.recoverOwnedStaging(
            operationID: id,
            itemID: itemID,
            effectID: UUID()
        )
        if case .completed = recovery {
            XCTFail("relocated staging must remain registered for manual recovery")
        }
        let record = try XCTUnwrap(registry.record(for: .init(
            operationID: id,
            itemID: itemID
        )))
        XCTAssertNotNil(record.stagingIdentity)
        XCTAssertFalse(record.ownedNodes.isEmpty)
    }

    func testMissingOriginalParentKeepsMovedStageRegisteredWithRecoveryRequired() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("missing-parent.txt")
        let destination = fixture.destination.appendingPathComponent("missing-parent.txt")
        let originalParent = fixture.destination
        let movedParent = fixture.root.appendingPathComponent(
            "destination-parent-moved-away",
            isDirectory: true
        )
        try Data("trusted".utf8).write(to: source)
        let faults = NativeCopyFaultController(beforeCommit: { _ in
            try FileManager.default.moveItem(at: originalParent, to: movedParent)
        })
        let registry = NativeCopyWorkspaceRegistry()
        let adapter = NativeCopyFileSystemAdapter(registry: registry)
        let service = try FileOperationService(dependencies: ServiceDependencies(
            journal: VolatileOperationJournal(),
            fileSystem: adapter,
            clock: SystemOperationClock(),
            ids: RandomOperationIDGenerator(),
            digest: CommonCryptoDigestProvider(),
            failpoints: NoopFailpointController(),
            executor: NativeCopyExecutor(registry: registry, faults: faults),
            diagnostics: NoopDiagnosticSink()
        ))
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .stop,
            verificationPolicy: .sha256
        ))
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .recoveryRequired)
        XCTAssertEqual(snapshot.terminalFailure?.code, .recoveryRequired)
        let movedStageName = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(atPath: movedParent.path)
                .first { $0.hasPrefix(".rascal-stage-") }
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: movedParent.appendingPathComponent(movedStageName).path
            )
        )
        let itemID = try XCTUnwrap(snapshot.items.first?.id)
        let recovery = await adapter.recoverOwnedStaging(
            operationID: id,
            itemID: itemID,
            effectID: UUID()
        )
        if case .completed = recovery {
            XCTFail("missing authorized parent path must not clear staging ownership")
        }
    }

    func testCommitParentReplacementAfterDescriptorOpenNeverCommitsReplacementStage() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("commit-parent.txt")
        let destination = fixture.destination.appendingPathComponent("commit-parent.txt")
        let originalParent = fixture.destination
        let movedParent = fixture.root.appendingPathComponent(
            "commit-parent-moved",
            isDirectory: true
        )
        let malicious = Data("malicious-stage".utf8)
        try Data("trusted-source".utf8).write(to: source)
        let faults = NativeCopyFaultController(afterCommitParentOpen: { _ in
            let stageName = try XCTUnwrap(
                FileManager.default.contentsOfDirectory(atPath: originalParent.path)
                    .first { $0.hasPrefix(".rascal-stage-") }
            )
            try FileManager.default.moveItem(at: originalParent, to: movedParent)
            try FileManager.default.createDirectory(
                at: originalParent,
                withIntermediateDirectories: false
            )
            try malicious.write(
                to: originalParent.appendingPathComponent(stageName)
            )
        })
        let service = try FileOperationService.makeVolatileNativeCopy(faults: faults)
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .stop,
            verificationPolicy: .sha256
        ))
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .recoveryRequired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: movedParent.appendingPathComponent(destination.lastPathComponent).path
            )
        )
        let replacementStage = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(atPath: originalParent.path)
                .first { $0.hasPrefix(".rascal-stage-") }
        )
        XCTAssertEqual(
            try Data(contentsOf: originalParent.appendingPathComponent(replacementStage)),
            malicious
        )
    }

    func testStageReplacementAtFinalRenameCheckpointIsNeverCommitted() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("commit-stage-race.txt")
        let destination = fixture.destination.appendingPathComponent("commit-stage-race.txt")
        let malicious = Data("replacement-at-rename".utf8)
        try Data("trusted-source".utf8).write(to: source)
        let faults = NativeCopyFaultController(beforeCommitRename: { staging in
            try FileManager.default.removeItem(at: staging)
            try malicious.write(to: staging)
        })
        let service = try FileOperationService.makeVolatileNativeCopy(faults: faults)
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .stop,
            verificationPolicy: .sha256
        ))
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .recoveryRequired)
        XCTAssertEqual(snapshot.terminalFailure?.code, .recoveryRequired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let replacementStage = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(atPath: fixture.destination.path)
                .first { $0.hasPrefix(".rascal-stage-") }
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appendingPathComponent(replacementStage)),
            malicious
        )
    }

    func testCleanupReplacementAfterManifestValidationIsNeverDeleted() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("cleanup-race.txt")
        let destination = fixture.destination.appendingPathComponent("cleanup-race.txt")
        let stagingParent = fixture.destination
        let malicious = Data("unowned-replacement".utf8)
        try Data("trusted".utf8).write(to: source)
        let faults = NativeCopyFaultController(
            rules: [
                NativeCopyFaultRule(
                    point: .commit,
                    code: .permissionDenied,
                    systemCode: EACCES
                )
            ],
            beforeCleanupNodeUnlink: { relativePath, _ in
                guard relativePath == "." else { return }
                let stageName = try XCTUnwrap(
                    FileManager.default.contentsOfDirectory(atPath: stagingParent.path)
                        .first { $0.hasPrefix(".rascal-stage-") }
                )
                let stage = stagingParent.appendingPathComponent(stageName)
                try FileManager.default.removeItem(at: stage)
                try malicious.write(to: stage)
            }
        )
        let service = try FileOperationService.makeVolatileNativeCopy(faults: faults)
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .stop,
            verificationPolicy: .sha256
        ))
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .recoveryRequired)
        XCTAssertEqual(snapshot.terminalFailure?.code, .recoveryRequired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let replacementStage = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(atPath: stagingParent.path)
                .first { $0.hasPrefix(".rascal-stage-") }
        )
        XCTAssertEqual(
            try Data(contentsOf: stagingParent.appendingPathComponent(replacementStage)),
            malicious
        )
        XCTAssertEqual(faults.hitCount(ruleIndex: 0), 1)
    }

    func testCleanupDescendantReplacementAtFinalUnlinkCheckpointIsNeverDeleted() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let tree = fixture.source.appendingPathComponent("CleanupTree", isDirectory: true)
        let nested = tree.appendingPathComponent("Nested", isDirectory: true)
        let child = nested.appendingPathComponent("child.txt")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("trusted-child".utf8).write(to: child)
        let malicious = Data("unowned-child".utf8)
        let faults = NativeCopyFaultController(
            rules: [
                NativeCopyFaultRule(
                    point: .commit,
                    code: .permissionDenied,
                    systemCode: EACCES
                )
            ],
            beforeCleanupNodeUnlink: { relativePath, node in
                guard relativePath == "Nested/child.txt" else { return }
                try FileManager.default.removeItem(at: node)
                try malicious.write(to: node)
            }
        )
        let service = try FileOperationService.makeVolatileNativeCopy(faults: faults)
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [tree],
            destination: fixture.destination,
            destinationMode: .container,
            conflictPolicy: .stop,
            verificationPolicy: .sha256
        ))
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .recoveryRequired)
        XCTAssertEqual(snapshot.terminalFailure?.code, .recoveryRequired)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destination.appendingPathComponent("CleanupTree").path
            )
        )
        let stageName = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(atPath: fixture.destination.path)
                .first { $0.hasPrefix(".rascal-stage-") }
        )
        let replacement = fixture.destination
            .appendingPathComponent(stageName)
            .appendingPathComponent("Nested/child.txt")
        XCTAssertEqual(try Data(contentsOf: replacement), malicious)
        XCTAssertEqual(faults.hitCount(ruleIndex: 0), 1)
    }

    func testCancelMidTreeCleansAllStagedChildren() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let tree = fixture.source.appendingPathComponent("LargeTree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
        for index in 0..<16 {
            try Data(repeating: UInt8(index), count: 512 * 1024).write(
                to: tree.appendingPathComponent(String(format: "%02d.bin", index))
            )
        }
        let destination = fixture.destination.appendingPathComponent("LargeTree")
        let firstCompletedChild = BlockingTestCheckpoint()
        let faults = NativeCopyFaultController(
            copyCallbackDelayNanoseconds: 10_000_000,
            afterNodeCopied: { source in
                if source.lastPathComponent == "00.bin" {
                    firstCompletedChild.hitAndBlock()
                }
            }
        )
        let service = try FileOperationService.makeVolatileNativeCopy(
            faults: faults
        )
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [tree],
            destination: fixture.destination,
            destinationMode: .container,
            conflictPolicy: .stop
        ))

        await firstCompletedChild.waitUntilHit()
        let cancelTask = Task { await service.cancel(id) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        firstCompletedChild.release()
        await cancelTask.value
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .cancelled, snapshot.terminalFailure?.diagnostic ?? "")
        XCTAssertGreaterThan(faults.copiedNodeCount(pathSuffix: "00.bin"), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try fixture.containsStagingObject())
    }

    func testInjectedEnumerationPermissionFailureCreatesNoFinal() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let tree = fixture.source.appendingPathComponent("DeniedTree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
        try Data("child".utf8).write(to: tree.appendingPathComponent("child.txt"))
        let destination = fixture.destination.appendingPathComponent("DeniedTree")
        let faults = NativeCopyFaultController(rules: [
            NativeCopyFaultRule(
                point: .enumerate,
                pathSuffix: "DeniedTree",
                call: 1,
                code: .permissionDenied,
                systemCode: EACCES
            )
        ])
        let service = try FileOperationService.makeVolatileNativeCopy(faults: faults)
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [tree],
            destination: fixture.destination,
            destinationMode: .container,
            conflictPolicy: .stop
        ))
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .failedRecoverable)
        XCTAssertEqual(snapshot.terminalFailure?.code, .permissionDenied)
        XCTAssertGreaterThan(faults.hitCount(ruleIndex: 0), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try fixture.containsStagingObject())
    }

    func testPauseResumeDuringFileCopyCompletesWithoutPartialFinal() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("pause.bin")
        let destination = fixture.destination.appendingPathComponent("pause.bin")
        let payload = Data(repeating: 0x3c, count: 16 * 1024 * 1024)
        try payload.write(to: source)
        let service = try FileOperationService.makeVolatileNativeCopy(
            faults: NativeCopyFaultController(copyCallbackDelayNanoseconds: 10_000_000)
        )
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .stop,
            verificationPolicy: .sha256
        ))

        _ = try await waitForState(id, service: service, states: [.staging])
        await service.pause(id)
        let pausedSnapshot = try await service.snapshot(id)
        XCTAssertEqual(pausedSnapshot.state, .paused)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        await service.resume(id)
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .completed, snapshot.terminalFailure?.diagnostic ?? "")
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertEqual(try Data(contentsOf: source), payload)
        XCTAssertFalse(try fixture.containsStagingObject())
    }

    func testCancelDuringFileCopyCleansStageAndPreservesSource() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("cancel.bin")
        let destination = fixture.destination.appendingPathComponent("cancel.bin")
        let payload = Data(repeating: 0xa7, count: 16 * 1024 * 1024)
        try payload.write(to: source)
        let firstCopiedBytes = BlockingTestCheckpoint()
        let faults = NativeCopyFaultController(
            copyCallbackDelayNanoseconds: 10_000_000,
            onDataProgress: { path, bytes in
                if path.hasSuffix("cancel.bin"), bytes > 0 {
                    firstCopiedBytes.hitAndBlock()
                }
            }
        )
        let service = try FileOperationService.makeVolatileNativeCopy(
            faults: faults
        )
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .stop,
            verificationPolicy: .sha256
        ))

        await firstCopiedBytes.waitUntilHit()
        let cancelTask = Task { await service.cancel(id) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        firstCopiedBytes.release()
        await cancelTask.value
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .cancelled, snapshot.terminalFailure?.diagnostic ?? "")
        XCTAssertGreaterThan(faults.maximumDataProgress(pathSuffix: "cancel.bin"), 0)
        XCTAssertEqual(try Data(contentsOf: source), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try fixture.containsStagingObject())
    }

    func testCancelBeforeMetadataApplicationCleansVerifiedStage() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("cancel-before-metadata.txt")
        let destination = fixture.destination.appendingPathComponent("cancel-before-metadata.txt")
        let payload = Data("metadata cancellation".utf8)
        try payload.write(to: source)
        let service = try FileOperationService.makeVolatileNativeCopy(
            faults: NativeCopyFaultController(metadataPhaseDelayNanoseconds: 300_000_000)
        )
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .stop,
            verificationPolicy: .sha256
        ))

        _ = try await waitForState(id, service: service, states: [.metadata])
        await service.cancel(id)
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .cancelled, snapshot.terminalFailure?.diagnostic ?? "")
        XCTAssertEqual(try Data(contentsOf: source), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try fixture.containsStagingObject())
    }

    func testCancelAfterMetadataBeforeVerificationCleansStage() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("cancel-after-metadata.txt")
        let destination = fixture.destination.appendingPathComponent("cancel-after-metadata.txt")
        let payload = Data("post-metadata cancellation".utf8)
        try payload.write(to: source)
        let service = try FileOperationService.makeVolatileNativeCopy(
            faults: NativeCopyFaultController(
                verificationPhaseDelayNanoseconds: 1_000_000_000
            )
        )
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .stop,
            verificationPolicy: .sha256
        ))

        _ = try await waitForState(id, service: service, states: [.verifying])
        await service.cancel(id)
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .cancelled, snapshot.terminalFailure?.diagnostic ?? "")
        XCTAssertEqual(try Data(contentsOf: source), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try fixture.containsStagingObject())
    }

    func testCancelAfterMetadataBeforeCommitCleansVerifiedStage() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("cancel-before-commit.txt")
        let destination = fixture.destination.appendingPathComponent("cancel-before-commit.txt")
        let payload = Data("verification cancellation".utf8)
        try payload.write(to: source)
        let verificationCompleted = AsyncTestSignal()
        let service = try FileOperationService.makeVolatileNativeCopy(faults:
            NativeCopyFaultController(
                postVerificationDelayNanoseconds: 1_000_000_000,
                afterVerify: { verificationCompleted.signal() }
            )
        )
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .stop,
            verificationPolicy: .sha256
        ))

        await verificationCompleted.wait()
        await service.cancel(id)
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .cancelled, snapshot.terminalFailure?.diagnostic ?? "")
        XCTAssertEqual(try Data(contentsOf: source), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try fixture.containsStagingObject())
    }

    func testInjectedCommitFailureCleansVerifiedStage() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("commit-fault.txt")
        let destination = fixture.destination.appendingPathComponent("commit-fault.txt")
        try Data("source".utf8).write(to: source)
        let faults = NativeCopyFaultController(rules: [
            NativeCopyFaultRule(
                point: .commit,
                pathSuffix: "commit-fault.txt",
                call: 1,
                code: .permissionDenied,
                systemCode: EACCES
            )
        ])
        let service = try FileOperationService.makeVolatileNativeCopy(faults: faults)
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .stop
        ))
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .recoveryRequired)
        XCTAssertEqual(snapshot.terminalFailure?.code, .permissionDenied)
        XCTAssertGreaterThan(faults.hitCount(ruleIndex: 0), 0)
        XCTAssertEqual(try Data(contentsOf: source), Data("source".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try fixture.containsStagingObject())
    }

    func testDestinationCreatedAtExclusiveCommitWinsWithoutOverwrite() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("race.txt")
        let destination = fixture.destination.appendingPathComponent("race.txt")
        try Data("source".utf8).write(to: source)
        let competitor = Data("competitor".utf8)
        let faults = NativeCopyFaultController(beforeCommit: { target in
            try competitor.write(to: target, options: .withoutOverwriting)
        })
        let service = try FileOperationService.makeVolatileNativeCopy(faults: faults)
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .stop
        ))
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .recoveryRequired)
        XCTAssertEqual(snapshot.terminalFailure?.code, .destinationChanged)
        XCTAssertEqual(try Data(contentsOf: destination), competitor)
        XCTAssertEqual(try Data(contentsOf: source), Data("source".utf8))
        XCTAssertFalse(try fixture.containsStagingObject())
    }

    func testKeepBothCommitRaceAdvancesSuffixAndUpdatesSnapshot() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("report.txt")
        let original = fixture.destination.appendingPathComponent("report.txt")
        let firstCandidate = fixture.destination.appendingPathComponent("report copy.txt")
        let secondCandidate = fixture.destination.appendingPathComponent("report copy 2.txt")
        try Data("source".utf8).write(to: source)
        try Data("existing".utf8).write(to: original)
        let competitor = Data("late competitor".utf8)
        let faults = NativeCopyFaultController(beforeCommit: { target in
            XCTAssertEqual(target, firstCandidate)
            try competitor.write(to: target, options: .withoutOverwriting)
        })
        let service = try FileOperationService.makeVolatileNativeCopy(faults: faults)
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [source],
            destination: fixture.destination,
            destinationMode: .container,
            conflictPolicy: .keepBoth,
            verificationPolicy: .sha256
        ))
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .completed, snapshot.terminalFailure?.diagnostic ?? "")
        XCTAssertEqual(snapshot.items.first?.destination, secondCandidate)
        XCTAssertEqual(try Data(contentsOf: original), Data("existing".utf8))
        XCTAssertEqual(try Data(contentsOf: firstCandidate), competitor)
        XCTAssertEqual(try Data(contentsOf: secondCandidate), Data("source".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("source".utf8))
        XCTAssertFalse(try fixture.containsStagingObject())
    }

    func testMultiSourceKeepBothPlansSameCaseAndUnicodeNamesBeforeFirstCommit() async throws {
        let fixture = try TemporaryCopyFixture()
        defer { fixture.cleanup() }
        let sourceA = fixture.source.appendingPathComponent("A", isDirectory: true)
        let sourceB = fixture.source.appendingPathComponent("B", isDirectory: true)
        let sourceC = fixture.source.appendingPathComponent("C", isDirectory: true)
        let sourceD = fixture.source.appendingPathComponent("D", isDirectory: true)
        let sourceE = fixture.source.appendingPathComponent("E", isDirectory: true)
        let sourceF = fixture.source.appendingPathComponent("F", isDirectory: true)
        for directory in [sourceA, sourceB, sourceC, sourceD, sourceE, sourceF] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let reportUpper = sourceA.appendingPathComponent("Report")
        let reportLower = sourceB.appendingPathComponent("report")
        let composed = sourceC.appendingPathComponent("Caf\u{00e9}")
        let decomposed = sourceD.appendingPathComponent("Cafe\u{0301}")
        let sameA = sourceE.appendingPathComponent("same.txt")
        let sameB = sourceF.appendingPathComponent("same.txt")
        let sources = [reportUpper, reportLower, composed, decomposed, sameA, sameB]
        for (index, source) in sources.enumerated() {
            try Data("payload-\(index)".utf8).write(to: source)
        }

        let service = try FileOperationService.makeVolatileNativeCopy()
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: sources,
            destination: fixture.destination,
            destinationMode: .container,
            conflictPolicy: .keepBoth,
            verificationPolicy: .sha256
        ))
        let snapshot = try await waitForTerminal(id, service: service)

        XCTAssertEqual(snapshot.state, .completed, snapshot.terminalFailure?.diagnostic ?? "")
        let finalURLs = snapshot.items.compactMap(\.destination)
        XCTAssertEqual(finalURLs.count, sources.count)
        XCTAssertEqual(Set(finalURLs.map(\.path)).count, sources.count)
        for (index, finalURL) in finalURLs.enumerated() {
            XCTAssertEqual(try Data(contentsOf: finalURL), Data("payload-\(index)".utf8))
            XCTAssertEqual(try Data(contentsOf: sources[index]), Data("payload-\(index)".utf8))
        }
        XCTAssertFalse(try fixture.containsStagingObject())
    }

    private func waitForState(
        _ id: OperationID,
        service: FileOperationService,
        states: Set<OperationState>,
        timeout: Duration = .seconds(15)
    ) async throws -> OperationSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let snapshot = try await service.snapshot(id)
            if states.contains(snapshot.state) { return snapshot }
            if [
                OperationState.completed, .completedWithSkips,
                .completedWithSourceRetained, .cancelled, .failedRecoverable,
                .recoveryRequired, .cleanupRequired, .rolledBack
            ].contains(snapshot.state) {
                XCTFail("native copy reached \(snapshot.state) before expected state \(states)")
                return snapshot
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("native copy did not reach expected state \(states) before timeout")
        return try await service.snapshot(id)
    }

    private func setExtendedAttribute(
        _ name: String,
        value: Data,
        at url: URL,
        options: Int32 = 0
    ) throws {
        let result = value.withUnsafeBytes {
            setxattr(url.path, name, $0.baseAddress, value.count, 0, options)
        }
        guard result == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path, "xattr": name]
            )
        }
    }

    private func createEmptyFile(at url: URL) throws -> URL {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EIO),
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
        return url
    }

    private func randomData(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        arc4random_buf(&bytes, count)
        return Data(bytes)
    }

    private func availableBytes(at url: URL) throws -> Int64 {
        var facts = statfs()
        guard statfs(url.path, &facts) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
        return Int64(facts.f_bavail) * Int64(facts.f_bsize)
    }

    private func measureRascalCopy(
        source: URL,
        destination: URL
    ) async throws -> (seconds: Double, rssDelta: Int64) {
        let idle = try currentResidentBytes()
        let monitor = Task<Int64, Error> {
            var peak = idle
            while !Task.isCancelled {
                peak = max(peak, try self.currentResidentBytes())
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return max(peak, try self.currentResidentBytes())
        }
        let start = ContinuousClock.now
        let service = try FileOperationService.makeVolatileNativeCopy()
        let id = try await service.submit(OperationRequest(
            kind: .copy,
            sources: [source],
            destination: destination,
            destinationMode: .exact,
            conflictPolicy: .stop,
            verificationPolicy: .structural
        ))
        let snapshot = try await waitForTerminal(id, service: service, timeout: .seconds(300))
        let duration = start.duration(to: .now)
        let seconds = Double(duration.components.seconds) +
            Double(duration.components.attoseconds) / 1.0e18
        monitor.cancel()
        let peak = try await monitor.value
        XCTAssertEqual(snapshot.state, .completed, snapshot.terminalFailure?.diagnostic ?? "")
        return (seconds, max(0, peak - idle))
    }

    private func measureSystemCopy(
        source: URL,
        destination: URL
    ) throws -> (seconds: Double, rssDelta: Int64) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/time")
        process.arguments = ["-l", "/bin/cp", source.path, destination.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        let start = ContinuousClock.now
        try process.run()
        process.waitUntilExit()
        let duration = start.duration(to: .now)
        let seconds = Double(duration.components.seconds) +
            Double(duration.components.attoseconds) / 1.0e18
        let details = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "Rascal.M2.Performance.cp",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: details]
            )
        }
        guard let peak = details.split(separator: "\n").compactMap({ line -> Int64? in
            guard line.contains("maximum resident set size") else { return nil }
            return Int64(line.split(whereSeparator: \.isWhitespace).first ?? "")
        }).first, peak > 0 else {
            throw NSError(
                domain: "Rascal.M2.Performance.cp",
                code: Int(EIO),
                userInfo: [NSLocalizedDescriptionKey: "maximum resident set size is unavailable"]
            )
        }
        return (seconds, peak)
    }

    private func currentResidentBytes() throws -> Int64 {
        var info = proc_taskinfo()
        let size = MemoryLayout<proc_taskinfo>.size
        let result = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, $0, Int32(size))
        }
        guard result == Int32(size), info.pti_resident_size > 0 else {
            throw NSError(
                domain: "Rascal.M2.Performance.rss",
                code: Int(errno == 0 ? EIO : errno),
                userInfo: [NSLocalizedDescriptionKey: "resident memory sample is unavailable"]
            )
        }
        return Int64(info.pti_resident_size)
    }

    private func applyACL(to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "everyone deny delete", url.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw NSError(
                domain: "Rascal.NativeCopy.ACLFixture",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
    }

    private func waitForTerminal(
        _ id: OperationID,
        service: FileOperationService,
        timeout: Duration = .seconds(15)
    ) async throws -> OperationSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let snapshot = try await service.snapshot(id)
            if [
                OperationState.completed, .completedWithSkips,
                .completedWithSourceRetained, .cancelled, .failedRecoverable,
                .recoveryRequired, .cleanupRequired, .rolledBack
            ].contains(snapshot.state) {
                return snapshot
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("native copy did not reach a terminal state before timeout")
        return try await service.snapshot(id)
    }
}

private func m2EvidencePayload(_ payload: OperationEventPayload) -> String {
    switch payload {
    case .admitted:
        return "admitted"
    case let .stateChanged(from, to):
        return "state:\(from.rawValue)->\(to.rawValue)"
    case let .itemStateChanged(from, to):
        return "item:\(from.rawValue)->\(to.rawValue)"
    case let .progress(value):
        return "progress:\(value.bytesCompleted):" +
            (value.bytesTotal.map(String.init) ?? "-")
    case .decisionRequired:
        return "decision-required"
    case .decisionResolved:
        return "decision-resolved"
    case let .failure(failure):
        return "failure:\(failure.code.rawValue)"
    case let .receiptRecorded(receipt):
        return "receipt:\(receipt.sourceCleanupPending)"
    case .recoveryAvailable:
        return "recovery-available"
    case let .recoveryConverged(actionID, actions):
        return "recovery-converged:\(actionID.uuidString.lowercased()):\(actions.count)"
    case .completed:
        return "completed"
    }
}

private final class BlockingTestCheckpoint: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = AsyncTestSignal()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var didEnter = false

    func hitAndBlock() {
        let shouldBlock = lock.withLock {
            guard !didEnter else { return false }
            didEnter = true
            return true
        }
        guard shouldBlock else { return }
        entered.signal()
        _ = releaseSemaphore.wait(timeout: .now() + 10)
    }

    func waitUntilHit() async {
        await entered.wait()
    }

    func release() {
        releaseSemaphore.signal()
    }
}

private final class AsyncTestSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            signaled = true
            defer { waiters.removeAll() }
            return waiters
        }
        pending.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                if signaled { return true }
                waiters.append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }
}

private final class TemporaryCopyFixture {
    let root: URL
    let source: URL
    let destination: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Rascal.NativeCopy.\(UUID().uuidString)", isDirectory: true
        )
        source = root.appendingPathComponent("source", isDirectory: true)
        destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func containsStagingObject() throws -> Bool {
        try FileManager.default.contentsOfDirectory(atPath: destination.path)
            .contains { $0.hasPrefix(".rascal-stage-") }
    }
}
