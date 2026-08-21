import Foundation
@testable import OtosKit
import Synchronization
import Testing

struct ExclusivePublicationTests {
    @Test func publishesStagingToAbsentFinalOnAPFS() throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let staging = temp.appending(path: ".stage.otos-import-staging")
        let final = temp.appending(path: "final.jpg")
        try Data([0x01, 0x02, 0x03]).write(to: staging)

        let outcome = ExclusivePublication.publish(staging: staging, final: final)
        #expect(outcome == .published)
        #expect(FileManager.default.fileExists(atPath: final.path))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test func refusesOverwriteWhenFinalExists() throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let staging = temp.appending(path: ".stage.otos-import-staging")
        let final = temp.appending(path: "final.jpg")
        try Data([0x01]).write(to: staging)
        try Data([0x02]).write(to: final)

        let outcome = ExclusivePublication.publish(staging: staging, final: final)
        #expect(outcome == .destinationExists)
        #expect(try Data(contentsOf: final) == Data([0x02]))
    }
}

struct CopyfileTransferTests {
    @Test func copiesBytesAndReportsCompletion() throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let source = temp.appending(path: "source.bin")
        let destination = temp.appending(path: "dest.bin")
        let payload = Data(repeating: 0xAB, count: 64 * 1024)
        try payload.write(to: source)

        let outcome = CopyfileTransfer.copy(
            from: source,
            to: destination,
            onProgress: { _ in },
            shouldContinue: { true }
        )
        #expect(outcome == .completed)
        #expect(try Data(contentsOf: destination) == payload)
    }

    @Test func cancelRemovesPartialDestination() throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let source = temp.appending(path: "source.bin")
        let destination = temp.appending(path: "dest.bin")
        try Data(repeating: 0xCD, count: 2 * 1024 * 1024).write(to: source)

        let counter = TestCounter()
        let outcome = CopyfileTransfer.copy(
            from: source,
            to: destination,
            onProgress: { _ in },
            shouldContinue: {
                counter.incrementAndGet() < 2
            }
        )
        #expect(outcome == .cancelled || outcome == .completed)
        if outcome == .cancelled {
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }
}

struct ActiveFileOperationJournalTests {
    @Test func journalRoundTripsThroughStore() async throws {
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)

        let operation = ActiveFileOperation(
            operationKey: .make(),
            mode: "import",
            sourceKind: .removableVolume,
            sourceDeviceIdentity: "volume:test",
            sourceRootPath: LibraryRootPath(rawValue: "/Volumes/CARD"),
            sourceRelativePath: MediaRelativePath(rawValue: "IMG_1.JPG"),
            destinationRootPath: LibraryRootPath(rawValue: "/Users/example/Pictures"),
            destinationRelativePath: MediaRelativePath(rawValue: "2026/07/IMG_1.JPG"),
            stagingPath: "/Users/example/Pictures/.tmp.otos-import-staging",
            contentHash: .empty,
            importBatchUnixMs: 1_704_067_200_000,
            sourceByteSize: 100,
            sourceModifiedAt: Date(timeIntervalSince1970: 1000),
            destinationModifiedAt: Date(timeIntervalSince1970: 1000),
            phase: .copying,
            deleteSourceRequested: false,
            updatedAt: Date()
        )
        try await store.beginImportOperation(operation)
        let loaded = try await store.activeImportOperations()
        #expect(loaded.count == 1)
        #expect(loaded.first?.operationKey == operation.operationKey)
        #expect(loaded.first?.phase == .copying)
        #expect(loaded.first?.contentHash == .empty)

        var updated = operation
        updated.phase = .readyToPublish
        updated.updatedAt = Date()
        try await store.recordImportOperationProgress(updated)
        let reloaded = try await store.activeImportOperations()
        #expect(reloaded.first?.phase == .readyToPublish)
        #expect(reloaded.first?.contentHash == .empty)

        try await store.abandonImportOperation(key: operation.operationKey)
        #expect(try await store.activeImportOperations().isEmpty)
    }

    @Test func journalMutationWithMissingRowThrows() async throws {
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        let key = ActiveFileOperationKey.make()
        let error = await #expect(throws: CatalogStoreError.self) {
            try await store.abandonImportOperation(key: key)
        }
        #expect(error == .importOperationMissing(key))
    }

    @Test func injectedReadyJournalFailureIsThrowing() async throws {
        let store = CatalogStore(
            location: .inMemory,
            scanCadence: .milliseconds(10),
            importJournalFailure: { transition in
                if case .progress(.readyToPublish) = transition {
                    throw NSError(domain: "test", code: 1)
                }
            }
        )
        try await store.start(scansSavedLibraries: false)
        let operation = ActiveFileOperation(
            operationKey: .make(),
            mode: "import",
            sourceKind: .removableVolume,
            sourceDeviceIdentity: nil,
            sourceRootPath: LibraryRootPath(rawValue: "/Volumes/CARD"),
            sourceRelativePath: MediaRelativePath(rawValue: "IMG_1.JPG"),
            destinationRootPath: LibraryRootPath(rawValue: "/Pictures"),
            destinationRelativePath: MediaRelativePath(rawValue: "final.jpg"),
            stagingPath: "/Pictures/.stage.otos-import-staging",
            contentHash: .empty,
            importBatchUnixMs: 1,
            sourceByteSize: 1,
            sourceModifiedAt: Date(timeIntervalSince1970: 1),
            destinationModifiedAt: Date(timeIntervalSince1970: 1),
            phase: .copying,
            deleteSourceRequested: false,
            updatedAt: Date()
        )
        try await store.beginImportOperation(operation)
        var ready = operation
        ready.phase = .readyToPublish
        await #expect(throws: NSError.self) {
            try await store.recordImportOperationProgress(ready)
        }
        #expect(try await store.activeImportOperations().count == 1)
    }
}

struct ImportRecoveryTests {
    private func operation(
        rootPath: LibraryRootPath,
        destinationRelativePath: String = "final.jpg",
        stagingPath: String?,
        digest: XXH3Digest128,
        byteSize: Int64,
        modifiedAt: Date,
        phase: ActiveFileOperationPhase = .readyToPublish
    ) -> ActiveFileOperation {
        ActiveFileOperation(
            operationKey: .make(),
            mode: "import",
            sourceKind: .removableVolume,
            sourceDeviceIdentity: "volume:test",
            sourceRootPath: LibraryRootPath(rawValue: "/Volumes/CARD"),
            sourceRelativePath: MediaRelativePath(rawValue: "IMG_1.JPG"),
            destinationRootPath: rootPath,
            destinationRelativePath: MediaRelativePath(rawValue: destinationRelativePath),
            stagingPath: stagingPath,
            contentHash: digest,
            importBatchUnixMs: 1_704_067_200_000,
            sourceByteSize: byteSize,
            sourceModifiedAt: Date(timeIntervalSince1970: 1000),
            destinationModifiedAt: modifiedAt,
            phase: phase,
            deleteSourceRequested: false,
            updatedAt: Date()
        )
    }

    @Test func readyToPublishRecoveryPublishesAndSettlesJournaledDigest() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let destination = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let final = destination.appending(path: "final.jpg", directoryHint: .notDirectory)
        let staging = destination.appending(path: ".stage.otos-import-staging", directoryHint: .notDirectory)
        try Data("imported".utf8).write(to: staging)
        let digest: XXH3Digest128
        guard case let .complete(value) = ContentHasher().hashMaterializedFile(at: staging) else {
            Issue.record("expected staging digest")
            return
        }
        digest = value
        let expectedDestinationDate = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        try FileManager.default.setAttributes(
            [.modificationDate: expectedDestinationDate],
            ofItemAtPath: staging.path
        )

        let rootPath = try CatalogPath.normalizedDirectoryPath(for: destination)
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destination)
        let operation = ActiveFileOperation(
            operationKey: .make(),
            mode: "import",
            sourceKind: .removableVolume,
            sourceDeviceIdentity: "volume:test",
            sourceRootPath: LibraryRootPath(rawValue: "/Volumes/CARD"),
            sourceRelativePath: MediaRelativePath(rawValue: "IMG_1.JPG"),
            destinationRootPath: rootPath,
            destinationRelativePath: MediaRelativePath(rawValue: "final.jpg"),
            stagingPath: staging.path,
            contentHash: digest,
            importBatchUnixMs: 1_704_067_200_000,
            sourceByteSize: 8,
            sourceModifiedAt: Date(timeIntervalSince1970: 1000),
            destinationModifiedAt: expectedDestinationDate,
            phase: .readyToPublish,
            deleteSourceRequested: false,
            updatedAt: Date()
        )
        try await store.beginImportOperation(operation)

        await MediaImportExecutor(store: store).recoverJournal()

        #expect(FileManager.default.fileExists(atPath: final.path))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(try await store.activeImportOperations().isEmpty)
        let asset = try #require(try await catalogStoreTestState(store).testAssets.first)
        #expect(asset.contentHash == digest)
        #expect(asset.contentHashSourceSize == 8)
    }

    @Test func finalAndStagingRecoveryTreatsFinalAsForeign() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let destination = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let final = destination.appending(path: "final.jpg")
        let staging = destination.appending(path: ".stage.otos-import-staging")
        try Data("foreign!".utf8).write(to: final)
        try Data("imported".utf8).write(to: staging)
        guard case let .complete(digest) = ContentHasher().hashMaterializedFile(at: staging) else {
            Issue.record("expected staging digest")
            return
        }
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: destination)
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destination)
        let op = operation(
            rootPath: rootPath,
            stagingPath: staging.path,
            digest: digest,
            byteSize: 8,
            modifiedAt: Date(timeIntervalSince1970: 1000)
        )
        try await store.beginImportOperation(op)

        await MediaImportExecutor(store: store).recoverJournal()

        #expect(try Data(contentsOf: final) == Data("foreign!".utf8))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(try await store.activeImportOperations().isEmpty)
        #expect(try await store.importBatches().isEmpty)
    }

    @Test func matchingFinalOnlyRecoverySettlesAfterOwnershipProof() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let destination = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let final = destination.appending(path: "final.jpg")
        try Data("imported".utf8).write(to: final)
        let modifiedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: final.path)
        guard case let .complete(digest) = ContentHasher().hashMaterializedFile(at: final) else {
            Issue.record("expected final digest")
            return
        }
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: destination)
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destination)
        let op = operation(
            rootPath: rootPath,
            stagingPath: nil,
            digest: digest,
            byteSize: 8,
            modifiedAt: modifiedAt
        )
        try await store.beginImportOperation(op)

        await MediaImportExecutor(store: store).recoverJournal()

        #expect(try await store.activeImportOperations().isEmpty)
        let asset = try #require(try await catalogStoreTestState(store).testAssets.first)
        #expect(asset.contentHash == digest)
    }

    @Test func mismatchingFinalOnlyRecoveryRetainsForeignFinal() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let destination = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let final = destination.appending(path: "final.jpg")
        try Data("foreign!".utf8).write(to: final)
        let modifiedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: final.path)
        let expected = temp.appending(path: "expected.bin")
        try Data("imported".utf8).write(to: expected)
        guard case let .complete(digest) = ContentHasher().hashMaterializedFile(at: expected) else {
            Issue.record("expected expected digest")
            return
        }
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: destination)
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destination)
        let op = operation(
            rootPath: rootPath,
            stagingPath: nil,
            digest: digest,
            byteSize: 8,
            modifiedAt: modifiedAt
        )
        try await store.beginImportOperation(op)

        await MediaImportExecutor(store: store).recoverJournal()

        #expect(try Data(contentsOf: final) == Data("foreign!".utf8))
        #expect(try await store.activeImportOperations().isEmpty)
        #expect(try await store.importBatches().isEmpty)
    }
}

struct CameraImportAccessTests {
    @Test func mockGatewayRevalidatesAndReportsDeleteCapability() async throws {
        let access = CameraImportAccess(
            revalidate: { identity, path, size, _ in
                identity == "cam-1" && path.rawValue == "IMG_1.JPG" && size == 10 ? .matches : .sourceNotReady
            },
            ensureBytes: { _, _, enrichment, staging in
                do {
                    let data = try Data(contentsOf: enrichment)
                    try data.write(to: staging)
                    return .completed
                } catch {
                    return .failed(String(describing: error))
                }
            },
            deleteItem: { _, _ in true },
            canDelete: { $0 == "cam-1" },
            eject: { _ in .ejected }
        )
        #expect(
            await access.revalidateItem(
                identity: "cam-1",
                relativePath: MediaRelativePath(rawValue: "IMG_1.JPG"),
                byteSize: 10,
                modifiedAt: nil
            ) == .matches
        )
        #expect(await access.canDelete(identity: "cam-1"))
        #expect(await access.eject(identity: "cam-1") == .ejected)

        let temp = try makeCatalogStoreTemporaryDirectory()
        let enrichment = temp.appending(path: "enrich.bin")
        let staging = temp.appending(path: "stage.bin")
        try Data([0x01, 0x02]).write(to: enrichment)
        let result = await access.ensureImportBytes(
            identity: "cam-1",
            relativePath: MediaRelativePath(rawValue: "IMG_1.JPG"),
            enrichmentURL: enrichment,
            importStagingURL: staging
        )
        #expect(result == .completed)
        #expect(try Data(contentsOf: staging) == Data([0x01, 0x02]))
    }
}

struct VolumeRenameCapabilityTests {
    @Test func temporaryDirectoryReportsAKnownCapability() throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let capability = VolumeRenameCapability.probe(url: temp)
        #expect(
            capability == .renameExcl
                || capability == .hardLink
                || capability == .checkThenAct
        )
    }
}

struct ImportExecutionProgressTests {
    @Test func byteProgressIsMonotonicAndReachesPlanTotals() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let destinationURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let sourceURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        var expectedBytes: Int64 = 0
        for index in 0 ..< 12 {
            let payload = Data(repeating: UInt8(index), count: 1024 * 1024)
            try payload.write(to: sourceURL.appending(path: "image-\(index).jpg"))
            expectedBytes += Int64(payload.count)
        }
        let sourceBefore = try FilesystemTreeSnapshot.capture(root: sourceURL)
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destinationURL)
        let destination = try CatalogPath.normalizedDirectoryPath(for: destinationURL)
        try await store.attachRemovableVolume(
            mountURL: sourceURL,
            identity: "volume:byte-progress",
            displayName: "Card",
            isEjectable: true
        )
        let source = try CatalogPath.normalizedDirectoryPath(for: sourceURL)
        _ = try await waitForCatalogStoreState(store) { state in
            !state.isScanning && state.removableSources.first?.activity == .idle
        }
        let tempDefaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(store: store, preferencesDomain: tempDefaults)
        await coordinator.start()
        await coordinator.setDestination(destination, for: source)
        let plan = try await waitForReadyPlan(coordinator, source: source)

        let collector = ProgressCollector()
        let result = await MediaImportExecutor(store: store).execute(
            plan: plan,
            batch: ImportBatchID(),
            sourceKind: .removableVolume,
            sourceDeviceIdentity: "volume:byte-progress",
            deleteSourceRequested: false
        ) { progress in
            collector.record(progress)
        }

        guard case .completed = result else {
            Issue.record("Expected completed execution, got \(result)")
            await coordinator.shutdown()
            return
        }
        let snapshots = collector.snapshots
        #expect(!snapshots.isEmpty)
        #expect(snapshots.allSatisfy { $0.totalCount == 12 && $0.totalBytes == expectedBytes })
        var previousBytes: Int64 = 0
        var previousElapsedMs = 0
        for snapshot in snapshots {
            #expect(snapshot.completedBytes >= previousBytes)
            #expect(snapshot.completedBytes <= expectedBytes)
            previousBytes = snapshot.completedBytes
            // The time base state E needs for "about N seconds left"
            // (import-bar.md, DES-032): monotonic, and near zero at the run's
            // first snapshot rather than carrying over from some other clock.
            #expect(snapshot.elapsedMs >= previousElapsedMs)
            previousElapsedMs = snapshot.elapsedMs
        }
        #expect(snapshots.last?.completedCount == 12)
        #expect(snapshots.last?.completedBytes == expectedBytes)
        #expect((snapshots.first?.elapsedMs ?? .max) < 2000, "First snapshot should be near run start, not carried over")
        let sourceAfter = try FilesystemTreeSnapshot.capture(root: sourceURL)
        #expect(sourceAfter == sourceBefore)
        await coordinator.shutdown()
    }

    /// Plan 0095 D8: when every attempted entry fails `sourceStillMatches` for the
    /// same non-per-file reason — no `cameraImport` gateway wired up, matching a
    /// device session that never opened — the run must report itself as a failure,
    /// not a misleadingly-labeled `.completed(failedCount: N of N)`.
    @Test func allEntriesFailingSourceNotReadyClassifiesRunAsFailed() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let sourceRoot = temp.appending(path: "Camera", directoryHint: .isDirectory)
        let destinationRoot = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let sourcePath = try CatalogPath.normalizedDirectoryPath(for: sourceRoot)
        let destinationPath = try CatalogPath.normalizedDirectoryPath(for: destinationRoot)
        let facts = (0 ..< 2).map { index -> PlanningFileFacts in
            let relative = MediaRelativePath(rawValue: "IMG_\(index).JPG")
            return PlanningFileFacts(
                id: MediaAssetID(libraryRootPath: sourcePath, relativePath: relative),
                sourceURL: sourceRoot.appending(path: relative.rawValue),
                relativePath: relative,
                byteSize: 10,
                contentModifiedAt: Date(timeIntervalSince1970: 100),
                captureWallCompact: nil,
                mediaKind: .image,
                fileExtension: "JPG",
                companions: [],
                contentTypeIdentifier: "public.jpeg"
            )
        }
        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .none
        policy.destinationNamePolicy = .original
        let snapshot = ImportPlanningSnapshot(
            generation: 1,
            sourceRoot: sourcePath,
            destinationRoot: destinationPath,
            sourceOccupancyRevision: 1,
            destinationOccupancyRevision: 1,
            sourceMedia: facts,
            destinationOccupants: [:],
            policy: policy,
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0) ?? .current
        )
        let plan = MediaTransferPlanner.buildImportPlan(snapshot: snapshot)
        #expect(plan.entries.count == 2)

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destinationRoot)
        let result = await MediaImportExecutor(store: store).execute(
            plan: plan,
            batch: ImportBatchID(),
            sourceKind: .deviceMTP,
            sourceDeviceIdentity: "camera:serial",
            deleteSourceRequested: false
        ) { _ in }

        guard case let .failed(reason) = result else {
            Issue.record("Expected systemic sourceNotReady failure, got \(result)")
            return
        }
        #expect(reason == .sourceNotReady)
    }

    /// A per-file staleness failure alongside a successful entry must stay
    /// `.completed(failedCount:)` — only a run where every attempted entry fails
    /// the *same* `.sourceNotReady` way is systemic (plan 0095 D8).
    @Test func mixedFailureReasonsStayCompletedNotSystemic() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let sourceRoot = temp.appending(path: "Card", directoryHint: .isDirectory)
        let destinationRoot = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        let keepURL = sourceRoot.appending(path: "keep.jpg")
        let staleURL = sourceRoot.appending(path: "stale.jpg")
        let modifiedAt = Date(timeIntervalSince1970: 100)
        try Data(repeating: 0x01, count: 10).write(to: keepURL)
        try Data(repeating: 0x02, count: 10).write(to: staleURL)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: keepURL.path)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: staleURL.path)

        let sourcePath = try CatalogPath.normalizedDirectoryPath(for: sourceRoot)
        let destinationPath = try CatalogPath.normalizedDirectoryPath(for: destinationRoot)
        func facts(name: String) -> PlanningFileFacts {
            let relative = MediaRelativePath(rawValue: name)
            return PlanningFileFacts(
                id: MediaAssetID(libraryRootPath: sourcePath, relativePath: relative),
                sourceURL: sourceRoot.appending(path: name),
                relativePath: relative,
                byteSize: 10,
                contentModifiedAt: modifiedAt,
                captureWallCompact: nil,
                mediaKind: .image,
                fileExtension: "jpg",
                companions: [],
                contentTypeIdentifier: "public.jpeg"
            )
        }
        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .none
        policy.destinationNamePolicy = .original
        let snapshot = ImportPlanningSnapshot(
            generation: 1,
            sourceRoot: sourcePath,
            destinationRoot: destinationPath,
            sourceOccupancyRevision: 1,
            destinationOccupancyRevision: 1,
            sourceMedia: [facts(name: "keep.jpg"), facts(name: "stale.jpg")],
            destinationOccupants: [:],
            policy: policy,
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0) ?? .current
        )
        let plan = MediaTransferPlanner.buildImportPlan(snapshot: snapshot)
        #expect(plan.entries.count == 2)

        // Mutate stale.jpg's live bytes after the plan captured its facts, forcing
        // a per-file `.changed(.size)` staleness failure alongside the other
        // entry's success.
        try Data(repeating: 0x03, count: 20).write(to: staleURL)

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destinationRoot)
        let result = await MediaImportExecutor(store: store).execute(
            plan: plan,
            batch: ImportBatchID(),
            sourceKind: .removableVolume,
            sourceDeviceIdentity: "volume:mixed-failure",
            deleteSourceRequested: false
        ) { _ in }

        guard case let .completed(publishedCount, _, hasEntryFailures, _, failedCount, _) = result else {
            Issue.record("Expected completed with one per-file failure, got \(result)")
            return
        }
        #expect(publishedCount == 1)
        #expect(failedCount == 1)
        #expect(hasEntryFailures)
    }

    /// Plan 0095 D12: state F-incomplete's "Show them" reveal selects from
    /// the batch row's destination-keyed grid, but `incompleteItems` used to
    /// record `entry.source.id` — the source card's identity, which never
    /// matches anything there, so the reveal selected nothing. A
    /// `.skippedForeign` entry now records the destination identity — the
    /// one thing actually sitting at that path for the reveal to select.
    @Test func incompleteItemsCarryDestinationIdentityNotSourceIdentity() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let sourceRoot = temp.appending(path: "Card", directoryHint: .isDirectory)
        let destinationRoot = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        let sourceURL = sourceRoot.appending(path: "a.jpg")
        let modifiedAt = Date(timeIntervalSince1970: 100)
        try Data(repeating: 0x01, count: 10).write(to: sourceURL)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: sourceURL.path)

        let sourcePath = try CatalogPath.normalizedDirectoryPath(for: sourceRoot)
        let destinationPath = try CatalogPath.normalizedDirectoryPath(for: destinationRoot)
        let relative = MediaRelativePath(rawValue: "a.jpg")
        let facts = PlanningFileFacts(
            id: MediaAssetID(libraryRootPath: sourcePath, relativePath: relative),
            sourceURL: sourceURL,
            relativePath: relative,
            byteSize: 10,
            contentModifiedAt: modifiedAt,
            captureWallCompact: nil,
            mediaKind: .image,
            fileExtension: "jpg",
            companions: [],
            contentTypeIdentifier: "public.jpeg"
        )
        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .none
        policy.destinationNamePolicy = .original
        let snapshot = ImportPlanningSnapshot(
            generation: 1,
            sourceRoot: sourcePath,
            destinationRoot: destinationPath,
            sourceOccupancyRevision: 1,
            destinationOccupancyRevision: 1,
            sourceMedia: [facts],
            destinationOccupants: [:],
            policy: policy,
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0) ?? .current
        )
        let plan = MediaTransferPlanner.buildImportPlan(snapshot: snapshot)
        #expect(plan.entries.count == 1)
        guard case .copy = plan.entries[0].disposition else {
            Issue.record("Expected a .copy disposition, got \(plan.entries[0].disposition)")
            return
        }
        let finalDestination = plan.entries[0].finalDestination

        // A foreign file lands at the computed destination path after
        // planning — a race, or a stale plan — forcing copyEntry's existence
        // check to skip it as foreign at execution time.
        try Data(repeating: 0x02, count: 20).write(to: destinationRoot.appending(path: finalDestination.rawValue))

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destinationRoot)
        let result = await MediaImportExecutor(store: store).execute(
            plan: plan,
            batch: ImportBatchID(),
            sourceKind: .removableVolume,
            sourceDeviceIdentity: "volume:d12-destination-identity",
            deleteSourceRequested: false
        ) { _ in }

        guard case let .completed(_, _, _, skippedForeignCount, _, incompleteItems) = result else {
            Issue.record("Expected completed with a skipped-foreign entry, got \(result)")
            return
        }
        #expect(skippedForeignCount == 1)
        let expectedDestinationID = MediaAssetID(libraryRootPath: destinationPath, relativePath: finalDestination)
        #expect(incompleteItems == [expectedDestinationID])
        #expect(!incompleteItems.contains(plan.entries[0].source.id))
    }

    @Test func zeroCopyPlanWithDeleteRequestedExecutesDeletion() async throws {
        let fixture = try await makeZeroCopyFixture()
        let result = await MediaImportExecutor(store: fixture.store).execute(
            plan: fixture.plan,
            batch: ImportBatchID(),
            sourceKind: .removableVolume,
            sourceDeviceIdentity: "volume:zero-copy-delete",
            deleteSourceRequested: true
        ) { _ in }

        guard case let .completedWithErase(_, _, _, _, _, _, eraseOutcome) = result else {
            Issue.record("Expected zero-copy deletion to complete, got \(result)")
            return
        }
        #expect(eraseOutcome.deletedCount == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.sourceFile.path))
        #expect(try await fixture.store.activeImportOperations().isEmpty)
    }

    @Test func zeroCopyPlanWithoutDeleteStaysReady() async throws {
        let fixture = try await makeZeroCopyFixture()
        let sourceBefore = try FilesystemTreeSnapshot.capture(root: fixture.sourceRoot)
        let result = await MediaImportExecutor(store: fixture.store).execute(
            plan: fixture.plan,
            batch: ImportBatchID(),
            sourceKind: .removableVolume,
            sourceDeviceIdentity: "volume:zero-copy-no-delete",
            deleteSourceRequested: false
        ) { _ in }

        guard case .completed = result else {
            Issue.record("Expected zero-copy execution to complete, got \(result)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: fixture.sourceFile.path))
        let sourceAfter = try FilesystemTreeSnapshot.capture(root: fixture.sourceRoot)
        #expect(sourceAfter == sourceBefore)
        #expect(try await fixture.store.activeImportOperations().isEmpty)
    }

    @Test func failedCopySourceSurvivesEraseSweep() async throws {
        let fixture = try await makeZeroCopyFixture()
        try FileManager.default.removeItem(at: fixture.destinationFile)
        let original = try #require(fixture.plan.entries.first)
        let staleFacts = PlanningFileFacts(
            id: original.source.id,
            sourceURL: original.source.sourceURL,
            relativePath: original.source.relativePath,
            byteSize: 11,
            contentModifiedAt: original.source.contentModifiedAt,
            captureWallCompact: original.source.captureWallCompact,
            namingFactState: original.source.namingFactState,
            mediaKind: original.source.mediaKind,
            fileExtension: original.source.fileExtension,
            companions: original.source.companions,
            contentTypeIdentifier: original.source.contentTypeIdentifier
        )
        let entry = MediaOperationPlanEntry(
            source: staleFacts,
            idealDestination: original.idealDestination,
            finalDestination: original.finalDestination,
            companionDestinations: original.companionDestinations,
            disposition: .copy(destination: original.finalDestination)
        )
        let plan = MediaOperationPlan(
            generation: fixture.plan.generation,
            mode: fixture.plan.mode,
            sourceOccupancyRevision: fixture.plan.sourceOccupancyRevision,
            destinationOccupancyRevision: fixture.plan.destinationOccupancyRevision,
            policy: fixture.plan.policy,
            entries: [entry],
            totals: MediaOperationPlanTotals(
                copyCount: 1,
                skipCount: 0,
                blockedCount: 0,
                companionCopyCount: 0,
                copyBytes: 11
            )
        )

        let result = await MediaImportExecutor(store: fixture.store).execute(
            plan: plan,
            batch: ImportBatchID(),
            sourceKind: .removableVolume,
            sourceDeviceIdentity: "volume:failed-copy-survival",
            deleteSourceRequested: true
        ) { _ in }

        guard case let .completedWithErase(_, _, _, _, failedCount, _, eraseOutcome) = result else {
            Issue.record("Expected a completed erase result, got \(result)")
            return
        }
        #expect(failedCount == 1)
        #expect(eraseOutcome.deletedCount == 0)
        #expect(FileManager.default.fileExists(atPath: fixture.sourceFile.path))
    }

    @Test func containmentHelperAcceptsDirectoryURLSlashAndNormalizedRoot() throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = try CatalogPath.normalizedDirectoryPath(for: temp)
        let inside = root.url.appending(path: "same.jpg")
        let outside = temp.deletingLastPathComponent().appending(path: "same.jpg")
        #expect(CatalogPath.relativePathIfContained(rootPath: root, fileURL: inside) == MediaRelativePath(rawValue: "same.jpg"))
        let trailingSlashRoot = LibraryRootPath(rawValue: root.rawValue + "/")
        #expect(CatalogPath.relativePathIfContained(rootPath: trailingSlashRoot, fileURL: inside) == MediaRelativePath(rawValue: "same.jpg"))
        #expect(CatalogPath.relativePathIfContained(rootPath: root, fileURL: outside) == nil)
    }

    private struct ZeroCopyFixture {
        let store: CatalogStore
        let plan: MediaOperationPlan
        let sourceRoot: URL
        let sourceFile: URL
        let destinationFile: URL
    }

    private func makeZeroCopyFixture() async throws -> ZeroCopyFixture {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let sourceRoot = temp.appending(path: "Card", directoryHint: .isDirectory)
        let destinationRoot = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let sourceFile = sourceRoot.appending(path: "same.jpg")
        let destinationFile = destinationRoot.appending(path: "same.jpg")
        let modifiedAt = Date(timeIntervalSince1970: 100)
        try Data(repeating: 0x42, count: 10).write(to: sourceFile)
        try Data(repeating: 0x42, count: 10).write(to: destinationFile)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: sourceFile.path)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: destinationFile.path)

        let sourcePath = try CatalogPath.normalizedDirectoryPath(for: sourceRoot)
        let destinationPath = try CatalogPath.normalizedDirectoryPath(for: destinationRoot)
        let relative = MediaRelativePath(rawValue: "same.jpg")
        let facts = PlanningFileFacts(
            id: MediaAssetID(libraryRootPath: sourcePath, relativePath: relative),
            sourceURL: sourceFile,
            relativePath: relative,
            byteSize: 10,
            contentModifiedAt: modifiedAt,
            captureWallCompact: nil,
            mediaKind: .image,
            fileExtension: "jpg",
            companions: [],
            contentTypeIdentifier: "public.jpeg"
        )
        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .none
        policy.destinationNamePolicy = .original
        let snapshot = ImportPlanningSnapshot(
            generation: 1,
            sourceRoot: sourcePath,
            destinationRoot: destinationPath,
            sourceOccupancyRevision: 1,
            destinationOccupancyRevision: 1,
            sourceMedia: [facts],
            destinationOccupants: [:],
            policy: policy,
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0) ?? .current
        )
        let plan = MediaTransferPlanner.buildImportPlan(snapshot: snapshot)
        #expect(plan.entries.first?.isSkipPreexisting == true)
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destinationRoot)
        return ZeroCopyFixture(
            store: store,
            plan: plan,
            sourceRoot: sourceRoot,
            sourceFile: sourceFile,
            destinationFile: destinationFile
        )
    }

    private func waitForReadyPlan(
        _ coordinator: MediaOperationCoordinator,
        source: LibraryRootPath,
        timeout: Duration = .seconds(5)
    ) async throws -> MediaOperationPlan {
        let deadline = ContinuousClock().now + timeout
        while ContinuousClock().now < deadline {
            if let plan = await coordinator.readyPlan(for: source) {
                return plan
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw ReadyPlanUnavailable()
    }
}

private struct ReadyPlanUnavailable: Error {}

private final class ProgressCollector: Sendable {
    private let recorder = TestRecorder<MediaOperationProgress>()

    nonisolated func record(_ progress: MediaOperationProgress) {
        recorder.record(progress)
    }

    nonisolated var snapshots: [MediaOperationProgress] {
        recorder.values
    }
}
