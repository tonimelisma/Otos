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
                    return .failed(.other(String(describing: error)))
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
            destinationTempURL: staging
        )
        #expect(result == .completed)
        #expect(try Data(contentsOf: staging) == Data([0x01, 0x02]))
    }

    /// A camera download refused for space is typed from the error chain, not
    /// its wording, so the executor can stop at the floor for a camera the way
    /// it does for a card (ADR 0027). Anything else stays a per-entry failure.
    @Test func downloadFailureIsOutOfSpaceOnlyFromATypedChain() {
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError, userInfo: nil)
        #expect(CameraByteFailure(cocoa) == .outOfSpace)
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC), userInfo: nil)
        #expect(CameraByteFailure(posix) == .outOfSpace)
        let wrapped = NSError(
            domain: "com.apple.ImageCaptureCore",
            code: -9999,
            userInfo: [NSUnderlyingErrorKey: posix]
        )
        #expect(CameraByteFailure(wrapped) == .outOfSpace)
        let wordsOnly = NSError(
            domain: "com.apple.ImageCaptureCore",
            code: -9999,
            userInfo: [NSLocalizedDescriptionKey: "No space left on device"]
        )
        guard case .other = CameraByteFailure(wordsOnly) else {
            Issue.record("An untyped error must not be classified by its wording")
            return
        }
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
        // Plan 0099: Ready requires proven naming facts; stand in for the enrichment
        // coordinator these tests do not run.
        await markEnrichmentLookedAtEveryRow(store, root: source)
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
            deleteSourceRequested: false,
            runID: UUID().uuidString
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
            sourceNamespaceRevision: 1,
            sourceNamingRevision: 0,
            destinationNamespaceRevision: 1,
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
            deleteSourceRequested: false,
            runID: UUID().uuidString
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
            sourceNamespaceRevision: 1,
            sourceNamingRevision: 0,
            destinationNamespaceRevision: 1,
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
            deleteSourceRequested: false,
            runID: UUID().uuidString
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
            sourceNamespaceRevision: 1,
            sourceNamingRevision: 0,
            destinationNamespaceRevision: 1,
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
            deleteSourceRequested: false,
            runID: UUID().uuidString
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
            deleteSourceRequested: true,
            runID: UUID().uuidString
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
            deleteSourceRequested: false,
            runID: UUID().uuidString
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
            sourceNamespaceRevision: fixture.plan.sourceNamespaceRevision,
            sourceNamingRevision: 0,
            destinationNamespaceRevision: fixture.plan.destinationNamespaceRevision,
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
            deleteSourceRequested: true,
            runID: UUID().uuidString
        ) { _ in }

        guard case let .completedWithErase(_, _, _, _, failedCount, _, eraseOutcome) = result else {
            Issue.record("Expected a completed erase result, got \(result)")
            return
        }
        #expect(failedCount == 1)
        #expect(eraseOutcome.deletedCount == 0)
        #expect(FileManager.default.fileExists(atPath: fixture.sourceFile.path))
    }

    @Test func busySourceNamespaceLeavesTheCopyStandingAndReportsAnIncompleteErase() async throws {
        let fixture = try await makeZeroCopyFixture()
        let sourcePath = try CatalogPath.normalizedDirectoryPath(for: fixture.sourceRoot)
        // Another namespace owner holds the card for the whole run. Before this
        // increment the executor took this lease in `execute()` and turned a
        // denial into `.failed(reason: .sourceRemoved)` — "The card was removed" —
        // aborting the import before a single byte moved.
        guard case .acquired = await fixture.store.acquireNamespaceMutationLease(
            for: sourcePath,
            owner: .mediaTrash
        ) else {
            Issue.record("Expected to hold the source namespace for this test")
            return
        }

        let result = await MediaImportExecutor(store: fixture.store).execute(
            plan: fixture.plan,
            batch: ImportBatchID(),
            sourceKind: .removableVolume,
            sourceDeviceIdentity: "volume:busy-source-namespace",
            deleteSourceRequested: true,
            runID: UUID().uuidString
        ) { _ in }

        guard case let .completedWithErase(_, _, _, _, _, _, eraseOutcome) = result else {
            Issue.record("A busy source namespace must not fail the import, got \(result)")
            return
        }
        // The erase is reported incomplete, which is the state `import-bar.md`
        // already specifies; nothing on the card is touched.
        #expect(eraseOutcome.deletedCount == 0)
        #expect(eraseOutcome.failedCount > 0)
        #expect(FileManager.default.fileExists(atPath: fixture.sourceFile.path))
    }

    @Test func everyJournaledEraseForOneRootRecoversInOneSweep() async throws {
        let fixture = try await makeZeroCopyFixture()
        let sourcePath = try CatalogPath.normalizedDirectoryPath(for: fixture.sourceRoot)

        // Several entries for the *same* root: the shape that made per-entry
        // lease acquisition race its own detached release, so only the first
        // entry recovered and the rest returned unlogged.
        var relatives: [MediaRelativePath] = []
        for index in 0 ..< 5 {
            let relative = MediaRelativePath(rawValue: "orphan-\(index).jpg")
            relatives.append(relative)
            let url = fixture.sourceRoot.appending(path: relative.rawValue)
            try Data(repeating: 0x37, count: 4).write(to: url)
            try await fixture.store.beginSourceEraseOperation(
                ActiveSourceEraseOperation(
                    key: UUID().uuidString,
                    sourceKind: .removableVolume,
                    sourceDeviceIdentity: "volume:zero-copy-fixture",
                    sourceRootPath: sourcePath,
                    sourceRelativePath: relative,
                    sourceByteSize: 4,
                    updatedAt: Date()
                )
            )
        }
        #expect(try await fixture.store.activeSourceEraseOperations().count == 5)

        await MediaImportExecutor(store: fixture.store).recoverJournal()

        for relative in relatives {
            let url = fixture.sourceRoot.appending(path: relative.rawValue)
            #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        }
        #expect(try await fixture.store.activeSourceEraseOperations().isEmpty)
    }

    // MARK: - ADR 0027: the disk floor

    private struct CardFixture {
        let store: CatalogStore
        let plan: MediaOperationPlan
        let sourceRoot: URL
        let destinationRoot: URL
        let destinationPath: LibraryRootPath
    }

    /// `count` real files of `bytesEach` on a card, planned into an empty
    /// library with original names — the shape every floor test starts from.
    private func makeCardFixture(count: Int, bytesEach: Int) async throws -> CardFixture {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let sourceRoot = temp.appending(path: "Card", directoryHint: .isDirectory)
        let destinationRoot = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let sourcePath = try CatalogPath.normalizedDirectoryPath(for: sourceRoot)
        let destinationPath = try CatalogPath.normalizedDirectoryPath(for: destinationRoot)
        let modifiedAt = Date(timeIntervalSince1970: 100)
        let facts = try (0 ..< count).map { index -> PlanningFileFacts in
            let relative = MediaRelativePath(rawValue: "IMG_\(index).jpg")
            let url = sourceRoot.appending(path: relative.rawValue)
            try Data(repeating: UInt8(index + 1), count: bytesEach).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
            return PlanningFileFacts(
                id: MediaAssetID(libraryRootPath: sourcePath, relativePath: relative),
                sourceURL: url,
                relativePath: relative,
                byteSize: Int64(bytesEach),
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
            sourceNamespaceRevision: 1,
            sourceNamingRevision: 0,
            destinationNamespaceRevision: 1,
            sourceMedia: facts,
            destinationOccupants: [:],
            policy: policy,
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0) ?? .current
        )
        let plan = MediaTransferPlanner.buildImportPlan(snapshot: snapshot)
        #expect(plan.totals.copyCount == count)
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destinationRoot)
        return CardFixture(store: store, plan: plan, sourceRoot: sourceRoot, destinationRoot: destinationRoot, destinationPath: destinationPath)
    }

    /// Bytes currently sitting in a directory tree — what a live volume's
    /// capacity would have lost to the copies that landed.
    private static func bytesLanded(under root: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    private func executeFloorRun(
        _ fixture: CardFixture,
        deleteSourceRequested: Bool = false,
        volumeCapacity: @escaping @Sendable (URL) -> Int64?
    ) async -> MediaImportExecutionResult {
        await MediaImportExecutor(store: fixture.store, volumeCapacity: volumeCapacity).execute(
            plan: fixture.plan,
            batch: ImportBatchID(),
            sourceKind: .removableVolume,
            sourceDeviceIdentity: "volume:disk-floor",
            deleteSourceRequested: deleteSourceRequested,
            runID: UUID().uuidString
        ) { _ in }
    }

    /// Three 1 KB entries into a volume with room for two above the floor:
    /// two land, the third is never attempted, and the run settles as stopped
    /// at the floor with the count it actually published.
    @Test func theFloorStopsTheRunBeforeTheEntryThatWouldBreachIt() async throws {
        let fixture = try await makeCardFixture(count: 3, bytesEach: 1024)
        let destination = fixture.destinationRoot
        let result = await executeFloorRun(fixture) { _ in
            FreeSpaceFloor.bytes + 2500 - Self.bytesLanded(under: destination)
        }
        guard case let .stopped(reason, publishedCount, _, _, _, failedCount) = result else {
            Issue.record("Expected a stopped run, got \(result)")
            return
        }
        guard case .diskFloor = reason else {
            Issue.record("Expected the disk floor as the reason, got \(reason)")
            return
        }
        #expect(publishedCount == 2)
        #expect(failedCount == 0, "an entry the floor refused was never attempted, so it is not a failure")
        #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "IMG_2.jpg").path))
    }

    /// A capacity figure that never moves (CacheDelete lagging) must not admit
    /// the third entry either: the bytes already in flight are counted.
    @Test func inFlightBytesCountEvenWhenTheCapacityFigureIsStale() async throws {
        let fixture = try await makeCardFixture(count: 3, bytesEach: 1024)
        let result = await executeFloorRun(fixture) { _ in FreeSpaceFloor.bytes + 2500 }
        guard case let .stopped(_, publishedCount, _, _, _, _) = result else {
            Issue.record("Expected a stopped run, got \(result)")
            return
        }
        #expect(publishedCount == 2)
    }

    /// A volume that does not answer admits everything; `ENOSPC` is the
    /// backstop, not a guess.
    @Test func anUnknownCapacityAdmitsEveryEntry() async throws {
        let fixture = try await makeCardFixture(count: 3, bytesEach: 1024)
        let result = await executeFloorRun(fixture) { _ in nil }
        guard case let .completed(publishedCount, _, _, _, _, _) = result else {
            Issue.record("Expected a completed run, got \(result)")
            return
        }
        #expect(publishedCount == 3)
    }

    /// A floor stop is never fully clean: with erase requested, the end-of-run
    /// sweep does not run and the result is `.stopped`, not
    /// `.completedWithErase`. Delete-after-import of entries that *landed* is
    /// unchanged — each is erased on its own settle, once proven in the
    /// library — while the entry the floor refused, which exists nowhere but
    /// the card, is never touched.
    @Test func aFloorStopNeverRunsTheEraseSweep() async throws {
        let fixture = try await makeCardFixture(count: 3, bytesEach: 1024)
        let destination = fixture.destinationRoot
        let result = await executeFloorRun(fixture, deleteSourceRequested: true) { _ in
            FreeSpaceFloor.bytes + 2500 - Self.bytesLanded(under: destination)
        }
        guard case let .stopped(_, publishedCount, _, _, _, _) = result else {
            Issue.record("Expected a stopped run, got \(result)")
            return
        }
        #expect(publishedCount == 2)
        #expect(!FileManager.default.fileExists(atPath: fixture.sourceRoot.appending(path: "IMG_0.jpg").path), "landed, proven, erased on settle")
        #expect(!FileManager.default.fileExists(atPath: fixture.sourceRoot.appending(path: "IMG_1.jpg").path), "landed, proven, erased on settle")
        #expect(FileManager.default.fileExists(atPath: fixture.sourceRoot.appending(path: "IMG_2.jpg").path), "refused by the floor: still only on the card")
        #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "IMG_2.jpg").path))
    }

    /// The write itself refusing for space is the same stop: the entry that
    /// hit `ENOSPC` is not counted as a failure — it never landed and the
    /// re-plan offers it again — and nothing after it is attempted.
    @Test func anOutOfSpaceWriteStopsTheRunTheSameWay() async throws {
        let fixture = try await makeCardFixture(count: 3, bytesEach: 1024)
        let executor = MediaImportExecutor(
            store: fixture.store,
            volumeCapacity: { _ in nil },
            transfer: { source, destination, onProgress, shouldContinue in
                if source.lastPathComponent == "IMG_1.jpg" {
                    return .failed(errno: ENOSPC)
                }
                return CopyfileTransfer.copy(from: source, to: destination, onProgress: onProgress, shouldContinue: shouldContinue)
            }
        )
        let result = await executor.execute(
            plan: fixture.plan,
            batch: ImportBatchID(),
            sourceKind: .removableVolume,
            sourceDeviceIdentity: "volume:enospc",
            deleteSourceRequested: false,
            runID: UUID().uuidString
        ) { _ in }
        guard case let .stopped(reason, publishedCount, _, _, _, failedCount) = result else {
            Issue.record("Expected a stopped run, got \(result)")
            return
        }
        guard case .diskFloor = reason else {
            Issue.record("Expected the disk floor as the reason, got \(reason)")
            return
        }
        #expect(publishedCount >= 1)
        #expect(failedCount == 0)
    }

    @Test func containmentHelperAcceptsDirectoryURLSlashAndNormalizedRoot() throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = try CatalogPath.normalizedDirectoryPath(for: temp)
        let inside = root.url.appending(path: "same.jpg")
        let outside = temp.deletingLastPathComponent().appending(path: "same.jpg")
        #expect(CatalogPath.relativePath(rootPath: root, fileURL: inside) == MediaRelativePath(rawValue: "same.jpg"))
        let trailingSlashRoot = LibraryRootPath(rawValue: root.rawValue + "/")
        #expect(CatalogPath.relativePath(rootPath: trailingSlashRoot, fileURL: inside) == MediaRelativePath(rawValue: "same.jpg"))
        #expect(CatalogPath.relativePath(rootPath: root, fileURL: outside) == nil)
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
            sourceNamespaceRevision: 1,
            sourceNamingRevision: 0,
            destinationNamespaceRevision: 1,
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
        // The card is attached, not merely a path on disk. `MediaOperationCoordinator`
        // only ever executes an import for a source it read out of
        // `store.currentLibraries()`, so an unattached source root is not a
        // configuration production can reach — and erase, which takes that root's
        // namespace lease, is correctly refused for a root the catalog does not own.
        try await store.attachRemovableVolume(
            mountURL: sourceRoot,
            identity: "volume:zero-copy-fixture",
            displayName: "Card",
            isEjectable: true
        )
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
