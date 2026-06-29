import Foundation
@testable import Otos
import Testing

/// The view model owns the `EnrichmentCoordinator`'s lifetime: it starts it, feeds it the
/// viewport, and (critically) starts it only after the catalog has loaded so persisted
/// assets enrich on launch even when the launch rescan is a no-op that fires no
/// notification. These tests drive that wiring with an injected fake enricher.
struct CatalogWindowViewModelEnrichmentTests {
    @MainActor
    @Test func startStartsInjectedCoordinatorAndViewportIsAccepted() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "one.jpg"), contents: "jpeg")

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10), diagnostics: nil)
        let captureDate = Date(timeIntervalSince1970: 900)
        let coordinator = EnrichmentCoordinator(
            store: store,
            enricher: completeEnricher(captureDate: captureDate),
            materialize: { _ in true },
            applyBatchSize: 1,
            diagnostics: nil
        )
        let model = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10), diagnostics: nil),
            enrichmentCoordinator: coordinator,
            diagnostics: nil,
            startsStallMonitor: false
            // startsEnrichment defaults true: start() must start the injected coordinator.
        )

        model.start()
        model.addLibrary(url: root)

        // The coordinator the view model started enriches the asset, and the enriched
        // capture date and thumbnail path surface in the projected window state.
        let state = try await waitForWindowState(model) { state in
            orderedAssets(in: state).first?.captureDate == captureDate
        }
        let asset = try #require(orderedAssets(in: state).first)
        #expect(asset.thumbnailPath == "t.heic")

        // The viewport priority hint is accepted without disrupting the enrichment result.
        model.viewportChanged([asset.id])
        #expect(asset.bestCaptureDate == captureDate)
        await coordinator.shutdown()
    }

    @MainActor
    @Test func persistedAssetsEnrichOnRelaunchAfterNoOpLaunchScan() async throws {
        // A persistent catalog whose launch rescan is a no-op (identical facts → no
        // notification) is the case start-after-load must cover: the coordinator must
        // enrich from the post-load snapshot, since no scan notification will wake it.
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "one.jpg"), contents: "jpeg")
        let databaseURL = temp.appending(path: "db/catalog.sqlite")

        // First launch: persist the cataloged asset with no enrichment (no coordinator).
        let firstStore = CatalogStore(
            location: .databaseFile(databaseURL),
            scanCadence: .milliseconds(10),
            diagnostics: nil
        )
        try await firstStore.start(scansSavedLibraries: false)
        try await firstStore.addLibrary(url: root)
        let firstScan = try await waitForCatalogStoreSnapshot(firstStore) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.count == 1
        }
        #expect(firstScan.testAssets.first?.needsEnrichment == true)
        await firstStore.shutdown()

        // Relaunch: a fresh store reloads the persisted, un-enriched asset from SQLite.
        let secondStore = CatalogStore(
            location: .databaseFile(databaseURL),
            scanCadence: .milliseconds(10),
            diagnostics: nil
        )
        let captureDate = Date(timeIntervalSince1970: 800)
        let coordinator = EnrichmentCoordinator(
            store: secondStore,
            enricher: completeEnricher(captureDate: captureDate),
            materialize: { _ in true },
            applyBatchSize: 1,
            diagnostics: nil
        )
        let model = CatalogWindowViewModel(
            catalogStore: secondStore,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10), diagnostics: nil),
            enrichmentCoordinator: coordinator,
            diagnostics: nil,
            startsStallMonitor: false
        )

        model.start()

        // The persisted asset enriches purely from the post-load snapshot.
        let state = try await waitForWindowState(model) { state in
            orderedAssets(in: state).first?.captureDate == captureDate
        }
        #expect(orderedAssets(in: state).first?.thumbnailPath == "t.heic")
        await coordinator.shutdown()
    }
}

// MARK: - Helpers

private func completeEnricher(captureDate: Date, thumbnailPath: String = "t.heic") -> MediaEnricher {
    MediaEnricher { id, _, size, mtime in
        .complete(
            EnrichmentResult(
                id: id,
                metadata: AssetMetadata(),
                captureDate: captureDate,
                thumbnailPath: thumbnailPath,
                sourceSize: size,
                sourceMTimeSeconds: mtime
            )
        )
    }
}

@MainActor
private func waitForWindowState(
    _ model: CatalogWindowViewModel,
    predicate: (CatalogWindowState) -> Bool
) async throws -> CatalogWindowState {
    for _ in 0 ..< 200 {
        let state = model.state
        if predicate(state) {
            return state
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw EnrichmentWiringTestError.timedOut
}

private func orderedAssets(in state: CatalogWindowState) -> [MediaAsset] {
    state.mediaGrid.orderedAssetIDs.compactMap { state.mediaGrid.assetsByID[$0] }
}

private enum EnrichmentWiringTestError: Error {
    case timedOut
}
