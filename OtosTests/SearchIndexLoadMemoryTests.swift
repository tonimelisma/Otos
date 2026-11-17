import Foundation
@testable import OtosKit
import Testing

/// Plan 0116 bet 2: what the search index's launch pass costs the process on a catalog of the
/// owner's shape (165,787 embeddings, 75,795 text readings of which 12,633 hold text), by the
/// kernel's own footprint (`ProcessResourceSample`). The first index builds the vector file
/// from the catalog; a second, as at the next launch, maps it and runs its first pass: the
/// vectors opened, the embeddings reconciled, the backlogs asked. The mapped vectors are clean,
/// file-backed pages, so that pass may add no more than `footprintBoundMB` to the footprint —
/// the heap the index keeps beside the file (each slot's asset and the lookup by asset) — and
/// must read no stored vector and no text reading: a query's words are matched by the
/// catalog's text index (`theLaunchPassReadsNoTextReading` guards that at every check). Then a
/// query's words are read from that index as the window reads them, each with the rows its
/// statement visited (`StatementVisits`). At the owner's size only on demand
/// (`OTOS_SCALE_TEST=1 script/check.sh --only SearchIndexLoadMemoryTests`); it writes
/// `build/search-index-memory/owner.txt`. A measurement, not a benchmark.
@Suite(.testScope, .serialized)
struct SearchIndexLoadMemoryTests {
    /// The search index's share of the 700 MB whole-app target (plan 0116).
    static let footprintBoundMB: UInt64 = 100

    /// Words a query asks the text index for: a word a sixth of the generated readings hold, a
    /// two-letter prefix most of them hold, a Japanese word one reading in eighteen holds.
    static let queries = ["open", "ca", "営業"]

    @Test(.enabled(if: StallReproductionTests.ownerSize))
    func theLaunchPassAddsLittleToTheFootprint() async throws {
        let directory = try makeTestDirectory()
        let catalog = try OwnerShapedCatalog.make(in: directory, scale: 1)
        let store = makeTestStore(location: .databaseFile(catalog.databaseURL))
        try await store.start(scansSavedLibraries: false)
        let vectorDirectory = try #require(store.searchIndexDirectory)
        let bundle = Bundle(for: CatalogWindowViewModel.self)
        // No reading session starts, so a pass's text drain ends at its first page.
        let noSession = { SearchTextReader { throw CocoaError(.featureUnsupported) } }

        let builder = PhotoSearchIndex(store: store, thumbnailDirectory: nil, vectorDirectory: vectorDirectory, bundle: bundle, textReader: noSession())
        let buildStart = ContinuousClock.now
        await builder.start()
        try await waitUntil { await builder.loadedFrom != nil }
        let builtIn = buildStart.duration(to: .now)
        #expect(await builder.loadedFrom == .rebuilt)
        await builder.shutdown()

        let visits = StatementVisits()
        try await visits.install(on: store)
        let before = ProcessResourceSample.current()
        let start = ContinuousClock.now
        let index = PhotoSearchIndex(store: store, thumbnailDirectory: nil, vectorDirectory: vectorDirectory, bundle: bundle, textReader: noSession())
        await index.start()
        try await waitUntil { await index.passesFinished >= 1 }
        let passedIn = start.duration(to: .now)
        let after = ProcessResourceSample.current()
        let passLoops = visits.take().byLoop
        let count = await index.embeddedCount
        let from = await index.loadedFrom
        await index.shutdown()

        var reads: [String] = []
        for word in Self.queries {
            let readStart = ContinuousClock.now
            let matched = try await store.windowReads.searchTextMatches([SearchTextQuery(word)])
            let ms = DiagnosticsTiming.milliseconds(since: readStart)
            let loops = visits.take().byLoop
            reads.append("""
            op=searchTextMatch word=\(word) matched=\(matched.ids.count) candidates=\(matched.candidates) ms=\(ms) \
            visited=\(loops.values.reduce(0, +)) \(loops.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            """)
        }
        await store.shutdown()
        try? FileManager.default.removeItem(at: directory)

        #expect(from == .file)
        #expect(count > 0)
        let textLoops = passLoops.filter { ["search_text", "sqlite_autoindex_search_text_1", "search_text_folded", "search_text_word"].contains($0.key) }
        #expect(textLoops.isEmpty, "the launch pass read text readings: \(textLoops)")
        let addedMB = (Int64(after.footprintBytes) - Int64(before.footprintBytes)) / 1_048_576
        #expect(addedMB <= Int64(Self.footprintBoundMB))

        func mb(_ bytes: UInt64?) -> String {
            bytes.map { "\($0 / 1_048_576)" } ?? "unknown"
        }
        let line = """
        op=searchIndexLoad embeddings=\(count) texts=\(catalog.shape.texts) buildMs=\(DiagnosticsTiming.milliseconds(builtIn)) \
        passMs=\(DiagnosticsTiming.milliseconds(passedIn)) \
        mappedMB=\(SearchVectorFormat.vectorsLength(slots: count) / 1_048_576) \
        footprintBeforeMB=\(mb(before.footprintBytes)) footprintAfterMB=\(mb(after.footprintBytes)) \
        peakBeforeMB=\(mb(before.peakFootprintBytes)) peakAfterMB=\(mb(after.peakFootprintBytes)) \
        passVisited=\(passLoops.values.reduce(0, +))
        """
        let url = SourceTree.root.appending(path: "build/search-index-memory/owner.txt")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(([line] + reads).joined(separator: "\n").utf8).write(to: url)
    }
}
