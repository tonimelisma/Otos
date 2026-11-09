import CoreGraphics
import Foundation
import ImageIO
@testable import OtosKit
import Testing
import UniformTypeIdentifiers

/// ADR 0048: a search embedding is read from the stored thumbnail it names, is stale when
/// that thumbnail changes, and the index answers a query from what it has read.
@Suite(.testDirectory)
struct PhotoSearchIndexTests {
    private struct Catalog {
        let store: CatalogStore
        let thumbnails: URL
        let red: MediaAssetID
        let blue: MediaAssetID
        let assets: [MediaAsset]
    }

    /// A library of two stills whose stored thumbnails are a red and a blue picture.
    private func makeCatalog() async throws -> Catalog {
        let temp = try makeTestDirectory()
        let library = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let thumbnails = temp.appending(path: "Thumbnails", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)
        try writeCatalogStoreFile(library.appending(path: "red.jpg"), contents: "jpeg red")
        try writeCatalogStoreFile(library.appending(path: "blue.jpg"), contents: "jpeg blue")
        try Self.writeJPEG(SearchModelTests.solid(red: 1, green: 0, blue: 0), to: thumbnails.appending(path: "red-thumb.jpg"))
        try Self.writeJPEG(SearchModelTests.solid(red: 0, green: 0, blue: 1), to: thumbnails.appending(path: "blue-thumb.jpg"))
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: library)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 2 }
        var ids: [String: MediaAssetID] = [:]
        for asset in scanned.testAssets {
            let name = asset.id.relativePath.rawValue.replacingOccurrences(of: ".jpg", with: "")
            ids[name] = asset.id
            try await enrich(store, asset, thumbnail: "\(name)-thumb.jpg")
        }
        return try Catalog(
            store: store, thumbnails: thumbnails, red: #require(ids["red"]), blue: #require(ids["blue"]), assets: scanned.testAssets
        )
    }

    private func enrich(_ store: CatalogStore, _ asset: MediaAsset, thumbnail: String) async throws {
        _ = await store.applyEnrichmentBatch([EnrichmentResult(
            id: asset.id,
            metadata: AssetMetadata(),
            enrichedKind: .image,
            thumbnailPath: thumbnail,
            sourceSize: asset.byteSize ?? 0,
            sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt),
            contentHash: nil
        )])
    }

    static func writeJPEG(_ image: CGImage, to url: URL) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// An embedding is written only for the thumbnail it was read from; once written the asset
    /// is no longer owed one and is current.
    @Test func anEmbeddingIsWrittenOnlyForTheThumbnailItWasReadFrom() async throws {
        let catalog = try await makeCatalog()
        let store = catalog.store
        let candidates = try await store.searchEmbeddingCandidates(limit: 10)
        #expect(Set(candidates.map(\.id)) == [catalog.red, catalog.blue])
        #expect(try await store.searchEmbeddingPendingCount() == 2)
        let red = try #require(candidates.first { $0.id == catalog.red })
        let vector = [Float](repeating: 0.5, count: SearchEmbedding.dimensions)

        let stale = try await store.applySearchEmbeddings([SearchEmbeddingResult(id: red.id, source: "stale", embedding: vector)])
        #expect(stale.isEmpty)
        let written = try await store.applySearchEmbeddings([SearchEmbeddingResult(id: red.id, source: red.source, embedding: vector)])
        #expect(written.map(\.id) == [catalog.red])

        #expect(try await store.searchEmbeddingCandidates(limit: 10).map(\.id) == [catalog.blue])
        #expect(try await store.searchEmbeddingPendingCount() == 1)
        let current = try await store.currentSearchEmbeddings()
        #expect(current.map(\.id) == [catalog.red])
        #expect(current.first?.embedding == vector)
        #expect(try await store.currentSearchEmbeddingIDs() == [catalog.red])
        await store.shutdown()
    }

    /// A new thumbnail — a changed file, an edit — makes the embedding stale: the asset is
    /// owed one again and its old vector no longer counts.
    @Test func aNewThumbnailMakesTheEmbeddingStale() async throws {
        let catalog = try await makeCatalog()
        let store = catalog.store
        let red = try #require(try await store.searchEmbeddingCandidates(limit: 10).first { $0.id == catalog.red })
        _ = try await store.applySearchEmbeddings([
            SearchEmbeddingResult(id: red.id, source: red.source, embedding: [Float](repeating: 1, count: SearchEmbedding.dimensions)),
        ])
        let asset = try #require(catalog.assets.first { $0.id == catalog.red })
        try await enrich(store, asset, thumbnail: "red-thumb-2.jpg")

        #expect(try await store.currentSearchEmbeddings().isEmpty)
        #expect(try await Set(store.searchEmbeddingCandidates(limit: 10).map(\.id)) == [catalog.red, catalog.blue])
        await store.shutdown()
    }

    /// A thumbnail that does not decode is recorded with no embedding: it is not offered
    /// again, and it matches nothing.
    @Test func anUndecodableThumbnailIsNotOfferedAgain() async throws {
        let catalog = try await makeCatalog()
        let store = catalog.store
        let red = try #require(try await store.searchEmbeddingCandidates(limit: 10).first { $0.id == catalog.red })
        _ = try await store.applySearchEmbeddings([SearchEmbeddingResult(id: red.id, source: red.source, embedding: nil)])

        #expect(try await store.searchEmbeddingCandidates(limit: 10).map(\.id) == [catalog.blue])
        #expect(try await store.currentSearchEmbeddings().isEmpty)
        await store.shutdown()
    }

    /// The index reads every thumbnail with the bundled model and answers a query from what
    /// it read: the red picture is the better match for a red one.
    @Test func theIndexEmbedsThumbnailsAndRanksAQuery() async throws {
        let catalog = try await makeCatalog()
        let index = PhotoSearchIndex(
            store: catalog.store,
            thumbnailDirectory: catalog.thumbnails,
            bundle: Bundle(for: CatalogWindowViewModel.self),
            cutoff: .none
        )
        let changes = await index.changes()
        await index.start()
        for await _ in changes where await index.embeddedCount == 2 {
            break
        }

        let matches = try await index.matches(for: "a red picture")
        #expect(matches.searchedCount == 2)
        #expect(matches.encoding.reading == .english)
        let red = try #require(matches.scores[catalog.red])
        let blue = try #require(matches.scores[catalog.blue])
        #expect(red > blue)
        #expect(try await catalog.store.searchEmbeddingPendingCount() == 0)
        await index.shutdown()
        await catalog.store.shutdown()
    }

    /// A descriptor's search narrows the published grid to what the index matches; a
    /// search that matches nothing says so; ending it shows the whole scope again.
    @Test func aSearchNarrowsThePublishedGrid() async throws {
        let catalog = try await makeCatalog()
        let bundle = Bundle(for: CatalogWindowViewModel.self)
        // A margin this small keeps only the best photo.
        let index = PhotoSearchIndex(
            store: catalog.store, thumbnailDirectory: catalog.thumbnails, bundle: bundle,
            cutoff: SearchCutoff(floor: -1, margin: 0.0001)
        )
        let changes = await index.changes()
        await index.start()
        for await _ in changes where await index.embeddedCount == 2 {
            break
        }
        let projection = CatalogProjection(cadence: .milliseconds(10))
        await projection.attachSearchIndex(index)
        let stream = await projection.states(store: catalog.store, initialDescriptor: .default)
        let recorder = AsyncValueRecorder<CatalogWindowState>()
        let recording = Task {
            for await state in stream {
                await recorder.append(state)
            }
        }
        defer { recording.cancel() }
        let red = catalog.red, blueID = catalog.blue
        _ = await recorder.waitForValues { $0.last?.mediaGrid.orderedAssetIDs.count == 2 }

        await projection.updateQueryDescriptor(CatalogQueryDescriptor(scope: .allMedia, search: CatalogSearch(text: "a red picture")))
        _ = await recorder.waitForValues { $0.last?.mediaGrid.orderedAssetIDs == [red] }
        await projection.updateQueryDescriptor(CatalogQueryDescriptor(scope: .allMedia, search: CatalogSearch(text: "a blue picture")))
        let blue = await recorder.waitForValues { $0.last?.mediaGrid.orderedAssetIDs == [blueID] }.last
        #expect(blue?.mediaGrid.dayBuckets.isEmpty == true)

        let nothing = PhotoSearchIndex(
            store: catalog.store, thumbnailDirectory: catalog.thumbnails, bundle: bundle,
            cutoff: SearchCutoff(floor: 2, margin: 0)
        )
        let nothingChanges = await nothing.changes()
        await nothing.start()
        for await _ in nothingChanges where await nothing.embeddedCount == 2 {
            break
        }
        await projection.attachSearchIndex(nothing)
        await projection.updateQueryDescriptor(CatalogQueryDescriptor(scope: .allMedia, search: CatalogSearch(text: "a dog")))
        let empty = await recorder.waitForValues {
            $0.last?.mediaEmptyState == .noSearchResults("a dog", stillReading: 0)
        }.last
        #expect(empty?.mediaGrid.orderedAssetIDs.isEmpty == true)

        await projection.updateQueryDescriptor(CatalogQueryDescriptor(scope: .allMedia))
        _ = await recorder.waitForValues { $0.last?.mediaGrid.orderedAssetIDs.count == 2 && $0.last?.queryDescriptor.search == nil }
        await index.shutdown()
        await nothing.shutdown()
        await catalog.store.shutdown()
    }

    /// Relevance order is best match first, ties in the scope's order, and ungrouped; the
    /// scope's own order keeps its day grouping. Unmatched items leave either way.
    @Test func searchedScopesKeepOrDropTheirOrder() {
        let ids = (0 ..< 4).map { MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/L"), relativePath: MediaRelativePath(rawValue: "\($0).jpg")) }
        let days: [Date?] = [Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 0), nil, Date(timeIntervalSince1970: 86400)]
        let scores: [MediaAssetID: Float] = [ids[0]: 0.1, ids[2]: 0.3, ids[3]: 0.1]

        let relevance = CatalogWindowPolicy.searched(ids: ids, dayBuckets: days, coordinates: [], scores: scores, order: .relevance)
        #expect(relevance.ids == [ids[2], ids[0], ids[3]])
        #expect(relevance.dayBuckets.isEmpty)

        let sorted = CatalogWindowPolicy.searched(ids: ids, dayBuckets: days, coordinates: [], scores: scores, order: .sort)
        #expect(sorted.ids == [ids[0], ids[2], ids[3]])
        #expect(sorted.dayBuckets == [days[0], days[2], days[3]])
    }

    /// The cut follows the best match, and never falls below the floor.
    @Test func theCutoffFollowsTheBestMatch() {
        let cutoff = SearchCutoff(floor: 0.08, margin: 0.04)
        #expect(cutoff.threshold(best: 0.20) == 0.16)
        #expect(cutoff.threshold(best: 0.10) == 0.08)
    }

    @Test func blankTextIsNoSearch() {
        #expect(CatalogSearch(text: "  \n ") == nil)
        #expect(CatalogSearch(text: "  dog ")?.text == "dog")
    }
}
