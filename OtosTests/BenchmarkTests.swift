import AppKit
import CoreImage
import CryptoKit
import Foundation
import GRDB
@testable import OtosKit
import Testing

/// The benchmark cases (ADR 0043). Run with `script/bench.sh run`; skipped otherwise.
///
/// Each case is a path a user waits for, or one that runs in the background at a size where
/// its cost shows. Every case also checks that it did its work, so a broken fixture fails
/// rather than measuring nothing.
@Suite(.serialized, .testScope, .enabled(if: Benchmark.isEnabled))
struct BenchmarkTests {
    @Test func catalogCases() async throws {
        let directory = try makeTestDirectory()
        let library = try await BenchmarkLibrary.make(in: directory)
        let store = library.store
        let libraries = library.libraries

        // The window's publication of All Media: the order query and the window state.
        let projection = CatalogProjection()
        let request = CatalogQueryRequest(descriptor: .default, generation: 0)
        try await Benchmark.measure("projection.windowState.allMedia") {
            guard case let .built(state, _, _, _) = try await projection.buildWindowState(
                store: store,
                libraries: libraries,
                request: request,
                reads: .none,
                revisions: CatalogFactRevisions()
            ) else {
                Issue.record("nothing is searched, so nothing waits on a reading")
                return
            }
            #expect(state.mediaGrid.orderedAssetIDs.count == BenchmarkLibrary.stillCount)
        }

        // The pass an enrichment write that moved no fact the window reads costs: the order,
        // the filter's options and the collapse answered from the last pass (ADR 0005).
        guard case let .built(_, _, firstReads, owed?) = try await projection.buildWindowState(
            store: store,
            libraries: libraries,
            request: request,
            reads: .none,
            revisions: CatalogFactRevisions()
        ) else {
            Issue.record("nothing is searched, and a first build owes its options")
            return
        }
        // The options a published window owes, read after it publishes (`OwedFilterOptions`).
        var options = CatalogFilterOptions.empty
        try await Benchmark.measure("projection.filterOptions.allMedia") {
            options = try await projection.readFilterOptions(owed, store: store).options
            #expect(!options.formatsByKind.isEmpty)
        }
        var lastReads = firstReads
        lastReads.filterOptions = CatalogProjectionReads.FilterOptions(
            row: owed.row,
            availableLibraryPaths: owed.availableLibraryPaths,
            placeNameLanguages: owed.placeNameLanguages,
            revisions: owed.revisions,
            answer: options
        )
        try await Benchmark.measure("projection.windowState.allMedia.heldReads") {
            guard case let .built(state, metrics, _, _) = try await projection.buildWindowState(
                store: store,
                libraries: libraries,
                request: request,
                reads: lastReads,
                revisions: CatalogFactRevisions()
            ) else {
                Issue.record("nothing is searched, so nothing waits on a reading")
                return
            }
            #expect(metrics.reuse == CatalogProjectionReuse(
                order: true, filterOptions: true, collapse: true, importBatches: true, placeNameLanguages: true
            ))
            #expect(state.mediaGrid.orderedAssetIDs.count == BenchmarkLibrary.stillCount)
        }

        // The first paint of a return to All Media after a capture date moved elsewhere: the
        // held order, options and collapse, answered from although the date moved since; the
        // pass after it reads the order again (`projection.windowState.allMedia`).
        var movedSince = CatalogFactRevisions()
        movedSince.record([.captureDate, .stacks])
        try await Benchmark.measure("projection.windowState.allMedia.returnHeld") {
            guard case let .built(state, metrics, _, _) = try await projection.buildWindowState(
                store: store,
                libraries: libraries,
                request: request,
                reads: lastReads,
                revisions: movedSince,
                answerFromHeld: true
            ) else {
                Issue.record("nothing is searched, so nothing waits on a reading")
                return
            }
            #expect(metrics.reuse.held && metrics.reuse.order && metrics.reuse.collapse)
            #expect(state.mediaGrid.orderedAssetIDs.count == BenchmarkLibrary.stillCount)
        }

        // Opening an import batch: a few hundred rows of the catalog, read by the batch's key
        // and sorted (`docs/research/2026-11-15-keyed-scope-query-plans.md`). The batch is
        // stamped on the catalog file the way an import stamps it.
        let batch = ImportBatchID(unixMilliseconds: 1_800_000_000_000)
        let batchSize = 210
        let stamp = try DatabaseQueue(path: directory.appending(path: "db/catalog.sqlite").path(percentEncoded: false))
        try await stamp.write { db in
            try db.execute(
                sql: """
                UPDATE media_asset SET import_batch_unix_ms = ?
                WHERE rowid IN (SELECT rowid FROM media_asset ORDER BY relative_path LIMIT ?)
                """,
                arguments: [batch.unixMilliseconds, batchSize]
            )
        }
        try stamp.close()
        let batchRequest = CatalogQueryRequest(descriptor: CatalogQueryDescriptor(scope: .importBatch(batch)), generation: 0)
        try await Benchmark.measure("projection.windowState.importBatch") {
            guard case let .built(state, _, _, _) = try await projection.buildWindowState(
                store: store,
                libraries: libraries,
                request: batchRequest,
                reads: .none,
                revisions: CatalogFactRevisions()
            ) else {
                Issue.record("nothing is searched, so nothing waits on a reading")
                return
            }
            #expect(state.mediaGrid.orderedAssetIDs.count == batchSize)
        }

        // On This Day's publication (ADR 0049) on the day a year after the fixture's, where
        // earlier years hold the day, and on a day a month after it, where none does and the
        // read falls back to earlier months: the scope's match, order and anniversaries.
        let allMedia = try await store.windowReads.orderedAssetIDs(
            for: .default,
            availableLibraryPaths: CatalogWindowPolicy.availablePaths(from: libraries)
        )
        let taken = try CalendarDay(#require(allMedia.dayBuckets.compactMap(\.self).first))
        for (name, day) in [
            ("projection.windowState.onThisDay.years", taken.inYear(taken.year + 1)),
            ("projection.windowState.onThisDay.months", Self.monthAfter(taken)),
        ] {
            let onThisDay = CatalogQueryRequest(descriptor: CatalogQueryDescriptor(scope: .onThisDay(day)), generation: 0)
            try await Benchmark.measure(name) {
                guard case let .built(state, _, _, _) = try await projection.buildWindowState(
                    store: store,
                    libraries: libraries,
                    request: onThisDay,
                    reads: .none,
                    revisions: CatalogFactRevisions()
                ) else {
                    Issue.record("nothing is searched, so nothing waits on a reading")
                    return
                }
                #expect(state.onThisDay?.anniversaries.isEmpty == false)
            }
        }

        // Opening Duplicates and a map area: narrow scopes no key names, read from the digests
        // the group subquery finds and from the area's map cells
        // (`docs/research/2026-11-15-proportional-small-scopes.md`). Every still is given a
        // place, one in fifty of them inside the area.
        let area = MapArea(south: 10, north: 10.5, west: 19.5, east: 20.5)
        let located = try DatabaseQueue(path: directory.appending(path: "db/catalog.sqlite").path(percentEncoded: false))
        let inArea = try await located.write { db in
            try db.execute(sql: """
            UPDATE asset_metadata SET primary_latitude = 10.0 + (rowid % 50) * 1.1, primary_longitude = 20.0
            """)
            return try Int.fetchOne(db, sql: """
            SELECT count(*) FROM asset_metadata WHERE primary_latitude BETWEEN 10 AND 10.5
            """) ?? 0
        }
        try located.close()
        #expect(inArea > 200)
        for (name, scope, expected) in [
            ("projection.windowState.duplicates", SidebarSelection.duplicates, BenchmarkLibrary.stillCount / 40 * 2),
            ("projection.windowState.mapArea", .mapArea(area), inArea),
        ] {
            let narrow = CatalogQueryRequest(descriptor: CatalogQueryDescriptor(scope: scope), generation: 0)
            try await Benchmark.measure(name) {
                guard case let .built(state, _, _, _) = try await projection.buildWindowState(
                    store: store,
                    libraries: libraries,
                    request: narrow,
                    reads: .none,
                    revisions: CatalogFactRevisions()
                ) else {
                    Issue.record("nothing is searched, so nothing waits on a reading")
                    return
                }
                #expect(state.mediaGrid.orderedAssetIDs.count == expected)
            }
        }

        // Places' first paint: every located still's coordinate with its order, which the map
        // clusters (ADR 0040, `docs/research/2026-11-15-places-first-paint.md`).
        let places = CatalogQueryRequest(descriptor: CatalogQueryDescriptor(scope: .places), generation: 0)
        try await Benchmark.measure("projection.windowState.places") {
            guard case let .built(state, _, _, _) = try await projection.buildWindowState(
                store: store,
                libraries: libraries,
                request: places,
                reads: .none,
                revisions: CatalogFactRevisions()
            ) else {
                Issue.record("nothing is searched, so nothing waits on a reading")
                return
            }
            let located = state.map?.located.count ?? 0
            #expect(located > BenchmarkLibrary.stillCount / 2)
            #expect(located == state.mediaGrid.orderedAssetIDs.count)
        }

        // A whole duplicates build, as `DuplicatesProjection` runs it after a catalog change.
        try await Benchmark.measure("duplicates.build") {
            let built = try await DuplicatesProjection.build(store: store, libraries: libraries).state
            #expect(built.groups.contains { $0.id.isSamePhoto })
            #expect(built.groups.contains { !$0.id.isSamePhoto })
        }

        // The build after a catalog change that moved nothing it is built from: the stills
        // and identical copies are read, the last build's pairing and evidence held.
        let held = try await DuplicatesProjection.build(store: store, libraries: libraries).memory
        try await Benchmark.measure("duplicates.build.unchanged") {
            let built = try await DuplicatesProjection.build(store: store, libraries: libraries, memory: held)
            #expect(!built.paired)
            #expect(built.state.groups.contains { $0.id.isSamePhoto })
        }

        // Its pure pairing step alone: every still without capture metadata tested against
        // its aspect bucket.
        let paths = CatalogWindowPolicy.availablePaths(from: libraries)
        let candidates = try await store.backgroundReads.samePhotoCandidates(availableLibraryPaths: paths)
        try await Benchmark.measure("duplicates.samePhotoPairs") {
            #expect(!SamePhotoPolicy.candidatePairs(candidates, excluding: [], reach: .acrossLibraries).isEmpty)
        }

        // People at a family archive's scale (ADR 0047): 10,000 faces, 1,000 of them the
        // user's across 20 people. `PeopleAssignment` runs a pass after every catalog change of
        // a kind it reads; the snapshot is its catalog read alone, and a settled pass reads,
        // builds the gallery and finds assignment's inputs unchanged.
        try await Self.addFaces(to: store, faces: 10000, people: 20, confirmedEach: 50)
        try await Benchmark.measure("people.snapshot.10k", iterations: 3) {
            let snapshot = try await store.backgroundReads.peopleSnapshot()
            #expect(snapshot.faces.count == 10000)
        }
        let people = PeopleAssignment(store: store)
        try await people.settle()
        try await Benchmark.measure("people.pass.10k", iterations: 3) {
            try await people.settle()
        }
        // The window's read of the gallery, which People's first paint waits for.
        try await Benchmark.measure("people.gallery.10k", iterations: 3) {
            let gallery = try await store.windowReads.peopleGallery(availableLibraryPaths: paths)
            #expect((gallery?.people.count ?? 0) >= 20)
        }

        // What a faces write costs the window and the derived owners once it settles: the
        // window's pass, and a build of each owner whose answer is built from faces
        // (`PeopleAssignment.inputs`, `DuplicatesProjection.inputs`). A new person is a faces
        // write that leaves every face where it was.
        let window = CatalogProjection(cadence: .milliseconds(25))
        let states = await window.states(store: store, initialDescriptor: .default)
        let consuming = Task {
            for await _ in states {}
        }
        defer { consuming.cancel() }
        func settled() async throws {
            try await waitUntil {
                let windowSettled = await window.isQuiescent
                let duplicatesSettled = await window.duplicatesAreQuiescent
                let peopleSettled = await window.peopleAreQuiescent
                return windowSettled && duplicatesSettled && peopleSettled
            }
        }
        try await settled()
        var added = 0
        try await Benchmark.measure("projection.derived.afterFacesWrite", iterations: 3) {
            added += 1
            let heard = await window.detailRefreshGeneration
            _ = try await store.perform(.moveToNewPerson([], name: "Benchmark \(added)"))
            // The projection has taken the change in; from then on it is not quiescent until
            // its pass has asked the owners, and they are not until their builds are done.
            try await waitUntil { await window.detailRefreshGeneration > heard }
            try await settled()
        }
        await store.shutdown()
    }

    /// The window's publication of a library of RAW+JPEG pairs (ADR 0052): the order read
    /// with its stack candidates, the stack rule and the collapse pass.
    @Test func stackCases() async throws {
        let library = try await BenchmarkPairLibrary.make(in: makeTestDirectory())
        let projection = CatalogProjection()
        let request = CatalogQueryRequest(descriptor: .default, generation: 0)
        var lastReads = CatalogProjectionReads.none
        try await Benchmark.measure("projection.windowState.pairs") {
            guard case let .built(state, _, reads, _) = try await projection.buildWindowState(
                store: library.store,
                libraries: library.libraries,
                request: request,
                reads: .none,
                revisions: CatalogFactRevisions()
            ) else {
                Issue.record("nothing is searched, so nothing waits on a reading")
                return
            }
            lastReads = reads
            #expect(state.mediaGrid.orderedAssetIDs.count == BenchmarkPairLibrary.tileCount)
        }
        // What an enrichment batch that moved capture dates of rows no stack holds costs: the
        // order read again over the stacks the last read built (`CatalogChangedFacts.stacks`).
        var datesMoved = CatalogFactRevisions()
        datesMoved.record(.captureDate)
        try await Benchmark.measure("projection.windowState.pairs.heldStacks") {
            guard case let .built(state, metrics, _, _) = try await projection.buildWindowState(
                store: library.store,
                libraries: library.libraries,
                request: request,
                reads: lastReads,
                revisions: datesMoved
            ) else {
                Issue.record("nothing is searched, so nothing waits on a reading")
                return
            }
            #expect(metrics.reuse.stacks && !metrics.reuse.order)
            #expect(state.mediaGrid.orderedAssetIDs.count == BenchmarkPairLibrary.tileCount)
        }
        await library.store.shutdown()
    }

    /// An Immich account's sync applying one batch of 500 assets (ADR 0046 §5) to an account
    /// that already holds 20,000: each asset's folder is listed in full, so the batch looks up
    /// 500 folders' rows. The cost must not grow with the account, or a large library's
    /// first sync stalls its own stream.
    @Test func immichListingCases() async throws {
        let temp = try makeTestDirectory()
        let store = makeTestStore(location: .databaseFile(temp.appending(path: "Catalog.sqlite")), stagingContainers: StagingContainers(base: temp))
        try await store.start(scansSavedLibraries: false)
        let rootPath = try await store.addImmichAccount(
            server: #require(URL(string: "https://photos.example.com")), userID: "u1", displayName: "Family"
        )
        func batch(_ range: Range<Int>) -> SourceListingChanges {
            let items = range.map { index in
                let folder = String(format: "asset-%06d", index)
                return SourceListedItem(
                    file: ScannedMediaFile(
                        relativePath: MediaRelativePath(rawValue: "\(folder)/IMG_\(index).JPG"),
                        name: "IMG_\(index).JPG",
                        contentTypeIdentifier: "public.jpeg",
                        byteSize: 1000,
                        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                        contentModifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
                    ),
                    sourceItemID: folder,
                    isHiddenBySource: false,
                    sourceHasProducts: true
                )
            }
            return SourceListingChanges(listed: items, completeFolders: items.map(\.sourceItemID))
        }
        let scan = try await store.beginSourceListing(rootPath: rootPath)
        for start in stride(from: 0, to: 20000, by: 500) {
            try await store.applySourceListingChanges(batch(start ..< start + 500), scan: scan)
        }
        let measured = batch(10000 ..< 10500)
        try await Benchmark.measure("immich.listing.batch500.of20k") {
            try await store.applySourceListingChanges(measured, scan: scan)
        }
        await store.endSourceListing(scan: scan)
        let kept = try await store.backgroundReads.sourceItemRows(["asset-010000", "asset-019999"], in: rootPath)
        #expect(kept.count == 2)
        await store.shutdown()
    }

    /// A pass's mirror pairing (ADR 0054) over a library of 16,000 digested files that an
    /// account mirrors in full, shaped like the owner's Camera Roll and its Immich external
    /// library: every pass pairs every file again, so once all are paired a pass costs one
    /// read of the library's digests and one indexed probe per file, and writes nothing.
    @Test func immichMirrorCases() async throws {
        let temp = try makeTestDirectory()
        let count = 16000
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let path: @Sendable (Int) -> String = { index in
            String(format: "%04d/IMG_%05d.JPG", 2000 + index / 1000, index)
        }
        let rootURL = temp.appending(path: "Camera Roll", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let scanner = CatalogScanner { _, _, batchHandler in
            let files = (0 ..< count).map { index in
                ScannedMediaFile(
                    relativePath: MediaRelativePath(rawValue: path(index)), name: String(format: "IMG_%05d.JPG", index),
                    contentTypeIdentifier: "public.jpeg", byteSize: 4,
                    createdAt: base.addingTimeInterval(Double(index)), contentModifiedAt: base.addingTimeInterval(Double(index)),
                    kind: .image
                )
            }
            try await batchHandler(files)
            return .mediaOnly(Set(files.map(\.relativePath)))
        }
        let store = makeTestStore(
            location: .databaseFile(temp.appending(path: "db/catalog.sqlite")), scanner: scanner,
            stagingContainers: StagingContainers(base: temp)
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: rootURL)
        let library = try CatalogPath.normalizedDirectoryPath(for: rootURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == count }
        func digest(_ index: Int) -> ContentDigest {
            ContentDigest(bytes: Array(Insecure.SHA1.hash(data: Data("file \(index)".utf8))))!
        }
        for start in stride(from: 0, to: count, by: 500) {
            _ = await store.applyEnrichmentBatch((start ..< start + 500).map { index in
                EnrichmentResult(
                    id: MediaAssetID(libraryRootPath: library, relativePath: MediaRelativePath(rawValue: path(index))),
                    metadata: nil, rendering: nil, sourceSize: 4,
                    sourceMTimeSeconds: Int(base.timeIntervalSince1970) + index, contentHash: digest(index)
                )
            })
        }
        let account = try await store.addImmichAccount(
            server: #require(URL(string: "https://photos.example.com")), userID: "u1", displayName: "Family"
        )
        let prefix = "/mnt/onedrive/Pictures/Camera Roll/"
        let scan = try await store.beginSourceListing(rootPath: account)
        for start in stride(from: 0, to: count, by: 500) {
            let items = (start ..< start + 500).map { index in
                let folder = String(format: "asset-%06d", index)
                return SourceListedItem(
                    file: ScannedMediaFile(
                        relativePath: MediaRelativePath(rawValue: "\(folder)/IMG_\(String(format: "%05d", index)).JPG"),
                        name: String(format: "IMG_%05d.JPG", index), contentTypeIdentifier: "public.jpeg", byteSize: 4,
                        createdAt: base.addingTimeInterval(Double(index)), contentModifiedAt: base.addingTimeInterval(Double(index))
                    ),
                    sourceItemID: folder, isHiddenBySource: false, sourceHasProducts: true,
                    sourcePathChecksum: ImmichPathChecksum(serverPath: prefix + path(index))
                )
            }
            try await store.applySourceListingChanges(SourceListingChanges(listed: items), scan: scan)
        }
        await store.endSourceListing(scan: scan)
        try await store.recordMirror(account: account, library: library, serverPrefix: prefix)
        let first = try await store.backgroundReads.pairMirroredCopies(account: account)
        #expect(first == count)

        try await Benchmark.measure("immich.mirror.pass.of16k") {
            let paired = try await store.backgroundReads.pairMirroredCopies(account: account)
            #expect(paired == 0)
        }
        // All Media over 16,000 photos of two copies each (ADR 0054): with both roots the
        // stored best copy decides every row; with the library away each account copy asks
        // the digest index whether a better copy is reachable.
        try await Benchmark.measure("copies.order.allMedia.of16k") {
            let ids = try await store.windowReads.orderedAssetIDs(
                for: CatalogQueryDescriptor(scope: .allMedia), availableLibraryPaths: [library, account]
            ).ids
            #expect(ids.count == count)
        }
        try await Benchmark.measure("copies.order.libraryAway.of16k") {
            let ids = try await store.windowReads.orderedAssetIDs(
                for: CatalogQueryDescriptor(scope: .allMedia), availableLibraryPaths: [account]
            ).ids
            #expect(ids.count == count)
        }
        await store.shutdown()
    }

    /// The same day of the month in the month after `day`'s.
    private static func monthAfter(_ day: CalendarDay) -> CalendarDay {
        day.month == 12
            ? CalendarDay(year: day.year + 1, month: 1, day: day.day)
            : CalendarDay(year: day.year, month: day.month + 1, day: day.day)
    }

    /// One face on each of the first `faces` stills, embedded as `groupingLibrary` makes them,
    /// with each person's confirmed faces named through the store's own act.
    private static func addFaces(to store: CatalogStore, faces count: Int, people: Int, confirmedEach: Int) async throws {
        let assets = try await waitForCatalogStoreState(store) { !$0.isScanning }.testAssets
            .sorted { $0.id.relativePath.rawValue < $1.id.relativePath.rawValue }
            .prefix(count)
        let (facts, _) = groupingLibrary(faces: count, people: people, confirmedEach: confirmedEach)
        var named: [PersonID: [FaceID]] = [:]
        var renderings: [EnrichmentResult] = []
        var readings: [PreviewFaceResult] = []
        for (asset, fact) in zip(assets, facts) {
            let face = DetectedFace(
                box: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.25),
                landmarks: FaceAlignment.template.map { CGPoint(x: $0.x / 112, y: $0.y / 112) },
                quality: 0.8,
                embedding: fact.embedding
            )
            let preview = "preview-\(asset.id.relativePath.rawValue).heic"
            renderings.append(EnrichmentResult(
                id: asset.id,
                metadata: nil,
                rendering: EnrichedRendering(thumbnailPath: "thumb.jpg", previewPath: preview),
                sourceSize: asset.byteSize,
                sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt),
                contentHash: nil
            ))
            readings.append(PreviewFaceResult(
                candidate: PreviewFaceCandidate(
                    id: asset.id, previewPath: preview, sourceSize: asset.byteSize,
                    sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt), renderedRevision: 0, recipe: .neutral
                ),
                faces: EnrichedFaces(faces: [face], analysisRevision: FaceAnalyzer.revision)
            ))
            if let person = fact.assignment.person {
                named[person, default: []].append(FaceID(asset: asset.id, index: 0))
            }
        }
        for start in stride(from: 0, to: renderings.count, by: 500) {
            _ = await store.applyEnrichmentBatch(Array(renderings[start ..< min(start + 500, renderings.count)]))
            try await store.applyPreviewFaces(Array(readings[start ..< min(start + 500, readings.count)]))
        }
        for (person, faces) in named.sorted(by: { $0.key < $1.key }) {
            let created = try #require(try await store.perform(.moveToNewPerson([], name: "Person \(person.rawValue)")).person)
            for start in stride(from: 0, to: faces.count, by: 50) {
                _ = try await store.perform(.move(Array(faces[start ..< min(start + 50, faces.count)]), to: created))
            }
        }
    }

    /// A grid structural apply, which the user waits for on every switch of view. The pure
    /// half at two sizes: 15,000 photos taken ten a day over 1,500 days, and the owner's
    /// library, 158,000 photos over 5,000 days, where AppKit's diffable snapshot took 13–15
    /// seconds. Then the whole apply at the owner's size through the controller in a window:
    /// the off-main build, `reloadData`, the layout resolve and the post-apply pass, which is
    /// what stands between a sidebar click and a painted grid.
    @Test func gridCases() async throws {
        let small = Self.dayGroupedGrid(prefix: "", photos: 15000, days: 1500)
        try await Benchmark.measure("grid.structureBuild.days1500") {
            let built = await MediaGridViewController.buildStructure(for: small, descriptorChanged: true, previous: .empty)
            #expect(built.structure.numberOfSections == 1500)
            #expect(built.structure.orderedIDs.count == 15000)
        }

        let owner = Self.dayGroupedGrid(prefix: "a/", photos: 158_000, days: 5000)
        try await Benchmark.measure("grid.structureBuild.days5000") {
            let built = await MediaGridViewController.buildStructure(for: owner, descriptorChanged: true, previous: .empty)
            #expect(built.structure.numberOfSections == 5000)
            #expect(built.structure.orderedIDs.count == 158_000)
        }

        try await Self.measureOwnerScaleApply(
            owner,
            other: Self.dayGroupedGrid(prefix: "b/", photos: 158_000, days: 5000)
        )

        // The enrichment trickle at the owner's size: 200 photos learn a capture day far
        // from the one they were shown under, so each leaves its day for another. The pure
        // half (structure, policy and batch derivation, off the main actor), then the whole
        // apply through the controller in a window, where it is a `performBatchUpdates`.
        let reordered = Self.withPhotosMovedBetweenDays(owner, moving: 200, days: 5000)
        let ownerStructure = MediaGridStructure(grid: owner)
        try await Benchmark.measure("grid.reorderBuild.days5000") {
            let built = await MediaGridViewController.buildStructure(
                for: reordered, descriptorChanged: false, previous: ownerStructure
            )
            #expect(built.summary.reorderOnly)
            #expect(built.batchUpdates?.movedItems.count ?? 0 >= 200)
        }
        try await Self.measureOwnerScaleReorder(owner, reordered: reordered)
    }

    /// Move to Trash's visible half at the owner's size (DES-119): Projection takes 5 photos
    /// off the held window (`hidingItems`, off the main actor), and the grid applies their
    /// removal on the main thread. The apply alternates removal and return, as a Move to
    /// Trash and its undo do, so each iteration applies the same five.
    @Test func hideCases() async throws {
        let owner = Self.dayGroupedGrid(prefix: "a/", photos: 158_000, days: 5000)
        let window = CatalogWindowState(
            title: "All Media",
            libraries: [],
            removableSources: [],
            mediaGrid: owner,
            filterOptions: .empty,
            resolvedSidebarSelection: .allMedia,
            mediaEmptyState: nil,
            deviceConnectionBanner: nil
        ).sharingUnchanged(with: nil)
        let ids = owner.orderedAssetIDs
        let trashed = Set(stride(from: 1000, to: 158_000, by: 31000).map { ids[$0] })
        try await Benchmark.measure("projection.hide.days5000") {
            let hidden = window.hidingItems(trashed)
            #expect(hidden.mediaGrid.orderedAssetIDs.count == 158_000 - trashed.count)
        }
        try await Self.measureOwnerScaleHide(owner, hidden: window.hidingItems(trashed).mediaGrid)
        try await Self.measureOwnerScaleInsert(owner)
    }

    /// An import's arrival at the owner's size: ten new photos of a newer day land at the top
    /// of the grid, each publication a fresh order (no edit to follow), alternating with the
    /// order without them, so each iteration inserts or removes the same ten on screen.
    @MainActor
    private static func measureOwnerScaleInsert(_ owner: CatalogMediaGridState) async throws {
        let arrivals = (0 ..< 10).map { index in
            MediaAssetID(
                libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
                relativePath: MediaRelativePath(rawValue: "DCIM/new/IMG_\(index).HEIC")
            )
        }
        let newDay = Optional(Date(timeIntervalSince1970: Double(5001) * 86400))
        let arrived = CatalogMediaGridState(
            scope: owner.scope,
            orderedAssetIDs: arrivals + owner.orderedAssetIDs,
            dayBuckets: Array(repeating: newDay, count: arrivals.count) + owner.dayBuckets
        )
        let without = CatalogMediaGridState(scope: owner.scope, orderedAssetIDs: owner.orderedAssetIDs, dayBuckets: owner.dayBuckets)
        // Projection builds each publication's index off the main actor.
        arrived.content.prepareIndex()
        without.content.prepareIndex()
        let controller = MediaGridViewController()
        _ = controller.view
        let window = orderedInTestWindow(width: 1200, height: 800, contentView: controller.view)
        defer { window.close() }
        controller.view.layoutSubtreeIfNeeded()
        controller.receive(without)
        try await awaitGridShows(controller, without)
        var next = arrived
        try await Benchmark.measure("grid.insertApply.days5000.mainThread", counting: .mainThread) {
            controller.receive(next)
            try await awaitGridShows(controller, next)
            controller.collectionView.layoutSubtreeIfNeeded()
            next = next.orderedAssetIDs.count == owner.orderedAssetIDs.count ? arrived : without
        }
    }

    @MainActor
    private static func measureOwnerScaleHide(_ owner: CatalogMediaGridState, hidden: CatalogMediaGridState) async throws {
        let controller = MediaGridViewController()
        _ = controller.view
        let window = orderedInTestWindow(width: 1200, height: 800, contentView: controller.view)
        defer { window.close() }
        controller.view.layoutSubtreeIfNeeded()
        controller.receive(owner)
        try await awaitGridShows(controller, owner)
        var next = hidden
        try await Benchmark.measure("grid.hideApply.days5000.mainThread", counting: .mainThread) {
            controller.receive(next)
            try await awaitGridShows(controller, next)
            controller.collectionView.layoutSubtreeIfNeeded()
            next = next.orderedAssetIDs.count == owner.orderedAssetIDs.count ? hidden : owner
        }
    }

    /// An act shown in the step that handles it (DES-120), at the owner's size. A choice on five
    /// visible tiles reconfigures them in place on the main thread, never through a structural
    /// apply; an expansion re-collapses the held order off the main actor; a favourite lays
    /// over 2,000 people and re-sorts them by the builder's order.
    @Test func shownFirstCases() async throws {
        let owner = Self.dayGroupedGrid(prefix: "s/", photos: 158_000, days: 5000)
        let ids = owner.orderedAssetIDs
        // One RAW+JPEG pair every 100 photos: the RAW is the photo after its JPEG.
        let pairs = stride(from: 0, to: ids.count - 1, by: 100).map { index in
            PhotoStack(
                id: PhotoStackID(kind: .pair, libraryRootPath: ids[index].libraryRootPath, key: "\(index)"),
                members: [ids[index], ids[index + 1]],
                key: ids[index],
                keyChoice: .notRated,
                rawMembers: [ids[index + 1]],
                photos: [ids[index]]
            )
        }
        let stacks = CatalogStacks(pairs)
        let collapsed = PhotoStackCollapse.collapse(
            ids: ids, dayBuckets: owner.dayBuckets, coordinates: [], stacks: stacks, expanded: []
        )
        let held = CatalogProjectionReads.Collapse(
            ids: ids, dayBuckets: owner.dayBuckets, coordinates: [], stacks: stacks, expanded: [], result: collapsed
        )
        let window = CatalogWindowState(
            title: "All Media",
            libraries: [],
            removableSources: [],
            mediaGrid: owner.replacingContent(
                CatalogGridContent(orderedAssetIDs: collapsed.ids, dayBuckets: collapsed.dayBuckets, stacks: collapsed.grid)
            ),
            filterOptions: .empty,
            resolvedSidebarSelection: .allMedia,
            mediaEmptyState: nil,
            deviceConnectionBanner: nil
        )
        let expanded: Set<PhotoStackID> = [pairs[pairs.count / 2].id]
        try await Benchmark.measure("projection.expandHeld.days5000") {
            let shown = try #require(CatalogProjection.expanding(window, held: held, to: expanded))
            #expect(shown.state.mediaGrid.orderedAssetIDs.count == collapsed.ids.count + 1)
        }
        // The grid's apply of the first tile's expansion, on screen, then of its collapse,
        // alternately: each publication an edit of the one on screen, made off the main
        // actor beforehand.
        let onScreen: Set<PhotoStackID> = [pairs[0].id]
        var shownStates: [CatalogMediaGridState] = []
        var current = (state: window, collapse: held)
        for index in 0 ..< 7 {
            let next = try #require(CatalogProjection.expanding(
                current.state, held: current.collapse, to: index.isMultiple(of: 2) ? onScreen : []
            ))
            next.state.mediaGrid.content.prepareIndex()
            shownStates.append(next.state.mediaGrid)
            current = next
        }
        try await Self.measureOwnerScaleExpand(window.mediaGrid, then: shownStates)
        let people = (0 ..< 2000).map { index in
            PersonSummary(
                id: PersonID(rawValue: Int64(index)), name: "Person \(index)", birthday: nil, isHidden: false,
                isFavorite: false, media: MediaCount(items: [(ids[index], false)]), cover: nil, userFaces: []
            )
        }
        let state = CatalogPeopleState(people: people, unchecked: MediaCount(), hasFaces: true)
        var favourite = PeopleOverlayEffect()
        favourite.people[PersonID(rawValue: 1999)] = PersonEdit(isFavorite: true)
        try await Benchmark.measure("people.overlayFavourite.people2000") {
            #expect(state.overlaying(favourite).people.first?.id == PersonID(rawValue: 1999))
        }
        try await Self.measureOwnerScaleChoice(owner)
    }

    /// A stack expanding and collapsing in the grid at the owner's size: `shown` holds the
    /// warm-up's grid and then one per measured iteration, each an edit of the one before.
    @MainActor
    private static func measureOwnerScaleExpand(
        _ collapsed: CatalogMediaGridState,
        then shown: [CatalogMediaGridState]
    ) async throws {
        collapsed.content.prepareIndex()
        let controller = MediaGridViewController()
        _ = controller.view
        let window = orderedInTestWindow(width: 1200, height: 800, contentView: controller.view)
        defer { window.close() }
        controller.view.layoutSubtreeIfNeeded()
        controller.receive(collapsed)
        try await awaitGridShows(controller, collapsed)
        var next = shown.makeIterator()
        try await Benchmark.measure("grid.expandApply.days5000.mainThread", counting: .mainThread) {
            let upcoming = next.next()
            let grid = try #require(upcoming)
            controller.receive(grid)
            try await awaitGridShows(controller, grid)
            controller.collectionView.layoutSubtreeIfNeeded()
        }
    }

    @MainActor
    private static func measureOwnerScaleChoice(_ owner: CatalogMediaGridState) async throws {
        let controller = MediaGridViewController()
        _ = controller.view
        let window = orderedInTestWindow(width: 1200, height: 800, contentView: controller.view)
        defer { window.close() }
        controller.view.layoutSubtreeIfNeeded()
        controller.receive(owner)
        try await awaitGridShows(controller, owner)
        controller.collectionView.layoutSubtreeIfNeeded()
        let chosen = Array(controller.visibleAssetIDs().prefix(5))
        for id in chosen {
            controller.tileContents.mergeDetail(MediaTileDetail(libraryRootPath: id.libraryRootPath, relativePath: id.relativePath))
        }
        var change = TileChoiceChange()
        var choice = MediaChoice.liked
        try await Benchmark.measure("grid.choiceReconfigure.days5000.mainThread", counting: .mainThread) {
            for id in chosen {
                controller.tileContents.setMediaChoice(choice, for: id)
            }
            change = TileChoiceChange(revision: change.revision &+ 1, ids: Set(chosen))
            controller.receiveTileChoiceChange(change)
            choice = choice == .liked ? .notRated : .liked
        }
    }

    /// The two orders alternated, so every iteration moves the same 200 photos one way or
    /// back, the same query each time: the apply the projection publishes as capture days
    /// arrive. Measured twice: the whole process, and the main thread alone, which is the
    /// share a user can feel as a hang (the build runs off it).
    @MainActor
    private static func measureOwnerScaleReorder(
        _ owner: CatalogMediaGridState,
        reordered: CatalogMediaGridState
    ) async throws {
        let controller = MediaGridViewController()
        _ = controller.view
        let window = orderedInTestWindow(width: 1200, height: 800, contentView: controller.view)
        defer { window.close() }
        controller.view.layoutSubtreeIfNeeded()
        controller.receive(owner)
        try await awaitGridShows(controller, owner)
        var next = reordered
        for (name, counted) in [
            ("grid.reorderApply.days5000", Benchmark.Counted.process),
            ("grid.reorderApply.days5000.mainThread", .mainThread),
        ] {
            try await Benchmark.measure(name, counting: counted) {
                controller.receive(next)
                try await awaitGridShows(controller, next)
                controller.collectionView.layoutSubtreeIfNeeded()
                #expect(controller.structure.numberOfSections == 5000)
                next = next.orderedAssetIDs == owner.orderedAssetIDs ? reordered : owner
            }
        }
    }

    /// `grid` with `count` photos, spread evenly through it, each moved to the day half the
    /// library away from its own and shown first in that day, as Date sort places it.
    private static func withPhotosMovedBetweenDays(
        _ grid: CatalogMediaGridState,
        moving count: Int,
        days: Int
    ) -> CatalogMediaGridState {
        let photos = grid.orderedAssetIDs.count
        let stride = photos / count
        var entries = grid.orderedAssetIDs.indices.map { index in
            (id: grid.orderedAssetIDs[index], day: days - index * days / photos, moved: false, position: index)
        }
        for index in Swift.stride(from: stride / 2, to: photos, by: stride).prefix(count) {
            entries[index].day = (entries[index].day + days / 2) % days + 1
            entries[index].moved = true
        }
        entries.sort { lhs, rhs in
            if lhs.day != rhs.day {
                return lhs.day > rhs.day
            }
            if lhs.moved != rhs.moved {
                return lhs.moved
            }
            return lhs.position < rhs.position
        }
        return CatalogMediaGridState(
            scope: grid.scope,
            orderedAssetIDs: entries.map(\.id),
            dayBuckets: entries.map { Optional(Date(timeIntervalSince1970: Double($0.day) * 86400)) }
        )
    }

    /// The window's apply of a publication at the owner's size (158,000 tiles, a tenth of them
    /// collapsed RAW+JPEG pairs), on the main actor: a republication that moved nothing the user
    /// sees (an enrichment batch), an order that lost and regained one item under a loupe, and
    /// a scope switch between two libraries of that size. Each state is built from fresh
    /// values, as the projection builds every pass, and handed over as the projection
    /// publishes it (`published(_:after:)`).
    @MainActor
    @Test func windowApplyCases() async throws {
        let model = CatalogWindowViewModel(
            catalogStore: makeTestStore(location: .inMemory),
            enrichmentCoordinator: nil,
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: .suite(UUID().uuidString),
            volumeCapacity: ampleVolumeCapacity,
            trashFiles: .refusing
        )
        let ownerSize = 158_000
        let first = Self.ownerWindowState(prefix: "a/", photos: ownerSize, scope: .allMedia, generation: 1)
            .sharingUnchanged(with: nil)
        let republished = Self.published(
            Self.ownerWindowState(prefix: "a/", photos: ownerSize, scope: .allMedia, generation: 2),
            after: first
        )
        model.applyState(first)
        let selected = first.mediaGrid.orderedAssetIDs[5000]
        _ = model.applyGridClick(hit: selected, modifiers: [], orderedIDs: first.mediaGrid.orderedAssetIDs)
        var next = republished
        try await Benchmark.measure("window.apply.republished.158k") {
            model.applyState(next)
            #expect(model.gridSelection.selection == [selected])
            next = next.mediaGrid.detailRefreshGeneration == 1 ? republished : first
        }

        let lostOne = Self.published(
            Self.ownerWindowState(prefix: "a/", photos: ownerSize, scope: .allMedia, generation: 3, dropping: 1000),
            after: first
        )
        model.applyState(first)
        model.openLoupe(id: selected)
        next = lostOne
        try await Benchmark.measure("window.apply.orderChanged.158k") {
            model.applyState(next)
            #expect(model.focusedAssetID == selected)
            next = next.mediaGrid.detailRefreshGeneration == 1 ? lostOne : first
        }
        model.exitToGrid()

        let other = Self.published(
            Self.ownerWindowState(
                prefix: "b/",
                photos: ownerSize,
                scope: .library(LibraryRootPath(rawValue: "/Pictures/b/")),
                generation: 4
            ),
            after: first
        )
        model.applyState(first)
        next = other
        try await Benchmark.measure("window.apply.scopeChanged.158k") {
            model.applyState(next)
            #expect(model.state.mediaGrid.orderedAssetIDs.count == ownerSize)
            next = next.mediaGrid.detailRefreshGeneration == 1 ? other : first
        }

        // The grid's gate asks whether a publication holds the order it shows: by identity,
        // so its cost is not the library's.
        let gate = MediaGridMutationGate()
        _ = gate.receive(first.mediaGrid)
        _ = gate.completeStructuralApply(applied: first.mediaGrid)
        next = republished
        try await Benchmark.measure("grid.gate.republished.158k") {
            let actions = gate.receive(next.mediaGrid)
            guard case .refreshVisible = actions.first else {
                Issue.record("a republished order is a detail refresh, not \(actions)")
                return
            }
            next = next.mediaGrid.detailRefreshGeneration == 1 ? republished : first
        }
    }

    /// What the window's cheap apply costs Projection, off the main actor, at the owner's
    /// size: handing on an equal rebuilt content (the comparison of every identity, day and
    /// stack), and a new order (the comparison up to its first difference, and the position
    /// index it builds). Each iteration publishes a state built fresh, as a pass does.
    @Test func windowPublishCases() async throws {
        let ownerSize = 158_000
        let first = Self.ownerWindowState(prefix: "a/", photos: ownerSize, scope: .allMedia, generation: 1)
            .sharingUnchanged(with: nil)
        // Published states are kept, so no iteration measures freeing one.
        var kept: [CatalogWindowState] = []
        var equal = (0 ..< 4).map { _ in
            Self.ownerWindowState(prefix: "a/", photos: ownerSize, scope: .allMedia, generation: 2)
        }
        try await Benchmark.measure("window.publish.republished.158k", iterations: 3) {
            let published = equal.removeLast().sharingUnchanged(with: first)
            #expect(published.mediaGrid.sharesContent(with: first.mediaGrid))
            kept.append(published)
        }
        var changed = (0 ..< 4).map { _ in
            Self.ownerWindowState(prefix: "a/", photos: ownerSize, scope: .allMedia, generation: 3, dropping: 1000)
        }
        try await Benchmark.measure("window.publish.orderChanged.158k", iterations: 3) {
            let published = changed.removeLast().sharingUnchanged(with: first)
            #expect(!published.mediaGrid.sharesContent(with: first.mediaGrid))
            kept.append(published)
        }
        #expect(kept.count == 8)
    }

    /// What the window receives for `next` published after `previous`.
    private static func published(_ next: CatalogWindowState, after previous: CatalogWindowState) -> CatalogWindowState {
        next.sharingUnchanged(with: previous)
    }

    /// `photos` tiles under Date sort over 5,000 days, every tenth a collapsed RAW+JPEG pair,
    /// optionally without the tile at `dropping`; `generation` is its detail refresh.
    private static func ownerWindowState(
        prefix: String,
        photos: Int,
        scope: SidebarSelection,
        generation: UInt64,
        dropping: Int? = nil
    ) -> CatalogWindowState {
        let root = LibraryRootPath(rawValue: "/Pictures")
        func id(_ name: String) -> MediaAssetID {
            MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "DCIM/\(prefix)\(name)"))
        }
        let kept = (0 ..< photos).filter { $0 != dropping }
        let ids = kept.map { id("IMG_\($0).\($0 % 10 == 0 ? "JPG" : "HEIC")") }
        let buckets = kept.map { Optional(Date(timeIntervalSince1970: Double(5000 - $0 * 5000 / photos) * 86400)) }
        var tiles: [MediaAssetID: TileStacks] = [:]
        var hidden: [MediaAssetID: MediaAssetID] = [:]
        for index in kept where index % 10 == 0 {
            let shown = id("IMG_\(index).JPG")
            let raw = id("IMG_\(index).CR3")
            let pair = PhotoStack(
                id: PhotoStackID(kind: .pair, libraryRootPath: root, key: "\(prefix)IMG_\(index)"),
                members: [raw, shown],
                key: shown,
                keyChoice: .notRated,
                rawMembers: [raw],
                photos: [shown]
            )
            tiles[shown] = TileStacks(pair: pair)
            hidden[raw] = shown
        }
        let grid = CatalogMediaGridState(
            descriptor: CatalogQueryDescriptor(scope: scope),
            orderedAssetIDs: ids,
            dayBuckets: buckets,
            stacks: CatalogGridStacks(tiles: tiles, shownForHiddenMember: hidden),
            detailRefreshGeneration: generation
        )
        return CatalogWindowState(
            title: "Bench",
            libraries: [],
            removableSources: [],
            mediaGrid: grid,
            filterOptions: .empty,
            resolvedSidebarSelection: scope,
            mediaEmptyState: nil,
            deviceConnectionBanner: nil,
            queryGeneration: 0
        )
    }

    /// Two libraries of the owner's size, alternated, so every iteration replaces the whole
    /// grid as a sidebar switch does. Measured for the whole process and for the main
    /// thread alone.
    @MainActor
    private static func measureOwnerScaleApply(
        _ owner: CatalogMediaGridState,
        other: CatalogMediaGridState
    ) async throws {
        let controller = MediaGridViewController()
        _ = controller.view
        let window = orderedInTestWindow(width: 1200, height: 800, contentView: controller.view)
        defer { window.close() }
        controller.view.layoutSubtreeIfNeeded()
        var next = owner
        for (name, counted) in [
            ("grid.structuralApply.days5000", Benchmark.Counted.process),
            ("grid.structuralApply.days5000.mainThread", .mainThread),
        ] {
            try await Benchmark.measure(name, counting: counted) {
                controller.receive(next)
                try await awaitGridShows(controller, next)
                controller.collectionView.layoutSubtreeIfNeeded()
                #expect(controller.structure.numberOfSections == 5000)
                next = next.orderedAssetIDs == owner.orderedAssetIDs ? other : owner
            }
        }
    }

    /// `photos` photos spread evenly over `days` days, newest first as Date sort shows them.
    private static func dayGroupedGrid(prefix: String, photos: Int, days: Int) -> CatalogMediaGridState {
        let ids = (0 ..< photos).map { index in
            MediaAssetID(
                libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
                relativePath: MediaRelativePath(rawValue: "DCIM/\(prefix)IMG_\(index).HEIC")
            )
        }
        let buckets = (0 ..< photos).map { index in
            Optional(Date(timeIntervalSince1970: Double(days - index * days / photos) * 86400))
        }
        return CatalogMediaGridState(
            scope: .library(LibraryRootPath(rawValue: "/Pictures/\(prefix)")),
            orderedAssetIDs: ids,
            dayBuckets: buckets
        )
    }

    /// The Swift around Auto straighten's and Auto crop's models, which runs per photo opened in
    /// Edit, at the sizes a 4:3 photo reads at.
    @Test func editAnalysisCases() async throws {
        // GeoCalib's solve on a 416 × 320 photo's fields.
        let fields = PerspectiveFieldSolver.Fields.camera(
            width: 416, height: 320, roll: 5 * .pi / 180, pitch: 12 * .pi / 180, focal: 380
        )
        try await Benchmark.measure("edit.perspectiveSolve") {
            #expect(PerspectiveFieldSolver.solve(fields) != nil)
        }

        // FocalNet's retention of every candidate crop over a 64 × 64 importance map.
        let grid = AutoCropModel.mapSize, width = 4032, height = 3024
        let values = (0 ..< grid * grid).map { Double(($0 * 37) % 101) / 100 }
        let boxes = AutoCropModel.candidates(width: width, height: height)
        try await Benchmark.measure("edit.cropRetention") {
            let map = ImportanceMap(values)
            let retention = boxes.map {
                map.retention(of: AutoCropModel.pixelBox($0, width: width, height: height), width: width, height: height)
            }
            #expect(retention.contains { $0 > 0.99 })
        }
    }

    /// The work enrichment does for each face it reads (ADR 0047): aligning five points, cutting
    /// the opaque 112 px crop out of a 12-megapixel photo, and the embedding model's prediction.
    /// Alignment and cropping are batched (20,000 and 16) so each case retires enough
    /// instructions to be steady; one alignment alone is lost in the measurement's own cost.
    @Test func faceCases() async throws {
        let moved = CGAffineTransform(rotationAngle: 0.2).scaledBy(x: 5.5, y: 5.5).translatedBy(x: 380, y: 250)
        let points = FaceAlignment.template.applying(moved)
        try await Benchmark.measure("face.align.x20000") {
            var aligned = 0
            for _ in 0 ..< 20000 where FaceAlignment.similarity(from: points, to: FaceAlignment.template) != nil {
                aligned += 1
            }
            #expect(aligned == 20000)
        }

        let photo = try CIImage(cgImage: FaceAnalyzerTests.patternImage(seed: 4, size: 4000))
        let transform = try #require(FaceAlignment.similarity(from: points, to: FaceAlignment.template))
        let context = CIContext()
        try await Benchmark.measure("face.crop.x16") {
            var crops = 0
            for _ in 0 ..< 16 where FaceAnalyzer.alignedCrop(of: photo, transform: transform, context: context) != nil {
                crops += 1
            }
            #expect(crops == 16)
        }

        // Assignment over a library the size of the bake-off's: 3,000 faces, 300 of them the
        // user's across 10 people, the rest open (ADR 0047).
        let (faces, people) = Self.groupingLibrary(faces: 3000, people: 10, confirmedEach: 30)
        try await Benchmark.measure("people.assign") {
            let result = FaceAssignmentPolicy.assign(faces: faces, people: people)
            #expect(!result.guesses.isEmpty)
        }

        // A family archive's scale: 10,000 faces, 1,000 the user's across 20 people.
        let (large, largePeople) = Self.groupingLibrary(faces: 10000, people: 20, confirmedEach: 50)
        try await Benchmark.measure("people.assign.10k", iterations: 3) {
            let result = FaceAssignmentPolicy.assign(faces: large, people: largePeople)
            #expect(!result.guesses.isEmpty)
        }
        // The owner's shape: hundreds of people, most with a few faces the user gave them.
        // Each round visits every open face once per person, so cost grows with faces times
        // people, which the 20-person cases cannot show (2026-11-13: 682 people, 89,474
        // faces). 400 people is the most the generator's person-per-axis embeddings allow.
        let (crowd, crowdPeople) = Self.groupingLibrary(faces: 20000, people: 400, confirmedEach: 5)
        try await Benchmark.measure("people.assign.400people", iterations: 1) {
            let result = FaceAssignmentPolicy.assign(faces: crowd, people: crowdPeople)
            #expect(!result.guesses.isEmpty)
        }

        // A cold start: nobody named, every person found among the faces.
        let cold = large.map { face in
            FaceFact(id: face.id, captureSeconds: face.captureSeconds, embedding: face.embedding,
                     assignment: .open, rejected: [])
        }
        try await Benchmark.measure("people.assign.cold.10k", iterations: 3) {
            #expect(!FaceAssignmentPolicy.assign(faces: cold, people: []).newPeople.isEmpty)
        }
        // Grouping alone, on the faces nobody is the user's.
        let unconfirmed = large.filter { $0.assignment == .open }
        try await Benchmark.measure("people.unnamedGroups.9k", iterations: 3) {
            #expect(!FaceAssignmentPolicy.unnamedGroups(unconfirmed).isEmpty)
        }

        let model = try FaceEmbeddingModel(bundle: Bundle(for: CatalogWindowViewModel.self))
        let crop = try FaceAnalyzerTests.patternImage(seed: 5)
        try await Benchmark.measure("face.embed") {
            let embedding = try model.embedding(of: crop)
            #expect(embedding.values.count == FaceEmbeddingModel.dimensions)
        }
    }

    /// Keyword search (ADR 0048): the resize and the image tower for one stored thumbnail, as
    /// indexing reads each; a query's tokens and text tower; and the match over a 20,000-photo
    /// library's embeddings, which every search pass runs. Translation is the system's, so a
    /// case reads English.
    @Test func searchCases() async throws {
        let bundle = Bundle(for: CatalogWindowViewModel.self)
        let thumbnail = SearchModelTests.solid(red: 0.3, green: 0.6, blue: 0.2, width: 256, height: 171)
        try await Benchmark.measure("search.resample.x16") {
            var squares = 0
            for _ in 0 ..< 16 where SearchImageResampler.square(thumbnail, side: SearchImageModel.side) != nil {
                squares += 1
            }
            #expect(squares == 16)
        }

        let image = try SearchImageModel(bundle: bundle)
        try await Benchmark.measure("search.embedImage") {
            let embedding = try image.embedding(of: thumbnail)
            #expect(embedding.count == SearchEmbedding.dimensions)
        }

        let tokenizer = try SearchTextTokenizer(bundle: bundle)
        let text = try SearchTextModel(bundle: bundle)
        try await Benchmark.measure("search.embedQuery") {
            let embedding = try text.embedding(of: tokenizer.tokenIDs(for: "children on a swing at the beach"))
            #expect(embedding.count == SearchEmbedding.dimensions)
        }

        let vocabulary = try SearchLabelVocabulary(bundle: bundle)
        let dog = try text.embedding(of: tokenizer.tokenIDs(for: "dog"))
        try await Benchmark.measure("search.nameLabels") {
            #expect(vocabulary.labels(namedBy: dog).contains("dog"))
        }

        // A library's readings: 5,000 photos' text, one in fifty holding the word, matched as
        // a search pass matches them (`PhotoSearchIndex`): the index holds each reading
        // folded, and the pass reads its query's words once.
        let readings = (0 ..< 5000).map { index in
            SearchTextReading.folded(
                index % 50 == 0 ? "Proof of Insurance · Policy \(index)" : "Menu \(index) · Café crème 4,50 € · Open daily"
            )
        }
        try await Benchmark.measure("search.textMatch.5k") {
            let query = SearchTextQuery("insurance")
            #expect(readings.count { query.matches(folded: $0) } == 100)
        }

        let sign = try #require(SearchReadingTests.picture(saying: "OTOS SEARCH 2026"))
        // The cold reading compiles Vision's text models, which a loaded machine can make
        // Vision give up on; it happens here, read again after a failure, so the case measures
        // warm readings only. A reader lost for this process to a purge of those compiled
        // models (`SearchTextReading.losesTheProcess`, by its error's type and status) is the
        // machine's, not the commit's: no reading in this process can succeed, so this
        // process records no `search.readText` and the other processes measure it.
        try await withKnownIssue("Vision's text reader was lost for this process to a cache purge", isIntermittent: true) {
            _ = try SearchReadingTests.readRetryingFailures(sign)
            try await Benchmark.measure("search.readText") {
                let read = try SearchTextReading.read(sign)
                #expect(!read.isEmpty)
            }
        } matching: { issue in
            issue.error.map(SearchTextReading.losesTheProcess) ?? false
        }

        var generator = SplitMix64(seed: 11)
        let count = 20000
        let vectors = (0 ..< count * SearchEmbedding.dimensions).map { _ in Float(generator.next() % 2001) / 1000 - 1 }
        let query = (0 ..< SearchEmbedding.dimensions).map { _ in Float(generator.next() % 2001) / 1000 - 1 }
        try await Benchmark.measure("search.match.20k") {
            #expect(PhotoSearchIndex.scores(vectors, count: count, query: query).count == count)
        }
    }

    /// Faces of `people` people, each a direction in embedding space with small per-face
    /// variation, spread over ten years; the first `confirmedEach` of each person the user's.
    static func groupingLibrary(faces count: Int, people: Int, confirmedEach: Int) -> ([FaceFact], [PersonFact]) {
        var generator = SplitMix64(seed: 7)
        let root = LibraryRootPath(rawValue: "/Bench")
        var faces: [FaceFact] = []
        for index in 0 ..< count {
            let person = index % people
            var vector = [Float](repeating: 0, count: FaceEmbeddingModel.dimensions)
            vector[person] = 1
            for _ in 0 ..< 8 {
                vector[people + Int(generator.next() % UInt64(FaceEmbeddingModel.dimensions - people))] += 0.15
            }
            faces.append(FaceFact(
                id: FaceID(asset: MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "\(index).jpg")), index: 0),
                captureSeconds: 1_300_000_000 + Double(index) * 105_000,
                embedding: FaceEmbedding(normalizing: vector)!,
                assignment: index / people < confirmedEach ? .user(PersonID(rawValue: Int64(person + 1))) : .open,
                rejected: []
            ))
        }
        return (faces, (1 ... people).map { PersonFact(id: PersonID(rawValue: Int64($0)), birthdaySeconds: nil, isBare: false) })
    }
}
