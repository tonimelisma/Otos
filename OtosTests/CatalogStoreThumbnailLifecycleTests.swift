import Foundation
@testable import Otos
import Testing

struct CatalogStoreThumbnailLifecycleTests {
    @Test func acceptedStagedThumbnailPromotesAndStampsCatalog() async throws {
        let fixture = try await makeThumbnailLifecycleFixture()
        let generated = try fixture.stageThumbnail(finalName: "thumb.jpg", stagedName: ".thumb.jpg.accepted.tmp")

        let outcome = await fixture.store.applyEnrichmentBatch([
            EnrichmentResult(
                id: fixture.id,
                metadata: AssetMetadata(cameraModel: "Cam"),
                timestampFacts: EnrichmentTimestampFacts(original: Date(timeIntervalSince1970: 700)),
                thumbnailPath: nil,
                sourceSize: 100,
                sourceMTimeSeconds: 1000,
                contentHash: .empty,
                generatedThumbnail: generated
            ),
        ])

        #expect(outcome == .applied(count: 1))
        #expect(!FileManager.default.fileExists(atPath: fixture.stagedURL(for: generated).path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: fixture.finalURL(for: generated).path(percentEncoded: false)))
        let current = try #require(try await catalogStoreTestState(fixture.store).testAssets.first { $0.id == fixture.id })
        #expect(current.thumbnailPath == generated.finalRelativePath)
        #expect(!current.needsEnrichment(hashRequired: true))
    }

    @Test func staleStagedThumbnailIsDiscardedWithoutReplacingFinalThumbnail() async throws {
        let fixture = try await makeThumbnailLifecycleFixture()
        let finalName = ThumbnailStore.relativeName(for: fixture.id)
        let finalURL = ThumbnailStore.url(for: finalName, in: fixture.thumbnailDirectory)
        try FileManager.default.createDirectory(at: fixture.thumbnailDirectory, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: finalURL)
        await fixture.store.applyEnrichmentBatch([fixture.acceptedResult(thumbnailPath: finalName)])

        try await fixture.makeCurrentRowStale()
        let generated = try fixture.stageThumbnail(
            finalName: finalName,
            stagedName: ".\(finalName).stale.tmp",
            contents: "new"
        )
        let outcome = await fixture.store.applyEnrichmentBatch([fixture.staleResult(generatedThumbnail: generated)])

        #expect(outcome == .applied(count: 0))
        #expect(try Data(contentsOf: finalURL) == Data("old".utf8))
        #expect(!FileManager.default.fileExists(atPath: fixture.stagedURL(for: generated).path(percentEncoded: false)))
        let current = try #require(try await catalogStoreTestState(fixture.store).testAssets.first { $0.id == fixture.id })
        #expect(current.thumbnailPath == finalName)
        #expect(current.needsEnrichment(hashRequired: true))
    }

    @Test func acceptedThumbnaillessResultDeletesSupersededAppOwnedThumbnail() async throws {
        let fixture = try await makeThumbnailLifecycleFixture()
        let finalName = ThumbnailStore.relativeName(for: fixture.id)
        let finalURL = ThumbnailStore.url(for: finalName, in: fixture.thumbnailDirectory)
        try FileManager.default.createDirectory(at: fixture.thumbnailDirectory, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: finalURL)
        await fixture.store.applyEnrichmentBatch([fixture.acceptedResult(thumbnailPath: finalName)])

        let outcome = await fixture.store.applyEnrichmentBatch([
            EnrichmentResult(
                id: fixture.id,
                metadata: AssetMetadata(),
                thumbnailPath: nil,
                sourceSize: 100,
                sourceMTimeSeconds: 1000,
                contentHash: .empty
            ),
        ])

        #expect(outcome == .applied(count: 1))
        #expect(!FileManager.default.fileExists(atPath: finalURL.path(percentEncoded: false)))
        let current = try #require(
            try await catalogStoreTestState(fixture.store).testAssets.first { $0.id == fixture.id }
        )
        #expect(current.thumbnailPath == nil)
        #expect(!current.needsEnrichment(hashRequired: true))
    }

    @Test func failedThumbnailPromotionReleasesEnrichmentClaimForRetry() async throws {
        let fixture = try await makeThumbnailLifecycleFixture()
        let candidates = try await fixture.store.enrichmentCandidates(prioritizing: [], limit: 1)
        let asset = try #require(candidates.first)
        #expect(asset.id == fixture.id)

        let outcome = await fixture.store.applyEnrichmentBatch([
            EnrichmentResult(
                id: fixture.id,
                metadata: AssetMetadata(cameraModel: "Cam"),
                timestampFacts: EnrichmentTimestampFacts(original: Date(timeIntervalSince1970: 700)),
                thumbnailPath: nil,
                sourceSize: asset.byteSize,
                sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt),
                contentHash: .empty,
                generatedThumbnail: GeneratedThumbnail(
                    finalRelativePath: ThumbnailStore.relativeName(for: fixture.id),
                    stagedRelativePath: ".missing-thumbnail.tmp"
                )
            ),
        ])

        #expect(outcome == .writeFailed)
        let retryCandidates = try await fixture.store.enrichmentCandidates(prioritizing: [], limit: 1)
        #expect(retryCandidates.map(\.id) == [fixture.id])
    }

    @Test func promotionFailureDoesNotRollBackEarlierAcceptedRows() async throws {
        let fixture = try await makeThumbnailLifecycleFixture()
        let accepted = try fixture.stageThumbnail(finalName: "accepted.jpg", stagedName: ".accepted.jpg.tmp")
        let missing = GeneratedThumbnail(
            finalRelativePath: "missing.jpg",
            stagedRelativePath: ".missing-thumbnail.tmp"
        )

        let outcome = await fixture.store.applyEnrichmentBatch([
            EnrichmentResult(
                id: fixture.id,
                metadata: AssetMetadata(cameraModel: "AcceptedCam"),
                timestampFacts: EnrichmentTimestampFacts(original: Date(timeIntervalSince1970: 700)),
                thumbnailPath: nil,
                sourceSize: 100,
                sourceMTimeSeconds: 1000,
                contentHash: .empty,
                generatedThumbnail: accepted
            ),
            EnrichmentResult(
                id: fixture.id,
                metadata: AssetMetadata(cameraModel: "FailedCam"),
                timestampFacts: EnrichmentTimestampFacts(original: Date(timeIntervalSince1970: 900)),
                thumbnailPath: nil,
                sourceSize: 100,
                sourceMTimeSeconds: 1000,
                contentHash: .empty,
                generatedThumbnail: missing
            ),
        ])

        #expect(outcome == .writeFailed)
        #expect(FileManager.default.fileExists(atPath: fixture.finalURL(for: accepted).path(percentEncoded: false)))
        let current = try #require(try await catalogStoreTestState(fixture.store).testAssets.first { $0.id == fixture.id })
        #expect(current.thumbnailPath == accepted.finalRelativePath)
        #expect(!current.needsEnrichment(hashRequired: true))
    }
}

private struct ThumbnailLifecycleFixture {
    let store: CatalogStore
    let root: URL
    let id: MediaAssetID
    let mtime: ThumbnailLifecycleSeconds
    let emit: @Sendable (FilesystemEvent) -> Void
    let thumbnailDirectory: URL

    func stageThumbnail(
        finalName: String,
        stagedName: String,
        contents: String = "thumb"
    ) throws -> GeneratedThumbnail {
        try FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
        let generated = GeneratedThumbnail(finalRelativePath: finalName, stagedRelativePath: stagedName)
        try Data(contents.utf8).write(to: stagedURL(for: generated))
        return generated
    }

    func stagedURL(for generated: GeneratedThumbnail) -> URL {
        ThumbnailStore.url(for: generated.stagedRelativePath, in: thumbnailDirectory)
    }

    func finalURL(for generated: GeneratedThumbnail) -> URL {
        ThumbnailStore.url(for: generated.finalRelativePath, in: thumbnailDirectory)
    }

    func acceptedResult(thumbnailPath: String) -> EnrichmentResult {
        EnrichmentResult(
            id: id,
            metadata: AssetMetadata(cameraModel: "InitialCam"),
            timestampFacts: EnrichmentTimestampFacts(original: Date(timeIntervalSince1970: 700)),
            thumbnailPath: thumbnailPath,
            sourceSize: 100,
            sourceMTimeSeconds: 1000,
            contentHash: .empty
        )
    }

    func staleResult(generatedThumbnail: GeneratedThumbnail) -> EnrichmentResult {
        EnrichmentResult(
            id: id,
            metadata: AssetMetadata(cameraModel: "StaleCam"),
            timestampFacts: EnrichmentTimestampFacts(original: Date(timeIntervalSince1970: 900)),
            thumbnailPath: nil,
            sourceSize: 100,
            sourceMTimeSeconds: 1000,
            contentHash: .empty,
            generatedThumbnail: generatedThumbnail
        )
    }

    func makeCurrentRowStale() async throws {
        let mtime = mtime
        let emit = emit
        let root = root
        let store = store
        let id = id

        await mtime.set(2000)
        emit(FilesystemEvent(path: root.appending(path: "a.jpg").path(percentEncoded: false), flags: 0))
        _ = try await waitForCatalogStoreState(store) { snapshot in
            guard let asset = snapshot.testAssets.first(where: { $0.id == id }) else { return false }
            return !snapshot.isScanning && MediaAsset.mtimeSeconds(asset.contentModifiedAt) == 2000
        }
    }
}

private func makeThumbnailLifecycleFixture() async throws -> ThumbnailLifecycleFixture {
    let temp = try makeCatalogStoreTemporaryDirectory()
    let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try writeCatalogStoreFile(root.appending(path: "a.jpg"), contents: "jpeg")
    let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
    let rel = MediaRelativePath(rawValue: "a.jpg")
    let id = MediaAssetID(libraryRootPath: rootPath, relativePath: rel)
    let mtime = ThumbnailLifecycleSeconds(1000)
    let (watcher, emit) = CatalogFilesystemWatcher.testing()
    let databaseURL = temp.appending(path: "db/catalog.sqlite")
    let store = CatalogStore(
        location: .databaseFile(databaseURL),
        scanner: thumbnailLifecycleScanner(rel, mtime: mtime),
        filesystemWatcher: watcher,
        filesystemEventDebounce: .milliseconds(20)
    )
    try await store.start(scansSavedLibraries: false)
    try await store.addLibrary(url: root)
    _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
    return ThumbnailLifecycleFixture(
        store: store,
        root: root,
        id: id,
        mtime: mtime,
        emit: emit,
        thumbnailDirectory: databaseURL.deletingLastPathComponent()
            .appending(path: "Thumbnails", directoryHint: .isDirectory)
    )
}

private actor ThumbnailLifecycleSeconds {
    private(set) var value: Int

    init(_ value: Int) {
        self.value = value
    }

    func set(_ value: Int) {
        self.value = value
    }
}

private func thumbnailLifecycleScanner(
    _ rel: MediaRelativePath,
    mtime: ThumbnailLifecycleSeconds
) -> CatalogScanner {
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
