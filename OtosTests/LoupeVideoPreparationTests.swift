import AVFoundation
import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// Loupe video preparation (APP-020, DES-087): opening a video prepares it for
/// playback with no click, exactly as opening an image decodes it. These run against a
/// real `CatalogStore` because `bestKind` — the fact that starts preparation — is a
/// catalog answer, and a fake reader would assert the trigger against itself.
@Suite(.testScope)
@MainActor
struct LoupeVideoPreparationTests {
    private func makeVideoCatalog() async throws -> (CatalogStore, MediaAssetID) {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Movies", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        let rel = MediaRelativePath(rawValue: "clip.mov")
        let id = MediaAssetID(libraryRootPath: rootPath, relativePath: rel)
        let store = makeTestStore(
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
        previewOutcome: PreviewImageLoader.Outcome,
        videoLoader: VideoPreviewLoader? = nil
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
            videoLoader: videoLoader ?? VideoPreviewLoader(
                status: { _ in .materialized },
                materializationRequester: ClosureMaterializationRequester(status: { _ in .materialized }) { _ in .testMaterialized }
            ),
            volumeCapacity: ampleVolumeCapacity,
            trashFiles: .refusing
        )
    }

    /// Polls because preparation is started by `setFocus`'s detail read — an unnamed
    /// task by design (kind resolution), so there is no handle to await.
    private func waitForVideoState(_ model: CatalogWindowViewModel) async throws {
        try await waitUntil { model.loupeVideoState != nil }
    }

    // Validates: APP-020
    @Test func focusingAVideoPreparesItPausedWithoutAClick() async throws {
        let (store, id) = try await makeVideoCatalog()
        let model = await makeModel(store: store, previewOutcome: .unavailable)
        model.applyState(makeLoupeVideoState(orderedIDs: [id]))

        model.openLoupe(id: id)
        try await waitForVideoState(model)

        // No Try Again anywhere in this test: opening was enough.
        let state = try #require(model.loupeVideoState)
        #expect(state.id == id)
        #expect(state.isPlaying == false)
    }

    // Validates: APP-020
    @Test func focusMovingOffAVideoTearsDownItsPreparation() async throws {
        let (store, id) = try await makeVideoCatalog()
        let model = await makeModel(store: store, previewOutcome: .unavailable)
        model.applyState(makeLoupeVideoState(orderedIDs: [id]))
        model.openLoupe(id: id)
        try await waitForVideoState(model)

        model.exitToGrid()

        #expect(model.loupeVideo == nil)
        #expect(model.loupeVideoPrepareTask == nil)
    }

    // Validates: APP-020
    /// The defect this pins: a video whose bytes could not come left the pane as it was,
    /// so a click on it did nothing anyone could see. Now the pane says why, and Try Again
    /// shows its wait in the frame it is pressed (DES-086, DES-120) and asks by the same
    /// path opening did.
    @Test func aVideoThatCannotComeSaysWhyAndTryAgainShowsItsWaitAtOnce() async throws {
        let (store, id) = try await makeVideoCatalog()
        let source = HeldVideoSource()
        let model = await makeModel(
            store: store,
            previewOutcome: .unavailable,
            videoLoader: VideoPreviewLoader(status: source.status, materializationRequester: source.requester)
        )
        model.applyState(makeLoupeVideoState(orderedIDs: [id]))

        model.openLoupe(id: id)
        try await waitUntil { model.loupeVideo == .unavailable(id, .serverUnreachable) }

        model.retryLoupeVideo()
        #expect(model.loupeVideo == .preparing(id))

        await source.gate.waitForArrivals(1)
        await source.gate.open()
        try await waitForVideoState(model)
        #expect(model.loupeVideoState?.id == id)
        #expect(source.attempts == 2)
    }

    // Validates: APP-020
    /// Opening a video shows its wait from the frame it is opened in, once its kind is
    /// known, rather than a poster that looks finished.
    @Test func aVideoBeingPreparedIsShownAsAWait() async throws {
        let (store, id) = try await makeVideoCatalog()
        let source = HeldVideoSource(failsFirst: false)
        let model = await makeModel(
            store: store,
            previewOutcome: .unavailable,
            videoLoader: VideoPreviewLoader(status: source.status, materializationRequester: source.requester)
        )
        model.applyState(makeLoupeVideoState(orderedIDs: [id]))

        model.openLoupe(id: id)
        await source.gate.waitForArrivals(1)
        #expect(model.loupeVideo == .preparing(id))
        #expect(PanePresentation.overlay(
            paneID: id, isDownloading: false, video: model.loupeVideo.map { ($0.id, $0.phase) }
        ) == .waiting)

        await source.gate.open()
        try await waitForVideoState(model)
    }
}

/// A cloud-only video whose download the test holds at its gate; the first attempt fails
/// as an unreachable server does when `failsFirst`.
private final class HeldVideoSource: Sendable {
    let gate = ArrivalGate()
    private let failsFirst: Bool
    private let state = Mutex((attempts: 0, arrived: false))

    init(failsFirst: Bool = true) {
        self.failsFirst = failsFirst
    }

    var attempts: Int {
        state.withLock(\.attempts)
    }

    var status: @Sendable (URL) -> FileMaterializationStatus {
        { [self] _ in state.withLock(\.arrived) ? .materialized : .dataless }
    }

    var requester: ClosureMaterializationRequester {
        ClosureMaterializationRequester(status: status) { [self] _ in
            await attempt()
        }
    }

    private func attempt() async -> MaterializationResult {
        let attempt = state.withLock { value -> Int in
            value.attempts += 1
            return value.attempts
        }
        if failsFirst, attempt == 1 {
            return MaterializationResult(outcome: .serverUnreachable, rerequestCount: 0, elapsedMs: 0)
        }
        await gate.arrive()
        state.withLock { $0.arrived = true }
        return .testMaterialized
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
