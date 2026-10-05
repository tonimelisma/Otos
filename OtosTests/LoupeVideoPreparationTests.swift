import AVFoundation
import Foundation
@testable import OtosKit
import Testing

/// Loupe video preparation (APP-020, DES-087): opening a video prepares it for
/// playback with no click, exactly as opening an image decodes it. These run against a
/// real `CatalogStore` because `bestKind` — the fact that starts preparation — is a
/// catalog answer, and a fake reader would assert the trigger against itself.
@MainActor
struct LoupeVideoPreparationTests {
    private func makeVideoCatalog() async throws -> (CatalogStore, MediaAssetID) {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Movies", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        let rel = MediaRelativePath(rawValue: "clip.mov")
        let id = MediaAssetID(libraryRootPath: rootPath, relativePath: rel)
        let store = CatalogStore(
            location: .databaseFile(temp.appending(path: "db/catalog.sqlite")),
            scanner: CatalogScanner { _, _, batchHandler in
                try await batchHandler([
                    ScannedMediaFile(
                        relativePath: rel,
                        name: "clip.mov",
                        contentTypeIdentifier: "com.apple.quicktime-movie",
                        byteSize: 4096,
                        createdAt: Date(timeIntervalSince1970: 500),
                        contentModifiedAt: Date(timeIntervalSince1970: 500)
                    ),
                ])
                return .mediaOnly([rel])
            }
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        await store.applyEnrichmentBatch([
            EnrichmentResult(
                id: id,
                metadata: AssetMetadata(),
                enrichedKind: .video,
                thumbnailPath: nil,
                sourceSize: 4096,
                sourceMTimeSeconds: 500,
                contentHash: .empty,
                generatedThumbnail: nil
            ),
        ])
        return (store, id)
    }

    private func makeModel(
        store: CatalogStore,
        previewOutcome: PreviewImageLoader.Outcome
    ) async -> CatalogWindowViewModel {
        let previewLoader = FakePreviewLoader()
        await previewLoader.setDefaultOutcome(previewOutcome)
        return CatalogWindowViewModel(
            catalogStore: store,
            enrichmentCoordinator: nil,
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: PreferencesDomain.suite(UUID().uuidString),
            previewLoader: previewLoader,
            videoLoader: VideoPreviewLoader(
                status: { _ in .materialized },
                materializationRequester: ClosureMaterializationRequester { _ in .testMaterialized }
            )
        )
    }

    /// Polls because preparation is started by `setFocus`'s detail read — an unnamed
    /// task by design (kind resolution), so there is no handle to await.
    private func waitForVideoState(_ model: CatalogWindowViewModel) async throws {
        try await waitUntil { model.loupeVideoState != nil }
    }

    @Test func focusingAVideoPreparesItPausedWithoutAClick() async throws {
        let (store, id) = try await makeVideoCatalog()
        let model = await makeModel(store: store, previewOutcome: .unavailable)
        model.applyState(makeLoupeVideoState(orderedIDs: [id]))

        model.openLoupe(id: id)
        try await waitForVideoState(model)

        // No onPlayVideo call anywhere in this test: opening was enough.
        let state = try #require(model.loupeVideoState)
        #expect(state.id == id)
        #expect(state.isPlaying == false)
    }

    @Test func videoPreparationNeverWritesDownloadingSlots() async throws {
        let (store, id) = try await makeVideoCatalog()
        // `.unavailable` keeps the pane-preview path — the sole owner of the pane's
        // progress indicator — from ever inserting the slot, so anything found in
        // `downloadingSlots` could only have come from the video path.
        let model = await makeModel(store: store, previewOutcome: .unavailable)
        model.applyState(makeLoupeVideoState(orderedIDs: [id]))

        model.openLoupe(id: id)
        try await waitForVideoState(model)
        await model.paneRequestTasks[.loupe]?.value

        #expect(model.downloadingSlots.isEmpty)
    }

    @Test func focusMovingOffAVideoTearsDownItsPreparation() async throws {
        let (store, id) = try await makeVideoCatalog()
        let model = await makeModel(store: store, previewOutcome: .unavailable)
        model.applyState(makeLoupeVideoState(orderedIDs: [id]))
        model.openLoupe(id: id)
        try await waitForVideoState(model)

        model.exitToGrid()

        #expect(model.loupeVideoState == nil)
        #expect(model.loupeVideoPrepareTask == nil)
    }
}

private func makeLoupeVideoState(orderedIDs: [MediaAssetID]) -> CatalogWindowState {
    CatalogWindowState(
        title: "Test",
        libraries: [],
        removableSources: [],
        mediaGrid: CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: orderedIDs),
        filterOptions: .empty,
        resolvedSidebarSelection: .allMedia,
        mediaEmptyState: .noMedia,
        deviceConnectionBanner: nil,
        queryGeneration: 0
    )
}
