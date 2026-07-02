import Foundation
import GRDB
@testable import Otos
import Testing

struct CatalogStoreEnrichmentTests {
    // MARK: - Pure model: staleness signature and best-date

    @Test func needsEnrichmentTracksSizeAndMtimeSignature() {
        let m1000 = Date(timeIntervalSince1970: 1000)
        let m2000 = Date(timeIntervalSince1970: 2000)
        #expect(makeAsset(size: 100, modifiedAt: m1000, stampSize: nil, stampMtime: nil).needsEnrichment)
        #expect(!makeAsset(size: 100, modifiedAt: m1000, stampSize: 100, stampMtime: 1000).needsEnrichment)
        #expect(makeAsset(size: 200, modifiedAt: m1000, stampSize: 100, stampMtime: 1000).needsEnrichment)
        #expect(makeAsset(size: 100, modifiedAt: m2000, stampSize: 100, stampMtime: 1000).needsEnrichment)
    }

    @Test func bestCaptureDatePrefersMetadataThenFilesystem() {
        let capture = Date(timeIntervalSince1970: 700)
        let created = Date(timeIntervalSince1970: 500)
        let modified = Date(timeIntervalSince1970: 900)
        #expect(
            makeAsset(bestCaptureDate: capture, createdAt: created, modifiedAt: modified).bestCaptureDate == capture
        )
        #expect(
            makeAsset(bestCaptureDate: created, createdAt: created, modifiedAt: modified).bestCaptureDate == created
        )
        #expect(makeAsset(bestCaptureDate: modified, createdAt: nil, modifiedAt: modified).bestCaptureDate == modified)
        #expect(makeAsset(bestCaptureDate: nil, createdAt: nil, modifiedAt: nil).bestCaptureDate == nil)
    }

    @Test func metadataExtraJSONRoundTrips() throws {
        let meta = AssetMetadata(
            family: "image",
            fileExtension: "jpg",
            brand: nil,
            timestamps: [
                CaptureTimestampRecord(
                    role: "original",
                    instant: Date(timeIntervalSince1970: 700),
                    utcOffsetSeconds: 3600,
                    precision: "full",
                    year: 1992, month: 6, day: 1, hour: 12, minute: 0, second: 0
                ),
            ],
            locations: [GeoRecord(source: "exifGPS", latitude: 1.5, longitude: 2.5, altitudeMeters: 10)],
            cameraMake: "Acme",
            cameraModel: "X1",
            lensModel: "50mm",
            orientation: 1,
            pixelWidth: 4000,
            pixelHeight: 3000,
            durationSeconds: nil
        )
        let json = try #require(CatalogStore.encodeMetadataExtraJSON(meta))
        #expect(CatalogStore.decodeMetadataExtraJSON(json) == meta)
    }

    // MARK: - Store: rescan merge, persistence, and purge

    @Test func rescanPreservesEnrichmentAndMtimeChangeMakesStale() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
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
            filesystemWatcher: watcher,
            filesystemEventDebounce: .milliseconds(20),
            diagnostics: nil
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }

        let captureDate = Date(timeIntervalSince1970: 700)
        await store.applyEnrichmentBatch([
            EnrichmentResult(
                id: id,
                metadata: AssetMetadata(cameraModel: "Cam"),
                timestampFacts: EnrichmentTimestampFacts(original: captureDate),
                thumbnailPath: "thumb.jpg",
                sourceSize: 100,
                sourceMTimeSeconds: 1000
            ),
        ])

        let enriched = try #require(try await catalogStoreTestState(store).testAssets.first { $0.id == id })
        #expect(enriched.thumbnailPath == "thumb.jpg")
        #expect(enriched.bestCaptureDate == captureDate)
        #expect(enriched.needsEnrichment == false)

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
        #expect(asset.bestCaptureDate == captureDate)
        #expect(asset.enrichedSourceSize == 100)
        #expect(asset.needsEnrichment == true)
    }

    @Test func enrichmentPersistsAndReloads() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
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
                metadata: AssetMetadata(cameraModel: "Cam", pixelWidth: 4000, pixelHeight: 3000),
                timestampFacts: EnrichmentTimestampFacts(original: captureDate),
                thumbnailPath: "thumb.jpg",
                sourceSize: scannedSize,
                sourceMTimeSeconds: scannedMTime
            ),
        ])

        let persistedMetadata = try await persistedMetadataRow(
            databaseURL: databaseURL,
            rootPath: rootPath,
            relativePath: rel
        )
        #expect(persistedMetadata.cameraModel == "Cam")
        #expect(persistedMetadata.pixelWidth == 4000)
        #expect(persistedMetadata.metadata?.cameraModel == "Cam")
        #expect(persistedMetadata.metadata?.pixelWidth == 4000)
        let queriedMetadata = try #require(try await store.metadata(for: id))
        #expect(queriedMetadata.cameraModel == "Cam")
        #expect(queriedMetadata.pixelWidth == 4000)

        let reloaded = CatalogStore(location: .databaseFile(databaseURL))
        try await reloaded.start(scansSavedLibraries: false)
        let asset = try #require(try await catalogStoreTestState(reloaded).testAssets.first { $0.id == id })
        #expect(asset.thumbnailPath == "thumb.jpg")
        #expect(asset.bestCaptureDate == captureDate)
        #expect(asset.enrichedSourceSize == scannedSize)
        #expect(asset.enrichedSourceMTimeSeconds == scannedMTime)
        #expect(asset.needsEnrichment == false)
    }

    @Test func staleEnrichmentCompletionDoesNotStampChangedSourceCurrent() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
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
            filesystemWatcher: watcher,
            filesystemEventDebounce: .milliseconds(20),
            diagnostics: nil
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
                metadata: AssetMetadata(cameraModel: "OldCam"),
                timestampFacts: EnrichmentTimestampFacts(original: Date(timeIntervalSince1970: 700)),
                thumbnailPath: "old.jpg",
                sourceSize: 100,
                sourceMTimeSeconds: 1000
            ),
        ])

        let current = try #require(try await catalogStoreTestState(store).testAssets.first { $0.id == id })
        #expect(current.thumbnailPath == nil)
        #expect(current.bestCaptureDate == Date(timeIntervalSince1970: 500))
        #expect(current.enrichedSourceSize == nil)
        #expect(current.enrichedSourceMTimeSeconds == nil)
        #expect(current.needsEnrichment)

        let reloaded = CatalogStore(location: .databaseFile(databaseURL), diagnostics: nil)
        try await reloaded.start(scansSavedLibraries: false)
        let persisted = try #require(try await catalogStoreTestState(reloaded).testAssets.first { $0.id == id })
        #expect(persisted.thumbnailPath == nil)
        #expect(persisted.bestCaptureDate == Date(timeIntervalSince1970: 500))
        #expect(persisted.enrichedSourceSize == nil)
        #expect(persisted.enrichedSourceMTimeSeconds == nil)
        #expect(persisted.needsEnrichment)
    }

    @Test func provenDeletionPurgesThumbnailFile() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
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
            filesystemWatcher: watcher,
            filesystemEventDebounce: .milliseconds(20),
            diagnostics: nil
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
                sourceMTimeSeconds: 1000
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
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        let rel = MediaRelativePath(rawValue: "a.jpg")
        let id = MediaAssetID(libraryRootPath: rootPath, relativePath: rel)

        let store = CatalogStore(
            location: .databaseFile(databaseURL),
            scanner: singleFileScanner(rel, mtime: MutableSeconds(1000)),
            diagnostics: nil
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
                sourceMTimeSeconds: 1000
            ),
        ])
        #expect(FileManager.default.fileExists(atPath: thumbnailURL.path(percentEncoded: false)))

        try await store.removeLibrary(path: rootPath)
        #expect(!FileManager.default.fileExists(atPath: thumbnailURL.path(percentEncoded: false)))
        let snapshot = try await catalogStoreTestState(store)
        #expect(snapshot.testAssets.isEmpty)
    }
}

// MARK: - Helpers

private func makeAsset(
    size: Int64? = 100,
    bestCaptureDate: Date? = nil,
    createdAt: Date? = nil,
    modifiedAt: Date? = nil,
    stampSize: Int64? = nil,
    stampMtime: Int? = nil
) -> MediaAsset {
    MediaAsset(
        libraryRootPath: LibraryRootPath(rawValue: "/Library"),
        relativePath: MediaRelativePath(rawValue: "a.jpg"),
        name: "a.jpg",
        contentTypeIdentifier: "public.jpeg",
        byteSize: size,
        createdAt: createdAt,
        contentModifiedAt: modifiedAt,
        thumbnailPath: nil,
        bestCaptureDate: bestCaptureDate,
        enrichedSourceSize: stampSize,
        enrichedSourceMTimeSeconds: stampMtime
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
            SELECT camera_model, pixel_width, metadata_extra_json
            FROM asset_metadata
            WHERE library_root_id = ? AND relative_path = ?
            """,
            arguments: [rootID, relativePath.rawValue]
        )
        let row = try #require(fetchedRow)
        return try PersistedMetadataRow(
            cameraModel: row["camera_model"] as String?,
            pixelWidth: row["pixel_width"] as Int?,
            metadata: CatalogStore.metadataExtra(libraryRootID: rootID, relativePath: relativePath, db: db)
        )
    }
}

private struct PersistedMetadataRow {
    let cameraModel: String?
    let pixelWidth: Int?
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
    CatalogScanner { _, _, _, batchHandler in
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
        return [rel]
    }
}

private func presenceScanner(_ rel: MediaRelativePath, present: MutablePresence) -> CatalogScanner {
    CatalogScanner { _, _, _, batchHandler in
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
            return [rel]
        }
        return []
    }
}
