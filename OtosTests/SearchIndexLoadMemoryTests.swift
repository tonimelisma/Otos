import Foundation
@testable import OtosKit
import Testing

/// Plan 0116 bet 2: what the search index's memory costs the process on a catalog of the
/// owner's shape (165,787 embeddings), by the kernel's own footprint (`ProcessResourceSample`).
/// The first index builds the vector file from the catalog; a second, as at the next launch,
/// maps it. The mapped vectors are clean, file-backed pages, so the second load may add no more
/// than `footprintBoundMB` to the footprint — the heap the index keeps beside the file (each
/// slot's asset and the lookup by asset) — and must read no stored vector. At the owner's size
/// only on demand (`OTOS_SCALE_TEST=1 script/check.sh --only SearchIndexLoadMemoryTests`); it
/// writes `build/search-index-memory/owner.txt`. A measurement, not a benchmark.
@Suite(.testScope, .serialized)
struct SearchIndexLoadMemoryTests {
    /// The search index's share of the 700 MB whole-app target (plan 0116).
    static let footprintBoundMB: UInt64 = 100

    @Test(.enabled(if: StallReproductionTests.ownerSize))
    func aMappedFileAddsLittleToTheFootprint() async throws {
        let directory = try makeTestDirectory()
        let catalog = try OwnerShapedCatalog.make(in: directory, scale: 1)
        let store = makeTestStore(location: .databaseFile(catalog.databaseURL))
        try await store.start(scansSavedLibraries: false)
        let vectorDirectory = try #require(store.searchIndexDirectory)
        let bundle = Bundle(for: CatalogWindowViewModel.self)

        let builder = PhotoSearchIndex(store: store, thumbnailDirectory: nil, vectorDirectory: vectorDirectory, bundle: bundle)
        let buildStart = ContinuousClock.now
        await builder.start()
        try await waitUntil { await builder.loadedFrom != nil }
        let builtIn = buildStart.duration(to: .now)
        #expect(await builder.loadedFrom == .rebuilt)
        await builder.shutdown()

        let before = ProcessResourceSample.current()
        let start = ContinuousClock.now
        let index = PhotoSearchIndex(store: store, thumbnailDirectory: nil, vectorDirectory: vectorDirectory, bundle: bundle)
        await index.start()
        try await waitUntil { await index.loadedFrom != nil }
        let loadedIn = start.duration(to: .now)
        let after = ProcessResourceSample.current()
        let count = await index.embeddedCount
        let from = await index.loadedFrom
        await index.shutdown()
        await store.shutdown()
        #expect(from == .file)
        #expect(count > 0)
        let addedMB = (Int64(after.footprintBytes) - Int64(before.footprintBytes)) / 1_048_576
        #expect(addedMB <= Int64(Self.footprintBoundMB))

        func mb(_ bytes: UInt64?) -> String {
            bytes.map { "\($0 / 1_048_576)" } ?? "unknown"
        }
        let line = """
        op=searchIndexLoad embeddings=\(count) buildMs=\(DiagnosticsTiming.milliseconds(builtIn)) \
        loadMs=\(DiagnosticsTiming.milliseconds(loadedIn)) \
        mappedMB=\(SearchVectorFormat.vectorsLength(slots: count) / 1_048_576) \
        footprintBeforeMB=\(mb(before.footprintBytes)) footprintAfterMB=\(mb(after.footprintBytes)) \
        peakBeforeMB=\(mb(before.peakFootprintBytes)) peakAfterMB=\(mb(after.peakFootprintBytes))
        """
        let url = SourceTree.root.appending(path: "build/search-index-memory/owner.txt")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(line.utf8).write(to: url)
    }
}
