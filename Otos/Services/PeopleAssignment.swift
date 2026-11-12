import Foundation
import OSLog

/// People Assignment guide
///
/// This actor owns who every face is (ADR 0047, `docs/design/people.md`): it gives each face
/// its most likely person, writes Otos's guesses into the catalog, and publishes the People
/// gallery and the tally of photos not yet checked. They are a fact about the whole catalog,
/// not about what the window shows, so like the duplicate groups they have their own owner
/// and their own loop: the window's publication never waits for an assignment, and a change
/// of scope, filter or sort never starts one.
///
/// `CatalogProjection` asks for a pass with `request()` after a publication that took up a
/// catalog change; every act on faces or people is one (`CatalogStore.perform(_:)`), and so
/// is every enrichment batch that reads faces. A request only adds to `requested`; a pass
/// records the value it started from and covers exactly that when it succeeds, so a request
/// made while a pass runs is never lost and runs next (ADR 0032). One loop task runs every
/// pass off a `bufferingNewest(1)` doorbell, so passes never overlap.
///
/// A pass reads the catalog through the Store in one transaction, assigns off this actor
/// (`@concurrent`, `FaceAssignmentPolicy`), and writes what changed (`applyAssignment`).
/// Assignment is rebuilt from the user's word and the seeds alone, so run on its own output
/// it changes nothing: a pass that wrote asks for one more, which reads what it wrote and
/// publishes. A pass that wrote nothing publishes what it read. The store writes a guess only
/// where the face is still Otos's to decide, so an act made while a pass runs always wins.
///
/// What a published pass read is kept (`snapshot`, `ranker`) to answer which people the
/// faces of the selected photos could be (`candidates(for:)`) without another read.
///
/// A failed pass publishes nothing and leaves its request outstanding for the next request
/// to retry. `stop()` is teardown: it ends both streams, so the loop and the consumer end
/// with them.
actor PeopleAssignment {
    typealias Builder = @Sendable (CatalogStore, [CatalogLibraryState]) async throws -> CatalogPeopleState

    /// Built states, each differing from the one before; only the newest matters. One
    /// consumer: `CatalogProjection`.
    nonisolated let builds: AsyncStream<CatalogPeopleState>
    private nonisolated let buildsContinuation: AsyncStream<CatalogPeopleState>.Continuation
    private nonisolated let bell: AsyncStream<Void>
    private nonisolated let doorbell: AsyncStream<Void>.Continuation
    private let store: CatalogStore
    /// Tests replace the pass to hold it at its suspension; production assigns.
    private let builder: Builder?
    /// Bumped by every request. Nothing decrements or clears it.
    private var requested: UInt64 = 0
    /// The `requested` value the last successful pass started from.
    private var covered: UInt64 = 0
    private var runningPasses = 0
    private var published: CatalogPeopleState?
    /// What the last published pass read, for `candidates(for:)`.
    private var snapshot: PeopleSnapshot?
    private var ranker = FaceRanker.empty
    private var loopTask: Task<Void, Never>?

    /// True when every request has been covered by a successful pass and none is running.
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

    /// The catalog may have changed: People is owed a pass.
    func request() {
        requested &+= 1
        doorbell.yield()
    }

    /// Teardown, callable from anywhere: ends the loop and the stream of builds.
    nonisolated func stop() {
        doorbell.finish()
        buildsContinuation.finish()
    }

    /// The people each face of `photos` could be, from the last published pass: a hidden
    /// person's face is not ranked, and a hidden person is never a candidate.
    func candidates(for photos: [MediaAssetID]) async -> [FaceID: [FaceCandidate]] {
        guard let snapshot, let published else {
            return [:]
        }
        return await Self.candidates(for: photos, snapshot: snapshot, state: published, ranker: ranker)
    }

    private func pass() async {
        guard requested != covered else {
            return
        }
        runningPasses += 1
        defer { runningPasses -= 1 }
        let startedFrom = requested
        let outcome: Outcome
        do {
            // Before the catalog's first load there is nothing to assign; the load is a
            // catalog change, so a request follows it.
            guard let libraries = await store.loadedLibraries() else {
                return
            }
            if let builder {
                outcome = try await .publish(builder(store, libraries), nil, .empty)
            } else {
                outcome = try await Self.run(store: store, libraries: libraries)
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            return
        } catch {
            OtosLog.catalog.errorOperation("people.assignment", phase: "failed", fields: [
                "error": String(describing: error),
            ])
            return
        }
        // Synchronous from here: nothing interleaves between covering the request and
        // publishing what covers it.
        covered = startedFrom
        switch outcome {
        case let .publish(built, read, ranker):
            if let read {
                snapshot = read
                self.ranker = ranker
            }
            if built != published {
                published = built
                buildsContinuation.yield(built)
            }
        case .wrote:
            // The next pass reads what this one wrote and publishes it.
            requested &+= 1
        }
        if requested != covered {
            doorbell.yield()
        }
    }

    enum Outcome {
        /// The catalog holds the assignment: publish it, with what was read.
        case publish(CatalogPeopleState, PeopleSnapshot?, FaceRanker)
        /// The pass wrote; the next one publishes.
        case wrote
    }
}

extension PeopleAssignment {
    /// One pass over the available fixed libraries: read, assign, write what changed.
    /// Internal for the tests and benchmarks that run passes without the loop.
    static func run(store: CatalogStore, libraries: [CatalogLibraryState]) async throws -> Outcome {
        let signpost = OtosSignpost.performance.beginInterval("PeopleAssignment")
        defer { OtosSignpost.performance.endInterval("PeopleAssignment", signpost) }
        let start = ContinuousClock.now
        let snapshot = try await store.peopleSnapshot(availableLibraryPaths: CatalogWindowPolicy.availablePaths(from: libraries))
        let readMs = DiagnosticsTiming.milliseconds(since: start)
        let assignStart = ContinuousClock.now
        let plan = await assign(snapshot)
        let assignMs = DiagnosticsTiming.milliseconds(since: assignStart)
        let written = try await store.applyAssignment(plan)
        OtosLog.catalog.debugOperation("people.assignment", phase: written > 0 ? "wrote" : "settled", fields: [
            "faces": "\(snapshot.faces.count)",
            "people": "\(snapshot.people.count)",
            "guesses": "\(plan.guesses.count)",
            "newPeople": "\(plan.newPeople.count)",
            "rows": "\(written)",
            "readMs": "\(readMs)",
            "assignMs": "\(assignMs)",
        ])
        guard written == 0 else {
            return .wrote
        }
        let built = await derive(snapshot)
        return .publish(built.state, snapshot, built.ranker)
    }

    /// Assignment, off the actor.
    @concurrent
    private static func assign(_ snapshot: PeopleSnapshot) async -> FaceAssignmentPlan {
        let result = FaceAssignmentPolicy.assign(faces: snapshot.faces, people: snapshot.personFacts)
        return FaceAssignmentPlan.changes(from: snapshot, to: result)
    }

    /// The gallery and the ranker, off the actor.
    @concurrent
    private static func derive(_ snapshot: PeopleSnapshot) async -> (state: CatalogPeopleState, ranker: FaceRanker) {
        let state = PeopleStateBuilder.state(from: snapshot)
        let offered = Set(state.visiblePeople.map(\.id))
        return (state, FaceRanker(faces: snapshot.faces, people: snapshot.personFacts, offered: offered))
    }

    /// The faces of the selected photos most likely to need ranking: at most this many faces
    /// are ranked, the first in path order, so selecting a whole library stays quick; the
    /// rest show without candidates.
    static let rankedFaceLimit = 256

    @concurrent
    private static func candidates(
        for photos: [MediaAssetID],
        snapshot: PeopleSnapshot,
        state: CatalogPeopleState,
        ranker: FaceRanker
    ) async -> [FaceID: [FaceCandidate]] {
        let wanted = Set(photos)
        let hidden = Set(state.hiddenPeople.map(\.id))
        let faces = snapshot.faces.filter { face in
            wanted.contains(face.id.asset) && !face.isNotFace && !(face.assignment.person.map(hidden.contains) ?? false)
        }
        var photoPeople: [MediaAssetID: Set<PersonID>] = [:]
        for face in snapshot.faces where wanted.contains(face.id.asset) && !face.isNotFace {
            if let person = face.assignment.person {
                photoPeople[face.id.asset, default: []].insert(person)
            }
        }
        let ranked = faces.sorted { FaceAssignmentPolicy.pathOrder($0.id, $1.id) }.prefix(rankedFaceLimit)
        return ranker.candidates(for: Array(ranked), photoPeople: photoPeople)
    }
}

/// People state builder guide
///
/// Turns a `PeopleSnapshot` into the People gallery. Pure: the same snapshot always gives the
/// same state, so it is tested without a catalog.
/// - **A person:** every face with them, whoever gave it; the count is their photos; the
///   cover is the key photo the user chose, else the newest face.
/// - **Order:** favourites first, then most photos, then the name in the locale's order;
///   hidden people after everyone else, in the same order. A person with no face at all is
///   shown only when the user said something about them (a name, a birthday, a favourite,
///   hidden): a person Otos found and the user never touched is gone with their last face.
nonisolated enum PeopleStateBuilder {
    static func state(from snapshot: PeopleSnapshot) -> CatalogPeopleState {
        let usable = snapshot.faces.filter { !$0.isNotFace }
        var faces: [PersonID: [FaceTile]] = [:]
        var userFaces: [PersonID: [FaceTile]] = [:]
        var anchorPhotos: [PersonID: Set<MediaAssetID>] = [:]
        for face in usable {
            guard let person = face.assignment.person, let tile = snapshot.tiles[face.id] else { continue }
            faces[person, default: []].append(tile)
            if case .user = face.assignment {
                userFaces[person, default: []].append(tile)
            }
            if face.assignment.isAnchor {
                anchorPhotos[person, default: []].insert(face.id.asset)
            }
        }
        let hidden = Set(snapshot.people.filter(\.isHidden).map(\.id))
        var photoFaces: [MediaAssetID: [PhotoFace]] = [:]
        for face in usable {
            guard let tile = snapshot.tiles[face.id] else { continue }
            if let person = face.assignment.person, hidden.contains(person) {
                continue
            }
            photoFaces[face.id.asset, default: []].append(PhotoFace(tile: tile, person: face.assignment.person))
        }
        let people = snapshot.people.compactMap { person -> PersonSummary? in
            let own = (faces[person.id] ?? []).sorted(by: newestFirst)
            guard !own.isEmpty || !person.isBare else { return nil }
            let keyPhoto = snapshot.keyPhotos[person.id].flatMap { id in own.first { $0.id == id } }
            return PersonSummary(
                id: person.id,
                name: person.name,
                birthday: person.birthday,
                isHidden: person.isHidden,
                isFavorite: person.isFavorite,
                photoCount: Set(own.map { snapshot.photoOfStackMember[$0.id.asset] ?? $0.id.asset }).count,
                cover: keyPhoto ?? own.first,
                userFaces: (userFaces[person.id] ?? []).sorted(by: newestFirst),
                anchorPhotos: anchorPhotos[person.id] ?? []
            )
        }.sorted(by: galleryOrder)
        return CatalogPeopleState(
            people: people,
            photoFaces: photoFaces,
            uncheckedPhotoCount: snapshot.uncheckedPhotoCount,
            faceCount: usable.count,
            revision: snapshot.revision
        )
    }

    static func galleryOrder(_ lhs: PersonSummary, _ rhs: PersonSummary) -> Bool {
        if lhs.isHidden != rhs.isHidden {
            return !lhs.isHidden
        }
        if lhs.isFavorite != rhs.isFavorite {
            return lhs.isFavorite
        }
        if lhs.photoCount != rhs.photoCount {
            return lhs.photoCount > rhs.photoCount
        }
        // A named person before an unnamed one of the same count, then by name.
        if (lhs.name == nil) != (rhs.name == nil) {
            return lhs.name != nil
        }
        let order = lhs.displayName.localizedStandardCompare(rhs.displayName)
        if order != .orderedSame {
            return order == .orderedAscending
        }
        return lhs.id < rhs.id
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
            FaceAssignmentPolicy.pathOrder(lhs.id, rhs.id)
        }
    }
}
