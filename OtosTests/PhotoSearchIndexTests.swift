import CoreGraphics
import Foundation
import ImageIO
@testable import OtosKit
import Synchronization
import Testing
import UniformTypeIdentifiers

/// ADR 0048: a search embedding is read from the stored thumbnail it names, is stale when
/// that thumbnail changes, and the index answers a query from what it has read.
// Serialized: every case builds its own index, which loads the image and text models
// (hundreds of megabytes) and Vision's readers. Run side by side they took the test host
// past its 2 GB ceiling (2,142 MB) under the full suite.
@Suite(.serialized, .testDirectory)
struct PhotoSearchIndexTests {
    private struct Catalog {
        let store: CatalogStore
        let thumbnails: URL
        let red: MediaAssetID
        let blue: MediaAssetID
        let assets: [MediaAsset]
    }

    /// A library of two stills whose stored thumbnails are a red and a blue picture, and with
    /// `broken`, a third, the newest, whose stored thumbnail does not decode.
    private func makeCatalog(broken: Bool = false) async throws -> Catalog {
        let temp = try makeTestDirectory()
        let library = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let thumbnails = temp.appending(path: "Thumbnails", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)
        try writeCatalogStoreFile(library.appending(path: "red.jpg"), contents: "jpeg red")
        try writeCatalogStoreFile(library.appending(path: "blue.jpg"), contents: "jpeg blue")
        try Self.writeJPEG(SearchModelTests.solid(red: 1, green: 0, blue: 0), to: thumbnails.appending(path: "red-thumb.jpg"))
        try Self.writeJPEG(SearchModelTests.solid(red: 0, green: 0, blue: 1), to: thumbnails.appending(path: "blue-thumb.jpg"))
        if broken {
            try writeCatalogStoreFile(library.appending(path: "broken.jpg"), contents: "jpeg broken")
            try Data("not an image".utf8).write(to: thumbnails.appending(path: "broken-thumb.jpg"))
        }
        let count = broken ? 3 : 2
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: library)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == count }
        var ids: [String: MediaAssetID] = [:]
        for asset in scanned.testAssets {
            let name = asset.id.relativePath.rawValue.replacingOccurrences(of: ".jpg", with: "")
            ids[name] = asset.id
            // The broken one is the newest (2096), so it heads every page of one.
            let captured = name == "broken" ? Date(timeIntervalSince1970: 4_000_000_000) : nil
            try await enrich(store, asset, thumbnail: "\(name)-thumb.jpg", captured: captured)
        }
        return try Catalog(
            store: store, thumbnails: thumbnails, red: #require(ids["red"]), blue: #require(ids["blue"]), assets: scanned.testAssets
        )
    }

    private func enrich(
        _ store: CatalogStore, _ asset: MediaAsset, thumbnail: String, captured: Date? = nil, preview: String? = nil
    ) async throws {
        _ = await store.applyEnrichmentBatch([EnrichmentResult(
            id: asset.id,
            metadata: AssetMetadata.absoluteCapture(instant: captured),
            enrichedKind: .image,
            thumbnailPath: thumbnail,
            sourceSize: asset.byteSize ?? 0,
            sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt),
            contentHash: nil,
            previewPath: preview
        )])
    }

    /// Counts the recognitions a reader attempts and fails the first `failing` of them with
    /// `error`.
    private final class Recognitions: Sendable {
        private let count = Mutex(0)
        private let failing: Int
        private let error: any Error

        init(failing: Int, with error: any Error) {
            self.failing = failing
            self.error = error
        }

        var attempted: Int {
            count.withLock { $0 }
        }

        func recognize(_: CGImage) throws -> [RecognizedTextLine] {
            let attempt = count.withLock {
                $0 += 1
                return $0
            }
            if attempt <= failing {
                throw error
            }
            return [RecognizedTextLine(text: "OPEN", confidence: 1)]
        }
    }

    /// Gives the red and blue stills decodable stored previews, so each is owed a text reading.
    private func givePreviews(_ catalog: Catalog) async throws {
        for (name, id) in [("red", catalog.red), ("blue", catalog.blue)] {
            let asset = try #require(catalog.assets.first { $0.id == id })
            try Self.writeJPEG(SearchModelTests.solid(red: 0.5, green: 0.5, blue: 0.5), to: catalog.thumbnails.appending(path: "\(name)-preview.jpg"))
            try await enrich(catalog.store, asset, thumbnail: "\(name)-thumb.jpg", preview: "\(name)-preview.jpg")
        }
        #expect(try await catalog.store.searchTextCandidates(limit: 10).candidates.count == 2)
    }

    /// A text reading that loses Vision's reader for its session's process ends the pass's
    /// reading with every still not read owed, and the retry after the backoff reads them in a
    /// new session: Otos reads text again without a relaunch.
    @Test func aSessionThatEndsIsReplacedAndTheRetryReadsTheRest() async throws {
        let catalog = try await makeCatalog()
        try await givePreviews(catalog)
        let lost = Recognitions(failing: 1, with: SearchReadingTests.readerLostError)
        let reader = SearchTextReader { RecognizingSession(lost.recognize) }
        let index = PhotoSearchIndex(
            store: catalog.store, thumbnailDirectory: catalog.thumbnails, bundle: Bundle(for: CatalogWindowViewModel.self),
            cutoff: .none, backoff: (.zero, .zero), textReader: reader
        )
        await index.start()
        try await waitUntil { try await catalog.store.searchTextCandidates(limit: 10).candidates.isEmpty }
        #expect(lost.attempted == 3)
        #expect(await reader.sessionsStarted == 2)
        #expect(await index.retriesScheduled > 0)
        await index.shutdown()
        await catalog.store.shutdown()
    }

    /// A recognition that fails about one picture leaves that still owed and the pass reads
    /// the rest; a retry reads it again.
    @Test func aFailedRecognitionStaysOwedAndARetryReadsIt() async throws {
        let catalog = try await makeCatalog()
        try await givePreviews(catalog)
        let once = Recognitions(failing: 1, with: NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError))
        let index = PhotoSearchIndex(
            store: catalog.store, thumbnailDirectory: catalog.thumbnails, bundle: Bundle(for: CatalogWindowViewModel.self),
            cutoff: .none, backoff: (.zero, .zero), textReader: SearchTextReader { RecognizingSession(once.recognize) }
        )
        await index.start()
        try await waitUntil { try await catalog.store.searchTextCandidates(limit: 10).candidates.isEmpty }
        #expect(once.attempted == 3)
        #expect(await index.retriesScheduled > 0)
        await index.shutdown()
        await catalog.store.shutdown()
    }

    /// The index's shutdown while a text reading is in flight ends that reading's child and
    /// returns once it is gone, and the still being read, like every still not yet read, stays
    /// owed: it is not stamped as holding no text. `cat` stands in for a child mid-reading: it
    /// keeps its output open (as descriptor 3) and never answers, and exits at its input's end.
    @Test func aReadingCutShortByShutdownStaysOwed() async throws {
        let catalog = try await makeCatalog()
        try await givePreviews(catalog)
        let started = Mutex<[Int32]>([])
        let reader = SearchTextReader {
            let child = try SearchTextChild(executable: URL(filePath: "/bin/sh"), arguments: ["-c", "exec cat 3>&1 > /dev/null"])
            started.withLock { $0.append(child.processIdentifier) }
            return child
        }
        defer {
            for pid in started.withLock({ $0 }) {
                kill(pid, SIGKILL)
            }
        }
        let index = PhotoSearchIndex(
            store: catalog.store, thumbnailDirectory: catalog.thumbnails, bundle: Bundle(for: CatalogWindowViewModel.self),
            cutoff: .none, backoff: (.zero, .zero), textReader: reader
        )
        await index.start()
        let pid = try await waitForValue { started.withLock { $0.first } }

        await index.shutdown()
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(started.withLock { $0.count } == 1)
        #expect(try await catalog.store.searchTextCandidates(limit: 10).candidates.count == 2)
        await catalog.store.shutdown()
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
        let candidates = try await store.searchEmbeddingCandidates(limit: 10).candidates
        #expect(Set(candidates.map(\.id)) == [catalog.red, catalog.blue])
        #expect(try await store.searchEmbeddingPendingCount() == 2)
        let red = try #require(candidates.first { $0.id == catalog.red })
        let vector = [Float](repeating: 0.5, count: SearchEmbedding.dimensions)

        let stale = try await store.applySearchEmbeddings([SearchEmbeddingResult(id: red.id, source: "stale", embedding: vector)])
        #expect(stale.isEmpty)
        let written = try await store.applySearchEmbeddings([SearchEmbeddingResult(id: red.id, source: red.source, embedding: vector)])
        #expect(written.map(\.id) == [catalog.red])

        #expect(try await store.searchEmbeddingCandidates(limit: 10).candidates.map(\.id) == [catalog.blue])
        #expect(try await store.searchEmbeddingPendingCount() == 1)
        let current = try await store.currentSearchEmbeddings(for: [catalog.red, catalog.blue])
        #expect(current.map(\.id) == [catalog.red])
        #expect(current.first.flatMap { SearchEmbeddingStorage.embedding(from: $0.vector) } == vector)
        #expect(try await store.currentSearchEmbeddingIDs().ids == [catalog.red])
        await store.shutdown()
    }

    /// A new thumbnail — a changed file, an edit — makes the embedding stale: the asset is
    /// owed one again and its old vector no longer counts.
    @Test func aNewThumbnailMakesTheEmbeddingStale() async throws {
        let catalog = try await makeCatalog()
        let store = catalog.store
        let red = try #require(try await store.searchEmbeddingCandidates(limit: 10).candidates.first { $0.id == catalog.red })
        _ = try await store.applySearchEmbeddings([
            SearchEmbeddingResult(id: red.id, source: red.source, embedding: [Float](repeating: 1, count: SearchEmbedding.dimensions)),
        ])
        let asset = try #require(catalog.assets.first { $0.id == catalog.red })
        try await enrich(store, asset, thumbnail: "red-thumb-2.jpg")

        #expect(try await store.currentSearchEmbeddings(for: [catalog.red]).isEmpty)
        #expect(try await Set(store.searchEmbeddingCandidates(limit: 10).candidates.map(\.id)) == [catalog.red, catalog.blue])
        await store.shutdown()
    }

    /// A thumbnail that does not decode is no reading: nothing is recorded, it stays owed, and
    /// a pass pages past it, so the newest asset failing does not stop the rest being read.
    @Test func anUndecodableThumbnailStaysOwedAndDoesNotHoldUpTheRest() async throws {
        let catalog = try await makeCatalog(broken: true)
        let store = catalog.store
        let broken = try #require(catalog.assets.first { $0.id.relativePath.rawValue == "broken.jpg" })
        let first = try await store.searchEmbeddingCandidates(limit: 1)
        #expect(first.candidates.map(\.id) == [broken.id])
        let second = try await store.searchEmbeddingCandidates(after: first.next, limit: 1)
        #expect(second.candidates.count == 1 && second.candidates.first?.id != broken.id)

        let index = PhotoSearchIndex(
            store: store, thumbnailDirectory: catalog.thumbnails, bundle: Bundle(for: CatalogWindowViewModel.self),
            pageSize: 1, cutoff: .none, backoff: (.seconds(86400), .seconds(86400))
        )
        await index.start()
        try await waitUntil { await index.retriesScheduled > 0 }
        #expect(await index.embeddedCount == 2)
        #expect(try await store.searchEmbeddingCandidates(limit: 10).candidates.map(\.id) == [broken.id])
        #expect(try await store.searchEmbeddingPendingCount() == 1)
        #expect(try await store.photoInfoOverlay(for: broken.id)?.sceneLabels == nil)
        await index.shutdown()
        await store.shutdown()
    }

    /// The index reads every thumbnail with the bundled model and answers a query from what
    /// it read: the red picture is the better match for a red one.
    @Test func aReadThatFailedIsRetriedWithoutACatalogChange() async throws {
        let catalog = try await makeCatalog()
        // A bundle whose image model points at nothing until the first pass has failed: the
        // model cannot load, as on a full disk, and the catalog does not change afterwards.
        let real = try #require(Bundle(for: CatalogWindowViewModel.self).resourceURL)
        let temp = try makeTestDirectory()
        let folder = temp.appending(path: "Resources", directoryHint: .isDirectory)
        let later = temp.appending(path: "Later", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: later, withIntermediateDirectories: true)
        let model = "SigLIP2Image.mlmodelc"
        for name in try FileManager.default.contentsOfDirectory(atPath: real.path) {
            let target = name == model ? later.appending(path: name) : real.appending(path: name)
            try FileManager.default.createSymbolicLink(at: folder.appending(path: name), withDestinationURL: target)
        }
        let bundle = try #require(Bundle(url: folder))
        let index = PhotoSearchIndex(
            store: catalog.store, thumbnailDirectory: catalog.thumbnails, bundle: bundle, cutoff: .none,
            backoff: (.zero, .zero)
        )
        let changes = await index.changes()
        await index.start()
        try await waitUntil { await index.retriesScheduled > 0 }
        #expect(await index.embeddedCount == 0)
        try FileManager.default.createSymbolicLink(at: later.appending(path: model), withDestinationURL: real.appending(path: model))
        for await _ in changes where await index.embeddedCount == 2 {
            break
        }
        #expect(await index.embeddedCount == 2)
        await index.shutdown()
    }

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

        let query = try await SearchQueryEncoder(bundle: Bundle(for: CatalogWindowViewModel.self)).englishEncoding(of: "a red picture")
        let matches = try await index.matches(query, facts: nil, among: [catalog.red, catalog.blue])
        #expect(matches.searchedCount == 2)
        let red = try #require(matches.scores?[catalog.red])
        let blue = try #require(matches.scores?[catalog.blue])
        #expect(red > blue)
        #expect(try await catalog.store.searchEmbeddingPendingCount() == 0)
        await index.shutdown()
        await catalog.store.shutdown()
    }

    /// The cut follows the best match in the scope searched, not in the library: a scope whose
    /// best photo scores below the library's best still shows it.
    @Test func theCutFollowsTheBestMatchInTheScope() async throws {
        let catalog = try await makeCatalog()
        let index = PhotoSearchIndex(
            store: catalog.store, thumbnailDirectory: catalog.thumbnails, bundle: Bundle(for: CatalogWindowViewModel.self),
            cutoff: SearchCutoff(floor: -1, margin: 0.0001)
        )
        let changes = await index.changes()
        await index.start()
        for await _ in changes where await index.embeddedCount == 2 {
            break
        }
        let query = try await SearchQueryEncoder(bundle: Bundle(for: CatalogWindowViewModel.self)).englishEncoding(of: "a red picture")
        #expect(try await index.matches(query, facts: nil, among: [catalog.red, catalog.blue]).scores.map { Set($0.keys) } == [catalog.red])
        let blueOnly = try await index.matches(query, facts: nil, among: [catalog.blue])
        #expect(blueOnly.scores.map { Set($0.keys) } == [catalog.blue])
        #expect(blueOnly.searchedCount == 1)
        await index.shutdown()
        await catalog.store.shutdown()
    }

    /// A descriptor's search narrows the published grid to what the index matches; a
    /// search that matches nothing says so; ending it shows the whole scope again.
    @Test func aSearchNarrowsThePublishedGrid() async throws {
        let catalog = try await makeCatalog()
        let bundle = Bundle(for: CatalogWindowViewModel.self)
        // Read as English: the window's path is under test, not the Mac's recogniser.
        let encoder = SearchQueryEncoder(bundle: bundle)
        let english: SearchQueryReader.Encode = { try await encoder.englishEncoding(of: $0.text) }
        // A margin this small keeps only the best photo.
        let index = PhotoSearchIndex(
            store: catalog.store, thumbnailDirectory: catalog.thumbnails, bundle: bundle,
            cutoff: SearchCutoff(floor: -1, margin: 0.0001), queries: SearchQueryReader(encode: english)
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
            cutoff: SearchCutoff(floor: 2, margin: 0), queries: SearchQueryReader(encode: english)
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

    /// A window showing "a red picture" over the red and blue library, settled: the grid shows
    /// the red one and no pass is owed.
    private struct ShownSearch {
        let catalog: Catalog
        let index: PhotoSearchIndex
        let projection: CatalogProjection
        let recorder: AsyncValueRecorder<CatalogWindowState>
        let recording: Task<Void, Never>

        func tearDown() async {
            recording.cancel()
            await index.shutdown()
            await catalog.store.shutdown()
        }
    }

    private func showRedSearch() async throws -> ShownSearch {
        let catalog = try await makeCatalog()
        let bundle = Bundle(for: CatalogWindowViewModel.self)
        let encoder = SearchQueryEncoder(bundle: bundle)
        let english: SearchQueryReader.Encode = { try await encoder.englishEncoding(of: $0.text) }
        let index = PhotoSearchIndex(
            store: catalog.store, thumbnailDirectory: catalog.thumbnails, bundle: bundle,
            cutoff: SearchCutoff(floor: -1, margin: 0.0001), queries: SearchQueryReader(encode: english)
        )
        let changes = await index.changes()
        await index.start()
        for await _ in changes where await index.embeddedCount == 2 {
            break
        }
        let projection = CatalogProjection(cadence: .milliseconds(10))
        await projection.attachSearchIndex(index)
        let stream = await projection.states(
            store: catalog.store,
            initialDescriptor: CatalogQueryDescriptor(scope: .allMedia, search: CatalogSearch(text: "a red picture"))
        )
        let recorder = AsyncValueRecorder<CatalogWindowState>()
        let recording = Task {
            for await state in stream {
                await recorder.append(state)
            }
        }
        let red = catalog.red
        _ = await recorder.waitForValues { $0.last?.mediaGrid.orderedAssetIDs == [red] }
        _ = try await waitForProjectionQuiescence(projection, recordedBy: recorder)
        return ShownSearch(catalog: catalog, index: index, projection: projection, recorder: recorder, recording: recording)
    }

    /// A lap that takes up only a fact the search does not read — a choice the user made,
    /// which reads the order again — publishes from the answer it holds: the index is not
    /// asked to match again.
    @Test func aLapWithFactsTheSearchDoesNotReadMatchesNothingAgain() async throws {
        let shown = try await showRedSearch()
        let projection = shown.projection
        let matched = await projection.searchMatchCount
        let ordered = await projection.orderQueryCount
        let revision = await shown.index.revision
        let refreshed = await shown.recorder.snapshot().last?.mediaGrid.detailRefreshGeneration ?? 0

        _ = try await shown.catalog.store.setMediaChoice(.liked, for: [shown.catalog.blue])
        let lap = await shown.recorder.waitForValues { ($0.last?.mediaGrid.detailRefreshGeneration ?? 0) > refreshed }.last
        try await waitForProjectionQuiescence(projection)

        #expect(lap?.mediaGrid.orderedAssetIDs == [shown.catalog.red])
        #expect(await projection.orderQueryCount > ordered)
        #expect(await shown.index.revision == revision)
        #expect(await projection.searchMatchCount == matched)
        await shown.tearDown()
    }

    /// A new thumbnail moves what the index holds: the red photo's embedding is stale and read
    /// again, its revision moves, and the window asks the index to match again.
    @Test func aLapAfterTheIndexMovedMatchesAgain() async throws {
        let shown = try await showRedSearch()
        let projection = shown.projection
        let matched = await projection.searchMatchCount
        let revision = await shown.index.revision
        let red = try #require(shown.catalog.assets.first { $0.id == shown.catalog.red })

        try Self.writeJPEG(
            SearchModelTests.solid(red: 0.9, green: 0, blue: 0),
            to: shown.catalog.thumbnails.appending(path: "red-thumb-2.jpg")
        )
        try await enrich(shown.catalog.store, red, thumbnail: "red-thumb-2.jpg")
        try await waitUntil { await projection.searchMatchCount > matched }

        #expect(await shown.index.revision > revision)
        let redID = shown.catalog.red
        _ = await shown.recorder.waitForValues { $0.last?.mediaGrid.orderedAssetIDs == [redID] }
        await shown.tearDown()
    }

    /// A query being read (here a wedged Translation, held at its suspension) keeps what the
    /// window shows and says it is searching, for as long as the reading lasts: a filter change
    /// delivered while it is held publishes nothing else, never the scope unsearched; ending
    /// the search publishes the whole scope at once; and the answer goes out when the reading
    /// ends.
    @Test func aQueryBeingReadKeepsWhatTheWindowShowsAndSaysSo() async throws {
        let catalog = try await makeCatalog()
        let bundle = Bundle(for: CatalogWindowViewModel.self)
        let encoder = SearchQueryEncoder(bundle: bundle)
        let (gate, open) = AsyncStream<Void>.makeStream()
        let reader = SearchQueryReader { request in
            if request.text == "järvi" {
                for await _ in gate {
                    break
                }
            }
            return try await encoder.englishEncoding(of: request.text)
        }
        let index = PhotoSearchIndex(
            store: catalog.store, thumbnailDirectory: catalog.thumbnails, bundle: bundle,
            cutoff: SearchCutoff(floor: -1, margin: 0.0001), queries: reader
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
        let red = catalog.red
        let lake = CatalogSearch(text: "järvi")
        await projection.updateQueryDescriptor(CatalogQueryDescriptor(scope: .allMedia, search: CatalogSearch(text: "a red picture")))
        let answered = await recorder.waitForValues { $0.last?.mediaGrid.orderedAssetIDs == [red] }
        #expect(answered.last?.searchPhase == .read)

        await projection.updateQueryDescriptor(CatalogQueryDescriptor(scope: .allMedia, search: lake))
        let marked = await recorder.waitForValues { $0.last?.searchPhase == .reading }
        let firstMark = marked.count - 1
        #expect(marked.last?.mediaGrid.orderedAssetIDs == [red])
        // Delivered while the reading is held at its suspension.
        await projection.updateQueryDescriptor(CatalogQueryDescriptor(
            scope: .allMedia, filter: MediaFilter(kinds: [.image]), search: lake
        ))
        await projection.updateQueryDescriptor(CatalogQueryDescriptor(scope: .allMedia, filter: MediaFilter(kinds: [.image])))
        let ended = await recorder.waitForValues { $0.last?.queryDescriptor.search == nil }
        #expect(ended.last?.mediaGrid.orderedAssetIDs.count == 2)
        #expect(ended.last?.searchPhase == nil)
        for state in ended[firstMark ..< ended.count - 1] {
            #expect(state.searchPhase == .reading)
            #expect(state.mediaGrid.orderedAssetIDs == [red])
        }

        // Searched again while the first reading is still held: the whole scope shown is kept.
        await projection.updateQueryDescriptor(CatalogQueryDescriptor(
            scope: .allMedia, filter: MediaFilter(kinds: [.image]), search: lake
        ))
        let remarked = await recorder.waitForValues { $0.last?.searchPhase == .reading && $0.last?.queryDescriptor.search == nil }
        let secondMark = remarked.count - 1
        #expect(remarked.last?.mediaGrid.orderedAssetIDs.count == 2)
        open.yield()
        open.finish()
        let read = await recorder.waitForValues { $0.last?.searchPhase == .read && $0.last?.queryDescriptor.search == lake }
        for state in read[secondMark ..< read.count - 1] {
            #expect(state.searchPhase == .reading)
        }
        await index.shutdown()
        await catalog.store.shutdown()
    }

    /// A Translation that fails until the test lets it succeed.
    private actor ReadingFailure {
        private(set) var failing = true

        func stop() {
            failing = false
        }
    }

    /// A query whose reading fails is never answered with the scope unsearched: the grid holds
    /// the empty state that says the search could not be made, and the answer replaces it when
    /// a retry reads the query.
    @Test func aQueryThatCannotBeReadSaysSoAndNeverShowsTheScopeUnsearched() async throws {
        let catalog = try await makeCatalog()
        let bundle = Bundle(for: CatalogWindowViewModel.self)
        let encoder = SearchQueryEncoder(bundle: bundle)
        let failure = ReadingFailure()
        let reader = SearchQueryReader(backoff: (.zero, .zero)) { request in
            if await failure.failing {
                throw CocoaError(.featureUnsupported)
            }
            return try await encoder.englishEncoding(of: request.text)
        }
        let index = PhotoSearchIndex(
            store: catalog.store, thumbnailDirectory: catalog.thumbnails, bundle: bundle,
            cutoff: SearchCutoff(floor: -1, margin: 0.0001), queries: reader
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
        _ = await recorder.waitForValues { $0.last?.mediaGrid.orderedAssetIDs.count == 2 }

        let red = CatalogSearch(text: "a red picture")
        await projection.updateQueryDescriptor(CatalogQueryDescriptor(scope: .allMedia, search: red))
        let failed = await recorder.waitForValues { $0.last?.searchPhase == .failed }.last
        #expect(failed?.mediaEmptyState == .searchFailed("a red picture"))
        #expect(failed?.mediaGrid.orderedAssetIDs.isEmpty == true)

        await failure.stop()
        let read = await recorder.waitForValues { $0.last?.searchPhase == .read }
        #expect(read.last?.mediaGrid.orderedAssetIDs == [catalog.red])
        for state in read where state.queryDescriptor.search == red {
            #expect(state.searchPhase != nil)
            #expect(state.searchPhase == .read || state.mediaGrid.orderedAssetIDs.isEmpty)
        }
        await index.shutdown()
        await catalog.store.shutdown()
    }

    /// A query about words puts the photo whose text holds them first; the picture alone
    /// would not find it.
    @Test func aWordQueryRanksThePhotoHoldingTheWordFirst() async throws {
        let catalog = try await makeCatalog()
        let store = catalog.store
        let blue = try #require(catalog.assets.first { $0.id == catalog.blue })
        _ = await store.applyEnrichmentBatch([EnrichmentResult(
            id: blue.id, metadata: AssetMetadata(), enrichedKind: .image, thumbnailPath: "blue-thumb.jpg",
            sourceSize: blue.byteSize ?? 0, sourceMTimeSeconds: MediaAsset.mtimeSeconds(blue.contentModifiedAt), contentHash: nil,
            previewPath: "blue-preview.heic"
        )])
        let candidate = try #require(try await store.searchTextCandidates(limit: 10).candidates.first { $0.id == catalog.blue })
        _ = try await store.applySearchTexts([SearchTextResult(
            id: blue.id, source: candidate.source, lines: [RecognizedTextLine(text: "Proof of Insurance", confidence: 1)]
        )])
        let index = PhotoSearchIndex(
            store: store, thumbnailDirectory: catalog.thumbnails, bundle: Bundle(for: CatalogWindowViewModel.self), cutoff: .none
        )
        let changes = await index.changes()
        await index.start()
        for await _ in changes where await index.embeddedCount == 2 {
            break
        }
        let query = try await SearchQueryEncoder(bundle: Bundle(for: CatalogWindowViewModel.self)).englishEncoding(of: "insurance")
        let matches = try await index.matches(query, facts: nil, among: [catalog.red, catalog.blue])
        let scores = try #require(matches.scores)
        #expect(try #require(scores[catalog.blue]) > PhotoSearchIndex.textMatchScore - 1)
        #expect(try #require(scores[catalog.blue]) > (scores[catalog.red] ?? -1))
        await index.shutdown()
        await store.shutdown()
    }

    /// ADR 0032 rule 1: a pass that reconciles the text readings changes memory only after its
    /// reads. A query answered while the pass awaits the readings memory lacks gets the answer
    /// its revision names: the one memory gave before the pass, not memory with the gone
    /// readings removed and the new ones not yet in, under the same revision.
    @Test func aQueryDuringATextReconcileAnswersAsItsRevisionSays() async throws {
        let catalog = try await makeCatalog()
        let store = catalog.store
        let red = try #require(catalog.assets.first { $0.id == catalog.red })
        let blue = try #require(catalog.assets.first { $0.id == catalog.blue })
        try await giveReading(store, blue, preview: "blue-preview.heic", text: "Proof of Insurance")
        let held = ArrivalGate()
        let index = PhotoSearchIndex(
            store: store, thumbnailDirectory: catalog.thumbnails, bundle: Bundle(for: CatalogWindowViewModel.self), cutoff: .none,
            textReader: SearchTextReader { RecognizingSession { _ in [] } },
            readTexts: { [redID = catalog.red] ids in
                // Only the pass that reads red's new reading is held.
                if ids.contains(redID) {
                    await held.arrive()
                }
                return try await store.currentSearchTexts(for: ids)
            }
        )
        let changes = await index.changes()
        await index.start()
        for await _ in changes where await index.embeddedCount == 2 {
            break
        }
        let query = try await SearchQueryEncoder(bundle: Bundle(for: CatalogWindowViewModel.self)).englishEncoding(of: "insurance")
        let scope = [catalog.red, catalog.blue]
        let before = try await waitForValue {
            let matches = try await index.matches(query, facts: nil, among: scope)
            return (matches.scores?[catalog.blue] ?? 0) > PhotoSearchIndex.textMatchScore - 1 ? matches : nil
        }

        // Blue's reading goes stale (a new preview) and red gets one: a pass removes the one
        // and reads the other.
        try await giveReading(store, red, preview: "red-preview.heic", text: "Insurance policy")
        _ = await store.applyEnrichmentBatch([EnrichmentResult(
            id: blue.id, metadata: AssetMetadata(), enrichedKind: .image, thumbnailPath: "blue-thumb.jpg",
            sourceSize: blue.byteSize ?? 0, sourceMTimeSeconds: MediaAsset.mtimeSeconds(blue.contentModifiedAt), contentHash: nil,
            previewPath: "blue-preview-2.heic"
        )])
        await held.waitForArrivals(1)

        let during = try await index.matches(query, facts: nil, among: scope)
        try #require(during.indexRevision == before.indexRevision, "nothing but the held text read is in this pass")
        #expect(during == before)

        // Blue's new preview can land after the held pass took its snapshot, under load, and
        // then its reading leaves in the pass after that one: the answer settles once both
        // changes are in, in whichever passes they came.
        await held.open()
        _ = try await waitForValue {
            let matches = try await index.matches(query, facts: nil, among: scope)
            let settled = matches.indexRevision != before.indexRevision
                && (matches.scores?[catalog.red] ?? 0) > PhotoSearchIndex.textMatchScore - 1
                && (matches.scores?[catalog.blue] ?? 0) < PhotoSearchIndex.textMatchScore - 1
            return settled ? matches : nil
        }
        await index.shutdown()
        await store.shutdown()
    }

    /// Gives `asset` a stored preview named `preview` and a text reading of it.
    private func giveReading(_ store: CatalogStore, _ asset: MediaAsset, preview: String, text: String) async throws {
        let thumbnail = asset.id.relativePath.rawValue.replacingOccurrences(of: ".jpg", with: "-thumb.jpg")
        _ = await store.applyEnrichmentBatch([EnrichmentResult(
            id: asset.id, metadata: AssetMetadata(), enrichedKind: .image, thumbnailPath: thumbnail,
            sourceSize: asset.byteSize ?? 0, sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt), contentHash: nil,
            previewPath: preview
        )])
        let candidate = try #require(try await store.searchTextCandidates(limit: 10).candidates.first { $0.id == asset.id })
        _ = try await store.applySearchTexts([SearchTextResult(
            id: asset.id, source: candidate.source, lines: [RecognizedTextLine(text: text, confidence: 1)]
        )])
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
