import Foundation
@testable import OtosKit
import Testing

/// Plan 0116 stage 4: what the search index's first load costs the process on a catalog of the
/// owner's shape (165,787 embeddings of 3 KB), by the kernel's own footprint
/// (`ProcessResourceSample`): the footprint before and after the load and the process's peak.
/// At the owner's size only on demand (`OTOS_SCALE_TEST=1 script/check.sh --only
/// SearchIndexLoadMemoryTests`); it writes `build/search-index-memory/owner.txt`. A measurement,
/// not a benchmark. The load it replaced (every embedding decoded into one array, then copied
/// into the matrix) took this test host past its 2 GB ceiling, so it is not measured beside it.
@Suite(.testScope, .serialized)
struct SearchIndexLoadMemoryTests {
    @Test(.enabled(if: StallReproductionTests.ownerSize))
    func thePagedLoadHoldsTheMatrixAndOnePage() async throws {
        let directory = try makeTestDirectory()
        let catalog = try OwnerShapedCatalog.make(in: directory, scale: 1)
        let store = makeTestStore(location: .databaseFile(catalog.databaseURL))
        try await store.start(scansSavedLibraries: false)
        let index = PhotoSearchIndex(store: store, thumbnailDirectory: nil, bundle: Bundle(for: CatalogWindowViewModel.self))

        let before = ProcessResourceSample.current()
        let start = ContinuousClock.now
        await index.start()
        try await waitUntil { await index.embeddedCount > 0 }
        let loadedIn = start.duration(to: .now)
        let after = ProcessResourceSample.current()
        let count = await index.embeddedCount
        await index.shutdown()
        await store.shutdown()
        #expect(count > 0)

        func mb(_ bytes: UInt64?) -> String {
            bytes.map { "\($0 / 1_048_576)" } ?? "unknown"
        }
        let line = """
        op=searchIndexLoad embeddings=\(count) loadMs=\(DiagnosticsTiming.milliseconds(loadedIn)) \
        matrixMB=\(count * SearchEmbedding.dimensions * MemoryLayout<Float>.size / 1_048_576) \
        footprintBeforeMB=\(mb(before.footprintBytes)) footprintAfterMB=\(mb(after.footprintBytes)) \
        peakBeforeMB=\(mb(before.peakFootprintBytes)) peakAfterMB=\(mb(after.peakFootprintBytes))
        """
        let url = SourceTree.root.appending(path: "build/search-index-memory/owner.txt")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(line.utf8).write(to: url)
    }
}
