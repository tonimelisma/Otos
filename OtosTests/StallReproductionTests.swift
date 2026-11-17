import Foundation
import GRDB
import OSLog
@testable import OtosKit
import SQLite3
import Synchronization
import Testing

/// The owner's sidebar clicks waited 3–15 s: the window's reads waited for one of the main
/// pool's four readers while background owners' reads held all four for seconds
/// (`op=catalog.store.stall`, `connectionMs` up to 23 s with `lockMs` and `storeMs` 0). These
/// tests rebuild that on a generated catalog of his shape and backlog (`OwnerShapedCatalog`)
/// and measure it, as the baseline every design for it is judged by
/// (`docs/research/2026-11-16-stall-reproduction-baseline.md`).
///
/// `windowReadsAreAnsweredWhileEveryBackgroundOwnerRuns` states the requirement in what the
/// test owns on any machine: while every background owner runs, no window read waits for a
/// connection longer than the allowance (the lanes, plan 0116 bet 5); each window read visits
/// rows in proportion to what it answers or to its scope; and each background read visits
/// rows in proportion to what it owes, or, where what it owes is found only by walking the
/// library, walks it at most once per drain. It once asked each window read to answer within
/// 250 ms of its quiet time, and then, briefly, within the 1 s click budget. Both are
/// wall-clock bounds: with lanes the window's reads waited at most 4 ms for a connection while
/// All Media's stack rule took 230–273 ms live against 80 ms quiet and its stack read 152 ms
/// against 54 ms, the owners' work sharing 8 cores in an unoptimized test host, and a second
/// run under other sessions' load (load average 60) answered in up to 6.3 s with its quiet
/// times inflated alike (`docs/research/2026-11-16-window-read-lanes.md`). A failure that only
/// load causes is a test defect, so the answer times, live and quiet, with the load average,
/// are written to the report as a measurement, and the click budget is held where it is real:
/// the tour's scorecard on the owner's library. The test runs at the
/// owner's size only on demand
/// (`OTOS_SCALE_TEST=1 script/check.sh --only StallReproductionTests`), because building a
/// 2.4 GB catalog is not a per-PR cost. The small variant runs in every check and proves the
/// generator's backlog and the measurement themselves.
@Suite(.testScope, .serialized)
struct StallReproductionTests {
    /// Xcode's scheme always defines the key, empty unless the build-setting override is
    /// passed (`ProjectionEnrichmentScaleTests`), so the value is what is checked.
    static let ownerSize = ProcessInfo.processInfo.environment["OTOS_SCALE_TEST"] == "1"

    /// The longest a window read may wait for a connection while the background owners run:
    /// the live store writes a stall line for any longer wait.
    /// time: measurement — a bound on a measured wait; nothing waits on it.
    static let windowReadAllowance: Duration = .milliseconds(250)

    /// A background read visits at most this many rows for each row it returns or asks for.
    static let visitsPerOwedRow = 4

    /// The generated catalog holds the backlog it says it does, as the Store's own candidate
    /// reads count it.
    @Test func theGeneratedCatalogHoldsTheOwnersBacklog() async throws {
        let catalog = try OwnerShapedCatalog.make(in: makeTestDirectory(), scale: 0.01)
        let store = makeTestStore(location: .databaseFile(catalog.databaseURL))
        try await store.start(scansSavedLibraries: false)
        let libraries = try #require(await store.loadedLibraries())
        let available = CatalogWindowPolicy.availablePaths(from: libraries)
        #expect(available == [catalog.pictures, catalog.archive, catalog.account])

        let shape = catalog.shape
        #expect(try await store.windowReads.catalogedAssetCount(for: .allMedia) > 0)
        #expect(try await store.windowReads.searchEmbeddingPendingCount() == shape.embeddingsOwed)
        #expect(try await store.backgroundReads.renderSignatureCandidates(limit: 1000).candidates.count == shape.renderSignaturesOwed)
        #expect(try await store.backgroundReads.searchTextCandidates(limit: shape.assets).candidates.count == shape.textsOwed)
        #expect(try await store.backgroundReads.metadataRefreshCandidates(after: nil, limit: shape.assets).count == shape.metadataStaleInLibraries)
        #expect(try await !store.backgroundReads.photoDescriptionCandidates(limit: 16).candidates.isEmpty)
        #expect(shape.unhashable > shape.assets / 2, "the account and most of a OneDrive library are never hashed")
        let probes = try await store.backgroundReads.mirrorProbes(account: catalog.account)
        #expect(Set(probes.map(\.libraryRootPath)) == [catalog.pictures, catalog.archive])
        #expect(probes.first { $0.libraryRootPath == catalog.archive }?.serverPrefix == nil, "library 6 has no mirror")
        #expect(probes.first { $0.libraryRootPath == catalog.pictures }?.serverPrefix != nil)
    }

    /// The whole measurement runs on a small catalog: every background owner starts, every
    /// window read of every scope change is answered and timed, and every background read
    /// is replayed with SQLite's counts of the rows it visited.
    @Test func everyWindowReadAndBackgroundReadIsMeasuredOnASmallCatalog() async throws {
        let directory = try makeTestDirectory()
        let catalog = try OwnerShapedCatalog.make(in: directory, scale: 0.01)
        let report = try await StallReproduction.measure(catalog, in: directory, rounds: 1, readsStallLines: false)
        let renderSignatures = try #require(report.quiet.first { $0.name == "renderSignatureCandidates" })
        #expect(renderSignatures.returned == catalog.shape.renderSignaturesOwed)
        #expect(renderSignatures.visitedRows >= Int64(catalog.shape.renderSignaturesOwed), "SQLite counted the rows it visited")
        #expect(report.live.count == StallReproduction.scopeCount * 4)
        let unanswered = report.live.filter { !$0.answered }
        #expect(unanswered.isEmpty, "\(unanswered.count) window reads failed: \(report.summary(catalog))")
    }

    /// The requirement at the owner's size: while every background owner runs, no window read
    /// waits for a connection beyond the allowance, each window read visits rows in proportion
    /// to what it answers or to its scope, and background reads visit what they owe, or walk the
    /// library at most once per drain. Answer times are reported, not asserted.
    @Test(.enabled(if: ownerSize))
    func windowReadsAreAnsweredWhileEveryBackgroundOwnerRuns() async throws {
        let directory = try makeTestDirectory()
        let catalog = try OwnerShapedCatalog.make(in: directory, scale: 1)
        let report = try await StallReproduction.measure(catalog, in: directory, rounds: 3, readsStallLines: true)
        try StallReproduction.write(report.summary(catalog), named: "owner")
        let unanswered = report.live.filter { !$0.answered }
        #expect(unanswered.isEmpty, "\(unanswered.count) window reads failed")

        // A read outside the scope changes that is not a walk (`libraryVisitingReads`) visits
        // rows in proportion to what it returns or asks for; a read by key (`rowsReadByKey`)
        // visits the rows it joins for each.
        for read in report.quiet where !read.isWindowRead && StallReproduction.libraryVisitingReads[read.name] == nil {
            let perRow = StallReproduction.rowsReadByKey[read.name]?.rows ?? Self.visitsPerOwedRow
            #expect(
                read.visitedRows <= Int64(perRow * max(read.returned, read.limit)),
                "\(read.name) visited \(read.visitedRows) rows to return \(read.returned)"
            )
        }
        // Window reads have their own readers (plan 0116 bet 5): a background read takes one
        // of `CatalogReadAdmission.backgroundReaders` turns before it enters the pool. No window
        // read waits for a connection longer than the allowance (the live store's stall
        // threshold), and none a second.
        let waitedWindowReads = report.stalls.filter { StallReproduction.windowOperations.contains($0.operation) }
        #expect(waitedWindowReads.isEmpty, "\(waitedWindowReads.count) window reads waited \(Self.windowReadAllowance) or more")
        // A window read's work stays in proportion to what it answers, on any machine: the rows
        // it visits are at most `visitsPerOwedRow` per row it returns or per row its scope holds.
        // A read that applies the stack rule (the order read, and the imports' counts of what
        // each batch shows) reads the stack candidates of the scope's roots (`stackLoops`),
        // which the window holds across passes (ADR 0005); it reads each at most once per index.
        for read in report.quiet where read.isWindowRead {
            let stackVisits = read.visitedByLoop.filter { StallReproduction.stackLoops.contains($0.key) }.values.reduce(0, +)
            let own = read.visitedRows - stackVisits
            let bound = Int64(Self.visitsPerOwedRow * max(read.returned, read.limit, read.scopeRows))
            #expect(own <= bound, "\(read.name) of \(read.scope) visited \(own) rows for \(read.returned) returned, \(read.scopeRows) in scope")
            #expect(
                stackVisits <= Int64(2 * catalog.shape.assets),
                "\(read.name) of \(read.scope) read \(stackVisits) stack candidates"
            )
        }
        // A walk for what is owed visits each row it walks at most once per index it joins,
        // once per drain.
        for read in report.quiet {
            guard let walk = StallReproduction.libraryVisitingReads[read.name] else { continue }
            let bound = Int64(walk.indexes * catalog.shape.assets + Self.visitsPerOwedRow * max(read.returned, read.limit))
            #expect(read.visitedRows <= bound, "\(read.name) visited \(read.visitedRows) rows, more than once per drain (\(bound))")
        }
    }
}

/// Runs the measurement: a quiet replay of every read on one Store, then the window's scope
/// changes while every background owner runs on another, on the same file.
enum StallReproduction {
    /// The reads the window issues for a scope change, by the name a stall line gives them.
    static let windowOperations: Set<String> = [
        "orderedAssetIDs", "filterOptions", "importBatches", "mediaTileDetails", "visibleAssetCount", "catalogedAssetCount",
    ]
    /// A read that finds what it owes only by walking the library, and the indexes its walk
    /// joins: it visits each row at most once per index, once per drain (plan 0116 stage 1),
    /// whatever it returns. Each is a walk by what decides what is owed:
    /// - the search embedding and text readings, and descriptions: a row is owed when its
    ///   product's stamp differs from the asset's own, a comparison of two tables no index holds
    ///   (a trigger-kept ledger of owed rows was rejected, plan 0116 §5); a change that names
    ///   its rows is read by key (`CatalogChangedRows`);
    /// - a metadata record is stale by its family's revision, which a MediaMetadata release
    ///   moves, so no index can hold the stale ones without a migration per release (ADR 0039);
    /// - the unnamed place cells: a cell is unnamed when no `place_cell` row of the language
    ///   holds it, a join of every located cell;
    /// - duplicates' copies and an account's mirror probes read a whole set by nature.
    static let libraryVisitingReads: [String: (indexes: Int, owes: String)] = [
        "searchEmbeddingCandidates": (2, "stamp against embedding source"),
        "searchEmbeddingCandidates.drain": (2, "stamp against embedding source"),
        "searchTextCandidates": (2, "stamp against text source"),
        "searchTextCandidates.drain": (2, "stamp against text source"),
        "photoDescriptionCandidates": (2, "stamp against description source"),
        "metadataRefreshCandidates": (2, "family revision"),
        "unnamedPlaceCells": (2, "located cells against named cells"),
        "duplicateCopies": (1, "every hashed row"),
        "mirrorProbes": (1, "every row of the mirrored libraries"),
    ]
    /// A read outside a scope change that reads each row it asks for by key, joining more
    /// rows for each than `visitsPerOwedRow`, and why:
    /// - the People gallery reads each person with their key photo's and newest face's tiles:
    ///   the person, two faces and two photos.
    static let rowsReadByKey: [String: (rows: Int, joins: String)] = [
        "peopleGallery": (5, "person, key face and photo, newest face and photo"),
    ]
    /// The loops of an order read's stack read (`PhotoStackSQL.candidateQuery`).
    static let stackLoops: Set<String> = [
        "idx_media_asset_stack_candidate", "raw_folder", "pairing_folder", "idx_media_asset_burst",
    ]
    static let scopeCount = 5
    /// The visible tiles a scope change reads the details of.
    static let visibleTiles = 60

    struct QuietRead {
        let name: String
        let limit: Int
        let returned: Int
        /// The window read's scope, and the rows its order returned: what an options or
        /// imports read is in proportion to.
        var scope = ""
        var scopeRows = 0
        let answer: Duration
        let visitedRows: Int64
        let visitedByLoop: [String: Int64]
        let sorts: Int64
        var isWindowRead: Bool {
            StallReproduction.windowOperations.contains(name)
        }
    }

    struct LiveRead {
        let name: String
        let scope: String
        let answer: Duration
        let answered: Bool
    }

    struct Report {
        var quiet: [QuietRead] = []
        /// Each window read's quiet answer time, by `name@scope`.
        var quietWindow: [String: Duration] = [:]
        /// What each part of the run took: generation is the catalog's own.
        var phases: [String: Duration] = [:]
        var live: [LiveRead] = []
        var stalls: [StallLine] = []
        var changes: [String: Int] = [:]
        var mirrorProbe: Duration?
        var searchPasses = 0
        /// Each owner's changes heard and passes asked for (the search index's and the
        /// description writer's count their first).
        var wakes: [String: (heard: Int, wakes: Int)] = [:]
        var liveDuration: Duration = .zero
    }

    // MARK: - Measuring

    /// `readsStallLines`: read the Store's stall lines back from this process's log, which
    /// takes the unified log ten seconds or more to answer; a small catalog writes none.
    static func measure(
        _ catalog: OwnerShapedCatalog,
        in directory: URL,
        rounds: Int,
        readsStallLines: Bool
    ) async throws -> Report {
        var report = Report()
        let start = ContinuousClock.now
        try await measureQuiet(catalog, into: &report)
        report.phases["quiet"] = start.duration(to: .now)
        try await measureLive(catalog, in: directory, rounds: rounds, readsStallLines: readsStallLines, into: &report)
        return report
    }

    /// Every read once, one after another, on a Store whose connections count what each
    /// statement visited (`StatementVisits`). Nothing else runs.
    private static func measureQuiet(_ catalog: OwnerShapedCatalog, into report: inout Report) async throws {
        let store = makeTestStore(location: .databaseFile(catalog.databaseURL))
        try await store.start(scansSavedLibraries: false)
        let visits = StatementVisits()
        try await visits.install(on: store)
        let libraries = try #require(await store.loadedLibraries())
        let available = CatalogWindowPolicy.availablePaths(from: libraries)
        let language = PlaceNameLanguage(Locale.current)

        func replay(
            _ name: String,
            limit: Int = 0,
            scope: SidebarSelection? = nil,
            scopeRows: Int = 0,
            _ read: () async throws -> Int
        ) async throws {
            visits.reset()
            let start = ContinuousClock.now
            let returned = try await read()
            let answer = start.duration(to: .now)
            let counted = visits.take()
            report.quiet.append(QuietRead(
                name: name, limit: limit, returned: returned,
                scope: scope.map { String(describing: $0) } ?? "", scopeRows: scopeRows, answer: answer,
                visitedRows: counted.byLoop.values.reduce(0, +), visitedByLoop: counted.byLoop, sorts: counted.sorts
            ))
            if report.quiet.last?.isWindowRead == true {
                report.quietWindow["\(name)@\(scope.map { String(describing: $0) } ?? "")"] = answer
            }
        }

        // The background owners' reads, each with its owner's page size.
        try await replay("renderSignatureCandidates", limit: 128) { try await store.backgroundReads.renderSignatureCandidates(limit: 128).candidates.count }
        try await replay("searchEmbeddingCandidates", limit: 16) { try await store.backgroundReads.searchEmbeddingCandidates(limit: 16).candidates.count }
        try await replay("searchTextCandidates", limit: 8) { try await store.backgroundReads.searchTextCandidates(limit: 8).candidates.count }
        try await replay("photoDescriptionCandidates", limit: 16) { try await store.backgroundReads.photoDescriptionCandidates(limit: 16).candidates.count }
        // One drain is one walk (plan 0116): each owner's whole walk, page after page, as its
        // drain asks for it.
        try await replay("renderSignatureCandidates.drain", limit: 128) {
            try await walk { try await store.backgroundReads.renderSignatureCandidates(after: $0, limit: 128) }
        }
        try await replay("searchEmbeddingCandidates.drain", limit: 16) {
            try await walk { try await store.backgroundReads.searchEmbeddingCandidates(after: $0, limit: 16) }
        }
        try await replay("searchTextCandidates.drain", limit: 8) {
            try await walk { try await store.backgroundReads.searchTextCandidates(after: $0, limit: 8) }
        }
        try await replay("previewFaceCandidates", limit: 32) { try await store.backgroundReads.previewFaceCandidates(limit: 32).candidates.count }
        try await replay("metadataRefreshCandidates", limit: 64) {
            try await store.backgroundReads.metadataRefreshCandidates(after: nil, limit: 64).count
        }
        try await replay("unnamedPlaceCells", limit: 32) { try await store.backgroundReads.unnamedPlaceCells(language: language, limit: 32).count }
        // The search index's first load: every stored embedding, a page of 2,000 at a time.
        try await replay("searchEmbeddingRows.load", limit: PhotoSearchIndex.loadPageSize) {
            try await walk { try await store.backgroundReads.searchEmbeddingRows(after: $0, limit: PhotoSearchIndex.loadPageSize) }
        }
        try await replay("currentSearchEmbeddingIDs") { try await store.backgroundReads.currentSearchEmbeddingIDs().ids.count }
        // A query's words, from the text index (ADR 0048): a word, and a prefix many readings hold.
        for word in ["open", "ca"] {
            try await replay("searchTextMatches.\(word)") { try await store.windowReads.searchTextMatches([SearchTextQuery(word)]).ids.count }
        }
        var involved: [MediaAssetID] = []
        try await replay("samePhotoCandidates") {
            let candidates = try await store.backgroundReads.samePhotoCandidates(availableLibraryPaths: available)
            involved = candidates.prefix(visibleTiles).map(\.id)
            return candidates.count
        }
        try await replay("samePhotoEvidence", limit: involved.count) { try await store.backgroundReads.samePhotoEvidence(for: involved).count }
        try await replay("samePhotoCopies", limit: involved.count) { try await store.backgroundReads.samePhotoCopies(for: involved).count }
        try await replay("duplicateCopies") { try await store.backgroundReads.duplicateCopies(availableLibraryPaths: available).copies.count }
        var people = 0
        try await replay("peopleSnapshot") {
            let snapshot = try await store.backgroundReads.peopleSnapshot()
            people = snapshot.people.count
            return snapshot.faces.count
        }
        // The gallery asks for every person; it returns none while People has stored no facts.
        try await replay("peopleGallery", limit: people) {
            try await store.windowReads.peopleGallery(availableLibraryPaths: available)?.people.count ?? 0
        }
        try await replay("mirrorProbes") { try await store.backgroundReads.mirrorProbes(account: catalog.account).reduce(0) { $0 + $1.candidates.count } }

        // The window's reads for each scope change.
        for scope in try await scopes(catalog, store: store) {
            var ids: [MediaAssetID] = []
            try await replay("orderedAssetIDs", scope: scope) {
                ids = try await store.windowReads.orderedAssetIDs(for: CatalogQueryDescriptor(scope: scope), availableLibraryPaths: available).ids
                return ids.count
            }
            try await replay("filterOptions", scope: scope, scopeRows: ids.count) {
                try await store.windowReads.filterOptions(for: scope, availableLibraryPaths: available, placeNameLanguages: [language])
                    .formatsByKind.count
            }
            // An imports read counts the photos of the batches it returns.
            try await replay("importBatches", scope: scope) {
                try await store.windowReads.importBatches(counting: .newest(20, and: nil)).reduce(0) { $0 + ($1.photoCount ?? 0) }
            }
            let visible = Array(ids.prefix(visibleTiles))
            try await replay("mediaTileDetails", limit: visible.count, scope: scope) { try await store.windowReads.mediaTileDetails(for: visible).count }
        }
    }

    /// Every candidate of a walk, page after page from the first, as an owner's drain reads
    /// them; returns how many it found.
    private static func walk<Cursor>(
        _ page: (Cursor?) async throws -> CandidatePage<some Any, Cursor>
    ) async throws -> Int {
        var found = 0
        var cursor: Cursor?
        repeat {
            let next = try await page(cursor)
            found += next.candidates.count
            cursor = next.next
        } while cursor != nil
        return found
    }

    /// The scopes a click visits: All Media, each library and the account, and an import.
    private static func scopes(_ catalog: OwnerShapedCatalog, store: CatalogStore) async throws -> [SidebarSelection] {
        let batch = try #require(try await store.windowReads.importBatches(counting: .newest(1, and: nil)).first)
        return [.allMedia, .library(catalog.pictures), .library(catalog.account), .library(catalog.archive), .importBatch(batch.batchID)]
    }

    /// The background owners started as the window starts them (`CatalogWindowViewModel`), each
    /// with work it cannot finish: no thumbnail, preview or original is on disk, no download
    /// completes, no model loads. While they run, the window's reads of every scope change are
    /// asked and timed; the Store's stall lines name what held them.
    private static func measureLive(
        _ catalog: OwnerShapedCatalog,
        in directory: URL,
        rounds: Int,
        readsStallLines: Bool,
        into report: inout Report
    ) async throws {
        let logStart = Date()
        // Any window read that waits longer than the allowance writes a stall line.
        let store = makeTestStore(
            location: .databaseFile(catalog.databaseURL),
            stallThreshold: StallReproductionTests.windowReadAllowance
        )
        try await store.start(scansSavedLibraries: false)
        let libraries = try #require(await store.loadedLibraries())
        let available = CatalogWindowPolicy.availablePaths(from: libraries)
        let language = PlaceNameLanguage(Locale.current)
        let scopes = try await scopes(catalog, store: store)
        let thumbnails = directory.appending(path: "Thumbnails", directoryHint: .isDirectory)

        // What woke the owners: every change the Store announced while they ran.
        let changeLog = Tally()
        let changes = await store.changeNotifications()
        let changeTask = Task {
            for await change in changes {
                changeLog.add(String(describing: change))
            }
        }

        let owners = try RunningBackgroundOwners(store: store, thumbnails: thumbnails)

        let liveStart = ContinuousClock.now
        await owners.start(store: store)
        // An account's sync probes for mirrors once at launch (`ImmichCatalogSync`).
        let mirrorTask = Task { () -> Duration in
            let start = ContinuousClock.now
            _ = try await store.backgroundReads.mirrorProbes(account: catalog.account)
            return start.duration(to: .now)
        }

        for _ in 0 ..< rounds {
            for scope in scopes {
                report.live += try await scopeChange(
                    to: scope, store: store, available: available, language: language
                )
            }
        }
        report.liveDuration = liveStart.duration(to: .now)
        let shutdownStart = ContinuousClock.now
        report.mirrorProbe = try await mirrorTask.value
        let renderSignatures = owners.renderSignatures, previewFaces = owners.previewFaces
        let placeNames = owners.placeNames, searchIndex = owners.searchIndex, descriptions = owners.descriptions
        report.searchPasses = await searchIndex.passesFinished
        // Of the changes each owner heard, how many asked it for a pass.
        report.wakes = await [
            "renderSignatures": (renderSignatures.changesHeard, renderSignatures.wakes),
            "previewFaces": (previewFaces.changesHeard, previewFaces.wakes),
            "placeNames": (placeNames.changesHeard, placeNames.wakes),
            "searchIndex": (searchIndex.changesHeard, Int(searchIndex.requested)),
            "descriptions": (descriptions.changesHeard, Int(descriptions.requested)),
        ]

        await owners.shutdown()
        changeTask.cancel()
        report.changes = changeLog.counts
        report.phases["shutdown"] = shutdownStart.duration(to: .now)
        let logReadStart = ContinuousClock.now
        report.stalls = readsStallLines ? try StallLine.read(since: logStart) : []
        report.phases["logRead"] = logReadStart.duration(to: .now)
    }

    /// One click: the order, the filter's options and the imports asked together, then the
    /// visible tiles' details from the order's first rows. Each is timed from its ask.
    private static func scopeChange(
        to scope: SidebarSelection,
        store: CatalogStore,
        available: Set<LibraryRootPath>,
        language: PlaceNameLanguage
    ) async throws -> [LiveRead] {
        let name = String(describing: scope)
        async let order = timed("orderedAssetIDs", scope: name) {
            try await store.windowReads.orderedAssetIDs(for: CatalogQueryDescriptor(scope: scope), availableLibraryPaths: available).ids
        }
        async let options = timed("filterOptions", scope: name) {
            try await store.windowReads.filterOptions(for: scope, availableLibraryPaths: available, placeNameLanguages: [language])
        }
        async let imports = timed("importBatches", scope: name) {
            try await store.windowReads.importBatches(counting: .newest(20, and: nil))
        }
        let (orderRead, ids) = await order
        let visible = Array((ids ?? []).prefix(visibleTiles))
        let (tiles, _) = await timed("mediaTileDetails", scope: name) { try await store.windowReads.mediaTileDetails(for: visible) }
        return await [orderRead, options.0, imports.0, tiles]
    }

    /// `read`'s answer and the time from its ask; a read that failed is recorded unanswered.
    private static func timed<Value: Sendable>(
        _ read: String,
        scope: String,
        _ body: @Sendable () async throws -> Value
    ) async -> (LiveRead, Value?) {
        let start = ContinuousClock.now
        do {
            let value = try await body()
            return (LiveRead(name: read, scope: scope, answer: start.duration(to: .now), answered: true), value)
        } catch {
            return (LiveRead(name: read, scope: scope, answer: start.duration(to: .now), answered: false), nil)
        }
    }

    // MARK: - Reporting

    /// The Mac's one-minute load average, written beside the answer times it explains.
    static func loadAverage() -> String {
        var loads = [Double](repeating: 0, count: 1)
        return getloadavg(&loads, 1) == 1 ? String(format: "%.1f", loads[0]) : "unknown"
    }

    /// Writes a summary into the checkout's `build/stall-reproduction/`, which git ignores: a
    /// test host's standard output reaches no log.
    static func write(_ summary: String, named name: String) throws {
        let url = SourceTree.root.appending(path: "build/stall-reproduction/\(name).txt")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(summary.utf8).write(to: url)
    }
}

extension StallReproduction.Report {
    /// The baseline's tables, as the research note records them.
    func summary(_ catalog: OwnerShapedCatalog) -> String {
        func ms(_ duration: Duration?) -> String {
            duration.map { "\(DiagnosticsTiming.milliseconds($0))" } ?? "-"
        }
        var lines = [
            "op=stallReproduction.catalog assets=\(catalog.shape.assets) bytes=\(catalog.fileBytes) generationMs=\(ms(catalog.generation)) shape=\(catalog.shape)",
            "op=stallReproduction.live loadAverage=\(StallReproduction.loadAverage()) durationMs=\(ms(liveDuration)) mirrorProbeMs=\(ms(mirrorProbe)) searchPasses=\(searchPasses) phases=\(phases.sorted { $0.key < $1.key }.map { "\($0.key):\(ms($0.value))" }.joined(separator: ","))",
        ]
        for read in quiet {
            let loops = read.visitedByLoop.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key):\($0.value)" }.joined(separator: ",")
            lines.append(
                "op=stallReproduction.quiet read=\(read.name) limit=\(read.limit) returned=\(read.returned) ms=\(ms(read.answer)) visited=\(read.visitedRows) sorts=\(read.sorts) loops=\(loops)"
            )
        }
        for name in Set(live.map(\.name)).sorted() {
            let answers = live.filter { $0.name == name }.map(\.answer).sorted()
            let quiets = quietWindow.filter { $0.key.hasPrefix("\(name)@") }.values.sorted()
            let waited = stalls.filter { $0.operation == name }
            lines.append(
                "op=stallReproduction.window read=\(name) count=\(answers.count) quietP50Ms=\(ms(quiets.isEmpty ? nil : quiets[quiets.count / 2])) quietMaxMs=\(ms(quiets.last)) p50Ms=\(ms(answers[answers.count / 2])) maxMs=\(ms(answers.last)) stalls=\(waited.count) maxWaitMs=\(waited.map(\.waitMs).max() ?? 0) maxConnectionMs=\(waited.compactMap(\.connectionMs).max() ?? 0) maxSnapshotMs=\(waited.compactMap(\.snapshotMs).max() ?? 0) maxLockMs=\(waited.map(\.lockMs).max() ?? 0) maxStoreMs=\(waited.map(\.storeMs).max() ?? 0)"
            )
        }
        for holder in StallLine.holds(in: stalls) {
            lines.append(
                "op=stallReproduction.holder operation=\(holder.operation) holds=\(holder.holds) maxHeldMs=\(holder.maxMs) totalHeldMs=\(holder.totalMs) namedInStalls=\(holder.namedIn)"
            )
        }
        for (change, count) in changes.sorted(by: { $0.key < $1.key }) {
            lines.append("op=stallReproduction.change change=\(change) count=\(count)")
        }
        for (owner, counted) in wakes.sorted(by: { $0.key < $1.key }) {
            lines.append("op=stallReproduction.wakes owner=\(owner) heard=\(counted.heard) wakes=\(counted.wakes)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Counts by name, from any thread.
final class Tally: Sendable {
    private let counted = Mutex<[String: Int]>([:])

    var counts: [String: Int] {
        counted.withLock { $0 }
    }

    /// Adds one to `name` and returns its count.
    @discardableResult
    func add(_ name: String) -> Int {
        counted.withLock { counted in
            counted[name, default: 0] += 1
            return counted[name, default: 0]
        }
    }
}

// MARK: - Rows a statement visited

/// SQLite's own count of the rows each loop of a statement visited
/// (`sqlite3_stmt_scanstatus`, `SQLITE_SCANSTAT_NVISIT`; the system SQLite is built with
/// `SQLITE_ENABLE_STMT_SCANSTATUS`), summed over every statement that finished on the
/// connections it is installed on.
///
/// It reaches the Store's pool through reflection: the Store exposes no connection, and this
/// measurement adds nothing to the product. Installing replaces each connection's trace, so
/// the Store it is installed on writes no stall line; the quiet replay needs none.
final class StatementVisits: Sendable {
    struct Counted {
        var byLoop: [String: Int64] = [:]
        var sorts: Int64 = 0
    }

    private let counted = Mutex(Counted())

    func reset() {
        counted.withLock { $0 = Counted() }
    }

    func take() -> Counted {
        counted.withLock { counted in
            defer { counted = Counted() }
            return counted
        }
    }

    /// Installs the count on the writer and on every one of the main pool's readers: four
    /// reads held open together make the pool open all four.
    func install(on store: CatalogStore) async throws {
        let pool = try #require(Mirror(reflecting: store).children.first { $0.label == "dbWriter" }?.value as? DatabasePool)
        try await pool.writeWithoutTransaction { db in self.attach(to: db) }
        let readers = CatalogStore.readerCount
        let arrived = Tally()
        let release = DispatchSemaphore(value: 0)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< readers {
                group.addTask {
                    try await pool.read { db in
                        self.attach(to: db)
                        if arrived.add("reader") == readers {
                            for _ in 1 ..< readers {
                                release.signal()
                            }
                        } else {
                            release.wait()
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    /// Runs on the connection's own queue: the system SQLite is multi-thread, not serialized.
    private func attach(to db: Database) {
        sqlite3_trace_v2(db.sqliteConnection, UInt32(SQLITE_TRACE_PROFILE), { _, context, statement, _ in
            guard let context, let statement else { return 0 }
            Unmanaged<StatementVisits>.fromOpaque(context).takeUnretainedValue().record(OpaquePointer(statement))
            return 0
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func record(_ statement: OpaquePointer) {
        var byLoop: [String: Int64] = [:]
        var loop: Int32 = 0
        while true {
            var visited: Int64 = 0
            guard sqlite3_stmt_scanstatus(statement, loop, SQLITE_SCANSTAT_NVISIT, &visited) == 0 else { break }
            var name: UnsafePointer<CChar>?
            _ = sqlite3_stmt_scanstatus(statement, loop, SQLITE_SCANSTAT_NAME, &name)
            byLoop[name.map { String(cString: $0) } ?? "loop\(loop)", default: 0] += visited
            loop += 1
        }
        let sorts = Int64(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_SORT, 1))
        sqlite3_stmt_scanstatus_reset(statement)
        counted.withLock { counted in
            counted.byLoop.merge(byLoop, uniquingKeysWith: +)
            counted.sorts += sorts
        }
    }
}

// MARK: - The Store's stall lines

/// One `op=catalog.store.stall` line, read back from this process's log.
struct StallLine {
    struct Holder {
        let connection: String
        let operation: String
        /// When its transaction began, to the 100 ms: the same hold named in several lines is
        /// counted once.
        let startKey: Int64
        let heldMs: Int
    }

    let operation: String
    let storeMs: Int
    let waitMs: Int
    let connectionMs: Int?
    let snapshotMs: Int?
    let lockMs: Int
    let holders: [Holder]

    /// Every stall line this process wrote since `date`. Only one suite runs at the owner's
    /// size, so the lines are its Store's.
    static func read(since date: Date) throws -> [StallLine] {
        let log = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try log.getEntries(
            at: log.position(date: date),
            matching: NSPredicate(format: "subsystem == %@ AND category == %@", OtosLog.subsystem, OtosLog.Category.catalog.rawValue)
        )
        return entries.compactMap { entry in
            guard let entry = entry as? OSLogEntryLog, entry.composedMessage.hasPrefix("op=catalog.store.stall ") else {
                return nil
            }
            return StallLine(entry.composedMessage, at: entry.date)
        }
    }

    init?(_ message: String, at date: Date) {
        var fields: [String: String] = [:]
        for pair in message.split(separator: " ") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                fields[String(parts[0])] = String(parts[1])
            }
        }
        guard let operation = fields["operation"] else { return nil }
        self.operation = operation
        storeMs = fields["storeMs"].flatMap { Int($0) } ?? 0
        waitMs = fields["waitMs"].flatMap { Int($0) } ?? 0
        connectionMs = fields["connectionMs"].flatMap { Int($0) }
        snapshotMs = fields["snapshotMs"].flatMap { Int($0) }
        lockMs = fields["lockMs"].flatMap { Int($0) } ?? 0
        let lineMs = Int64(date.timeIntervalSince1970 * 1000)
        holders = [fields["running"], fields["endedDuringWait"]].compactMap(\.self).flatMap { list -> [Holder] in
            list == "none" ? [] : list.split(separator: ",").compactMap { Self.holder(String($0), lineMs: lineMs) }
        }
    }

    /// `main.reader.2:txn5300ms:readSearchEmbeddings:SELECT_…` or
    /// `main.reader.1:held8600ms-endedAgo120ms:renderSignatureCandidates:SELECT_…`.
    private static func holder(_ text: String, lineMs: Int64) -> Holder? {
        let parts = text.split(separator: ":", maxSplits: 3).map(String.init)
        guard parts.count >= 3 else { return nil }
        let timing = parts[1]
        let numbers = timing.split { !$0.isNumber }.compactMap { Int64($0) }
        guard let held = numbers.first else { return nil }
        let endedAgo = timing.hasPrefix("held") ? numbers.dropFirst().first ?? 0 : 0
        let start = lineMs - endedAgo - held
        return Holder(connection: parts[0], operation: parts[2], startKey: start / 100, heldMs: Int(held))
    }

    struct Holds {
        let operation: String
        let holds: Int
        let maxMs: Int
        let totalMs: Int
        let namedIn: Int
    }

    /// Each operation's holds across the lines, each counted once, longest first.
    static func holds(in stalls: [StallLine]) -> [Holds] {
        var byOperation: [String: [String: Int]] = [:]
        var namedIn: [String: Int] = [:]
        for stall in stalls {
            for holder in stall.holders {
                let key = "\(holder.connection)@\(holder.startKey)"
                byOperation[holder.operation, default: [:]][key] = max(byOperation[holder.operation]?[key] ?? 0, holder.heldMs)
                namedIn[holder.operation, default: 0] += 1
            }
        }
        return byOperation.map { operation, holds in
            Holds(
                operation: operation, holds: holds.count, maxMs: holds.values.max() ?? 0,
                totalMs: holds.values.reduce(0, +), namedIn: namedIn[operation] ?? 0
            )
        }.sorted { $0.maxMs > $1.maxMs }
    }
}
