import Foundation
import GRDB
@testable import OtosKit
import Testing

@Suite(.testDirectory)
struct CatalogStoreEnrichmentTests {
    // MARK: - Pure model: staleness signature and best-date

    @Test func needsEnrichmentTracksSizeAndMtimeSignature() {
        let m1000 = Date(timeIntervalSince1970: 1000)
        let m2000 = Date(timeIntervalSince1970: 2000)
        let unstamped = makeAsset(size: 100, modifiedAt: m1000, stampSize: nil, stampMtime: nil)
        let current = makeAsset(size: 100, modifiedAt: m1000, stampSize: 100, stampMtime: 1000)
        let resized = makeAsset(size: 200, modifiedAt: m1000, stampSize: 100, stampMtime: 1000)
        let touched = makeAsset(size: 100, modifiedAt: m2000, stampSize: 100, stampMtime: 1000)
        #expect(unstamped.needsEnrichment(.products))
        #expect(!current.needsEnrichment(.products))
        #expect(resized.needsEnrichment(.products))
        #expect(touched.needsEnrichment(.products))
    }

    @Test func missingOrMismatchedHashSignatureMakesCurrentAssetStale() {
        let modified = Date(timeIntervalSince1970: 1000)
        #expect(
            makeAsset(
                size: 100,
                modifiedAt: modified,
                stampSize: 100,
                stampMtime: 1000,
                contentHash: nil
            ).needsEnrichment(.products)
        )
        #expect(
            makeAsset(
                size: 100,
                modifiedAt: modified,
                stampSize: 100,
                stampMtime: 1000,
                hashSourceSize: 99,
                hashSourceMtime: 1000
            ).needsEnrichment(.products)
        )
        #expect(
            !makeAsset(
                size: 100,
                modifiedAt: modified,
                stampSize: 100,
                stampMtime: 1000,
                hashSourceSize: 100,
                hashSourceMtime: 1000
            ).needsEnrichment(.products)
        )
    }

    /// ENR-007: a `.removableVolume` source is never hashed in place (ADR 0018), so
    /// hash staleness is gated behind the claim — a metadata-current removable
    /// asset with no digest is fully enriched, while the same asset on a library root
    /// still needs enrichment.
    @Test func hashStalenessIsGatedOnHashRequired() {
        let modified = Date(timeIntervalSince1970: 1000)
        let noHash = makeAsset(
            size: 100,
            modifiedAt: modified,
            stampSize: 100,
            stampMtime: 1000,
            contentHash: nil
        )
        #expect(noHash.needsEnrichment(.metadata) == false)
        #expect(noHash.needsEnrichment(.products))
        #expect(noHash.metadataStale == false)
        #expect(noHash.hashStale)
    }

    /// A stored record that does not decode is an error, never an asset without metadata.
    @Test func anUndecodableMetadataRecordIsAnErrorNotAbsence() {
        #expect(throws: DecodingError.self) {
            try CatalogStore.decodeMetadataExtraJSON(#"{"family": 3}"#)
        }
    }

    // MARK: - Store: rescan merge, persistence, and purge

    @Test func rescanPreservesEnrichmentAndMtimeChangeMakesStale() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        let rel = MediaRelativePath(rawValue: "a.jpg")
        let id = MediaAssetID(libraryRootPath: rootPath, relativePath: rel)

        let mtime = MutableSeconds(1000)
        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        let store = CatalogStore(
            location: .inMemory,
            scanner: singleFileScanner(rel, mtime: mtime),
            filesystemWatcher: watcher
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }

        let captureDate = Date(timeIntervalSince1970: 700)
        await store.applyEnrichmentBatch([
            EnrichmentResult(
                id: id,
                metadata: AssetMetadata(
                    timestamps: [.absolute(instant: captureDate)],
                    cameraModel: "Cam",
                    durationSeconds: 42.5
                ),
                thumbnailPath: "thumb.jpg",
                sourceSize: 100,
                sourceMTimeSeconds: 1000,
                contentHash: .empty
            ),
        ])

        let enriched = try #require(try await catalogStoreTestState(store).testAssets.first { $0.id == id })
        #expect(enriched.thumbnailPath == "thumb.jpg")
        #expect(enriched.captureLocalTime == CaptureLocalTime(readingOf: captureDate))
        #expect(enriched.durationSeconds == 42.5)
        #expect(enriched.needsEnrichment(.products) == false)

        // Re-scan observing a changed mtime (same size): enrichment survives the merge,
        // and the changed (size, mtime) signature makes the asset stale again.
        await mtime.set(2000)
        emit(FilesystemEvent(path: root.appending(path: "a.jpg").path(percentEncoded: false), flags: 0))
        let restaled = try await waitForCatalogStoreState(store) { snapshot in
            guard let asset = snapshot.testAssets.first(where: { $0.id == id }) else { return false }
            return !snapshot.isScanning && asset.contentModifiedAt == Date(timeIntervalSince1970: 2000)
        }
        let asset = try #require(restaled.testAssets.first { $0.id == id })
        #expect(asset.thumbnailPath == "thumb.jpg")
        #expect(asset.captureLocalTime == CaptureLocalTime(readingOf: captureDate))
        #expect(asset.durationSeconds == 42.5)
        #expect(asset.metadataSourceSize == 100)
        #expect(asset.needsEnrichment(.products) == true)
    }

    @Test func enrichmentPersistsAndReloads() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "a.jpg"), contents: "jpeg")
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        let rel = MediaRelativePath(rawValue: "a.jpg")
        let id = MediaAssetID(libraryRootPath: rootPath, relativePath: rel)

        let store = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        let scanned = try await catalogStoreTestState(store)
        let scannedAsset = try #require(scanned.testAssets.first { $0.id == id })
        let scannedSize = try #require(scannedAsset.byteSize)
        let scannedMTime = MediaAsset.mtimeSeconds(scannedAsset.contentModifiedAt)

        let captureDate = Date(timeIntervalSince1970: 700)
        await store.applyEnrichmentBatch([
            EnrichmentResult(
                id: id,
                metadata: AssetMetadata(
                    timestamps: [.absolute(instant: captureDate)],
                    cameraModel: "Cam",
                    pixelWidth: 4000,
                    pixelHeight: 3000,
                    durationSeconds: 187.25
                ),
                thumbnailPath: "thumb.jpg",
                sourceSize: scannedSize,
                sourceMTimeSeconds: scannedMTime,
                contentHash: .empty
            ),
        ])

        try await expectVideoMetadataPersisted(
            databaseURL: databaseURL,
            rootPath: rootPath,
            relativePath: rel,
            store: store
        )

        let reloaded = CatalogStore(location: .databaseFile(databaseURL))
        try await reloaded.start(scansSavedLibraries: false)
        let asset = try #require(try await catalogStoreTestState(reloaded).testAssets.first { $0.id == id })
        #expect(asset.thumbnailPath == "thumb.jpg")
        #expect(asset.captureLocalTime == CaptureLocalTime(readingOf: captureDate))
        #expect(asset.durationSeconds == 187.25)
        #expect(asset.metadataSourceSize == scannedSize)
        #expect(asset.metadataSourceMTimeSeconds == scannedMTime)
        #expect(asset.needsEnrichment(.products) == false)
    }

    @Test func malformedStoredHashIsUnavailableAndStale() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "a.jpg"), contents: "jpeg")
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let store = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        let asset = try #require(scanned.testAssets.first)
        let rootPath = asset.libraryRootPath
        let mtime = MediaAsset.mtimeSeconds(asset.contentModifiedAt)
        await store.applyEnrichmentBatch([
            EnrichmentResult(
                id: asset.id,
                metadata: AssetMetadata(),
                thumbnailPath: nil,
                sourceSize: asset.byteSize,
                sourceMTimeSeconds: mtime,
                contentHash: .empty
            ),
        ])

        let db = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try await db.write { db in
            try db.execute(
                sql: "UPDATE media_asset SET content_hash_xxh3_128 = ? WHERE relative_path = ?",
                arguments: [Data(repeating: 0, count: 15), asset.relativePath.rawValue]
            )
        }
        let reloaded = CatalogStore(location: .databaseFile(databaseURL))
        try await reloaded.start(scansSavedLibraries: false)
        let persisted = try #require(try await catalogStoreTestState(reloaded).testAssets.first {
            $0.libraryRootPath == rootPath
        })
        #expect(persisted.contentHash == nil)
        #expect(persisted.needsEnrichment(.products))
    }

    @Test func staleEnrichmentCompletionDoesNotStampChangedSourceCurrent() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        let rel = MediaRelativePath(rawValue: "a.jpg")
        let id = MediaAssetID(libraryRootPath: rootPath, relativePath: rel)

        let mtime = MutableSeconds(1000)
        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let store = CatalogStore(
            location: .databaseFile(databaseURL),
            scanner: singleFileScanner(rel, mtime: mtime),
            filesystemWatcher: watcher
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }

        await mtime.set(2000)
        emit(FilesystemEvent(path: root.appending(path: "a.jpg").path(percentEncoded: false), flags: 0))
        _ = try await waitForCatalogStoreState(store) { snapshot in
            guard let asset = snapshot.testAssets.first(where: { $0.id == id }) else { return false }
            return !snapshot.isScanning && MediaAsset.mtimeSeconds(asset.contentModifiedAt) == 2000
        }

        await store.applyEnrichmentBatch([
            EnrichmentResult(
                id: id,
                metadata: AssetMetadata(
                    timestamps: [.absolute(instant: Date(timeIntervalSince1970: 700))],
                    cameraModel: "OldCam"
                ),
                thumbnailPath: "old.jpg",
                sourceSize: 100,
                sourceMTimeSeconds: 1000,
                contentHash: .empty
            ),
        ])

        let current = try #require(try await catalogStoreTestState(store).testAssets.first { $0.id == id })
        #expect(current.thumbnailPath == nil)
        #expect(current.captureLocalTime == CaptureLocalTime(readingOf: Date(timeIntervalSince1970: 500)))
        #expect(current.metadataSourceSize == nil)
        #expect(current.metadataSourceMTimeSeconds == nil)
        #expect(current.needsEnrichment(.products))

        let reloaded = CatalogStore(location: .databaseFile(databaseURL))
        try await reloaded.start(scansSavedLibraries: false)
        let persisted = try #require(try await catalogStoreTestState(reloaded).testAssets.first { $0.id == id })
        #expect(persisted.thumbnailPath == nil)
        #expect(persisted.captureLocalTime == CaptureLocalTime(readingOf: Date(timeIntervalSince1970: 500)))
        #expect(persisted.metadataSourceSize == nil)
        #expect(persisted.metadataSourceMTimeSeconds == nil)
        #expect(persisted.needsEnrichment(.products))
    }

    /// `structureChanged` must compare the STORED generated columns
    /// before vs after the write, not a Swift-side prediction of what the write will
    /// produce. Fixture: the asset scans with `created_at_unix = 500`; a first
    /// enrichment sets `capture_instant_unix = 700`, so `best_capture_local` becomes 700. A
    /// second enrichment result with every timestamp fact nil clears `capture_instant_unix`
    /// back to NULL (plain-assignment write, not COALESCE-preserved — see
    /// `writeEnrichmentOverlay`), so SQLite's generated column falls back to
    /// `created_at_unix = 500` — an effective order change that must be reported as
    /// `.catalogChanged`, not coalesced away as `.assetsDetailChanged`.
    ///
    /// Verified against the pre-refactor Swift recompute (`git stash` of the Stage 2a
    /// diff, then re-run): it also passes this exact scenario, because its own fallback
    /// chain (`oldRow.createdAtUnix`) happens to term-for-term match the generated
    /// column's COALESCE today — consistent with the plan's own finding that "the
    /// chains agree today." This is therefore a characterization test locking in
    /// correct stored-value comparison, not a caught live bug; the value of asking the
    /// database instead of predicting is that a *future* migration adding a new
    /// `best_capture_local` source cannot silently desync a Swift twin that no longer
    /// exists.
    @Test func timestampClearingStructuralChangeIsCatalogChanged() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        let rel = MediaRelativePath(rawValue: "a.jpg")
        let id = MediaAssetID(libraryRootPath: rootPath, relativePath: rel)

        let mtime = MutableSeconds(1000)
        let store = CatalogStore(location: .inMemory, scanner: singleFileScanner(rel, mtime: mtime))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }

        // First enrichment: capture instant = 700 (T1), moving best_capture off created_at (500, T0).
        await store.applyEnrichmentBatch([
            EnrichmentResult(
                id: id,
                metadata: .absoluteCapture(instant: Date(timeIntervalSince1970: 700)),
                thumbnailPath: nil,
                sourceSize: 100,
                sourceMTimeSeconds: 1000,
                contentHash: .empty
            ),
        ])
        let afterFirst = try #require(try await catalogStoreTestState(store).testAssets.first { $0.id == id })
        #expect(afterFirst.captureLocalTime == CaptureLocalTime(readingOf: Date(timeIntervalSince1970: 700)))

        // Subscribe synchronously (the `await` only returns once the continuation is
        // registered on the Store actor) before firing the write that must be
        // observed, rather than racing a spawned Task's own subscription against it.
        let changes = AsyncValueRecorder<CatalogStoreChange>()
        let changeStream = await store.changeNotifications()
        let changeTask = Task {
            for await change in changeStream {
                await changes.append(change)
            }
        }
        defer { changeTask.cancel() }

        // Second enrichment: every timestamp fact nil. Clears capture_instant_unix, so
        // best_capture_local moves T1 (700) -> T0 (500, created_at_unix) — structural.
        await store.applyEnrichmentBatch([
            EnrichmentResult(
                id: id,
                metadata: AssetMetadata(),
                thumbnailPath: nil,
                sourceSize: 100,
                sourceMTimeSeconds: 1000,
                contentHash: .empty
            ),
        ])

        _ = await changes.waitForValues { $0.last == .catalogChanged }
        let afterSecond = try #require(try await catalogStoreTestState(store).testAssets.first { $0.id == id })
        #expect(afterSecond.captureLocalTime == CaptureLocalTime(readingOf: Date(timeIntervalSince1970: 500)))
    }

    /// Overlay reuse clones the source's *stored* timestamp truth, and both date
    /// projections are rebuilt from it at the destination. Before the
    /// deduplication the destination's `ts_*_unix` values were copied from the
    /// source's own `ts_*_unix` columns while its capture wall was derived from
    /// `metadata_extra_json`; now both derive from the JSON, so this proves the
    /// sortable instant survives that change and still agrees with the wall.
    @Test func reusedOverlayClonesBothDateProjectionsFromStoredTimestamps() async throws {
        let temp = try makeTestDirectory()
        let source = temp.appending(path: "Source", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let sourceFile = source.appending(path: "IMG_1.JPG")
        try Data("camera".utf8).write(to: sourceFile)
        let sourcePath = try CatalogPath.normalizedDirectoryPath(for: source)

        let destination = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let destinationPath = try CatalogPath.normalizedDirectoryPath(for: destination)

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: source)
        try await store.addLibrary(url: destination)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }

        let sourceID = MediaAssetID(libraryRootPath: sourcePath, relativePath: MediaRelativePath(rawValue: "IMG_1.JPG"))
        let scanned = try await catalogStoreTestState(store)
        let scannedAsset = try #require(scanned.testAssets.first { $0.id == sourceID })
        let scannedSize = try #require(scannedAsset.byteSize)
        let scannedMTime = MediaAsset.mtimeSeconds(scannedAsset.contentModifiedAt)
        let scannedModifiedAt = try #require(scannedAsset.contentModifiedAt)
        guard case let .complete(digest) = ContentHasher().hashMaterializedFile(at: sourceFile) else {
            Issue.record("expected a source digest")
            return
        }

        // A local-authority record: one value that feeds the sortable instant and
        // the naming wall clock alike. No thumbnail, so reuse takes the direct path.
        let captureDate = Date(timeIntervalSince1970: 1_767_279_600)
        #expect(await store.applyEnrichmentBatch([
            EnrichmentResult(
                id: sourceID,
                metadata: .localCapture(instant: captureDate),
                thumbnailPath: nil,
                sourceSize: scannedSize,
                sourceMTimeSeconds: scannedMTime,
                contentHash: digest
            ),
        ]) == .applied(count: 1))

        let sourceWall = try await store.captureWall(for: sourceID)
        #expect(sourceWall != nil)
        // ADR 0036: the source's edit is overlay, so the library copy carries it.
        _ = try await store.setEditRecipe(EditRecipe(exposure: 1), for: sourceID)

        let batch = ImportBatchID()
        let operation = ActiveFileOperation(
            operationKey: .make(),
            sourceKind: .library,
            sourceDeviceIdentity: nil,
            sourceRootPath: sourcePath,
            sourceRelativePath: MediaRelativePath(rawValue: "IMG_1.JPG"),
            destinationRootPath: destinationPath,
            destinationRelativePath: MediaRelativePath(rawValue: "IMG_1.JPG"),
            stagingURL: nil,
            companionStagingURLs: [],
            contentHash: digest,
            importBatch: ImportBatchID(unixMilliseconds: batch.unixMilliseconds),
            sourceByteSize: scannedSize,
            sourceModifiedAt: scannedModifiedAt,
            destinationModifiedAt: scannedModifiedAt,
            phase: .readyToPublish,
            updatedAt: Date()
        )
        try await store.beginImportOperation(operation)

        let result = try await store.settleImportedAsset(
            operation: operation,
            byteSize: scannedSize,
            contentModifiedAt: scannedModifiedAt,
            companions: []
        )
        #expect(result == ImportProductsResult(metadata: .reused, rendering: .reused))

        let destinationID = MediaAssetID(
            libraryRootPath: destinationPath,
            relativePath: MediaRelativePath(rawValue: "IMG_1.JPG")
        )
        let settled = try await catalogStoreTestState(store)
        let destinationAsset = try #require(settled.testAssets.first { $0.id == destinationID })
        // The ordering column, rebuilt from the cloned records.
        // The record's wall clock is the instant's UTC reading (`localCapture`), and the local
        // time is that wall clock.
        #expect(destinationAsset.captureLocalTime == CaptureLocalTime(seconds: captureDate.timeIntervalSince1970))
        // The naming column, rebuilt from the same records — the two agree because
        // there is only one thing left for them to disagree about.
        #expect(try await store.captureWall(for: destinationID) == sourceWall)
        #expect(
            try await store.editRecipe(for: destinationID)
                == StoredEditRecipe(recipe: EditRecipe(exposure: 1), revision: 1)
        )
    }

    @Test func provenDeletionPurgesThumbnailFile() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        let rel = MediaRelativePath(rawValue: "a.jpg")
        let id = MediaAssetID(libraryRootPath: rootPath, relativePath: rel)

        let present = MutablePresence(true)
        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        let store = CatalogStore(
            location: .databaseFile(databaseURL),
            scanner: presenceScanner(rel, present: present),
            filesystemWatcher: watcher
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }

        // Create the real thumbnail file the catalog will reference, then enrich.
        let thumbnailDirectory = databaseURL.deletingLastPathComponent()
            .appending(path: "Thumbnails", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
        let thumbnailName = "thumb.jpg"
        let thumbnailURL = thumbnailDirectory.appending(path: thumbnailName, directoryHint: .notDirectory)
        try Data("thumb".utf8).write(to: thumbnailURL)
        await store.applyEnrichmentBatch([
            EnrichmentResult(
                id: id,
                metadata: AssetMetadata(),
                thumbnailPath: thumbnailName,
                sourceSize: 100,
                sourceMTimeSeconds: 1000,
                contentHash: .empty
            ),
        ])
        #expect(FileManager.default.fileExists(atPath: thumbnailURL.path(percentEncoded: false)))

        // The file disappears; a completed re-scan proves deletion, purging the row and
        // its thumbnail file.
        await present.set(false)
        emit(FilesystemEvent(path: root.appending(path: "a.jpg").path(percentEncoded: false), flags: 0))
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.isEmpty }
        #expect(!FileManager.default.fileExists(atPath: thumbnailURL.path(percentEncoded: false)))
    }

    @Test func removeLibraryPurgesThumbnailFiles() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        let rel = MediaRelativePath(rawValue: "a.jpg")
        let id = MediaAssetID(libraryRootPath: rootPath, relativePath: rel)

        let store = CatalogStore(
            location: .databaseFile(databaseURL),
            scanner: singleFileScanner(rel, mtime: MutableSeconds(1000))
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }

        let thumbnailDirectory = databaseURL.deletingLastPathComponent()
            .appending(path: "Thumbnails", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
        let thumbnailName = "thumb.jpg"
        let thumbnailURL = thumbnailDirectory.appending(path: thumbnailName, directoryHint: .notDirectory)
        try Data("thumb".utf8).write(to: thumbnailURL)
        await store.applyEnrichmentBatch([
            EnrichmentResult(
                id: id,
                metadata: AssetMetadata(),
                thumbnailPath: thumbnailName,
                sourceSize: 100,
                sourceMTimeSeconds: 1000,
                contentHash: .empty
            ),
        ])
        #expect(FileManager.default.fileExists(atPath: thumbnailURL.path(percentEncoded: false)))

        #expect(try await store.removeLibrary(path: rootPath) == .removed)
        #expect(!FileManager.default.fileExists(atPath: thumbnailURL.path(percentEncoded: false)))
        let snapshot = try await catalogStoreTestState(store)
        #expect(snapshot.testAssets.isEmpty)
    }

    @Test func enrichmentWithoutThumbnailStampsDefinitiveUnavailableOutcome() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        let rel = MediaRelativePath(rawValue: "broken.jpg")
        let id = MediaAssetID(libraryRootPath: rootPath, relativePath: rel)

        let store = CatalogStore(
            location: .databaseFile(databaseURL),
            scanner: singleFileScanner(rel, mtime: MutableSeconds(1000))
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }

        await store.applyEnrichmentBatch([
            EnrichmentResult(
                id: id,
                metadata: AssetMetadata(),
                enrichedKind: .image,
                thumbnailPath: nil,
                sourceSize: 100,
                sourceMTimeSeconds: 1000,
                contentHash: .empty,
                generatedThumbnail: nil
            ),
        ])

        let asset = try #require(try await catalogStoreTestState(store).testAssets.first { $0.id == id })
        #expect(asset.thumbnailPath == nil)
        #expect(asset.metadataSourceSize == 100)
        #expect(asset.metadataSourceMTimeSeconds == 1000)
        #expect(!asset.needsEnrichment(.products))

        let details = try await store.mediaTileDetails(for: [id])
        let detail = try #require(details[id])
        #expect(detail.thumbnailUnavailable)
        #expect(detail.thumbnailPath == nil)
        #expect(detail.renderedSourceMTimeSeconds == 1000)
    }

    /// ARC-053: the copy is the card file, byte for byte, so each of the card's products
    /// becomes the copy's whenever its stamp names the bytes the import copied. The copy
    /// keeps the digest the import computed from it.
    @Test func aCardImportReusesTheCardsCurrentProducts() async throws {
        let card = try await enrichedCardImportFixture()
        let result = try await card.settle(sourceModifiedAt: card.scannedModifiedAt)

        #expect(result == ImportProductsResult(metadata: .reused, rendering: .reused))

        let state = try await catalogStoreTestState(card.store)
        let copy = try #require(state.testAssets.first { $0.id.libraryRootPath == card.destinationPath })
        #expect(copy.captureLocalTime == CaptureLocalTime(seconds: card.captureDate.timeIntervalSince1970))
        #expect(copy.contentHash == card.copyDigest)
        #expect(!copy.needsEnrichment(.products))
    }

    /// ADR 0009: a card row with its metadata but no rendering yet (its first pass) gives
    /// the copy its metadata; the rendering stays owed for enrichment.
    @Test func aCardRowWithoutARenderingGivesTheCopyItsMetadataAndOwesTheRendering() async throws {
        let card = try await enrichedCardImportFixture(rendered: false)
        let result = try await card.settle(sourceModifiedAt: card.scannedModifiedAt)

        #expect(result == ImportProductsResult(metadata: .reused, rendering: .owed))
        let state = try await catalogStoreTestState(card.store)
        let copy = try #require(state.testAssets.first { $0.id.libraryRootPath == card.destinationPath })
        #expect(copy.captureLocalTime == CaptureLocalTime(seconds: card.captureDate.timeIntervalSince1970))
        #expect(!copy.metadataStale)
        #expect(copy.renderingStale)
        #expect(!copy.hashStale)
    }

    /// ADR 0009 §9: a copy that settles owing a product is offered to enrichment before any
    /// other background row, because its bytes are local now and may not be once a
    /// cloud-synced library evicts it. The import itself never waits for the product.
    @Test func aCopyOwingARenderingIsClaimedBeforeOtherBackgroundWork() async throws {
        let card = try await enrichedCardImportFixture(rendered: false)
        _ = try await card.settle(sourceModifiedAt: card.scannedModifiedAt)
        let copyID = MediaAssetID(libraryRootPath: card.destinationPath, relativePath: MediaRelativePath(rawValue: "IMG_1.JPG"))

        let claimed = try await card.store.enrichmentCandidates(limit: 1)

        #expect(claimed.map(\.asset.id) == [copyID])
        #expect(claimed.first?.scope == [.rendering])
    }

    /// A catalog write SQLite refuses because the disk is full (`SQLITE_FULL`) is typed as
    /// out of space where the catalog writes, so an import stops on it (ADR 0027).
    @Test func aCatalogWriteTheDiskCannotHoldIsTypedAsOutOfSpace() throws {
        let queue = try DatabaseQueue(path: makeTestDirectory().appending(path: "full.sqlite").path(percentEncoded: false))
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE t (b BLOB)")
            try db.execute(sql: "PRAGMA max_page_count = 8")
        }
        #expect(throws: CatalogStoreError.outOfSpace) {
            try CatalogStore.writeWithJournalDurability(queue) { db in
                try db.execute(sql: "INSERT INTO t VALUES (zeroblob(1000000))")
            }
        }
    }

    /// ARC-053: a card file that changed after it was enriched has an overlay for other
    /// bytes; the copy is enriched from its own.
    @Test func aCardImportWithAStaleOverlayEnrichesTheCopy() async throws {
        let card = try await enrichedCardImportFixture()
        let result = try await card.settle(sourceModifiedAt: card.scannedModifiedAt.addingTimeInterval(60))

        #expect(result == .owed)

        let state = try await catalogStoreTestState(card.store)
        let copy = try #require(state.testAssets.first { $0.id.libraryRootPath == card.destinationPath })
        #expect(copy.contentHash == card.copyDigest)
        #expect(copy.needsEnrichment(.products))
    }
}

/// A card holding one enriched photo, a library to import it into, and its staged copy.
private struct EnrichedCardImport {
    let store: CatalogStore
    let cardPath: LibraryRootPath
    let destinationPath: LibraryRootPath
    let staging: URL
    let copyDigest: XXH3Digest128
    let scannedSize: Int64
    let scannedModifiedAt: Date
    let captureDate: Date

    func settle(sourceModifiedAt: Date) async throws -> ImportProductsResult {
        let operation = ActiveFileOperation(
            operationKey: .make(),
            sourceKind: .removableVolume,
            sourceDeviceIdentity: .volume(uuid: "test"),
            sourceRootPath: cardPath,
            sourceRelativePath: MediaRelativePath(rawValue: "IMG_1.JPG"),
            destinationRootPath: destinationPath,
            destinationRelativePath: MediaRelativePath(rawValue: "IMG_1.JPG"),
            stagingURL: staging,
            companionStagingURLs: [],
            contentHash: copyDigest,
            importBatch: ImportBatchID(),
            sourceByteSize: scannedSize,
            sourceModifiedAt: sourceModifiedAt,
            destinationModifiedAt: sourceModifiedAt,
            phase: .readyToPublish,
            updatedAt: Date()
        )
        try await store.beginImportOperation(operation)
        return try await store.settleImportedAsset(
            operation: operation,
            byteSize: scannedSize,
            contentModifiedAt: sourceModifiedAt,
            companions: []
        )
    }
}

private func enrichedCardImportFixture(rendered: Bool = true) async throws -> EnrichedCardImport {
    let temp = try makeTestDirectory()
    let card = temp.appending(path: "CARD", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
    try Data("camera".utf8).write(to: card.appending(path: "IMG_1.JPG"))
    let cardPath = try CatalogPath.normalizedDirectoryPath(for: card)

    let destination = temp.appending(path: "Pictures", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let destinationPath = try CatalogPath.normalizedDirectoryPath(for: destination)

    let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
    try await store.start(scansSavedLibraries: false)
    try await store.attachRemovableVolume(
        mountURL: card,
        identity: .volume(uuid: "test"),
        displayName: "CARD",
        isEjectable: true
    )
    try await store.addLibrary(url: destination)
    let cardID = MediaAssetID(libraryRootPath: cardPath, relativePath: MediaRelativePath(rawValue: "IMG_1.JPG"))
    _ = try await waitForCatalogStoreState(store) { state in
        !state.isScanning && state.removableSources.contains { $0.path == cardPath && !$0.isScanning }
    }
    // The facts the scan recorded for the card file, read where the scan read them.
    let attributes = try FileManager.default.attributesOfItem(atPath: cardID.fileURL.path(percentEncoded: false))
    let scannedSize = try #require((attributes[.size] as? NSNumber)?.int64Value)
    let scannedModifiedAt = try #require(attributes[.modificationDate] as? Date)

    // A card row is enriched without a digest: it is read in place (ADR 0018). Its
    // metadata pass leaves the rendering owed (ADR 0009).
    let captureDate = Date(timeIntervalSince1970: 1_767_279_600)
    #expect(await store.applyEnrichmentBatch([
        EnrichmentResult(
            id: cardID,
            metadata: EnrichedMetadata(metadata: .localCapture(instant: captureDate), kind: .image, format: nil),
            rendering: rendered ? EnrichedRendering() : nil,
            sourceSize: scannedSize,
            sourceMTimeSeconds: MediaAsset.mtimeSeconds(scannedModifiedAt),
            contentHash: nil
        ),
    ]) == .applied(count: 1))

    let staging = destination.appending(path: ".stage.otos-import-staging")
    try Data("camera".utf8).write(to: staging)
    guard case let .complete(copyDigest) = ContentHasher().hashMaterializedFile(at: staging) else {
        throw CancellationError()
    }
    return EnrichedCardImport(
        store: store,
        cardPath: cardPath,
        destinationPath: destinationPath,
        staging: staging,
        copyDigest: copyDigest,
        scannedSize: scannedSize,
        scannedModifiedAt: scannedModifiedAt,
        captureDate: captureDate
    )
}

// MARK: - Helpers

private func makeAsset(
    size: Int64? = 100,
    captureLocalTime: CaptureLocalTime? = nil,
    createdAt: Date? = nil,
    modifiedAt: Date? = nil,
    stampSize: Int64? = nil,
    stampMtime: Int? = nil,
    contentHash: XXH3Digest128? = .empty,
    hashSourceSize: Int64? = nil,
    hashSourceMtime: Int? = nil
) -> MediaAsset {
    let resolvedHashSourceSize = contentHash == nil ? nil : (hashSourceSize ?? stampSize)
    let resolvedHashSourceMtime = contentHash == nil ? nil : (hashSourceMtime ?? stampMtime)
    return MediaAsset(
        libraryRootPath: LibraryRootPath(rawValue: "/Library"),
        relativePath: MediaRelativePath(rawValue: "a.jpg"),
        name: "a.jpg",
        contentTypeIdentifier: "public.jpeg",
        byteSize: size,
        createdAt: createdAt,
        contentModifiedAt: modifiedAt,
        thumbnailPath: nil,
        captureLocalTime: captureLocalTime,
        metadataSourceSize: stampSize,
        metadataSourceMTimeSeconds: stampMtime,
        renderedSourceSize: stampSize,
        renderedSourceMTimeSeconds: stampMtime,
        contentHash: contentHash,
        contentHashSourceSize: resolvedHashSourceSize,
        contentHashSourceMTimeSeconds: resolvedHashSourceMtime
    )
}

private func persistedMetadataRow(
    databaseURL: URL,
    rootPath: LibraryRootPath,
    relativePath: MediaRelativePath
) async throws -> PersistedMetadataRow {
    try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).read { db in
        let fetchedRootID = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM library_root WHERE path = ?",
            arguments: [rootPath.rawValue]
        )
        let rootID = try #require(fetchedRootID)
        let fetchedRow = try Row.fetchOne(
            db,
            sql: """
            SELECT camera_model, pixel_width, duration_seconds, metadata_extra_json
            FROM asset_metadata
            WHERE library_root_id = ? AND relative_path = ?
            """,
            arguments: [rootID, relativePath.rawValue]
        )
        let row = try #require(fetchedRow)
        return try PersistedMetadataRow(
            cameraModel: row["camera_model"] as String?,
            pixelWidth: row["pixel_width"] as Int?,
            durationSeconds: row["duration_seconds"] as Double?,
            metadata: CatalogQueryGateway.metadataExtra(libraryRootID: rootID, relativePath: relativePath, db: db)
        )
    }
}

private func expectVideoMetadataPersisted(
    databaseURL: URL,
    rootPath: LibraryRootPath,
    relativePath: MediaRelativePath,
    store: CatalogStore
) async throws {
    let persisted = try await persistedMetadataRow(
        databaseURL: databaseURL,
        rootPath: rootPath,
        relativePath: relativePath
    )
    #expect(persisted.cameraModel == "Cam")
    #expect(persisted.pixelWidth == 4000)
    #expect(persisted.durationSeconds == 187.25)
    #expect(persisted.metadata?.cameraModel == "Cam")
    #expect(persisted.metadata?.pixelWidth == 4000)
    #expect(persisted.metadata?.durationSeconds == 187.25)

    let id = MediaAssetID(libraryRootPath: rootPath, relativePath: relativePath)
    let queried = try #require(try await store.metadata(for: id))
    #expect(queried.cameraModel == "Cam")
    #expect(queried.pixelWidth == 4000)
    #expect(queried.durationSeconds == 187.25)
}

private struct PersistedMetadataRow {
    let cameraModel: String?
    let pixelWidth: Int?
    let durationSeconds: Double?
    let metadata: AssetMetadata?
}

/// Holds a mutable mtime so a scanner closure can return changing facts across scans.
private actor MutableSeconds {
    private(set) var value: Int

    init(_ value: Int) {
        self.value = value
    }

    func set(_ value: Int) {
        self.value = value
    }
}

private actor MutablePresence {
    private(set) var value: Bool

    init(_ value: Bool) {
        self.value = value
    }

    func set(_ value: Bool) {
        self.value = value
    }
}

private func singleFileScanner(_ rel: MediaRelativePath, mtime: MutableSeconds) -> CatalogScanner {
    CatalogScanner { _, _, batchHandler in
        let seconds = await mtime.value
        try await batchHandler([
            ScannedMediaFile(
                relativePath: rel,
                name: "a.jpg",
                contentTypeIdentifier: "public.jpeg",
                byteSize: 100,
                createdAt: Date(timeIntervalSince1970: 500),
                contentModifiedAt: Date(timeIntervalSince1970: TimeInterval(seconds))
            ),
        ])
        return .mediaOnly([rel])
    }
}

private func presenceScanner(_ rel: MediaRelativePath, present: MutablePresence) -> CatalogScanner {
    CatalogScanner { _, _, batchHandler in
        if await present.value {
            try await batchHandler([
                ScannedMediaFile(
                    relativePath: rel,
                    name: "a.jpg",
                    contentTypeIdentifier: "public.jpeg",
                    byteSize: 100,
                    createdAt: Date(timeIntervalSince1970: 500),
                    contentModifiedAt: Date(timeIntervalSince1970: 1000)
                ),
            ])
            return .mediaOnly([rel])
        }
        return .empty
    }
}
