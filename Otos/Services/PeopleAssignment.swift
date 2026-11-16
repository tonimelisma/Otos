import Foundation
import OSLog

/// People Assignment guide
///
/// This actor owns who every face is (ADR 0047, `docs/design/people.md`): it publishes the
/// People gallery and the tally of photos not yet checked from what the catalog stores, gives
/// each face its most likely person, and writes Otos's guesses back. They are a fact about the
/// whole catalog, not about what the window shows, so like the duplicate groups they have
/// their own owner and their own loop: the window's publication never waits for People, and a
/// change of scope, filter or sort never starts a pass.
///
/// `CatalogProjection` asks for a pass with `request()` after a publication that took up a
/// catalog change of a kind People reads (`inputs`); every act on faces or people is one
/// (`CatalogStore.perform(_:)`). A request only adds to `requested`; a pass records the value
/// it started from and covers exactly that when it succeeds, so a request made while a pass
/// runs is never lost and runs next (ADR 0032). One loop task runs every pass off a
/// `bufferingNewest(1)` doorbell, so passes never overlap.
///
/// A pass has two steps, the second only when owed:
/// 1. **The gallery, from what is stored.** One read of every face's row, its tile and whose
///    word its person is — never its vector — with the people, copies, stacks and tally
///    (`CatalogStore.peopleSnapshot`). The gallery built from it is published at once, so
///    People paints from the stored assignment and never waits for one.
/// 2. **Assignment, only when its inputs moved.** What assignment reads of the snapshot is
///    hashed (`AssignmentInputs`). The catalog keeps the hash of the last inputs whose
///    assignment it holds (`CatalogStore.settledPeopleAssignment`): while the two are equal,
///    the stored guesses are assignment's output on these inputs, and nothing runs.
///    Otherwise the vectors owed are read (`FaceVectors`, held across passes), assignment runs
///    off this actor, what it changes is written in short transactions, and the hash is
///    recorded. A guess is not an input, so the pass after a write that only moved guesses
///    finds the hash equal; a write that seeded a new person, released a seed or deleted an
///    emptied person moved an input, and the next pass assigns once more and writes nothing.
///
/// What a pass read is kept, without its tiles (`lastRead`), to answer which people the faces
/// of the selected photos could be (`candidates(for:)`); the ranker is built from it and the
/// vectors on the first such question, and again after either changes.
///
/// Rows only added (`CatalogStoreChange.assetsAdded`) change who no face is: they carry no
/// face yet. They change the tally alone, so `CatalogProjection` asks for that with
/// `requestTally()`: a tally pass reads the count by itself and republishes the last state
/// with it, and a full pass covers it too.
///
/// A failed pass leaves its request outstanding for the next request to retry; what it
/// published before failing stays published, since it is what the catalog holds. `stop()` is
/// teardown: it ends both streams, so the loop and the consumer end with them.
actor PeopleAssignment {
    typealias Builder = @Sendable (CatalogStore, [CatalogLibraryState]) async throws -> CatalogPeopleState

    /// What the People snapshot reads (`CatalogStore.peopleSnapshot`), so `CatalogProjection`
    /// asks for a pass only when one of these moved: the faces, who they are and which photos
    /// are checked for them; which rows are shown and which movies a Live Photo hides; the
    /// stacks a face's photo stands for and the copies it is one of (ADR 0052, 0054); a face's
    /// capture date; and the image its tile is cut from. A pass that only rebuilds the gallery
    /// costs one read: assignment runs only when what it reads moved.
    static let inputs: CatalogChangedFacts = [
        .faces, .membership, .grouping, .kindAndFormat, .captureDate, .choices, .images, .copies, .stacks,
    ]

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
    /// Bumped by every request for the unchecked tally alone; a full pass covers it too.
    private var tallyRequested: UInt64 = 0
    /// The `tallyRequested` value the last successful pass of either kind started from.
    private var tallyCovered: UInt64 = 0
    private var runningPasses = 0
    private var published: CatalogPeopleState?
    /// What the last pass read, without its tiles, for `candidates(for:)`.
    private var lastRead: PeopleSnapshot?
    /// Every face's vector read so far; read on the first assignment or ranking that needs it.
    private var vectors = FaceVectors()
    /// The ranker over `lastRead` and `vectors`; nil until asked for, and after either changes.
    private var ranker: FaceRanker?
    /// The inputs whose assignment the catalog holds; read from the catalog by the first pass.
    private var settled: AssignmentInputs?
    private var loopTask: Task<Void, Never>?

    /// True when every request has been covered by a successful pass and none is running.
    var isQuiescent: Bool {
        requested == covered && tallyRequested == tallyCovered && runningPasses == 0
    }

    /// Runs each full pass one heavy load at a time with the other owners' (`LoadAdmission`).
    private let admission: LoadAdmission

    init(store: CatalogStore, builder: Builder?, admission: LoadAdmission = LoadAdmission(isOpen: true)) {
        self.store = store
        self.builder = builder
        self.admission = admission
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

    /// The catalog may have changed: People is owed a pass. Returns the request, which every
    /// state built by a pass that started after it carries as `covers`.
    @discardableResult
    func request() -> UInt64 {
        requested &+= 1
        doorbell.yield()
        return requested
    }

    /// Rows were only added: the unchecked tally is owed a read, and nothing else.
    func requestTally() {
        tallyRequested &+= 1
        doorbell.yield()
    }

    /// Teardown, callable from anywhere: ends the loop and the stream of builds.
    nonisolated func stop() {
        doorbell.finish()
        buildsContinuation.finish()
    }

    /// The people each face of `photos` could be, from the last pass's read: a hidden
    /// person's face is not ranked, and a hidden person is never a candidate. The vectors owed
    /// are read first; a failed read ranks nothing, and is logged.
    func candidates(for photos: [MediaAssetID]) async -> [FaceID: [FaceCandidate]] {
        guard let read = lastRead else {
            return [:]
        }
        do {
            try await syncVectors(for: read)
        } catch {
            OtosLog.catalog.errorOperation("people.candidates", phase: "vectorsFailed", fields: [
                "error": String(describing: error),
            ])
            return [:]
        }
        // The read and the state may have moved while the vectors were read: rank what is
        // held now, from values taken in this synchronous step.
        guard let current = lastRead, let state = published else {
            return [:]
        }
        let ranker = ranker ?? Self.ranker(read: current, vectors: vectors, state: state)
        self.ranker = ranker
        return await Self.candidates(for: photos, read: current, vectors: vectors, state: state, ranker: ranker)
    }

    /// A full pass when one is owed, which reads the tally too; else a tally pass.
    private func pass() async {
        if requested != covered {
            await fullPass()
        } else if tallyRequested != tallyCovered {
            await tallyPass()
        }
    }

    private func fullPass() async {
        runningPasses += 1
        defer { runningPasses -= 1 }
        let startedFrom = requested
        let tallyStartedFrom = tallyRequested
        do {
            // Before the catalog's first load there is nothing to read; the load is a catalog
            // change, so a request follows it.
            guard let libraries = await store.loadedLibraries() else {
                return
            }
            // The snapshot and the vectors are the largest load Otos holds: one at a time with
            // the other heavy loads, none before the window's first grid.
            try await admission.run(.people) {
                if let builder {
                    let built = try await builder(store, libraries)
                    try Task.checkCancellation()
                    publish(built, covers: startedFrom, tally: tallyStartedFrom)
                } else {
                    try await galleryThenAssignment(libraries: libraries, startedFrom: startedFrom, tallyStartedFrom: tallyStartedFrom)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            OtosLog.catalog.errorOperation("people.pass", phase: "failed", fields: [
                "error": String(describing: error),
            ])
            return
        }
        covered = startedFrom
        ringIfOwed()
    }

    /// Step 1, then step 2 when owed (see the guide). Returns whether assignment ran.
    @discardableResult
    private func galleryThenAssignment(
        libraries: [CatalogLibraryState],
        startedFrom: UInt64,
        tallyStartedFrom: UInt64
    ) async throws -> Bool {
        let signpost = OtosSignpost.performance.beginInterval("PeopleAssignment")
        defer { OtosSignpost.performance.endInterval("PeopleAssignment", signpost) }
        let start = ContinuousClock.now
        let read = try await store.peopleSnapshot(availableLibraryPaths: CatalogWindowPolicy.availablePaths(from: libraries))
        let readMs = DiagnosticsTiming.milliseconds(since: start)
        let built = await Self.gallery(read)
        try Task.checkCancellation()
        // Synchronous from here to the publication: the read kept is the one published.
        lastRead = read.withoutTiles
        ranker = nil
        publish(built, covers: startedFrom, tally: tallyStartedFrom)
        let inputs = await Self.inputs(of: read)
        if settled == nil {
            let stored = try await store.settledPeopleAssignment()
            settled = settled ?? stored.map(AssignmentInputs.init(digest:))
        }
        guard inputs != settled else {
            OtosLog.catalog.debugOperation("people.pass", phase: "published", fields: [
                "faces": "\(read.faces.count)", "people": "\(read.people.count)", "readMs": "\(readMs)", "assigned": "false",
            ])
            return false
        }
        let vectorsStart = ContinuousClock.now
        try await syncVectors(for: read)
        let vectorsMs = DiagnosticsTiming.milliseconds(since: vectorsStart)
        let assignStart = ContinuousClock.now
        let (plan, missing) = await Self.assign(read, vectors: vectors)
        let assignMs = DiagnosticsTiming.milliseconds(since: assignStart)
        try Task.checkCancellation()
        let written = try await store.applyAssignment(plan)
        // Inputs whose vectors were not all held are not settled: a face whose vector is
        // missing was replaced by a write after the read, and the pass that write rings
        // assigns again.
        if missing == 0 {
            try await store.recordSettledPeopleAssignment(inputs.digest)
            settled = inputs
        }
        OtosLog.catalog.debugOperation("people.pass", phase: written > 0 ? "wrote" : "assigned", fields: [
            "faces": "\(read.faces.count)",
            "people": "\(read.people.count)",
            "vectors": "\(vectors.count)",
            "missingVectors": "\(missing)",
            "guesses": "\(plan.guesses.count)",
            "newPeople": "\(plan.newPeople.count)",
            "rows": "\(written)",
            "readMs": "\(readMs)",
            "vectorsMs": "\(vectorsMs)",
            "assignMs": "\(assignMs)",
            "assigned": "true",
        ])
        return true
    }

    /// Publishes `built` with the request and tally it covers, when it differs from the last.
    private func publish(_ built: CatalogPeopleState, covers: UInt64, tally: UInt64) {
        var built = built
        built.covers = covers
        tallyCovered = tally
        if built != published {
            published = built
            OtosLog.catalog.debugOperation("people.build", phase: "published", fields: [
                "faces": "\(built.faceCount)", "people": "\(built.people.count)", "covers": "\(covers)",
            ])
            buildsContinuation.yield(built)
        }
    }

    /// Reads the vectors `read` names that are not held, a page at a time, and forgets the
    /// ones no face names any more. Each page is applied in synchronous code and only above
    /// what is held then, so a ranking and a pass reading pages at once add each vector once.
    /// A vector whose bytes hold no embedding leaves its face out of assignment, and its
    /// photo owes its faces again, so a new reading replaces the row (ADR 0047).
    private func syncVectors(for read: PeopleSnapshot) async throws {
        var malformed: [Int64] = []
        while true {
            let page = try await store.faceEmbeddings(after: vectors.owed, limit: FaceVectors.pageSize)
            let owed = vectors.owed
            let fresh = page.filter { $0.vector > owed }
            vectors.add(fresh)
            malformed += fresh.filter { $0.embedding == nil }.map(\.vector)
            ranker = nil
            if page.count < FaceVectors.pageSize {
                break
            }
        }
        vectors.keep(read.vectors)
        guard !malformed.isEmpty else { return }
        let bad = Set(malformed)
        try await store.oweFacesAgain(Set(read.faces.filter { bad.contains($0.vector) }.map(\.id.asset)))
    }

    /// Reads the unchecked tally alone and republishes the last state with it. Before any
    /// state is published there is nothing to fold it into: the first full pass reads it.
    private func tallyPass() async {
        runningPasses += 1
        defer { runningPasses -= 1 }
        let startedFrom = tallyRequested
        // A test builder stands in for every pass, this one too.
        let built: CatalogPeopleState?
        let unchecked: MediaCount?
        do {
            guard let libraries = await store.loadedLibraries() else {
                return
            }
            if let builder {
                (built, unchecked) = try await (builder(store, libraries), nil)
            } else {
                (built, unchecked) = try await (nil, store.uncheckedForFaces(
                    availableLibraryPaths: CatalogWindowPolicy.availablePaths(from: libraries)
                ))
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            return
        } catch {
            OtosLog.catalog.errorOperation("people.tally", phase: "failed", fields: [
                "error": String(describing: error),
            ])
            return
        }
        // Synchronous from here: the state the tally goes into is the one published now.
        tallyCovered = startedFrom
        var state = built ?? published
        if let unchecked {
            state?.unchecked = unchecked
        }
        if let state, state != published {
            published = state
            buildsContinuation.yield(state)
        }
        ringIfOwed()
    }

    private func ringIfOwed() {
        if requested != covered || tallyRequested != tallyCovered {
            doorbell.yield()
        }
    }
}

extension PeopleAssignment {
    /// Runs passes as the loop would after each write's change, until one assigns nothing,
    /// and returns the gallery it published. Internal for the tests and benchmarks that run
    /// passes without the loop.
    func settle(libraries: [CatalogLibraryState]) async throws -> CatalogPeopleState {
        while true {
            requested &+= 1
            let startedFrom = requested
            let assigned = try await galleryThenAssignment(libraries: libraries, startedFrom: startedFrom, tallyStartedFrom: tallyRequested)
            covered = startedFrom
            if !assigned, let published {
                return published
            }
        }
    }

    /// The gallery, off the actor.
    @concurrent
    private static func gallery(_ read: PeopleSnapshot) async -> CatalogPeopleState {
        PeopleStateBuilder.state(from: read)
    }

    /// What assignment reads of `read`, hashed off the actor.
    @concurrent
    private static func inputs(of read: PeopleSnapshot) async -> AssignmentInputs {
        AssignmentInputs(read)
    }

    /// Assignment, off the actor, with how many faces had no vector held.
    @concurrent
    private static func assign(_ read: PeopleSnapshot, vectors: FaceVectors) async -> (FaceAssignmentPlan, missing: Int) {
        let facts = read.facts(with: vectors)
        // A malformed vector is held as such: its face is left out on purpose, not missing.
        let missing = read.faces.count { vectors.embedding($0.vector) == nil && !vectors.malformed.contains($0.vector) }
        return (FaceAssignmentPlan.assignment(of: read, facts: facts), missing)
    }

    /// The ranker over the faces of the people the gallery offers.
    private static func ranker(read: PeopleSnapshot, vectors: FaceVectors, state: CatalogPeopleState) -> FaceRanker {
        FaceRanker(faces: read.facts(with: vectors), people: read.personFacts, offered: Set(state.visiblePeople.map(\.id)))
    }

    /// The faces of the selected photos most likely to need ranking: at most this many faces
    /// are ranked, the first in path order, so selecting a whole library stays quick; the
    /// rest show without candidates.
    static let rankedFaceLimit = 256

    @concurrent
    private static func candidates(
        for photos: [MediaAssetID],
        read: PeopleSnapshot,
        vectors: FaceVectors,
        state: CatalogPeopleState,
        ranker: FaceRanker
    ) async -> [FaceID: [FaceCandidate]] {
        // A photo shows the named faces of its copies (`CatalogPeopleState.faces(of:)`), so
        // those are ranked too; each is ranked against the people of its own file.
        let wanted = Set(photos + photos.flatMap(state.copies(of:)))
        let hidden = Set(state.hiddenPeople.map(\.id))
        let faces = read.faces.filter { face in
            wanted.contains(face.id.asset) && !(face.assignment.person.map(hidden.contains) ?? false)
        }
        var photoPeople: [MediaAssetID: Set<PersonID>] = [:]
        for face in read.faces where wanted.contains(face.id.asset) {
            if let person = face.assignment.person {
                photoPeople[face.id.asset, default: []].insert(person)
            }
        }
        let ranked = faces.sorted { FaceAssignmentPolicy.pathOrder($0.id, $1.id) }.prefix(rankedFaceLimit)
        return ranker.candidates(for: ranked.compactMap { $0.fact(with: vectors) }, photoPeople: photoPeople)
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
        var faces: [PersonID: [FaceTile]] = [:]
        var userFaces: [PersonID: [FaceTile]] = [:]
        var anchorMedia: [PersonID: [MediaAssetID: Bool]] = [:]
        for face in snapshot.faces {
            guard let person = face.assignment.person, let tile = snapshot.tiles[face.id] else { continue }
            faces[person, default: []].append(tile)
            if case .user = face.assignment {
                userFaces[person, default: []].append(tile)
            }
            if face.assignment.isAnchor {
                anchorMedia[person, default: [:]][face.id.asset] = tile.isInVideo
            }
        }
        let hidden = Set(snapshot.people.filter(\.isHidden).map(\.id))
        var photoFaces: [MediaAssetID: [PhotoFace]] = [:]
        for face in snapshot.faces {
            guard let tile = snapshot.tiles[face.id] else { continue }
            if let person = face.assignment.person, hidden.contains(person) {
                continue
            }
            photoFaces[face.id.asset, default: []].append(PhotoFace(tile: tile, person: face.assignment.person))
        }
        var copies: [MediaAssetID: [MediaAssetID]] = [:]
        for group in snapshot.copies where group.count > 1 {
            for file in group {
                copies[file] = group.filter { $0 != file }
            }
        }
        let photo = { (face: FaceTile) in snapshot.photoOf[face.id.asset] ?? face.id.asset }
        let people = snapshot.people.compactMap { person -> PersonSummary? in
            let own = (faces[person.id] ?? []).sorted(by: newestFirst)
            guard !own.isEmpty || !snapshot.isBare(person) else { return nil }
            let keyPhoto = snapshot.keyPhotos[person.id].flatMap { id in own.first { $0.id == id } }
            return PersonSummary(
                id: person.id,
                name: person.name,
                birthday: person.birthday,
                isHidden: person.isHidden,
                isFavorite: person.isFavorite,
                media: MediaCount(items: own.map { face in (photo(face), face.isInVideo) }),
                cover: keyPhoto ?? own.first,
                userFaces: (userFaces[person.id] ?? []).sorted(by: newestFirst),
                anchorMedia: anchorMedia[person.id] ?? [:],
                newestFaces: Array(onePerPhoto(own, photo: photo).prefix(PersonSummary.newestFaceCount))
            )
        }.sorted(by: galleryOrder)
        return CatalogPeopleState(
            people: people,
            photoFaces: photoFaces,
            copies: copies,
            unchecked: snapshot.unchecked,
            faceCount: snapshot.faces.count
        )
    }

    /// `faces` with only the first face of each photo they are in: a photo's copies, and the
    /// files of a stack, are one photo (`PeopleSnapshot.photoOf`), each read for its faces.
    static func onePerPhoto(_ faces: [FaceTile], photo: (FaceTile) -> MediaAssetID) -> [FaceTile] {
        var seen: Set<MediaAssetID> = []
        return faces.filter { seen.insert(photo($0)).inserted }
    }

    static func galleryOrder(_ lhs: PersonSummary, _ rhs: PersonSummary) -> Bool {
        if lhs.isHidden != rhs.isHidden {
            return !lhs.isHidden
        }
        if lhs.isFavorite != rhs.isFavorite {
            return lhs.isFavorite
        }
        if lhs.media.total != rhs.media.total {
            return lhs.media.total > rhs.media.total
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

/// Face vectors guide
///
/// The face vectors People holds (ADR 0047): every stored face's embedding, read from the
/// catalog once and afterwards only as new readings write them (`FaceEmbeddingSQL`), kept in
/// fixed-size chunks of contiguous rows so an embedding handed out is a view into its chunk,
/// never a copy.
///
/// - **Reading:** `owed` is the number above which the catalog may hold vectors this does not.
///   `CatalogStore.faceEmbeddings(after:limit:)` reads them `pageSize` at a time, each page its
///   own short read, and `add(_:)` appends a page. A reading's vector is never rewritten in
///   place: a new reading writes a new row with a higher number, so nothing at or below
///   `owed` changes.
/// - **Forgetting:** `keep(_:)` drops every vector no stored face names. A dropped row's place
///   stays empty until a compaction, which runs when a quarter of the rows are empty and
///   rebuilds the chunks from the vectors kept.
/// - **Copies:** a chunk is an array, and an embedding handed out keeps its chunk alive.
///   Appending to a chunk a pass still reads copies that chunk alone, at most `chunkRows`
///   vectors; a compaction copies every vector once.
/// - **Malformed rows:** a vector whose bytes are no embedding is held as malformed, so its
///   face is left out of assignment and its photo owes its faces again (`malformed`).
nonisolated struct FaceVectors: Sendable {
    /// One row of the vector table as read: its number, and its embedding, nil when its bytes
    /// hold none.
    nonisolated struct Read: Sendable, Equatable {
        let vector: Int64
        let embedding: FaceEmbedding?
    }

    /// Vectors per read: 4 MB of rows, one short read each.
    static let pageSize = 2048
    static let chunkRows = 4096
    private static let dimensions = FaceEmbeddingModel.dimensions

    private var chunks: [[Float]] = []
    /// Each vector's chunk and row.
    private var places: [Int64: Place] = [:]
    private var emptyRows = 0
    /// The vectors whose bytes hold no embedding.
    private(set) var malformed: Set<Int64> = []
    /// The largest vector number read; the catalog's rows above it are not held.
    private(set) var owed: Int64 = 0

    private struct Place: Sendable {
        let chunk: Int
        let row: Int
    }

    /// The vectors held.
    var count: Int {
        places.count
    }

    /// The face's embedding, a view into its chunk; nil when the vector is not held.
    func embedding(_ vector: Int64) -> FaceEmbedding? {
        guard let place = places[vector] else { return nil }
        let start = place.row * Self.dimensions
        return FaceEmbedding(view: chunks[place.chunk][start ..< start + Self.dimensions])
    }

    /// Appends the rows of a page read in number order above `owed`; rows at or below it are
    /// already held and are passed over.
    mutating func add(_ page: [Read]) {
        for read in page where read.vector > owed {
            owed = read.vector
            guard let embedding = read.embedding else {
                malformed.insert(read.vector)
                continue
            }
            append(read.vector, embedding)
        }
    }

    private mutating func append(_ vector: Int64, _ embedding: FaceEmbedding) {
        if chunks.isEmpty || chunks[chunks.count - 1].count == Self.chunkRows * Self.dimensions {
            var chunk: [Float] = []
            chunk.reserveCapacity(Self.chunkRows * Self.dimensions)
            chunks.append(chunk)
        }
        let chunk = chunks.count - 1
        places[vector] = Place(chunk: chunk, row: chunks[chunk].count / Self.dimensions)
        chunks[chunk].append(contentsOf: embedding.values)
    }

    /// Keeps only `vectors`, the ones stored faces name.
    mutating func keep(_ vectors: Set<Int64>) {
        let gone = places.keys.filter { !vectors.contains($0) }
        for vector in gone {
            places[vector] = nil
        }
        malformed.formIntersection(vectors)
        emptyRows += gone.count
        guard emptyRows * 4 > places.count + emptyRows else { return }
        var compacted = FaceVectors()
        for vector in places.keys.sorted() {
            if let embedding = embedding(vector) {
                compacted.append(vector, embedding)
            }
        }
        compacted.malformed = malformed
        compacted.owed = owed
        self = compacted
    }
}
