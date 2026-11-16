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
/// `windowReadsAreAnsweredWhileEveryBackgroundOwnerRuns` states the requirement: while every
/// background owner runs, a window read is answered as soon as it would be on a quiet
/// catalog, and a background owner's read visits rows in proportion to what it owes, not to
/// the library. The current design fails both, so the assertions are a known issue until a
/// design lands that passes them; the test runs at the owner's size only on demand
/// (`OTOS_SCALE_TEST=1 script/check.sh --only StallReproductionTests`), because building a
/// 2.4 GB catalog is not a per-PR cost. The small variant runs in every check and proves the
/// generator's backlog and the measurement themselves.
@Suite(.testDirectory, .serialized)
struct StallReproductionTests {
    /// Xcode's scheme always defines the key, empty unless the build-setting override is
    /// passed (`ProjectionEnrichmentScaleTests`), so the value is what is checked.
    static let ownerSize = ProcessInfo.processInfo.environment["OTOS_SCALE_TEST"] == "1"

    /// A window read may take this much longer while the background owners run than on the
    /// quiet catalog: their work shares the Mac's cores and disk, never a connection.
    /// time: measurement — a bound on a measured answer time; nothing waits on it.
    static let windowReadAllowance: Duration = .milliseconds(250)
    /// A background read visits at most this many rows for each row it returns or asks for.
    static let visitsPerOwedRow = 4

    /// The generated catalog holds the backlog it says it does, as the Store's own candidate
    /// reads count it.
    @Test func theGeneratedCatalogHoldsTheOwnersBacklog() async throws {
        let catalog = try OwnerShapedCatalog.make(in: makeTestDirectory(), scale: 0.01)
        let store = CatalogStore(location: .databaseFile(catalog.databaseURL))
        try await store.start(scansSavedLibraries: false)
        let libraries = try #require(await store.loadedLibraries())
        let available = CatalogWindowPolicy.availablePaths(from: libraries)
        #expect(available == [catalog.pictures, catalog.archive, catalog.account])

        let shape = catalog.shape
        #expect(try await store.catalogedAssetCount(for: .allMedia) > 0)
        #expect(try await store.searchEmbeddingPendingCount() == shape.embeddingsOwed)
        #expect(try await store.renderSignatureCandidates(limit: 1000).candidates.count == shape.renderSignaturesOwed)
        #expect(try await store.searchTextCandidates(limit: shape.assets).candidates.count == shape.textsOwed)
        #expect(try await store.metadataRefreshCandidates(after: nil, limit: shape.assets).count == shape.metadataStaleInLibraries)
        #expect(try await !store.photoDescriptionCandidates(limit: 16).candidates.isEmpty)
        #expect(shape.unhashable > shape.assets / 2, "the account and most of a OneDrive library are never hashed")
        let probes = try await store.mirrorProbes(account: catalog.account)
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
        #expect(unanswered.isEmpty, "\(unanswered.count) window reads failed")
        try StallReproduction.write(report.summary(catalog), named: "small")
    }

    /// The requirement at the owner's size: window reads answered as on a quiet catalog while
    /// every background owner runs, and background reads that visit what they owe.
    @Test(.enabled(if: ownerSize))
    func windowReadsAreAnsweredWhileEveryBackgroundOwnerRuns() async throws {
        let directory = try makeTestDirectory()
        let catalog = try OwnerShapedCatalog.make(in: directory, scale: 1)
        let report = try await StallReproduction.measure(catalog, in: directory, rounds: 3, readsStallLines: true)
        try StallReproduction.write(report.summary(catalog), named: "owner")
        let unanswered = report.live.filter { !$0.answered }
        #expect(unanswered.isEmpty, "\(unanswered.count) window reads failed")

        // A background read not named below visits rows in proportion to what it returns or
        // asks for; that holds outside the known issue, so a regression of one fails.
        for read in report.quiet where !read.isWindowRead && !StallReproduction.libraryVisitingReads.contains(read.name) {
            #expect(
                read.visitedRows <= Self.visitsPerOwedRow * max(read.returned, read.limit),
                "\(read.name) visited \(read.visitedRows) rows to return \(read.returned)"
            )
        }
        withKnownIssue(
            "Open defect: background owners hold the main pool's readers; libraryVisitingReads still visit every row they read"
        ) {
            for read in report.live {
                let quiet = try #require(report.quietWindow["\(read.name)@\(read.scope)"])
                #expect(
                    read.answer <= quiet + Self.windowReadAllowance,
                    "\(read.name) of \(read.scope): \(read.answer) live, \(quiet) quiet"
                )
            }
            let waitedWindowReads = report.stalls.filter { StallReproduction.windowOperations.contains($0.operation) }
            #expect(waitedWindowReads.isEmpty, "\(waitedWindowReads.count) window reads waited a second or more")
            for read in report.quiet where StallReproduction.libraryVisitingReads.contains(read.name) {
                #expect(
                    read.visitedRows <= Self.visitsPerOwedRow * max(read.returned, read.limit),
                    "\(read.name) visited \(read.visitedRows) rows to return \(read.returned)"
                )
            }
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
    /// The background reads that still visit every row of the roots they read to find what
    /// they owe, whatever they return: what is owed is decided by comparing a derived row's
    /// source with its asset across two tables, or the read is a whole-set read by nature.
    /// Each walk now runs once per drain rather than once per page (plan 0116 stage 1).
    static let libraryVisitingReads: Set<String> = [
        "searchEmbeddingCandidates", "searchEmbeddingCandidates.drain",
        "searchTextCandidates",
        "photoDescriptionCandidates",
        "unnamedPlaceCells", "duplicateCopies", "peopleSnapshot", "mirrorProbes",
        // A record is stale by its family's revision, which a MediaMetadata release moves, so
        // no index can hold the stale ones without a migration per release (ADR 0039): the
        // refresher's cursor walks its libraries' rows once per pass.
        "metadataRefreshCandidates",
    ]
    static let scopeCount = 5
    /// The visible tiles a scope change reads the details of.
    static let visibleTiles = 60

    struct QuietRead {
        let name: String
        let limit: Int
        let returned: Int
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
        let store = CatalogStore(location: .databaseFile(catalog.databaseURL))
        try await store.start(scansSavedLibraries: false)
        let visits = StatementVisits()
        try await visits.install(on: store)
        let libraries = try #require(await store.loadedLibraries())
        let available = CatalogWindowPolicy.availablePaths(from: libraries)
        let language = PlaceNameLanguage(Locale.current)

        func replay(_ name: String, limit: Int = 0, scope: SidebarSelection? = nil, _ read: () async throws -> Int) async throws {
            visits.reset()
            let start = ContinuousClock.now
            let returned = try await read()
            let answer = start.duration(to: .now)
            let counted = visits.take()
            report.quiet.append(QuietRead(
                name: name, limit: limit, returned: returned, answer: answer,
                visitedRows: counted.byLoop.values.reduce(0, +), visitedByLoop: counted.byLoop, sorts: counted.sorts
            ))
            if report.quiet.last?.isWindowRead == true {
                report.quietWindow["\(name)@\(scope.map { String(describing: $0) } ?? "")"] = answer
            }
        }

        // The background owners' reads, each with its owner's page size.
        try await replay("renderSignatureCandidates", limit: 128) { try await store.renderSignatureCandidates(limit: 128).candidates.count }
        try await replay("searchEmbeddingCandidates", limit: 16) { try await store.searchEmbeddingCandidates(limit: 16).candidates.count }
        try await replay("searchTextCandidates", limit: 8) { try await store.searchTextCandidates(limit: 8).candidates.count }
        try await replay("photoDescriptionCandidates", limit: 16) { try await store.photoDescriptionCandidates(limit: 16).candidates.count }
        // One drain is one walk (plan 0116): each owner's whole walk, page after page, as its
        // drain asks for it.
        try await replay("renderSignatureCandidates.drain", limit: 128) {
            try await walk { try await store.renderSignatureCandidates(after: $0, limit: 128) }
        }
        try await replay("searchEmbeddingCandidates.drain", limit: 16) {
            try await walk { try await store.searchEmbeddingCandidates(after: $0, limit: 16) }
        }
        try await replay("searchTextCandidates.drain", limit: 8) {
            try await walk { try await store.searchTextCandidates(after: $0, limit: 8) }
        }
        try await replay("previewFaceCandidates", limit: 32) { try await store.previewFaceCandidates(limit: 32).candidates.count }
        try await replay("metadataRefreshCandidates", limit: 64) {
            try await store.metadataRefreshCandidates(after: nil, limit: 64).count
        }
        try await replay("unnamedPlaceCells", limit: 32) { try await store.unnamedPlaceCells(language: language, limit: 32).count }
        // The search index's first load: every stored embedding, a page of 2,000 at a time.
        try await replay("searchEmbeddingRows.load", limit: PhotoSearchIndex.loadPageSize) {
            try await walk { try await store.searchEmbeddingRows(after: $0, limit: PhotoSearchIndex.loadPageSize) }
        }
        try await replay("currentSearchEmbeddingIDs") { try await store.currentSearchEmbeddingIDs().ids.count }
        try await replay("currentSearchTextIDs") { try await store.currentSearchTextIDs().ids.count }
        var involved: [MediaAssetID] = []
        try await replay("samePhotoCandidates") {
            let candidates = try await store.samePhotoCandidates(availableLibraryPaths: available)
            involved = candidates.prefix(visibleTiles).map(\.id)
            return candidates.count
        }
        try await replay("samePhotoDetails", limit: involved.count) { try await store.samePhotoDetails(for: involved).count }
        try await replay("duplicateCopies") { try await store.duplicateCopies(availableLibraryPaths: available).copies.count }
        try await replay("peopleSnapshot") { try await store.peopleSnapshot(availableLibraryPaths: available).faces.count }
        try await replay("mirrorProbes") { try await store.mirrorProbes(account: catalog.account).reduce(0) { $0 + $1.candidates.count } }

        // The window's reads for each scope change.
        for scope in try await scopes(catalog, store: store) {
            var ids: [MediaAssetID] = []
            try await replay("orderedAssetIDs", scope: scope) {
                ids = try await store.orderedAssetIDs(for: CatalogQueryDescriptor(scope: scope), availableLibraryPaths: available).ids
                return ids.count
            }
            try await replay("filterOptions", scope: scope) {
                try await store.filterOptions(for: scope, availableLibraryPaths: available, placeNameLanguages: [language])
                    .formatsByKind.count
            }
            try await replay("importBatches", scope: scope) { try await store.importBatches(counting: .newest(20, and: nil)).count }
            let visible = Array(ids.prefix(visibleTiles))
            try await replay("mediaTileDetails", limit: visible.count, scope: scope) { try await store.mediaTileDetails(for: visible).count }
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
        let batch = try #require(try await store.importBatches(counting: .newest(1, and: nil)).first)
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
        let store = CatalogStore(location: .databaseFile(catalog.databaseURL))
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

        let materializer = MaterializationCoordinator(
            store: store,
            executor: { _ in MaterializationResult(outcome: .requestFailed, rerequestCount: 0, elapsedMs: 0) },
            volumeCapacity: ampleVolumeCapacity,
            status: { _ in .dataless }
        )
        let enrichment = EnrichmentCoordinator(
            store: store,
            enricher: MediaEnricher { _, _, _, _, _, _ in .notMaterialized },
            materializationRequester: materializer
        )
        let renderSignatures = RenderSignatureRefresher(store: store, thumbnailDirectory: thumbnails)
        let previewFaces = PreviewFaceReader(store: store, thumbnailDirectory: thumbnails) { _ in throw CocoaError(.featureUnsupported) }
        let placeNames = PlaceNameReader(store: store, namer: PlaceNameReader.Namer { _, _ in .none })
        // The test bundle holds no search model, so no embedding is made, as on a Mac whose
        // model is still loading; every read before the model runs as in the app.
        let searchIndex = PhotoSearchIndex(
            store: store,
            thumbnailDirectory: thumbnails,
            bundle: Bundle(for: BundleMarker.self),
            textReader: SearchTextReader { RecognizingSession { _ in [] } }
        )
        let descriptions = PhotoDescriptionWriter(
            store: store, thumbnailDirectory: thumbnails
        ) { _, _ in throw CocoaError(.featureUnsupported) }
        let metadata = MetadataRefresher(store: store) { _ in .unreachable }
        // Duplicates and People run under the projection, which also reads All Media's order.
        let projection = CatalogProjection()
        let states = await projection.states(store: store, initialDescriptor: .default)
        let projectionTask = Task {
            for await _ in states {}
        }

        let liveStart = ContinuousClock.now
        await materializer.start()
        await enrichment.start()
        await renderSignatures.start()
        await previewFaces.start()
        await placeNames.start()
        await searchIndex.start()
        await descriptions.start()
        let metadataTask = Task { await metadata.refresh() }
        // An account's sync probes for mirrors once at launch (`ImmichCatalogSync`).
        let mirrorTask = Task { () -> Duration in
            let start = ContinuousClock.now
            _ = try await store.mirrorProbes(account: catalog.account)
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
        report.searchPasses = await searchIndex.passesFinished
        // Of the changes each owner heard, how many asked it for a pass.
        report.wakes = await [
            "renderSignatures": (renderSignatures.changesHeard, renderSignatures.wakes),
            "previewFaces": (previewFaces.changesHeard, previewFaces.wakes),
            "placeNames": (placeNames.changesHeard, placeNames.wakes),
            "searchIndex": (searchIndex.changesHeard, Int(searchIndex.requested)),
            "descriptions": (descriptions.changesHeard, Int(descriptions.requested)),
        ]

        await enrichment.shutdown()
        await materializer.shutdown()
        await renderSignatures.shutdown()
        await previewFaces.shutdown()
        await placeNames.shutdown()
        await searchIndex.shutdown()
        await descriptions.shutdown()
        await metadata.shutdown()
        _ = await metadataTask.value
        projectionTask.cancel()
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
            try await store.orderedAssetIDs(for: CatalogQueryDescriptor(scope: scope), availableLibraryPaths: available).ids
        }
        async let options = timed("filterOptions", scope: name) {
            try await store.filterOptions(for: scope, availableLibraryPaths: available, placeNameLanguages: [language])
        }
        async let imports = timed("importBatches", scope: name) {
            try await store.importBatches(counting: .newest(20, and: nil))
        }
        let (orderRead, ids) = await order
        let visible = Array((ids ?? []).prefix(visibleTiles))
        let (tiles, _) = await timed("mediaTileDetails", scope: name) { try await store.mediaTileDetails(for: visible) }
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
            "op=stallReproduction.live durationMs=\(ms(liveDuration)) mirrorProbeMs=\(ms(mirrorProbe)) searchPasses=\(searchPasses) phases=\(phases.sorted { $0.key < $1.key }.map { "\($0.key):\(ms($0.value))" }.joined(separator: ","))",
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

/// A class whose bundle is the test bundle, which holds no search model.
private final class BundleMarker {}

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
        let readers = 4
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
