import Foundation
@testable import OtosKit
import Testing

/// ARC-018 / ARC-022: each Store change names the kinds of fact it touched, and the projection
/// repeats a read only when a kind it depends on was touched. An enrichment write that cannot
/// change the shown order or the filter's options publishes its detail refresh without reading
/// either; one that can — a capture date read from bytes, a stack fact — reads the order again.
@Suite(.testScope)
struct ProjectionEnrichmentCoalescingTests {
    private static let assetCount = 2000
    private static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func seededScanner() -> CatalogScanner {
        CatalogScanner { rootPath, _, batchHandler in
            // A second library's files are not copies of the first's (ADR 0054): another size
            // and a capture half a second later.
            let second = rootPath.rawValue.hasSuffix("/Family/") || rootPath.rawValue.hasSuffix("/Family")
            let files = (0 ..< Self.assetCount).map { index in
                ScannedMediaFile(
                    relativePath: MediaRelativePath(rawValue: String(format: "a%05d.jpg", index)),
                    name: String(format: "a%05d.jpg", index),
                    contentTypeIdentifier: "public.jpeg",
                    byteSize: second ? 5 : 4,
                    createdAt: Self.baseDate.addingTimeInterval(Double(index) + (second ? 0.5 : 0)),
                    contentModifiedAt: Self.baseDate.addingTimeInterval(Double(index) + (second ? 0.5 : 0))
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
        let store = makeTestStore(location: .inMemory, scanner: seededScanner())
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: rootURL)
        let state = try await waitForCatalogStoreState(store) {
            !$0.isScanning && $0.testAssets.count == Self.assetCount
        }
        return (store, state)
    }

    /// A seeded store with a projection publishing it, settled on the library's own order.
    private struct Window {
        let store: CatalogStore
        let projection: CatalogProjection
        let recorder: AsyncValueRecorder<CatalogWindowState>
        let recording: Task<Void, Never>
        let ids: [MediaAssetID]
        let assets: [MediaAssetID: MediaAsset]

        /// What the projection has read so far: its order reads and its options reads.
        var reads: (order: UInt64, options: UInt64) {
            get async {
                await (projection.orderQueryCount, projection.filterOptionsQueryCount)
            }
        }

        /// Waits for `write`'s change to be published: a newer detail refresh, settled.
        func publish(_ write: () async throws -> Void) async throws {
            let generation = await recorder.snapshot().last?.mediaGrid.detailRefreshGeneration ?? 0
            try await write()
            _ = await recorder.waitForValues { ($0.last?.mediaGrid.detailRefreshGeneration ?? 0) > generation }
            _ = try await waitForProjectionQuiescence(projection, recordedBy: recorder)
        }
    }

    private func settledWindow() async throws -> Window {
        let temp = try makeTestDirectory()
        let rootURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let store = makeTestStore(location: .inMemory, scanner: seededScanner())
        let projection = CatalogProjection(cadence: .milliseconds(25))
        let recorder = AsyncValueRecorder<CatalogWindowState>()
        let stream = await projection.states(store: store, initialDescriptor: .default)
        let recording = Task {
            for await state in stream {
                await recorder.append(state)
            }
        }
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: rootURL)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: rootURL)
        _ = try await waitForCatalogStoreState(store) {
            !$0.isScanning && $0.testAssets.count == Self.assetCount
        }
        // Settled on the library's scope, so no resolution transition reads in what follows.
        _ = await recorder.waitForValues {
            $0.last?.resolvedSidebarSelection == .library(rootPath)
                && $0.last?.mediaGrid.orderedAssetIDs.count == Self.assetCount
        }
        let settled = try await waitForProjectionQuiescence(projection, recordedBy: recorder)
        let ids = try #require(settled.last?.mediaGrid.orderedAssetIDs)
        let assets = try await store.mediaAssets(for: ids)
        return Window(store: store, projection: projection, recorder: recorder, recording: recording, ids: ids, assets: assets)
    }

    /// Store-level oracle: a batch that changes no capture date, kind, format, grouping
    /// identifier or location names its detail and what it wrote — its record and its
    /// rendering — and none of those; a digest no other file holds makes no file a copy, so it
    /// names no `.copies`; one that changes the capture date names it.
    @Test func enrichmentNotificationNamesWhatTheBatchChanged() async throws {
        let (store, state) = try await seededStore()
        let asset = try #require(state.testAssets.first)
        // Subscribe synchronously (the `await` only returns once the continuation is
        // registered on the Store actor) before firing the writes below, rather than
        // racing a spawned Task's own subscription against them.
        let changes = AsyncValueRecorder<CatalogStoreChange>()
        let changeStream = await store.changeNotifications()
        let changeTask = Task {
            for await change in changeStream {
                await changes.append(change)
            }
        }
        defer { changeTask.cancel() }

        _ = await store.applyEnrichmentBatch([detailEnrichment(for: asset)])
        let detail = await changes.waitForValues { $0.count == 1 }
        #expect(detail.last == .changed([.detail, .mediaRecord, .images]))

        _ = await store.applyEnrichmentBatch([
            detailEnrichment(for: asset, captureDate: Self.baseDate.addingTimeInterval(1_000_000)),
        ])
        let dated = await changes.waitForValues { $0.count == 2 }
        #expect(dated.last == .changed([.detail, .mediaRecord, .images, .captureDate]))
    }

    /// The stacks are held while no stack candidate's fact moves (ADR 0052): the JPEG of the
    /// seeded library has no RAW beside it, so its new capture date names no `.stacks` (the
    /// test above), while the same write to the JPEG of a RAW+JPEG pair does, and so does one
    /// to the RAW.
    @Test func aCaptureDateNamesTheStacksOnlyForAStackCandidate() async throws {
        let temp = try makeTestDirectory()
        let rootURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let pair = CatalogScanner { _, _, batchHandler in
            let files = [("DSC_1.ARW", "com.sony.arw-raw-image"), ("DSC_1.JPG", "public.jpeg")].map { name, type in
                ScannedMediaFile(
                    relativePath: MediaRelativePath(rawValue: name),
                    name: name,
                    contentTypeIdentifier: type,
                    byteSize: 4,
                    createdAt: Self.baseDate,
                    contentModifiedAt: Self.baseDate
                )
            }
            try await batchHandler(files)
            return .mediaOnly(Set(files.map(\.relativePath)))
        }
        let store = makeTestStore(location: .inMemory, scanner: pair)
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: rootURL)
        let state = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 2 }
        let changes = AsyncValueRecorder<CatalogStoreChange>()
        let changeStream = await store.changeNotifications()
        let changeTask = Task {
            for await change in changeStream {
                await changes.append(change)
            }
        }
        defer { changeTask.cancel() }

        for (index, asset) in state.testAssets.sorted(by: { $0.id.relativePath.rawValue < $1.id.relativePath.rawValue }).enumerated() {
            _ = await store.applyEnrichmentBatch([
                detailEnrichment(for: asset, captureDate: Self.baseDate.addingTimeInterval(1_000_000)),
            ])
            let seen = await changes.waitForValues { $0.count == index + 1 }
            #expect(seen.last?.facts.contains(.stacks) == true, "\(asset.id.relativePath.rawValue)")
        }
    }

    /// End-to-end: detail-only enrichment batches read neither the order nor the options; a
    /// capture date read from bytes reads the order once and reorders, and leaves the options
    /// standing, since a date offers no other type or place.
    @Test func detailOnlyEnrichmentBatchesSkipTheOrderAndOptionsReads() async throws {
        let window = try await settledWindow()
        defer { window.recording.cancel() }
        let baseline = await window.reads

        // 35 detail-only batches of 2 assets each — effective facts unchanged.
        let detailResults = try window.ids.prefix(70).map { id -> EnrichmentResult in
            try detailEnrichment(for: #require(window.assets[id]))
        }
        try await window.publish {
            for batchStart in stride(from: 0, to: detailResults.count, by: 2) {
                let end = min(batchStart + 2, detailResults.count)
                _ = await window.store.applyEnrichmentBatch(Array(detailResults[batchStart ..< end]))
            }
        }
        let afterDetail = await window.reads
        #expect(afterDetail.order == baseline.order, "baseline=\(baseline) afterDetail=\(afterDetail)")
        #expect(afterDetail.options == baseline.options, "baseline=\(baseline) afterDetail=\(afterDetail)")

        // A newer capture date moves the oldest asset to the top.
        let reorderTarget = try #require(window.ids.last)
        let reorderAsset = try #require(window.assets[reorderTarget])
        _ = await window.store.applyEnrichmentBatch([
            detailEnrichment(for: reorderAsset, captureDate: Self.baseDate.addingTimeInterval(10000)),
        ])
        let reordered = await window.recorder.waitForValues {
            $0.last?.mediaGrid.orderedAssetIDs.first == reorderTarget
        }
        #expect(reordered.last?.mediaGrid.orderedAssetIDs.first == reorderTarget)
        try await waitForProjectionQuiescence(window.projection)
        let final = await window.reads
        #expect(final.order == afterDetail.order + 1, "afterDetail=\(afterDetail) final=\(final)")
        #expect(final.options == afterDetail.options, "afterDetail=\(afterDetail) final=\(final)")
        await window.store.shutdown()
    }

    /// Copies kept together change what the Duplicates rows hold, never the library's order
    /// or its options: the change is published as a refresh with neither read again.
    @Test func aWriteThatCannotChangeTheOrderIsPublishedWithoutReadingIt() async throws {
        let window = try await settledWindow()
        defer { window.recording.cancel() }
        let before = await window.reads
        try await window.publish {
            _ = try await window.store.keepCopiesTogether([Array(window.ids.prefix(2))])
        }
        let after = await window.reads
        #expect(after == before, "before=\(before) after=\(after)")
        #expect(await window.recorder.snapshot().last?.mediaGrid.orderedAssetIDs == window.ids)
        await window.store.shutdown()
    }

    /// Identical copies share their kinds, formats and places, so which file is a copy offers
    /// no other choice: All Media, which shows one copy of each, reads its order again for a
    /// digest that makes two files copies, and never its options. On the owner's catalog 227 of
    /// the 277 changes in four minutes named copies, and each read the options again.
    @Test func aDigestThatMakesCopiesNeverReadsTheOptionsAgain() async throws {
        let window = try await settledWindow()
        defer { window.recording.cancel() }
        // A second library, so All Media is its own row and not the one library's.
        let archive = try makeTestDirectory().appending(path: "Archive", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try await window.store.addLibrary(url: archive)
        _ = try await waitForCatalogStoreState(window.store) { !$0.isScanning && $0.libraries.count == 2 }
        await window.projection.updateSidebarSelection(.allMedia)
        _ = await window.recorder.waitForValues { $0.last?.resolvedSidebarSelection == .allMedia }
        _ = try await waitForProjectionQuiescence(window.projection, recordedBy: window.recorder)
        let before = await window.reads
        let digest = try #require(ContentDigest(data: Data(repeating: 7, count: 20)))
        let results = try window.ids.prefix(2).map { id in
            try detailEnrichment(for: #require(window.assets[id]), contentHash: digest)
        }
        try await window.publish {
            _ = await window.store.applyEnrichmentBatch(results)
        }
        let after = await window.reads
        #expect(after.order == before.order + 1, "before=\(before) after=\(after)")
        #expect(after.options == before.options, "before=\(before) after=\(after)")
        await window.store.shutdown()
    }

    /// A choice is a stack fact (ADR 0052) and what the choices filter selects by, so the order
    /// is read again; it offers no other type or place, so the options are not.
    @Test func aStackFactReadsTheOrderAgain() async throws {
        let window = try await settledWindow()
        defer { window.recording.cancel() }
        let before = await window.reads
        try await window.publish {
            _ = try await window.store.setMediaChoice(.liked, for: [window.ids[0]])
        }
        let after = await window.reads
        #expect(after.order == before.order + 1, "before=\(before) after=\(after)")
        #expect(after.options == before.options, "before=\(before) after=\(after)")
        await window.store.shutdown()
    }

    /// Faces decide nothing the library's order holds, so reading them reads no order there;
    /// a person's photos are the faces given that person, so a face given the person shown
    /// reads that order again.
    @Test func facesReadTheOrderOnlyWhereTheScopeIsByPerson() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg", "b.jpg"])
        let projection = CatalogProjection(cadence: .milliseconds(25))
        let recorder = AsyncValueRecorder<CatalogWindowState>()
        let stream = await projection.states(
            store: library.store,
            initialDescriptor: CatalogQueryDescriptor(scope: .library(library.rootPath))
        )
        let recording = Task {
            for await state in stream {
                await recorder.append(state)
            }
        }
        defer { recording.cancel() }
        _ = await recorder.waitForValues { $0.last?.mediaGrid.orderedAssetIDs.count == 2 }
        let settled = try await waitForProjectionQuiescence(projection, recordedBy: recorder)

        let beforeFaces = await projection.orderQueryCount
        let refreshed = settled.last?.mediaGrid.detailRefreshGeneration ?? 0
        try await library.readFaces([library.result(for: "a.jpg", faces: [PeopleStoreTests.face(x: 0.1)])])
        _ = await recorder.waitForValues { ($0.last?.mediaGrid.detailRefreshGeneration ?? 0) > refreshed }
        try await waitForProjectionQuiescence(projection)
        #expect(await projection.orderQueryCount == beforeFaces)

        let sam = try #require(try await library.store.perform(.moveToNewPerson([], name: "Sam")).person)
        await projection.updateSidebarSelection(.person(sam))
        try await waitForProjectionQuiescence(projection)
        let beforeAssignment = await projection.orderQueryCount
        // The user's own act, not a guess: `PeopleAssignment` runs its own passes after every
        // faces write and decides guesses itself, so a guess written here raced its next pass,
        // which could give the face to someone else and leave Sam's photos empty — the hang
        // seen under a loaded parallel run. A user's act is never Otos's to decide again.
        _ = try await library.store.perform(.move([FaceID(asset: library.id("a.jpg"), index: 0)], to: sam))
        let shown = await recorder.waitForValues { $0.last?.mediaGrid.orderedAssetIDs == [library.id("a.jpg")] }
        #expect(shown.last?.mediaGrid.orderedAssetIDs == [library.id("a.jpg")])
        #expect(await projection.orderQueryCount > beforeAssignment)
        await library.store.shutdown()
    }

    /// Two libraries published under All Media, settled, then one library opened and
    /// settled: All Media's answers are held while the user is in the library.
    private func windowInALibraryAfterAllMedia() async throws -> (Window, library: LibraryRootPath) {
        let temp = try makeTestDirectory()
        let firstURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let secondURL = temp.appending(path: "Family", directoryHint: .isDirectory)
        for url in [firstURL, secondURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let store = makeTestStore(location: .inMemory, scanner: seededScanner())
        let projection = CatalogProjection(cadence: .milliseconds(25))
        let recorder = AsyncValueRecorder<CatalogWindowState>()
        let stream = await projection.states(store: store, initialDescriptor: .default)
        let recording = Task {
            for await state in stream {
                await recorder.append(state)
            }
        }
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: firstURL)
        try await store.addLibrary(url: secondURL)
        _ = try await waitForCatalogStoreState(store) {
            !$0.isScanning && $0.testAssets.count == 2 * Self.assetCount
        }
        // With one library All Media resolved to it, and the projection kept that resolution;
        // with two, the user can open All Media.
        try await waitForProjectionQuiescence(projection)
        await projection.updateSidebarSelection(.allMedia)
        _ = await recorder.waitForValues { $0.last?.resolvedSidebarSelection == .allMedia }
        let allMedia = try await waitForProjectionQuiescence(projection, recordedBy: recorder)
        let ids = try #require(allMedia.last?.mediaGrid.orderedAssetIDs)
        try #require(ids.count == 2 * Self.assetCount, "All Media shows \(ids.count)")
        let assets = try await store.mediaAssets(for: ids)
        let libraryPath = try CatalogPath.normalizedDirectoryPath(for: firstURL)
        let library = SidebarSelection.library(libraryPath)
        await projection.updateSidebarSelection(library)
        _ = await recorder.waitForValues { $0.last?.resolvedSidebarSelection == library }
        let shown = try await waitForProjectionQuiescence(projection, recordedBy: recorder).last?.mediaGrid.orderedAssetIDs.count
        try #require(shown == Self.assetCount, "the library shows \(String(describing: shown))")
        let window = Window(store: store, projection: projection, recorder: recorder, recording: recording, ids: ids, assets: assets)
        return (window, libraryPath)
    }

    /// ARC-018: All Media's order is held while the user is in another scope that reads its
    /// own, so returning to it with no fact moved reads nothing and shows what it showed.
    @Test func aReturnToAllMediaWithNoFactMovedReadsNothing() async throws {
        let (window, _) = try await windowInALibraryAfterAllMedia()
        defer { window.recording.cancel() }
        let before = await window.reads
        let published = await window.recorder.count()

        await window.projection.updateSidebarSelection(.allMedia)
        _ = await window.recorder.waitForValues { $0.last?.resolvedSidebarSelection == .allMedia }
        let recorded = try await waitForProjectionQuiescence(window.projection, recordedBy: window.recorder)

        // Every publication of the return shows the held order; only the filter's options,
        // held for one row and read after the window publishes, are read again. The return
        // starts at its first All Media publication: the Duplicates and People owners can
        // publish the library's window again after it was counted.
        let returns = recorded.dropFirst(published)
            .drop { $0.resolvedSidebarSelection != .allMedia }
        #expect(!returns.isEmpty && returns.allSatisfy { $0.mediaGrid.orderedAssetIDs == window.ids })
        let after = await window.reads
        #expect(after.order == before.order, "before=\(before) after=\(after)")
        await window.store.shutdown()
    }

    /// ARC-018: a return to a scope whose facts moved while the user was elsewhere paints what
    /// it last showed at once, without a read, and the pass after it reads the moved order
    /// again and republishes: a capture date moved in the library reorders All Media only in
    /// the second publication.
    @Test func aReturnToAScopeWhoseFactsMovedPaintsWhatItHeldThenReadsAgain() async throws {
        let (window, library) = try await windowInALibraryAfterAllMedia()
        defer { window.recording.cancel() }
        let oldest = try #require(window.ids.last { $0.libraryRootPath == library })
        let asset = try #require(window.assets[oldest])
        try await window.publish {
            _ = await window.store.applyEnrichmentBatch([
                detailEnrichment(for: asset, captureDate: Self.baseDate.addingTimeInterval(10000)),
            ])
        }
        let before = await window.reads
        let published = await window.recorder.count()

        await window.projection.updateSidebarSelection(.allMedia)
        _ = await window.recorder.waitForValues { $0.last?.resolvedSidebarSelection == .allMedia }
        let recorded = try await waitForProjectionQuiescence(window.projection, recordedBy: window.recorder)
        // The Duplicates and People owners publish on their own schedule, so the library's
        // window can be published again after it was counted: the return starts at its first
        // All Media publication.
        let returns = recorded.dropFirst(published)
            .drop { $0.resolvedSidebarSelection != .allMedia }

        #expect(returns.first?.resolvedSidebarSelection == .allMedia)
        #expect(returns.first?.mediaGrid.orderedAssetIDs == window.ids, "the first paint is the held order")
        #expect(returns.last?.mediaGrid.orderedAssetIDs.first == oldest, "the next pass read the moved date")
        let after = await window.reads
        #expect(after.order == before.order + 1, "before=\(before) after=\(after)")
        await window.store.shutdown()
    }

    private func detailEnrichment(
        for asset: MediaAsset,
        captureDate: Date? = nil,
        contentHash: ContentDigest = .empty
    ) -> EnrichmentResult {
        EnrichmentResult(
            id: asset.id,
            metadata: .absoluteCapture(instant: captureDate ?? asset.captureLocalTime?.presentationDate()),
            enrichedKind: asset.bestKind,
            enrichedFormat: asset.bestFormat,
            thumbnailPath: nil,
            sourceSize: asset.byteSize,
            sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt),
            contentHash: contentHash
        )
    }
}
