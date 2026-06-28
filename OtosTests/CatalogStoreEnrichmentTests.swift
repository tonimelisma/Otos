import Foundation
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
        #expect(makeAsset(captureDate: capture, createdAt: created, modifiedAt: modified).bestCaptureDate == capture)
        #expect(makeAsset(captureDate: nil, createdAt: created, modifiedAt: modified).bestCaptureDate == created)
        #expect(makeAsset(captureDate: nil, createdAt: nil, modifiedAt: modified).bestCaptureDate == modified)
        #expect(makeAsset(captureDate: nil, createdAt: nil, modifiedAt: nil).bestCaptureDate == nil)
    }

    @Test func metadataBlobRoundTrips() throws {
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
        let data = try #require(CatalogStore.encodeMetadata(meta))
        #expect(CatalogStore.decodeMetadata(data) == meta)
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
        _ = try await waitForCatalogStoreSnapshot(store) { !$0.isScanning && $0.testAssets.count == 1 }

        let captureDate = Date(timeIntervalSince1970: 700)
        await store.applyEnrichmentBatch([
            EnrichmentResult(
                id: id,
                metadata: AssetMetadata(cameraModel: "Cam"),
                captureDate: captureDate,
                thumbnailPath: "thumb.heic",
                sourceSize: 100,
                sourceMTimeSeconds: 1000
            ),
        ])

        let enriched = try #require(await store.currentSnapshot().testAssets.first { $0.id == id })
        #expect(enriched.thumbnailPath == "thumb.heic")
        #expect(enriched.captureDate == captureDate)
        #expect(enriched.bestCaptureDate == captureDate)
        #expect(enriched.needsEnrichment == false)

        // Re-scan observing a changed mtime (same size): enrichment survives the merge,
        // and the changed (size, mtime) signature makes the asset stale again.
        await mtime.set(2000)
        emit(FilesystemEvent(path: root.appending(path: "a.jpg").path(percentEncoded: false), flags: 0))
        let restaled = try await waitForCatalogStoreSnapshot(store) { snapshot in
            guard let asset = snapshot.testAssets.first(where: { $0.id == id }) else { return false }
            return !snapshot.isScanning && asset.contentModifiedAt == Date(timeIntervalSince1970: 2000)
        }
        let asset = try #require(restaled.testAssets.first { $0.id == id })
        #expect(asset.thumbnailPath == "thumb.heic")
        #expect(asset.captureDate == captureDate)
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
        _ = try await waitForCatalogStoreSnapshot(store) { !$0.isScanning && $0.testAssets.count == 1 }
        let scanned = await store.currentSnapshot()
        let scannedAsset = try #require(scanned.testAssets.first { $0.id == id })
        let scannedSize = try #require(scannedAsset.byteSize)
        let scannedMTime = MediaAsset.mtimeSeconds(scannedAsset.contentModifiedAt)

        let captureDate = Date(timeIntervalSince1970: 700)
        await store.applyEnrichmentBatch([
            EnrichmentResult(
                id: id,
                metadata: AssetMetadata(cameraModel: "Cam", pixelWidth: 4000, pixelHeight: 3000),
                captureDate: captureDate,
                thumbnailPath: "thumb.heic",
                sourceSize: scannedSize,
                sourceMTimeSeconds: scannedMTime
            ),
        ])

        let reloaded = CatalogStore(location: .databaseFile(databaseURL))
        try await reloaded.start(scansSavedLibraries: false)
        let asset = try #require(await reloaded.currentSnapshot().testAssets.first { $0.id == id })
        #expect(asset.thumbnailPath == "thumb.heic")
        #expect(asset.captureDate == captureDate)
        #expect(asset.enrichedSourceSize == scannedSize)
        #expect(asset.enrichedSourceMTimeSeconds == scannedMTime)
        #expect(asset.needsEnrichment == false)
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
        _ = try await waitForCatalogStoreSnapshot(store) { !$0.isScanning && $0.testAssets.count == 1 }

        // Create the real thumbnail file the catalog will reference, then enrich.
        let thumbnailDirectory = databaseURL.deletingLastPathComponent()
            .appending(path: "Thumbnails", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
        let thumbnailName = "thumb.heic"
        let thumbnailURL = thumbnailDirectory.appending(path: thumbnailName, directoryHint: .notDirectory)
        try Data("thumb".utf8).write(to: thumbnailURL)
        await store.applyEnrichmentBatch([
            EnrichmentResult(
                id: id,
                metadata: AssetMetadata(),
                captureDate: nil,
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
        _ = try await waitForCatalogStoreSnapshot(store) { !$0.isScanning && $0.testAssets.isEmpty }
        #expect(!FileManager.default.fileExists(atPath: thumbnailURL.path(percentEncoded: false)))
    }
}

// MARK: - Helpers

private func makeAsset(
    size: Int64? = 100,
    captureDate: Date? = nil,
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
        captureDate: captureDate,
        enrichedSourceSize: stampSize,
        enrichedSourceMTimeSeconds: stampMtime
    )
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
