import Foundation
@testable import OtosKit
import Testing

/// `ProjectionEnrichmentCoalescingTests` proves the detail/structural
/// skip mechanism at n=2,000, in memory, with 4-byte fixtures. It cannot prove the
/// mechanism holds under real WAL pressure — the field non-linearity that motivates
/// the detail-only path (the same query ranging 62 ms -> 7,034 ms) is driven by write
/// pressure an in-memory database never reproduces. This test uses an on-disk database
/// and real enrichment writes at ~25k assets, gated behind `OTOS_SCALE_TEST` because it
/// is materially slower than the default suite (real disk I/O, not memory).
///
/// This test intentionally does **not** assert a `SidebarSelectionToPaint` budget. Plan
/// 0065's own ordering note says that budget must come from Stage 3 field evidence,
/// which is blocked on this machine (OneDrive is not serving reads — verified directly,
/// not inferred from process presence). Inventing a number here would violate that
/// instruction; only `orderQueryCount` — a mechanism assertion, not a performance
/// budget — is checked.
@Suite(.testScope)
struct ProjectionEnrichmentScaleTests {
    private static let assetCount = 25000
    private static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func seededScanner() -> CatalogScanner {
        CatalogScanner { _, _, batchHandler in
            let files = (0 ..< Self.assetCount).map { index in
                ScannedMediaFile(
                    relativePath: MediaRelativePath(rawValue: String(format: "a%06d.jpg", index)),
                    name: String(format: "a%06d.jpg", index),
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

    private func detailEnrichment(for asset: MediaAsset) -> EnrichmentResult {
        EnrichmentResult(
            id: asset.id,
            metadata: .absoluteCapture(instant: asset.captureLocalTime?.presentationDate()),
            enrichedKind: asset.bestKind,
            enrichedFormat: asset.bestFormat,
            thumbnailPath: nil,
            sourceSize: asset.byteSize,
            sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt),
            contentHash: .empty
        )
    }

    /// Xcode's scheme sets this key unconditionally to satisfy `$(OTOS_SCALE_TEST)`
    /// substitution (see Otos.xcscheme's LaunchAction EnvironmentVariables) — it
    /// resolves to an *empty* string, not an absent key, whenever the build-setting
    /// override isn't passed. Check for the specific value, matching the
    /// `OTOS_UI_VERBOSE` convention (`Instrumentation.swift`), not mere presence.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OTOS_SCALE_TEST"] == "1"))
    func detailOnlyEnrichmentStormOnDiskKeepsOrderQueriesBounded() async throws {
        let temp = try makeTestDirectory()
        let rootURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let databaseURL = temp.appending(path: "db/catalog.sqlite")

        let store = makeTestStore(location: .databaseFile(databaseURL), scanner: seededScanner())
        let projection = CatalogProjection(volumeCapacity: ampleVolumeCapacity, cadence: .milliseconds(25))
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
        _ = await recorder.waitForValues { $0.last?.mediaGrid.orderedAssetIDs.count == Self.assetCount }
        _ = try await waitForCatalogStoreState(store) {
            !$0.isScanning && $0.testAssets.count == Self.assetCount
        }
        _ = await recorder.waitForValues { $0.last?.resolvedSidebarSelection == .library(rootPath) }
        let settled = try await waitForProjectionQuiescence(projection, recordedBy: recorder)

        let baselineOrderQueries = await projection.orderQueryCount
        let ids = try #require(settled.last?.mediaGrid.orderedAssetIDs)
        let assetsByID = try await store.windowReads.mediaAssets(for: ids)

        // A storm of small detail-only batches — effective ordering/scope facts
        // unchanged — against a real on-disk database under WAL write pressure.
        let stormBatchCount = 200
        let detailResults = try ids.prefix(stormBatchCount * 2).map { id -> EnrichmentResult in
            let asset = try #require(assetsByID[id])
            return detailEnrichment(for: asset)
        }
        for batchStart in stride(from: 0, to: detailResults.count, by: 2) {
            let end = min(batchStart + 2, detailResults.count)
            _ = await store.applyEnrichmentBatch(Array(detailResults[batchStart ..< end]))
        }
        try await waitForProjectionQuiescence(projection)

        let afterStormOrderQueries = await projection.orderQueryCount
        #expect(
            afterStormOrderQueries - baselineOrderQueries <= 1,
            "baseline=\(baselineOrderQueries) afterStorm=\(afterStormOrderQueries) storm=\(stormBatchCount) detail-only batches must not force a full re-sort"
        )

        // One structural batch must still re-run the full order query exactly once.
        let reorderTarget = try #require(ids.last)
        let reorderAsset = try #require(assetsByID[reorderTarget])
        _ = await store.applyEnrichmentBatch([
            EnrichmentResult(
                id: reorderAsset.id,
                metadata: .absoluteCapture(instant: Self.baseDate.addingTimeInterval(1_000_000)),
                enrichedKind: reorderAsset.bestKind,
                enrichedFormat: reorderAsset.bestFormat,
                thumbnailPath: nil,
                sourceSize: reorderAsset.byteSize,
                sourceMTimeSeconds: MediaAsset.mtimeSeconds(reorderAsset.contentModifiedAt),
                contentHash: .empty
            ),
        ])
        _ = await recorder.waitForValues { $0.last?.mediaGrid.orderedAssetIDs.first == reorderTarget }
        try await waitForProjectionQuiescence(projection)
        let finalOrderQueries = await projection.orderQueryCount
        #expect(
            finalOrderQueries == afterStormOrderQueries + 1,
            "afterStorm=\(afterStormOrderQueries) final=\(finalOrderQueries)"
        )
    }
}
