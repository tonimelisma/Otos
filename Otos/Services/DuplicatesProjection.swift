import Foundation
import OSLog

/// Duplicates Projection guide
/// This actor owns the catalog's duplicate groups (ADR 0042): identical copies by digest,
/// then versions of the same photo. The groups are a fact about the whole catalog, not about
/// what the window shows, so they have their own owner and their own loop: the window's
/// publication never waits for a build, and a change of scope, filter or sort never starts
/// one.
///
/// `CatalogProjection` asks for a build with `request()` after a publication that took up a
/// catalog change of a kind the groups are built from (`inputs`), so requests arrive no faster than the window's own cadence for store
/// changes. A request only adds to `requested`; a pass records the value it started from
/// and covers exactly that when its build succeeds, so a request made while a build runs is
/// never lost and runs next (ADR 0032). One loop task runs every pass off a
/// `bufferingNewest(1)` doorbell, so builds never overlap. A build reads the catalog
/// through the Store, then compares pixels off this actor (`@concurrent`), so a `request()`
/// never waits behind the comparison.
///
/// A failed build publishes nothing and leaves its request outstanding for the next
/// request to retry. `stop()` is teardown: it ends both streams, so the loop and the
/// consumer end with them. Every build whose groups differ from the last published ones is
/// yielded on `builds`, which `CatalogProjection` merges into the window state.
actor DuplicatesProjection {
    typealias Builder = @Sendable (CatalogStore, [CatalogLibraryState]) async throws -> CatalogDuplicatesState

    /// What the groups are built from, so `CatalogProjection` asks for a build only when one
    /// of these moved: which rows are shown and which movies a Live Photo hides; digests,
    /// render signatures and the pairs kept together; and the facts a group's copies are
    /// compared and listed by — kind, capture date, the record's dimensions, camera and
    /// instant, the user's choice, and the images a signature is current for and the edit
    /// they show. Faces, places, search readings and enrichment's own stamps are not among
    /// them.
    static let inputs: CatalogChangedFacts = [
        .membership, .grouping, .copies, .kindAndFormat, .captureDate, .mediaRecord, .choices, .images,
    ]

    /// Built groups, each differing from the one before; only the newest matters. One
    /// consumer: `CatalogProjection`.
    nonisolated let builds: AsyncStream<CatalogDuplicatesState>
    private nonisolated let buildsContinuation: AsyncStream<CatalogDuplicatesState>.Continuation
    private nonisolated let bell: AsyncStream<Void>
    private nonisolated let doorbell: AsyncStream<Void>.Continuation
    private let store: CatalogStore
    /// Tests replace the build to hold it at its suspension; production builds the groups.
    private let builder: Builder?
    /// Bumped by every request. Nothing decrements or clears it.
    private var requested: UInt64 = 0
    /// The `requested` value the last successful build started from.
    private var covered: UInt64 = 0
    private var runningPasses = 0
    private var published: CatalogDuplicatesState?
    private var loopTask: Task<Void, Never>?

    /// True when every request has been covered by a successful build and none is running.
    /// Lets a test wait for settlement instead of guessing a sleep duration.
    var isQuiescent: Bool {
        requested == covered && runningPasses == 0
    }

    init(store: CatalogStore, builder: Builder?) {
        self.store = store
        self.builder = builder
        (builds, buildsContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (bell, doorbell) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// Starts the loop. It holds this owner weakly and ends when the doorbell finishes.
    func start() {
        guard loopTask == nil else {
            return
        }
        let bell = bell
        loopTask = Task { [weak self] in
            for await _ in bell {
                guard let self else {
                    return
                }
                await pass()
            }
        }
    }

    /// The catalog may have changed: the groups are owed a build.
    func request() {
        requested &+= 1
        doorbell.yield()
    }

    /// Teardown, callable from anywhere: ends the loop and the stream of builds. A build in
    /// flight finishes, and what it yields goes nowhere.
    nonisolated func stop() {
        doorbell.finish()
        buildsContinuation.finish()
    }

    private func pass() async {
        guard requested != covered else {
            return
        }
        runningPasses += 1
        defer { runningPasses -= 1 }
        let startedFrom = requested
        let built: CatalogDuplicatesState
        do {
            // Before the catalog's first load there is nothing to build; the load is a
            // catalog change, so a request follows it.
            guard let libraries = await store.loadedLibraries() else {
                return
            }
            if let builder {
                built = try await builder(store, libraries)
            } else {
                built = try await Self.build(store: store, libraries: libraries)
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            return
        } catch {
            OtosLog.catalog.errorOperation("duplicates.build", phase: "failed", fields: [
                "error": String(describing: error),
            ])
            return
        }
        // Synchronous from here: nothing interleaves between covering the request and
        // publishing what covers it.
        covered = startedFrom
        if built != published {
            published = built
            buildsContinuation.yield(built)
        }
        if requested != covered {
            doorbell.yield()
        }
    }
}

extension DuplicatesProjection {
    /// Duplicate groups in the available fixed libraries — within each, or across them, as
    /// the Store's reach says: identical copies by digest, then versions of the same photo
    /// among the rest.
    static func build(store: CatalogStore, libraries: [CatalogLibraryState]) async throws -> CatalogDuplicatesState {
        let signpost = OtosSignpost.performance.beginInterval("DuplicatesBuild")
        defer { OtosSignpost.performance.endInterval("DuplicatesBuild", signpost) }
        let start = ContinuousClock.now
        let availableLibraryPaths = CatalogWindowPolicy.availablePaths(from: libraries)
        let duplicates = try await store.duplicateCopies(availableLibraryPaths: availableLibraryPaths)
        let identical = DuplicateGroupPolicy.groups(
            copies: duplicates.copies, keptPairs: duplicates.keptPairs, reach: duplicates.reach
        )
        let identicalMs = DiagnosticsTiming.milliseconds(since: start)

        let candidatesStart = ContinuousClock.now
        let candidates = try await store.samePhotoCandidates(availableLibraryPaths: availableLibraryPaths)
        let pairs = await proposePairs(
            candidates, excluding: Set(identical.flatMap(\.copies).map(\.id)), reach: duplicates.reach
        )
        let candidatesMs = DiagnosticsTiming.milliseconds(since: candidatesStart)

        let detailsStart = ContinuousClock.now
        let involved = Array(Set(pairs.flatMap { [$0.left.id, $0.right.id] }))
        let details = pairs.isEmpty ? [:] : try await store.samePhotoDetails(for: involved)
        let detailsMs = DiagnosticsTiming.milliseconds(since: detailsStart)

        let compareStart = ContinuousClock.now
        let samePhoto = await samePhotoGroups(pairs: pairs, details: details, keptPairs: duplicates.keptPairs)
        let compareMs = DiagnosticsTiming.milliseconds(since: compareStart)

        let groups = identical + samePhoto
        let state = CatalogDuplicatesState(groups: groups)
        OtosLog.catalog.debugOperation("duplicates.groups", phase: "built", fields: [
            "copies": "\(groups.reduce(0) { $0 + $1.copies.count })",
            "groups": "\(groups.count)",
            "kept": "\(state.keptGroups.count)",
            "preselected": "\(groups.count { !$0.isKept && $0.defaultKeep != nil })",
            "waiting": "\(groups.count { !$0.isKept && $0.defaultKeep == nil })",
            "samePhoto": "\(samePhoto.count)",
            "reach": "\(duplicates.reach)",
            "choose": "\(state.layout.choose.count)",
            "different": "\(state.layout.different.count)",
            "folders": "\(state.layout.buckets.count)",
            "stills": "\(candidates.count)",
            "pairs": "\(pairs.count)",
            "detailed": "\(details.count)",
            "identicalMs": "\(identicalMs)",
            "candidatesMs": "\(candidatesMs)",
            "detailsMs": "\(detailsMs)",
            "compareMs": "\(compareMs)",
            "totalMs": "\(DiagnosticsTiming.milliseconds(since: start))",
        ])
        return state
    }

    /// The column pass over every still, off the actor: a file without capture metadata is
    /// tested against its whole aspect bucket.
    @concurrent
    private static func proposePairs(
        _ candidates: [SamePhotoCandidate],
        excluding excluded: Set<MediaAssetID>,
        reach: DuplicatesReach
    ) async -> [SamePhotoPair] {
        SamePhotoPolicy.candidatePairs(candidates, excluding: excluded, reach: reach)
    }

    /// Versions of the same photo from the proposed pairs, off the actor. A group the user
    /// kept whole is set aside like an identical one.
    @concurrent
    private static func samePhotoGroups(
        pairs: [SamePhotoPair],
        details: [MediaAssetID: SamePhotoDetail],
        keptPairs: Set<DuplicateKeptPair>
    ) async -> [DuplicateGroup] {
        SamePhotoPolicy.groups(pairs: pairs, details: details, keptPairs: keptPairs)
    }
}
