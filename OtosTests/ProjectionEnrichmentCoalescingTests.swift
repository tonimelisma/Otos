import Foundation
@testable import OtosKit
import Testing

/// ARC-018: enrichment that leaves the effective ordering/scope facts
/// (`best_capture`, `best_kind`, `best_format`) unchanged is a detail-only change, and
/// the projection must refresh visible detail without re-running the full ordered-asset
/// query. Only an effective order/scope change is structural and triggers a rebuild.
@Suite(.testDirectory)
struct ProjectionEnrichmentCoalescingTests {
    private static let assetCount = 2000
    private static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func seededScanner() -> CatalogScanner {
        CatalogScanner { _, _, batchHandler in
            let files = (0 ..< Self.assetCount).map { index in
                ScannedMediaFile(
                    relativePath: MediaRelativePath(rawValue: String(format: "a%05d.jpg", index)),
                    name: String(format: "a%05d.jpg", index),
                    contentTypeIdentifier: "public.jpeg",
                    byteSize: 4,
                    createdAt: Self.baseDate.addingTimeInterval(Double(index)),
                    contentModifiedAt: Self.baseDate.addingTimeInterval(Double(index))
                )
            }
            try await batchHandler(files)
            return .mediaOnly(Set(files.map(\.relativePath)))
        }
    }

    private func seededStore() async throws -> (CatalogStore, CatalogStoreTestState) {
        let temp = try makeTestDirectory()
        let rootURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let store = CatalogStore(location: .inMemory, scanner: seededScanner())
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: rootURL)
        let state = try await waitForCatalogStoreState(store) {
            !$0.isScanning && $0.testAssets.count == Self.assetCount
        }
        return (store, state)
    }

    /// Store-level oracle: a batch that changes no effective ordering/scope column emits
    /// `.assetsDetailChanged`; one that changes `best_capture` emits `.catalogChanged`.
    @Test func enrichmentNotificationDistinguishesDetailFromStructural() async throws {
        let (store, state) = try await seededStore()
        let asset = try #require(state.testAssets.first)
        // Subscribe synchronously (the `await` only returns once the continuation is
        // registered on the Store actor) before firing the writes below, rather than
        // racing a spawned Task's own subscription against them — a spawned Task only
        // schedules its body, it does not block until the `for await` actually
        // registers, so a write completing first would fire its notification with no
        // listener yet and hang the test until timeout.
        let changes = AsyncValueRecorder<CatalogStoreChange>()
        let changeStream = await store.changeNotifications()
        let changeTask = Task {
            for await change in changeStream {
                await changes.append(change)
            }
        }
        defer { changeTask.cancel() }

        // Detail-only: enrichment matches the asset's current effective facts.
        _ = await store.applyEnrichmentBatch([
            detailEnrichment(for: asset),
        ])
        _ = await changes.waitForValues { $0.last == .assetsDetailChanged }

        // Structural: a newer capture date changes best_capture.
        _ = await store.applyEnrichmentBatch([
            detailEnrichment(
                for: asset,
                captureDate: Self.baseDate.addingTimeInterval(1_000_000)
            ),
        ])
        _ = await changes.waitForValues { $0.last == .catalogChanged }
    }

    /// End-to-end: M detail-only enrichment batches must not re-run the full order query,
    /// while a structural batch must re-run it once and reorder.
    @Test func detailOnlyEnrichmentBatchesSkipTheFullOrderQuery() async throws {
        let temp = try makeTestDirectory()
        let rootURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let store = CatalogStore(location: .inMemory, scanner: seededScanner())
        let projection = CatalogProjection(cadence: .milliseconds(25))
        let recorder = AsyncValueRecorder<CatalogWindowState>()
        let stream = await projection.states(store: store, initialDescriptor: .default)
        let recordingTask = Task {
            for await state in stream {
                await recorder.append(state)
            }
        }
        defer { recordingTask.cancel() }

        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: rootURL)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: rootURL)
        _ = await recorder.waitForValues {
            $0.last?.mediaGrid.orderedAssetIDs.count == Self.assetCount
        }
        // Wait for scan completion and for the allMedia → library scope resolution to
        // settle, so the detail-batch measurement is not polluted by structural
        // resolution-transition publications.
        _ = try await waitForCatalogStoreState(store) {
            !$0.isScanning && $0.testAssets.count == Self.assetCount
        }
        _ = await recorder.waitForValues {
            $0.last?.resolvedSidebarSelection == .library(rootPath)
        }
        try await waitForProjectionQuiescence(projection)
        let baselineOrderQueries = await projection.orderQueryCount
        let ids = try #require(await recorder.snapshot().last?.mediaGrid.orderedAssetIDs)
        let assetsByID = try await store.mediaAssets(for: ids)

        // 35 detail-only batches of 2 assets each — effective facts unchanged.
        let detailResults = try ids.prefix(70).map { id -> EnrichmentResult in
            let asset = try #require(assetsByID[id])
            return detailEnrichment(for: asset)
        }
        for batchStart in stride(from: 0, to: detailResults.count, by: 2) {
            let end = min(batchStart + 2, detailResults.count)
            _ = await store.applyEnrichmentBatch(Array(detailResults[batchStart ..< end]))
        }
        try await waitForProjectionQuiescence(projection)

        let afterDetailOrderQueries = await projection.orderQueryCount
        #expect(
            afterDetailOrderQueries - baselineOrderQueries <= 1,
            "baseline=\(baselineOrderQueries) afterDetail=\(afterDetailOrderQueries)"
        )
        // Structural batch: a newer capture date moves the oldest asset to the top and
        // must re-run the full query once.
        let reorderTarget = try #require(ids.last)
        let reorderAsset = try #require(assetsByID[reorderTarget])
        _ = await store.applyEnrichmentBatch([
            detailEnrichment(
                for: reorderAsset,
                captureDate: Self.baseDate.addingTimeInterval(10000)
            ),
        ])
        let reordered = await recorder.waitForValues {
            $0.last?.mediaGrid.orderedAssetIDs.first == reorderTarget
        }
        #expect(reordered.last?.mediaGrid.orderedAssetIDs.first == reorderTarget)
        let finalCount = await projection.orderQueryCount
        #expect(
            finalCount == afterDetailOrderQueries + 1,
            "afterDetail=\(afterDetailOrderQueries) final=\(finalCount)"
        )
    }

    private func detailEnrichment(
        for asset: MediaAsset,
        captureDate: Date? = nil
    ) -> EnrichmentResult {
        EnrichmentResult(
            id: asset.id,
            metadata: .absoluteCapture(instant: captureDate ?? asset.bestCaptureDate),
            enrichedKind: asset.bestKind,
            enrichedFormat: asset.bestFormat,
            thumbnailPath: nil,
            sourceSize: asset.byteSize,
            sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt),
            contentHash: .empty
        )
    }
}
