import Foundation
import OSLog

/// People Projection guide
/// This actor owns what People shows (ADR 0047, `docs/design/people.md`): the People list,
/// the review's Suggestions and Unsure lists, and the tally of photos not yet checked. They
/// are a fact about the whole catalog, not about what the window shows, so like the duplicate
/// groups they have their own owner and their own loop: the window's publication never waits
/// for a build, and a change of scope, filter or sort never starts one.
///
/// `CatalogProjection` asks for a build with `request()` after a publication that took up a
/// catalog change; every act on faces or people is one (`CatalogStore.perform(_:)`), and so
/// is every enrichment batch that reads faces. A request only adds to `requested`; a pass
/// records the value it started from and covers exactly that when its build succeeds, so a
/// request made while a build runs is never lost and runs next (ADR 0032). One loop task
/// runs every pass off a `bufferingNewest(1)` doorbell, so builds never overlap. A build
/// reads the catalog through the Store in one transaction, then groups off this actor
/// (`@concurrent`), so a `request()` never waits behind grouping.
///
/// A failed build publishes nothing and leaves its request outstanding for the next request
/// to retry. `stop()` is teardown: it ends both streams, so the loop and the consumer end
/// with them. Every build that differs from the last published one is yielded on `builds`,
/// which `CatalogProjection` merges into the window state.
actor PeopleProjection {
    typealias Builder = @Sendable (CatalogStore, [CatalogLibraryState]) async throws -> CatalogPeopleState

    /// Built states, each differing from the one before; only the newest matters. One
    /// consumer: `CatalogProjection`.
    nonisolated let builds: AsyncStream<CatalogPeopleState>
    private nonisolated let buildsContinuation: AsyncStream<CatalogPeopleState>.Continuation
    private nonisolated let bell: AsyncStream<Void>
    private nonisolated let doorbell: AsyncStream<Void>.Continuation
    private let store: CatalogStore
    /// Tests replace the build to hold it at its suspension; production builds the state.
    private let builder: Builder?
    /// Bumped by every request. Nothing decrements or clears it.
    private var requested: UInt64 = 0
    /// The `requested` value the last successful build started from.
    private var covered: UInt64 = 0
    private var runningPasses = 0
    private var published: CatalogPeopleState?
    private var loopTask: Task<Void, Never>?

    /// True when every request has been covered by a successful build and none is running.
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

    /// The catalog may have changed: People is owed a build.
    func request() {
        requested &+= 1
        doorbell.yield()
    }

    /// Teardown, callable from anywhere: ends the loop and the stream of builds.
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
        let built: CatalogPeopleState
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
            OtosLog.catalog.errorOperation("people.build", phase: "failed", fields: [
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

extension PeopleProjection {
    /// People across the available fixed libraries.
    static func build(store: CatalogStore, libraries: [CatalogLibraryState]) async throws -> CatalogPeopleState {
        let signpost = OtosSignpost.performance.beginInterval("PeopleBuild")
        defer { OtosSignpost.performance.endInterval("PeopleBuild", signpost) }
        let start = ContinuousClock.now
        let snapshot = try await store.peopleSnapshot(availableLibraryPaths: CatalogWindowPolicy.availablePaths(from: libraries))
        let readMs = DiagnosticsTiming.milliseconds(since: start)
        let groupStart = ContinuousClock.now
        let state = await derive(snapshot)
        OtosLog.catalog.debugOperation("people.state", phase: "built", fields: [
            "people": "\(state.people.count)",
            "faces": "\(state.faceCount)",
            "suggestions": "\(state.suggestionCount)",
            "unsure": "\(state.unsureCount)",
            "unchecked": "\(state.uncheckedPhotoCount)",
            "readMs": "\(readMs)",
            "groupMs": "\(DiagnosticsTiming.milliseconds(since: groupStart))",
        ])
        return state
    }

    /// Grouping, off the actor.
    @concurrent
    private static func derive(_ snapshot: PeopleSnapshot) async -> CatalogPeopleState {
        PeopleStateBuilder.state(from: snapshot, calendar: .current)
    }
}

/// People state builder guide
///
/// Turns a `PeopleSnapshot` into what People shows. Pure: the same snapshot always gives the
/// same state, so it is tested without a catalog.
/// - **The list:** each person with their confirmed faces, newest first; most photos first,
///   then the name in the locale's order.
/// - **Suggestions:** `FacePeoplePolicy`'s suggestions, one row per person and year of the
///   face's photo, resting on the confirmed face of the row's strongest suggestion; then the
///   unnamed groups, one row per group and year.
/// - **Unsure:** one row per pair of candidates and year, with each candidate's confirmed face
///   nearest that year.
/// - **Years:** newest first; photos with no date last.
nonisolated enum PeopleStateBuilder {
    static func state(from snapshot: PeopleSnapshot, calendar: Calendar) -> CatalogPeopleState {
        let usable = snapshot.faces.filter { !$0.isNotFace }
        func tile(_ face: FaceID) -> FaceTile? {
            snapshot.tiles[face]
        }
        func year(_ tile: FaceTile) -> Int? {
            tile.captureDate.map { calendar.component(.year, from: $0) }
        }

        var confirmed: [PersonID: [FaceTile]] = [:]
        for face in usable {
            if let person = face.person, let tile = tile(face.id) {
                confirmed[person, default: []].append(tile)
            }
        }
        let people = snapshot.people.map { person in
            let faces = (confirmed[person.id] ?? []).sorted(by: newestFirst)
            return PersonSummary(
                id: person.id,
                name: person.name,
                birthday: person.birthday,
                photoCount: Set(faces.map(\.id.asset)).count,
                faces: faces
            )
        }.sorted { lhs, rhs in
            if lhs.photoCount != rhs.photoCount {
                return lhs.photoCount > rhs.photoCount
            }
            let order = lhs.displayName.localizedStandardCompare(rhs.displayName)
            if order != .orderedSame {
                return order == .orderedAscending
            }
            return lhs.id < rhs.id
        }
        let rank = Dictionary(uniqueKeysWithValues: people.enumerated().map { ($0.element.id, $0.offset) })

        let policy = FacePeoplePolicy.suggestions(faces: usable, people: snapshot.people.map(\.fact))

        // Suggestions: one row per (year, person), resting on its strongest suggestion.
        struct PersonYear: Hashable {
            let year: Int?
            let person: PersonID
        }
        var suggested: [PersonYear: [PeopleSuggestions.Suggestion]] = [:]
        for suggestion in policy.suggestions {
            guard let face = tile(suggestion.face) else { continue }
            suggested[PersonYear(year: year(face), person: suggestion.person), default: []].append(suggestion)
        }
        var suggestionRows: [Int?: [(rank: Int, size: Int, row: PeopleReviewRow)]] = [:]
        for (key, list) in suggested {
            guard let strongest = list.max(by: { $0.similarity < $1.similarity }),
                  let reference = tile(strongest.reference)
            else { continue }
            let faces = list.compactMap { tile($0.face) }.sorted(by: newestFirst)
            suggestionRows[key.year, default: []].append((
                rank[key.person] ?? Int.max,
                faces.count,
                PeopleReviewRow(kind: .person(key.person, referenceYear: year(reference)), references: [reference], faces: faces)
            ))
        }
        for group in policy.unnamedGroups {
            guard let first = group.first else { continue }
            var byYear: [Int?: [FaceTile]] = [:]
            for face in group.compactMap(tile) {
                byYear[year(face), default: []].append(face)
            }
            for (key, faces) in byYear {
                suggestionRows[key, default: []].append((
                    Int.max,
                    faces.count,
                    PeopleReviewRow(kind: .unnamed(group: first), references: [], faces: faces.sorted(by: newestFirst))
                ))
            }
        }

        // Unsure: one row per (year, pair), the pair in the People list's order.
        struct PairYear: Hashable {
            let year: Int?
            let first: PersonID
            let second: PersonID
        }
        var unsureFaces: [PairYear: [FaceTile]] = [:]
        for item in policy.unsure {
            guard let face = tile(item.face) else { continue }
            let ordered = [item.first, item.second].sorted { (rank[$0] ?? people.count, $0.rawValue) < (rank[$1] ?? people.count, $1.rawValue) }
            unsureFaces[PairYear(year: year(face), first: ordered[0], second: ordered[1]), default: []].append(face)
        }
        var unsureRows: [Int?: [(rank: Int, size: Int, row: PeopleReviewRow)]] = [:]
        for (key, faces) in unsureFaces {
            let references = [key.first, key.second].compactMap { person in
                nearest(confirmed[person] ?? [], toYear: key.year, year: year)
            }
            unsureRows[key.year, default: []].append((
                (rank[key.first] ?? people.count) * (people.count + 1) + (rank[key.second] ?? people.count),
                faces.count,
                PeopleReviewRow(kind: .unsure(key.first, key.second), references: references, faces: faces.sorted(by: newestFirst))
            ))
        }

        return CatalogPeopleState(
            people: people,
            suggestions: years(suggestionRows),
            unsure: years(unsureRows),
            uncheckedPhotoCount: snapshot.uncheckedPhotoCount,
            faceCount: usable.count
        )
    }

    /// Rows by year, newest year first and no date last; within a year in `rank` order, then
    /// largest first.
    private static func years(_ rows: [Int?: [(rank: Int, size: Int, row: PeopleReviewRow)]]) -> [PeopleReviewYear] {
        rows.map { year, rows in
            PeopleReviewYear(year: year, rows: rows.sorted { lhs, rhs in
                if lhs.rank != rhs.rank {
                    return lhs.rank < rhs.rank
                }
                if lhs.size != rhs.size {
                    return lhs.size > rhs.size
                }
                return newestFirst(lhs.row.faces[0], rhs.row.faces[0])
            }.map(\.row))
        }.sorted { ($0.year ?? Int.min) > ($1.year ?? Int.min) }
    }

    /// The confirmed face from the year nearest `target`, newest within it; the newest face
    /// when there is no target year.
    private static func nearest(_ faces: [FaceTile], toYear target: Int?, year: (FaceTile) -> Int?) -> FaceTile? {
        let sorted = faces.sorted(by: newestFirst)
        guard let target else {
            return sorted.first
        }
        return sorted.min { lhs, rhs in
            abs((year(lhs) ?? Int.min / 2) - target) < abs((year(rhs) ?? Int.min / 2) - target)
        }
    }

    /// Capture order, newest first; faces with no date last, then by photo and place.
    static func newestFirst(_ lhs: FaceTile, _ rhs: FaceTile) -> Bool {
        switch (lhs.captureSeconds, rhs.captureSeconds) {
        case let (left?, right?) where left != right:
            left > right
        case (.some, nil):
            true
        case (nil, .some):
            false
        default:
            (lhs.id.asset.relativePath.rawValue, lhs.id.asset.libraryRootPath.rawValue, lhs.id.index)
                < (rhs.id.asset.relativePath.rawValue, rhs.id.asset.libraryRootPath.rawValue, rhs.id.index)
        }
    }
}
