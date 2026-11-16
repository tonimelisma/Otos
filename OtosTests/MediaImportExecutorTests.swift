import Foundation
@testable import OtosKit
import Synchronization
import Testing

@Suite(.testScope)
struct ExclusivePublicationTests {
    @Test func refusesOverwriteWhenFinalExists() throws {
        let temp = try makeTestDirectory()
        let staging = temp.appending(path: ".stage.otos-import-staging")
        let final = temp.appending(path: "final.jpg")
        try Data([0x01]).write(to: staging)
        try Data([0x02]).write(to: final)

        let outcome = ExclusivePublication.publish(staging: staging, final: final)
        #expect(outcome == .destinationExists)
        #expect(try Data(contentsOf: final) == Data([0x02]))
    }
}

extension ExclusivePublicationTests {
    /// A publication refused for space says so, typed, so an import stops at the floor
    /// instead of failing entry after entry (ADR 0027).
    @Test func aPublicationRefusedForSpaceIsTypedAsSuch() {
        #expect(ExclusivePublication.Failure(errno: ENOSPC, call: "renamex_np").outOfSpace)
        #expect(!ExclusivePublication.Failure(errno: EACCES, call: "renamex_np").outOfSpace)
        #expect(ExclusivePublication.Failure(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))).outOfSpace)
    }
}

@Suite(.testScope)
struct CopyfileTransferTests {
    /// copyfile(3) writes a failed data or attribute step again when the callback answers
    /// continue, so a full disk retried forever. A failed step quits, and cancellation
    /// still wins (verified on a 10 MB disk image: continue retried 2,001 times in 0.03 s,
    /// quit stopped after one failure with ENOSPC).
    @Test func aFailedStepQuitsTheCopyInsteadOfRetrying() {
        #expect(CopyfileTransfer.statusAnswer(stage: COPYFILE_ERR, shouldContinue: true) == .fail)
        #expect(CopyfileTransfer.statusAnswer(stage: COPYFILE_PROGRESS, shouldContinue: true) == .proceed)
        #expect(CopyfileTransfer.statusAnswer(stage: COPYFILE_ERR, shouldContinue: false) == .cancel)
    }

    @Test func copiesBytesAndReportsCompletion() throws {
        let temp = try makeTestDirectory()
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

    /// `copyfile(3)` reports data progress once per block it writes, and asks whether to
    /// continue before each report. Answering "stop" at the first ask after bytes have
    /// landed cancels with the destination genuinely partial: some bytes written, not
    /// all. The written count is asserted rather than assumed, so a copy that finished
    /// in one block fails here instead of passing as a cancellation.
    @Test func cancelRemovesPartialDestination() throws {
        let temp = try makeTestDirectory()
        let source = temp.appending(path: "source.bin")
        let destination = temp.appending(path: "dest.bin")
        let total: Int64 = 8 * 1024 * 1024
        try Data(repeating: 0xCD, count: Int(total)).write(to: source)

        let written = Mutex<Int64>(0)
        let outcome = CopyfileTransfer.copy(
            from: source,
            to: destination,
            onProgress: { progress in written.withLock { $0 = progress.completedBytes } },
            shouldContinue: { written.withLock { $0 } == 0 }
        )

        #expect(outcome == .cancelled)
        let writtenAtCancel = written.withLock { $0 }
        #expect(writtenAtCancel > 0 && writtenAtCancel < total)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}

@Suite(.testScope)
struct ActiveFileOperationJournalTests {
    @Test func journalRoundTripsThroughStore() async throws {
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)

        let operation = ActiveFileOperation(
            operationKey: .make(),
            sourceKind: .removableVolume,
            sourceDeviceIdentity: .volume(uuid: "test"),
            sourceRootPath: LibraryRootPath(rawValue: "/Volumes/CARD"),
            sourceRelativePath: MediaRelativePath(rawValue: "IMG_1.JPG"),
            destinationRootPath: LibraryRootPath(rawValue: "/Users/example/Pictures"),
            destinationRelativePath: MediaRelativePath(rawValue: "2026/07/IMG_1.JPG"),
            stagingURL: URL(fileURLWithPath: "/Users/example/Pictures/.tmp.otos-import-staging"),
            companionStagingURLs: [],
            contentHash: .empty,
            importBatch: ImportBatchID(unixMilliseconds: 1_704_067_200_000),
            sourceByteSize: 100,
            sourceModifiedAt: Date(timeIntervalSince1970: 1000),
            destinationModifiedAt: Date(timeIntervalSince1970: 1000),
            phase: .copying,
            updatedAt: Date()
        )
        try await store.beginImportOperation(operation)
        let loaded = try await store.backgroundReads.activeImportOperations()
        #expect(loaded.count == 1)
        #expect(loaded.first?.operationKey == operation.operationKey)
        #expect(loaded.first?.phase == .copying)
        #expect(loaded.first?.contentHash == .empty)

        var updated = operation
        updated.phase = .readyToPublish
        updated.updatedAt = Date()
        try await store.recordImportOperationProgress(updated)
        let reloaded = try await store.backgroundReads.activeImportOperations()
        #expect(reloaded.first?.phase == .readyToPublish)
        #expect(reloaded.first?.contentHash == .empty)

        try await store.abandonImportOperation(key: operation.operationKey)
        #expect(try await store.backgroundReads.activeImportOperations().isEmpty)
    }
}

@Suite(.testScope)
struct ImportRecoveryTests {
    private func operation(
        rootPath: LibraryRootPath,
        destinationRelativePath: String = "final.jpg",
        stagingURL: URL?,
        digest: ContentDigest,
        byteSize: Int64,
        modifiedAt: Date,
        phase: ActiveFileOperationPhase = .readyToPublish
    ) -> ActiveFileOperation {
        ActiveFileOperation(
            operationKey: .make(),
            sourceKind: .removableVolume,
            sourceDeviceIdentity: .volume(uuid: "test"),
            sourceRootPath: LibraryRootPath(rawValue: "/Volumes/CARD"),
            sourceRelativePath: MediaRelativePath(rawValue: "IMG_1.JPG"),
            destinationRootPath: rootPath,
            destinationRelativePath: MediaRelativePath(rawValue: destinationRelativePath),
            stagingURL: stagingURL,
            companionStagingURLs: [],
            contentHash: digest,
            importBatch: ImportBatchID(unixMilliseconds: 1_704_067_200_000),
            sourceByteSize: byteSize,
            sourceModifiedAt: Date(timeIntervalSince1970: 1000),
            destinationModifiedAt: modifiedAt,
            phase: phase,
            updatedAt: Date()
        )
    }

    @Test func readyToPublishRecoveryPublishesAndSettlesJournaledDigest() async throws {
        let temp = try makeTestDirectory()
        let destination = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let final = destination.appending(path: "final.jpg", directoryHint: .notDirectory)
        let staging = destination.appending(path: ".stage.otos-import-staging", directoryHint: .notDirectory)
        try Data("imported".utf8).write(to: staging)
        let digest: ContentDigest
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
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destination)
        let operation = ActiveFileOperation(
            operationKey: .make(),
            sourceKind: .removableVolume,
            sourceDeviceIdentity: .volume(uuid: "test"),
            sourceRootPath: LibraryRootPath(rawValue: "/Volumes/CARD"),
            sourceRelativePath: MediaRelativePath(rawValue: "IMG_1.JPG"),
            destinationRootPath: rootPath,
            destinationRelativePath: MediaRelativePath(rawValue: "final.jpg"),
            stagingURL: staging,
            companionStagingURLs: [],
            contentHash: digest,
            importBatch: ImportBatchID(unixMilliseconds: 1_704_067_200_000),
            sourceByteSize: 8,
            sourceModifiedAt: Date(timeIntervalSince1970: 1000),
            destinationModifiedAt: expectedDestinationDate,
            phase: .readyToPublish,
            updatedAt: Date()
        )
        try await store.beginImportOperation(operation)

        await MediaImportRecovery(store: store).run()

        #expect(FileManager.default.fileExists(atPath: final.path))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(try await store.backgroundReads.activeImportOperations().isEmpty)
        let asset = try #require(try await catalogStoreTestState(store).testAssets.first)
        #expect(asset.contentHash == digest)
        #expect(asset.contentHashSourceSize == 8)
    }

    @Test func finalAndStagingRecoveryTreatsFinalAsForeign() async throws {
        let temp = try makeTestDirectory()
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
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destination)
        let op = operation(
            rootPath: rootPath,
            stagingURL: staging,
            digest: digest,
            byteSize: 8,
            modifiedAt: Date(timeIntervalSince1970: 1000)
        )
        try await store.beginImportOperation(op)

        await MediaImportRecovery(store: store).run()

        #expect(try Data(contentsOf: final) == Data("foreign!".utf8))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(try await store.backgroundReads.activeImportOperations().isEmpty)
        #expect(try await store.windowReads.importBatches(counting: .every).isEmpty)
    }

    @Test func matchingFinalOnlyRecoverySettlesAfterOwnershipProof() async throws {
        let temp = try makeTestDirectory()
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
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destination)
        let op = operation(
            rootPath: rootPath,
            stagingURL: nil,
            digest: digest,
            byteSize: 8,
            modifiedAt: modifiedAt
        )
        try await store.beginImportOperation(op)

        await MediaImportRecovery(store: store).run()

        #expect(try await store.backgroundReads.activeImportOperations().isEmpty)
        let asset = try #require(try await catalogStoreTestState(store).testAssets.first)
        #expect(asset.contentHash == digest)
    }

    @Test func mismatchingFinalOnlyRecoveryRetainsForeignFinal() async throws {
        let temp = try makeTestDirectory()
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
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destination)
        let op = operation(
            rootPath: rootPath,
            stagingURL: nil,
            digest: digest,
            byteSize: 8,
            modifiedAt: modifiedAt
        )
        try await store.beginImportOperation(op)

        await MediaImportRecovery(store: store).run()

        #expect(try Data(contentsOf: final) == Data("foreign!".utf8))
        #expect(try await store.backgroundReads.activeImportOperations().isEmpty)
        #expect(try await store.windowReads.importBatches(counting: .every).isEmpty)
    }

    /// Launch order: the coordinator starts on its own task, independent of
    /// `CatalogStore.start()`, so its startup recovery can reach the Store before
    /// the persisted roots are loaded. The registered destination root must still
    /// be recognized and the interrupted copy recovered in that same pass.
    /// Recovery removes every staging file the journal names, companions included, and
    /// never publishes a companion: the primary is published and settled, the companion
    /// staging file is gone, and the row with it.
    @Test func recoveryRemovesJournaledCompanionStaging() async throws {
        let temp = try makeTestDirectory()
        let destination = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let store = makeTestStore(location: .inMemory, filesystemWatcher: .noop)
        try await store.start(scansSavedLibraries: false)
        try await store.ensureLibrary(url: destination)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: destination)
        let staging = destination.appending(path: ".primary.otos-import-staging")
        let companionStaging = destination.appending(path: ".companion.otos-import-staging")
        try Data("12345678".utf8).write(to: staging)
        try Data("sidecar".utf8).write(to: companionStaging)
        let modified = Date(timeIntervalSince1970: 2000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: staging.path)
        guard case let .complete(digest) = ContentHasher().hashMaterializedFile(at: staging) else {
            Issue.record("expected a digest")
            return
        }
        var operation = operation(
            rootPath: rootPath,
            stagingURL: staging,
            digest: digest,
            byteSize: 8,
            modifiedAt: modified
        )
        operation.companionStagingURLs = [companionStaging]
        try await store.beginImportOperation(operation)

        await MediaImportRecovery(store: store).run()

        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "final.jpg").path))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(!FileManager.default.fileExists(atPath: companionStaging.path))
        #expect(try await store.backgroundReads.activeImportOperations().isEmpty)
        await store.shutdown()
    }

    /// A staging file that will not go keeps its row, marked abandoned, so nothing is
    /// left in the library that no record names; the next recovery that can remove it
    /// removes the row with it.
    @Test func aStagingFileThatWillNotGoKeepsItsRowUntilItDoes() async throws {
        let temp = try makeTestDirectory()
        let destination = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let locked = destination.appending(path: "locked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let store = makeTestStore(location: .inMemory, filesystemWatcher: .noop)
        try await store.start(scansSavedLibraries: false)
        try await store.ensureLibrary(url: destination)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: destination)
        let staging = locked.appending(path: ".stuck.otos-import-staging")
        try Data("partial".utf8).write(to: staging)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let copying = operation(
            rootPath: rootPath,
            stagingURL: staging,
            digest: .empty,
            byteSize: 7,
            modifiedAt: Date(),
            phase: .copying
        )
        try await store.beginImportOperation(copying)

        await MediaImportRecovery(store: store).run()

        #expect(try await store.backgroundReads.activeImportOperations().map(\.phase) == [.abandoned])
        #expect(FileManager.default.fileExists(atPath: staging.path))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        await MediaImportRecovery(store: store).run()

        #expect(try await store.backgroundReads.activeImportOperations().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        await store.shutdown()
    }

    @Test func coordinatorStartRecoversJournalBeforeStoreLoadsRoots() async throws {
        let temp = try makeTestDirectory()
        let destination = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let staging = destination.appending(path: ".stage.otos-import-staging")
        try Data("partial".utf8).write(to: staging)
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: destination)

        let previousLaunch = makeTestStore(location: .databaseFile(databaseURL))
        try await previousLaunch.start(scansSavedLibraries: false)
        try await previousLaunch.addLibrary(url: destination)
        _ = try await waitForCatalogStoreState(previousLaunch) { !$0.isScanning }
        try await previousLaunch.beginImportOperation(operation(
            rootPath: rootPath,
            stagingURL: staging,
            digest: .empty,
            byteSize: 7,
            modifiedAt: Date(),
            phase: .copying
        ))

        let relaunched = makeTestStore(location: .databaseFile(databaseURL))
        let coordinator = MediaOperationCoordinator(
            store: relaunched,
            preferencesDomain: PreferencesDomain.suite(UUID().uuidString),
            volumeCapacity: ampleVolumeCapacity
        )
        await coordinator.start()

        #expect(try await relaunched.backgroundReads.activeImportOperations().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        await coordinator.shutdown()
    }
}

@Suite(.testScope)
struct CameraImportAccessTests {
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

@Suite(.testScope)
struct ImportExecutionProgressTests {
    @Test func byteProgressIsMonotonicAndReachesPlanTotals() async throws {
        let temp = try makeTestDirectory()
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
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destinationURL)
        let destination = try CatalogPath.normalizedDirectoryPath(for: destinationURL)
        try await store.attachRemovableVolume(
            mountURL: sourceURL,
            identity: .volume(uuid: "byte-progress"),
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )
        let source = try CatalogPath.normalizedDirectoryPath(for: sourceURL)
        _ = try await waitForCatalogStoreState(store) { state in
            !state.isScanning && state.removableSources.first?.activity == .idle
        }
        // Ready requires proven naming facts (ARC-057); stand in for the enrichment
        // coordinator these tests do not run.
        await markEnrichmentLookedAtEveryRow(store, root: source)
        let tempDefaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: tempDefaults,
            volumeCapacity: ampleVolumeCapacity
        )
        await coordinator.start()
        await coordinator.setDestination(destination, for: source)
        let plan = try await waitForReadyPlan(coordinator, source: source)

        let collector = ProgressCollector()
        let started = ContinuousClock.now
        let result = await MediaImportExecutor(store: store, volumeCapacity: ampleVolumeCapacity).execute(
            plan: plan,
            batch: ImportBatchID(),
            sourceKind: .removableVolume,
            sourceDeviceIdentity: .volume(uuid: "byte-progress"),
            deleteSourceRequested: false,
            runID: UUID().uuidString
        ) { progress in
            collector.record(progress)
        }
        let observed = ContinuousClock.now - started

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
            // (import-bar.md, DES-032): monotonic, and counted from the run's own
            // start rather than carried over from some other clock.
            #expect(snapshot.elapsedMs >= previousElapsedMs)
            previousElapsedMs = snapshot.elapsedMs
        }
        #expect(snapshots.last?.completedCount == 12)
        #expect(snapshots.last?.completedBytes == expectedBytes)
        // No snapshot can claim more time than the run took while this test watched it: a
        // time base carried over from another clock would. (A fixed bound would only
        // measure how loaded the machine is.)
        let observedMs = DiagnosticsTiming.milliseconds(observed)
        #expect(
            (snapshots.last?.elapsedMs ?? .max) <= observedMs,
            "Elapsed time is counted from the run's start, not carried over"
        )
        let sourceAfter = try FilesystemTreeSnapshot.capture(root: sourceURL)
        #expect(sourceAfter == sourceBefore)
        await coordinator.shutdown()
    }

    /// APP-029: when every attempted entry fails `sourceStillMatches` for the
    /// same non-per-file reason — no `cameraImport` gateway wired up, matching a
    /// device session that never opened — the run must report itself as a failure,
    /// not a misleadingly-labeled `.completed(failedCount: N of N)`.
    @Test func allEntriesFailingSourceNotReadyClassifiesRunAsFailed() async throws {
        let temp = try makeTestDirectory()
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
            timeZone: TimeZone(secondsFromGMT: 0) ?? .current,
            destinationCapabilities: .unknown
        )
        let plan = MediaTransferPlanner.buildImportPlan(snapshot: snapshot)
        #expect(plan.entries.count == 2)

        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destinationRoot)
        let result = await MediaImportExecutor(store: store, volumeCapacity: ampleVolumeCapacity).execute(
            plan: plan,
            batch: ImportBatchID(),
            sourceKind: .deviceMTP,
            sourceDeviceIdentity: .camera(id: "serial"),
            deleteSourceRequested: false,
            runID: UUID().uuidString
        ) { _ in }

        guard case let .failed(reason, publishedCount) = result else {
            Issue.record("Expected systemic sourceNotReady failure, got \(result)")
            return
        }
        #expect(reason == .sourceNotReady)
        #expect(publishedCount == 0)
    }

    /// A per-file staleness failure alongside a successful entry must stay
    /// `.completed(failedCount:)` — only a run where every attempted entry fails
    /// the *same* `.sourceNotReady` way is systemic.
    @Test func mixedFailureReasonsStayCompletedNotSystemic() async throws {
        let temp = try makeTestDirectory()
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
            timeZone: TimeZone(secondsFromGMT: 0) ?? .current,
            destinationCapabilities: .unknown
        )
        let plan = MediaTransferPlanner.buildImportPlan(snapshot: snapshot)
        #expect(plan.entries.count == 2)

        // Mutate stale.jpg's live bytes after the plan captured its facts, forcing
        // a per-file `.changed(.size)` staleness failure alongside the other
        // entry's success.
        try Data(repeating: 0x03, count: 20).write(to: staleURL)

        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destinationRoot)
        let result = await MediaImportExecutor(store: store, volumeCapacity: ampleVolumeCapacity).execute(
            plan: plan,
            batch: ImportBatchID(),
            sourceKind: .removableVolume,
            sourceDeviceIdentity: .volume(uuid: "mixed-failure"),
            deleteSourceRequested: false,
            runID: UUID().uuidString
        ) { _ in }

        guard case let .completed(tally, _, nil) = result else {
            Issue.record("Expected completed with one per-file failure, got \(result)")
            return
        }
        let publishedCount = tally.publishedCount
        let hasEntryFailures = tally.hasEntryFailures
        let failedCount = tally.failedCount
        #expect(publishedCount == 1)
        #expect(failedCount == 1)
        #expect(hasEntryFailures)
    }

    /// APP-029: state F-incomplete's "Show them" reveal selects from the card
    /// row's grid — the only row the bar is drawn on — so a `.skippedForeign`
    /// entry records the card's own identity. The destination path holds a
    /// foreign file that is not this item, and the item never landed there.
    @Test func incompleteItemsCarrySourceIdentityNotDestinationIdentity() async throws {
        let temp = try makeTestDirectory()
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
            timeZone: TimeZone(secondsFromGMT: 0) ?? .current,
            destinationCapabilities: .unknown
        )
        let plan = MediaTransferPlanner.buildImportPlan(snapshot: snapshot)
        #expect(plan.entries.count == 1)
        guard case .copy = plan.entries[0].disposition else {
            Issue.record("Expected a .copy disposition, got \(plan.entries[0].disposition)")
            return
        }
        let finalDestination = try #require(plan.entries[0].destination)

        // A foreign file lands at the computed destination path after
        // planning — a race, or a stale plan — forcing copyEntry's existence
        // check to skip it as foreign at execution time.
        try Data(repeating: 0x02, count: 20).write(to: destinationRoot.appending(path: finalDestination.rawValue))

        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destinationRoot)
        let result = await MediaImportExecutor(store: store, volumeCapacity: ampleVolumeCapacity).execute(
            plan: plan,
            batch: ImportBatchID(),
            sourceKind: .removableVolume,
            sourceDeviceIdentity: .volume(uuid: "d12-destination-identity"),
            deleteSourceRequested: false,
            runID: UUID().uuidString
        ) { _ in }

        guard case let .completed(tally, incompleteItems, nil) = result else {
            Issue.record("Expected completed with a skipped-foreign entry, got \(result)")
            return
        }
        let skippedForeignCount = tally.skippedForeignCount
        #expect(skippedForeignCount == 1)
        let destinationID = MediaAssetID(libraryRootPath: destinationPath, relativePath: finalDestination)
        #expect(incompleteItems == [plan.entries[0].source.id])
        #expect(!incompleteItems.contains(destinationID))
    }

    @Test func zeroCopyPlanWithDeleteRequestedExecutesDeletion() async throws {
        let fixture = try await makeZeroCopyFixture()
        let result = await MediaImportExecutor(store: fixture.store, volumeCapacity: ampleVolumeCapacity).execute(
            plan: fixture.plan,
            batch: ImportBatchID(),
            sourceKind: .removableVolume,
            sourceDeviceIdentity: .volume(uuid: "zero-copy-delete"),
            deleteSourceRequested: true,
            runID: UUID().uuidString
        ) { _ in }

        guard case let .completed(_, _, eraseOutcome?) = result else {
            Issue.record("Expected zero-copy deletion to complete, got \(result)")
            return
        }
        #expect(eraseOutcome.deletedCount == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.sourceFile.path))
        #expect(try await fixture.store.backgroundReads.activeImportOperations().isEmpty)
    }

    @Test func zeroCopyPlanWithoutDeleteStaysReady() async throws {
        let fixture = try await makeZeroCopyFixture()
        let sourceBefore = try FilesystemTreeSnapshot.capture(root: fixture.sourceRoot)
        let result = await MediaImportExecutor(store: fixture.store, volumeCapacity: ampleVolumeCapacity).execute(
            plan: fixture.plan,
            batch: ImportBatchID(),
            sourceKind: .removableVolume,
            sourceDeviceIdentity: .volume(uuid: "zero-copy-no-delete"),
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
        #expect(try await fixture.store.backgroundReads.activeImportOperations().isEmpty)
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
        // Forced to a copy: the fixture planned this entry as already in the library,
        // and this test needs a copy that fails on the stale size.
        let entry = try MediaOperationPlanEntry(
            source: staleFacts,
            companionDestinations: original.companionDestinations,
            disposition: .copy(destination: #require(original.destination))
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

        let result = await MediaImportExecutor(store: fixture.store, volumeCapacity: ampleVolumeCapacity).execute(
            plan: plan,
            batch: ImportBatchID(),
            sourceKind: .removableVolume,
            sourceDeviceIdentity: .volume(uuid: "failed-copy-survival"),
            deleteSourceRequested: true,
            runID: UUID().uuidString
        ) { _ in }

        guard case let .completed(tally, _, eraseOutcome?) = result else {
            Issue.record("Expected a completed erase result, got \(result)")
            return
        }
        let failedCount = tally.failedCount
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

        let result = await MediaImportExecutor(store: fixture.store, volumeCapacity: ampleVolumeCapacity).execute(
            plan: fixture.plan,
            batch: ImportBatchID(),
            sourceKind: .removableVolume,
            sourceDeviceIdentity: .volume(uuid: "busy-source-namespace"),
            deleteSourceRequested: true,
            runID: UUID().uuidString
        ) { _ in }

        guard case let .completed(_, _, eraseOutcome?) = result else {
            Issue.record("A busy source namespace must not fail the import, got \(result)")
            return
        }
        // The erase is reported incomplete, which is the state `import-bar.md`
        // already specifies; nothing on the card is touched.
        #expect(eraseOutcome.deletedCount == 0)
        #expect(eraseOutcome.failedCount > 0)
        #expect(FileManager.default.fileExists(atPath: fixture.sourceFile.path))
    }

    /// A card file is erased only under the card's own namespace lease — on its entry's
    /// settle or in the end-of-run sweep. With another owner holding the card for the
    /// whole run, every copy still lands and not one card file is touched.
    @Test func aCardAnotherOwnerHoldsIsNeverErased() async throws {
        let fixture = try await makeCardFixture(count: 2, bytesEach: 64)
        let sourcePath = try CatalogPath.normalizedDirectoryPath(for: fixture.sourceRoot)
        guard case .acquired = await fixture.store.acquireNamespaceMutationLease(for: sourcePath, owner: .mediaTrash)
        else {
            Issue.record("Expected to hold the card's namespace for this test")
            return
        }

        let result = await executeFloorRun(fixture, deleteSourceRequested: true) { _ in nil }

        guard case let .completed(tally, _, eraseOutcome?) = result else {
            Issue.record("Expected a completed erase run, got \(result)")
            return
        }
        let publishedCount = tally.publishedCount
        #expect(publishedCount == 2)
        #expect(eraseOutcome == EraseOutcome(deletedCount: 0, skippedCount: 0, failedCount: 2))
        for name in ["IMG_0.jpg", "IMG_1.jpg"] {
            #expect(FileManager.default.fileExists(atPath: fixture.sourceRoot.appending(path: name).path))
            #expect(FileManager.default.fileExists(atPath: fixture.destinationRoot.appending(path: name).path))
        }
    }

    /// ADR 0027: each landed source is erased as it settles, and the outcome counts it as
    /// deleted. The end-of-run sweep leaves a path that was already erased alone rather
    /// than finding it gone and calling it skipped.
    @Test func anEraseRunCountsWhatItErasedAsEachEntryLanded() async throws {
        let fixture = try await makeCardFixture(count: 3, bytesEach: 64)

        let result = await executeFloorRun(fixture, deleteSourceRequested: true) { _ in nil }

        guard case let .completed(tally, _, eraseOutcome?) = result else {
            Issue.record("Expected a completed erase run, got \(result)")
            return
        }
        #expect(tally.publishedCount == 3)
        #expect(eraseOutcome == EraseOutcome(deletedCount: 3, skippedCount: 0, failedCount: 0))
        for index in 0 ..< 3 {
            #expect(!FileManager.default.fileExists(atPath: fixture.sourceRoot.appending(path: "IMG_\(index).jpg").path))
        }
    }

    /// A run never treats another run's journal as something to recover: an entry in
    /// flight in another library keeps its row and its staging file while this one runs.
    @Test func aRunLeavesAnotherRunsJournalAlone() async throws {
        let fixture = try await makeCardFixture(count: 1, bytesEach: 64)
        let otherLibrary = try makeTestDirectory()
        try await fixture.store.ensureLibrary(url: otherLibrary)
        let otherPath = try CatalogPath.normalizedDirectoryPath(for: otherLibrary)
        let staging = otherLibrary.appending(path: ".in-flight.otos-import-staging")
        try Data("half a copy".utf8).write(to: staging)
        let inFlight = ActiveFileOperation(
            operationKey: .make(),
            sourceKind: .removableVolume,
            sourceDeviceIdentity: .volume(uuid: "other-card"),
            sourceRootPath: LibraryRootPath(rawValue: "/Volumes/OTHER"),
            sourceRelativePath: MediaRelativePath(rawValue: "IMG_9.JPG"),
            destinationRootPath: otherPath,
            destinationRelativePath: MediaRelativePath(rawValue: "IMG_9.JPG"),
            stagingURL: staging,
            companionStagingURLs: [],
            contentHash: nil,
            importBatch: ImportBatchID(unixMilliseconds: 1),
            sourceByteSize: 11,
            sourceModifiedAt: Date(timeIntervalSince1970: 1),
            destinationModifiedAt: nil,
            phase: .copying,
            updatedAt: Date()
        )
        try await fixture.store.beginImportOperation(inFlight)

        _ = await executeFloorRun(fixture) { _ in nil }

        let journal = try await fixture.store.backgroundReads.activeImportOperations()
        #expect(journal.map(\.operationKey) == [inFlight.operationKey])
        #expect(journal.map(\.phase) == [.copying])
        #expect(journal.map(\.stagingURL) == [staging])
        #expect(FileManager.default.fileExists(atPath: staging.path))
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
                    key: .make(),
                    sourceKind: .removableVolume,
                    sourceDeviceIdentity: .volume(uuid: "zero-copy-fixture"),
                    sourceRootPath: sourcePath,
                    sourceRelativePath: relative,
                    sourceByteSize: 4,
                    updatedAt: Date()
                )
            )
        }
        #expect(try await fixture.store.backgroundReads.activeSourceEraseOperations().count == 5)

        await MediaImportRecovery(store: fixture.store).run()

        for relative in relatives {
            let url = fixture.sourceRoot.appending(path: relative.rawValue)
            #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        }
        #expect(try await fixture.store.backgroundReads.activeSourceEraseOperations().isEmpty)
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
        let temp = try makeTestDirectory()
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
            timeZone: TimeZone(secondsFromGMT: 0) ?? .current,
            destinationCapabilities: .unknown
        )
        let plan = MediaTransferPlanner.buildImportPlan(snapshot: snapshot)
        #expect(plan.totals.copyCount == count)
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destinationRoot)
        // Attached the way a card is, so erasing from it takes its namespace lease.
        try await store.attachRemovableVolume(
            mountURL: sourceRoot,
            identity: .volume(uuid: "card-fixture"),
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )
        return CardFixture(
            store: store,
            plan: plan,
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            destinationPath: destinationPath
        )
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
            sourceDeviceIdentity: .volume(uuid: "disk-floor"),
            deleteSourceRequested: deleteSourceRequested,
            runID: UUID().uuidString
        ) { _ in }
    }

    /// Three 1 KB entries into a volume with room for two above the floor:
    /// two land, the third is never attempted, and the run settles as stopped
    /// at the floor with the count it actually published. The figure never
    /// moves, as a lagging one (CacheDelete) does: the bytes this run has
    /// committed are what refuse the third.
    @Test func theFloorStopsTheRunBeforeTheEntryThatWouldBreachIt() async throws {
        let fixture = try await makeCardFixture(count: 3, bytesEach: 1024)
        let destination = fixture.destinationRoot
        let result = await executeFloorRun(fixture) { _ in FreeSpaceFloor.bytes + 2500 }
        guard case let .stopped(reason, tally) = result else {
            Issue.record("Expected a stopped run, got \(result)")
            return
        }
        let publishedCount = tally.publishedCount
        let failedCount = tally.failedCount
        guard case .diskFloor = reason else {
            Issue.record("Expected the disk floor as the reason, got \(reason)")
            return
        }
        #expect(publishedCount == 2)
        #expect(failedCount == 0, "an entry the floor refused was never attempted, so it is not a failure")
        #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "IMG_2.jpg").path))
    }

    /// A fresh figure shows each copy as it reaches the disk (`copyfile` reserves the
    /// whole file when it starts), and the run is not charged for it twice: a volume
    /// with room for exactly three takes all three, however far the copies have got
    /// when each admission reads the figure.
    @Test func aFreshFigureLetsTheRunCopyEverythingThatFits() async throws {
        let fixture = try await makeCardFixture(count: 3, bytesEach: 1024)
        let destination = fixture.destinationRoot
        let result = await executeFloorRun(fixture) { _ in
            FreeSpaceFloor.bytes + 3 * 1024 - Self.bytesOnDisk(under: destination)
        }
        guard case let .completed(tally, _, nil) = result else {
            Issue.record("Expected a completed run, got \(result)")
            return
        }
        let publishedCount = tally.publishedCount
        #expect(publishedCount == 3)
    }

    /// A figure that never moves does not let landed entries be forgotten: with more
    /// entries than workers, room for nine of ten copies nine, though entries land and
    /// leave the in-flight set while the run goes on.
    @Test func aFigureThatNeverMovesStillCountsTheEntriesThatLanded() async throws {
        let fixture = try await makeCardFixture(count: 10, bytesEach: 1024)
        let result = await executeFloorRun(fixture) { _ in FreeSpaceFloor.bytes + 9 * 1024 }
        guard case let .stopped(_, tally) = result else {
            Issue.record("Expected a stopped run, got \(result)")
            return
        }
        let publishedCount = tally.publishedCount
        #expect(publishedCount == 9)
    }

    /// Bytes sitting in a directory tree, staging files included: what a fresh capacity
    /// figure has lost to this run's copies so far.
    private static func bytesOnDisk(under root: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else {
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

    /// A volume that does not answer admits everything; `ENOSPC` is the
    /// backstop, not a guess.
    @Test func anUnknownCapacityAdmitsEveryEntry() async throws {
        let fixture = try await makeCardFixture(count: 3, bytesEach: 1024)
        let result = await executeFloorRun(fixture) { _ in nil }
        guard case let .completed(tally, _, nil) = result else {
            Issue.record("Expected a completed run, got \(result)")
            return
        }
        let publishedCount = tally.publishedCount
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
        let result = await executeFloorRun(fixture, deleteSourceRequested: true) { _ in FreeSpaceFloor.bytes + 2500 }
        guard case let .stopped(_, tally) = result else {
            Issue.record("Expected a stopped run, got \(result)")
            return
        }
        let publishedCount = tally.publishedCount
        #expect(publishedCount == 2)
        #expect(
            !FileManager.default.fileExists(atPath: fixture.sourceRoot.appending(path: "IMG_0.jpg").path),
            "landed, proven, erased on settle"
        )
        #expect(
            !FileManager.default.fileExists(atPath: fixture.sourceRoot.appending(path: "IMG_1.jpg").path),
            "landed, proven, erased on settle"
        )
        #expect(
            FileManager.default.fileExists(atPath: fixture.sourceRoot.appending(path: "IMG_2.jpg").path),
            "refused by the floor: still only on the card"
        )
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
                return CopyfileTransfer.copy(
                    from: source,
                    to: destination,
                    onProgress: onProgress,
                    shouldContinue: shouldContinue
                )
            }
        )
        let result = await executor.execute(
            plan: fixture.plan,
            batch: ImportBatchID(),
            sourceKind: .removableVolume,
            sourceDeviceIdentity: .volume(uuid: "enospc"),
            deleteSourceRequested: false,
            runID: UUID().uuidString
        ) { _ in }
        guard case let .stopped(reason, tally) = result else {
            Issue.record("Expected a stopped run, got \(result)")
            return
        }
        let publishedCount = tally.publishedCount
        let failedCount = tally.failedCount
        guard case .diskFloor = reason else {
            Issue.record("Expected the disk floor as the reason, got \(reason)")
            return
        }
        #expect(publishedCount >= 1)
        #expect(failedCount == 0)
    }

    /// Every worker's copy blocks its thread for as long as the volume takes, so the copies
    /// run on their own queue, never on the cooperative pool: with all eight workers' copies
    /// held, other async work still runs. On the cooperative pool (one thread per core) eight
    /// held copies took every thread of an eight-core Mac, and a visible tile's read waited
    /// 7–25 s for one (`docs/research/2026-11-15-small-scope-reads-and-tile-waits.md`).
    @Test func heldCopiesLeaveTheCooperativePoolFree() async throws {
        let fixture = try await makeCardFixture(count: MediaImportExecutor.workerCount, bytesEach: 1024)
        let (started, startedSink) = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)
        let release = DispatchSemaphore(value: 0)
        let executor = MediaImportExecutor(
            store: fixture.store,
            volumeCapacity: { _ in nil },
            transfer: { source, destination, onProgress, shouldContinue in
                startedSink.yield()
                release.wait()
                return CopyfileTransfer.copy(from: source, to: destination, onProgress: onProgress, shouldContinue: shouldContinue)
            }
        )
        let run = Task {
            await executor.execute(
                plan: fixture.plan,
                batch: ImportBatchID(),
                sourceKind: .removableVolume,
                sourceDeviceIdentity: .volume(uuid: "held"),
                deleteSourceRequested: false,
                runID: UUID().uuidString
            ) { _ in }
        }
        var held = 0
        for await _ in started {
            held += 1
            if held == MediaImportExecutor.workerCount {
                break
            }
        }
        // Every worker is inside its copy; work on the cooperative pool still runs.
        let ran = await Task.detached { true }.value
        #expect(ran)
        for _ in 0 ..< MediaImportExecutor.workerCount {
            release.signal()
        }
        guard case let .completed(tally, _, _) = await run.value else {
            Issue.record("Expected a completed run")
            return
        }
        #expect(tally.publishedCount == MediaImportExecutor.workerCount)
    }

    // MARK: - Companions travel only when their bytes do

    /// A copied companion lands beside its primary, is recorded with it, and its
    /// source is erased with it.
    @Test func aCopiedCompanionIsRecordedBesideItsPrimaryAndErasedWithIt() async throws {
        let fixture = try await makeCompanionFixture()
        let result = await executeCompanionRun(fixture, transfer: CopyfileTransfer.copy)
        guard case let .completed(tally, incompleteItems, .some) = result else {
            Issue.record("Expected a completed erase run, got \(result)")
            return
        }
        let publishedCount = tally.publishedCount
        #expect(publishedCount == 1)
        #expect(incompleteItems.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.destinationRoot.appending(path: "IMG_0.xmp").path))
        let companions = try await fixture.store.windowReads.companions(in: fixture.destinationPath)
        #expect(companions.map(\.relativePath.rawValue) == ["IMG_0.xmp"])
        #expect(companions.first?.primaryRelativePath?.rawValue == "IMG_0.jpg")
        #expect(!FileManager.default.fileExists(atPath: fixture.sourceRoot.appending(path: "IMG_0.xmp").path))
        #expect(try Self.stagingLeftovers(under: fixture.destinationRoot).isEmpty)
    }

    /// A companion whose copy fails is not in the library, so it is not recorded and
    /// its source is never erased; the primary still imports and the item is incomplete.
    @Test func aCompanionThatFailsToCopyStaysOnTheCardAndOutOfTheCatalog() async throws {
        let fixture = try await makeCompanionFixture()
        let result = await executeCompanionRun(fixture) { source, destination, onProgress, shouldContinue in
            if source.pathExtension == "xmp" {
                return .failed(errno: EIO)
            }
            return CopyfileTransfer.copy(
                from: source,
                to: destination,
                onProgress: onProgress,
                shouldContinue: shouldContinue
            )
        }
        try await expectCompanionLeftOnCard(fixture, result: result)
        #expect(!FileManager.default.fileExists(atPath: fixture.destinationRoot.appending(path: "IMG_0.xmp").path))
        #expect(try await fixture.store.windowReads.companions(in: fixture.destinationPath).isEmpty)
    }

    /// A file that took the companion's destination after planning is never
    /// overwritten, and the companion it displaced stays on the card. The catalog may
    /// list that occupant as the primary's companion once the library is reconciled —
    /// it is a real file there — so this test asserts on the bytes, not on catalog rows.
    @Test func aCompanionWhoseDestinationWasTakenIsNotCopiedOverIt() async throws {
        let fixture = try await makeCompanionFixture()
        let occupant = fixture.destinationRoot.appending(path: "IMG_0.xmp")
        try Data("someone else".utf8).write(to: occupant)
        let result = await executeCompanionRun(fixture, transfer: CopyfileTransfer.copy)
        try await expectCompanionLeftOnCard(fixture, result: result)
        #expect(try Data(contentsOf: occupant) == Data("someone else".utf8))
    }

    private func expectCompanionLeftOnCard(
        _ fixture: CardFixture,
        result: MediaImportExecutionResult
    ) async throws {
        guard case let .completed(tally, incompleteItems, .some) = result
        else {
            Issue.record("Expected a completed erase run, got \(result)")
            return
        }
        let publishedCount = tally.publishedCount
        let hasEntryFailures = tally.hasEntryFailures
        let failedCount = tally.failedCount
        #expect(publishedCount == 0, "an item is copied only when all of its files are in the library")
        #expect(failedCount == 1)
        #expect(hasEntryFailures)
        #expect(incompleteItems == fixture.plan.entries.map(\.source.id))
        #expect(FileManager.default.fileExists(atPath: fixture.destinationRoot.appending(path: "IMG_0.jpg").path))
        #expect(
            FileManager.default.fileExists(atPath: fixture.sourceRoot.appending(path: "IMG_0.xmp").path),
            "a companion that is not in the library is never erased"
        )
        #expect(!FileManager.default.fileExists(atPath: fixture.sourceRoot.appending(path: "IMG_0.jpg").path))
        #expect(try Self.stagingLeftovers(under: fixture.destinationRoot).isEmpty)
    }

    private func executeCompanionRun(
        _ fixture: CardFixture,
        transfer: @escaping MediaImportExecutor.VolumeTransfer
    ) async -> MediaImportExecutionResult {
        await MediaImportExecutor(store: fixture.store, volumeCapacity: { _ in nil }, transfer: transfer).execute(
            plan: fixture.plan,
            batch: ImportBatchID(),
            sourceKind: .removableVolume,
            sourceDeviceIdentity: .volume(uuid: "companion"),
            deleteSourceRequested: true,
            runID: UUID().uuidString
        ) { _ in }
    }

    /// One JPEG with an `.xmp` companion on an attached card, planned into an empty
    /// library with original names.
    private func makeCompanionFixture() async throws -> CardFixture {
        let temp = try makeTestDirectory()
        let sourceRoot = temp.appending(path: "Card", directoryHint: .isDirectory)
        let destinationRoot = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let sourcePath = try CatalogPath.normalizedDirectoryPath(for: sourceRoot)
        let destinationPath = try CatalogPath.normalizedDirectoryPath(for: destinationRoot)
        let modifiedAt = Date(timeIntervalSince1970: 100)
        let primary = MediaRelativePath(rawValue: "IMG_0.jpg")
        let sidecar = MediaRelativePath(rawValue: "IMG_0.xmp")
        for (relative, bytes) in [(primary, Data(repeating: 1, count: 1024)), (sidecar, Data("<x:xmpmeta/>".utf8))] {
            let url = sourceRoot.appending(path: relative.rawValue)
            try bytes.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        }
        let facts = PlanningFileFacts(
            id: MediaAssetID(libraryRootPath: sourcePath, relativePath: primary),
            sourceURL: sourceRoot.appending(path: primary.rawValue),
            relativePath: primary,
            byteSize: 1024,
            contentModifiedAt: modifiedAt,
            captureWallCompact: nil,
            mediaKind: .image,
            fileExtension: "jpg",
            companions: [MediaCompanion(
                relativePath: sidecar,
                primaryRelativePath: primary,
                kind: .xmp,
                byteSize: Int64(Data("<x:xmpmeta/>".utf8).count),
                contentModifiedAt: modifiedAt
            )],
            contentTypeIdentifier: "public.jpeg"
        )
        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .none
        policy.destinationNamePolicy = .original
        let plan = MediaTransferPlanner.buildImportPlan(snapshot: ImportPlanningSnapshot(
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
            timeZone: TimeZone(secondsFromGMT: 0) ?? .current,
            destinationCapabilities: .unknown
        ))
        #expect(plan.entries.first?.companionDestinations == [sidecar: sidecar])
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destinationRoot)
        try await store.attachRemovableVolume(
            mountURL: sourceRoot,
            identity: .volume(uuid: "companion"),
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )
        return CardFixture(
            store: store,
            plan: plan,
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            destinationPath: destinationPath
        )
    }

    /// Hidden staging files left in a library: an import that ended must leave none.
    private static func stagingLeftovers(under root: URL) throws -> [String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        return names.filter { $0.hasSuffix(MediaImportExecutor.destinationTempSuffix) }
    }

    private struct ZeroCopyFixture {
        let store: CatalogStore
        let plan: MediaOperationPlan
        let sourceRoot: URL
        let sourceFile: URL
        let destinationFile: URL
    }

    private func makeZeroCopyFixture() async throws -> ZeroCopyFixture {
        let temp = try makeTestDirectory()
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
            timeZone: TimeZone(secondsFromGMT: 0) ?? .current,
            destinationCapabilities: .unknown
        )
        let plan = MediaTransferPlanner.buildImportPlan(snapshot: snapshot)
        #expect(plan.entries.first?.isSkipPreexisting == true)
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destinationRoot)
        // The card is attached, not merely a path on disk. `MediaOperationCoordinator`
        // only ever executes an import for a source it read out of
        // `store.currentLibraries()`, so an unattached source root is not a
        // configuration production can reach — and erase, which takes that root's
        // namespace lease, is correctly refused for a root the catalog does not own.
        try await store.attachRemovableVolume(
            mountURL: sourceRoot,
            identity: .volume(uuid: "zero-copy-fixture"),
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
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
        source: LibraryRootPath
    ) async throws -> MediaOperationPlan {
        try await waitForValue(every: .milliseconds(25)) { await coordinator.readyPlan(for: source) }
    }
}

private final class ProgressCollector: Sendable {
    private let recorder = TestRecorder<MediaOperationProgress>()

    nonisolated func record(_ progress: MediaOperationProgress) {
        recorder.record(progress)
    }

    nonisolated var snapshots: [MediaOperationProgress] {
        recorder.values
    }
}

/// ADR 0018: a card row's digest, read while the card sat idle, is what its staged copy
/// must hash to. A copy that does not is never published.
@Suite(.testScope)
struct ImportVerifiesTheStagedCopyTests {
    @Test func aStagedCopyThatDoesNotMatchTheCardsDigestIsNeverPublished() async throws {
        let temp = try makeTestDirectory()
        let destinationURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let sourceURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: sourceURL.appending(path: "a.jpg"))
        try Data("second".utf8).write(to: sourceURL.appending(path: "b.jpg"))
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destinationURL)
        let destination = try CatalogPath.normalizedDirectoryPath(for: destinationURL)
        try await store.attachRemovableVolume(
            mountURL: sourceURL,
            identity: .volume(uuid: "verify-staged"),
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )
        let source = try CatalogPath.normalizedDirectoryPath(for: sourceURL)
        _ = try await waitForCatalogStoreState(store) { state in
            !state.isScanning && state.removableSources.first?.activity == .idle
        }
        await markEnrichmentLookedAtEveryRow(store, root: source)
        // The card row's digest says other bytes than a.jpg holds: what a copy through a
        // failing reader would produce, seen from the other side.
        let media = try #require(await store.windowReads.planningMedia(for: source))
        let first = try #require(media.first { $0.relativePath.rawValue == "a.jpg" })
        let wrong = try #require(ContentDigest(data: Data(repeating: 9, count: ContentDigest.byteCount)))
        let written = await store.applyContentHash(ContentHashResult(
            id: first.id,
            contentHash: wrong,
            sourceSize: first.byteSize,
            sourceMTimeSeconds: first.contentModifiedAt.map { Int($0.timeIntervalSince1970.rounded(.down)) }
        ))
        #expect(written == .applied(count: 1))

        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: PreferencesDomain.suite(UUID().uuidString),
            volumeCapacity: ampleVolumeCapacity
        )
        await coordinator.start()
        await coordinator.setDestination(destination, for: source)
        let plan = try await waitForValue(every: .milliseconds(25)) { await coordinator.readyPlan(for: source) }
        #expect(plan.entries.first { $0.source.relativePath.rawValue == "a.jpg" }?.source.contentHash == wrong)

        let result = await MediaImportExecutor(store: store, volumeCapacity: ampleVolumeCapacity).execute(
            plan: plan,
            batch: ImportBatchID(),
            sourceKind: .removableVolume,
            sourceDeviceIdentity: .volume(uuid: "verify-staged"),
            deleteSourceRequested: false,
            runID: UUID().uuidString
        ) { _ in }

        guard case let .completed(tally, _, nil) = result else {
            Issue.record("Expected completed with one per-file failure, got \(result)")
            await coordinator.shutdown()
            return
        }
        #expect(tally.publishedCount == 1)
        #expect(tally.failedCount == 1)
        // Import names files by its policy, so look for what landed rather than a name.
        let landed = try FileManager.default.subpathsOfDirectory(atPath: destinationURL.path)
            .filter { path in
                var isDirectory: ObjCBool = false
                let url = destinationURL.appending(path: path)
                return !url.lastPathComponent.hasPrefix(".")
                    && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && !isDirectory.boolValue
            }
        #expect(landed.count == 1)
        #expect(try landed.allSatisfy {
            try Data(contentsOf: destinationURL.appending(path: $0)) == Data("second".utf8)
        })
        await coordinator.shutdown()
    }
}

/// ADR 0018: what an import may treat as "already in a library" is re-read from the
/// catalog when a card is erased; a library copy waiting for the Trash no longer counts.
@Suite(.testScope)
struct LibraryContentRecheckTests {
    @Test func aLibraryCopyWaitingForTheTrashNoLongerHoldsTheContent() async throws {
        let temp = try makeTestDirectory()
        let libraryURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        try Data("held".utf8).write(to: libraryURL.appending(path: "a.jpg"))
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: libraryURL)
        let library = try CatalogPath.normalizedDirectoryPath(for: libraryURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        let facts = try #require(await store.windowReads.planningMedia(for: library)?.first)
        let digest = try #require(ContentDigest(data: Data(repeating: 4, count: ContentDigest.byteCount)))
        _ = await store.applyContentHash(ContentHashResult(
            id: facts.id,
            contentHash: digest,
            sourceSize: facts.byteSize,
            sourceMTimeSeconds: facts.contentModifiedAt.map { Int($0.timeIntervalSince1970.rounded(.down)) }
        ))

        #expect(try await store.backgroundReads.librariesHoldContent([digest]) == [digest])
        _ = try await store.markPendingTrash([facts.id], batch: MediaTrashBatchID())
        #expect(try await store.backgroundReads.librariesHoldContent([digest]).isEmpty)
        await store.shutdown()
    }
}
