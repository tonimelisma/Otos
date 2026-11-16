import Foundation
import OSLog

/// People Assignment guide
///
/// This actor owns who every face is (ADR 0047, `docs/design/people.md`): it gives each face
/// its most likely person, writes Otos's guesses back, and writes each person's gallery facts
/// (`PersonGalleryFacts`: their photo count and newest face), from which the People gallery
/// paints. It publishes nothing to the window: the gallery is the window's own read of the
/// people (`PeopleGallery`), so People's first paint never waits for this owner's read or for
/// its turn among the heavy loads. Who the faces are is a fact about the whole catalog, not
/// about what the window shows, so like the duplicate groups it has its own owner and its own
/// loop, and a change of scope, filter or sort never starts a pass.
///
/// `CatalogProjection` asks for a pass with `request()` after a publication that took up a
/// catalog change of a kind assignment reads (`inputs`). A request only adds to `requested`;
/// a pass records the value it started from and covers exactly that when it succeeds, so a
/// request made while a pass runs is never lost and runs next (ADR 0032). One loop task runs
/// every pass off a `bufferingNewest(1)` doorbell, so passes never overlap.
///
/// A pass:
/// 1. **Reads what assignment reads** (`CatalogStore.peopleSnapshot`): every face's row and
///    whose word its person is — never its vector nor its tile — with the people, the gallery
///    facts stored for them, copies and stacks.
/// 2. **Writes the gallery facts that moved** (`CatalogStore.writePeopleGalleryFacts`), computed
///    from scratch from the read (`PeopleSnapshot.computedGalleryFacts`). The write announces
///    `.peopleGallery`, which assignment does not read, so it never starts another pass.
/// 3. **Assigns, only when its inputs moved.** What assignment reads of the snapshot is
///    hashed (`AssignmentInputs`). The catalog keeps the hash of the last inputs whose
///    assignment it holds (`CatalogStore.settledPeopleAssignment`): while the two are equal,
///    the stored guesses are assignment's output on these inputs, and nothing runs.
///    Otherwise the vectors owed are read (`FaceVectors`, held across passes), assignment runs
///    off this actor, what it changes is written in short transactions, and the hash is
///    recorded. A guess is not an input, so the pass after a write that only moved guesses
///    finds the hash equal and only writes the gallery facts the guesses moved; a write that
///    seeded a new person, released a seed or deleted an emptied person moved an input, and
///    the next pass assigns once more and writes nothing.
///
/// What a pass read is kept (`lastRead`) to answer which people the faces of the selected
/// photos could be (`candidates(for:)`); the ranker is built from it and the vectors on the
/// first such question, and again after either changes.
///
/// A failed pass leaves its request outstanding for the next request to retry. `stop()` is
/// teardown: it ends the doorbell, so the loop ends with it. The requests, the pass and its
/// reads are kept in `OwnerActivity` (`QuiescentOwner`).
actor PeopleAssignment: QuiescentOwner {
    /// What the People snapshot reads (`CatalogStore.peopleSnapshot`), so `CatalogProjection`
    /// asks for a pass only when one of these moved: the faces, who they are and the people;
    /// which rows are shown and which movies a Live Photo hides; the stacks a face's photo
    /// stands for and the copies it is one of (ADR 0052, 0054); and, of a photo that holds a
    /// face, its capture date, kind and grouping (`.faceTiles`), so a date of a photo nobody is
    /// in wakes nothing. Not `.peopleGallery`, which this owner writes.
    static let inputs: CatalogChangedFacts = [
        .faces, .membership, .faceTiles, .choices, .copies, .stacks,
    ]

    private nonisolated let bell: AsyncStream<Void>
    private nonisolated let doorbell: AsyncStream<Void>.Continuation
    private let store: CatalogStore
    /// Every request, the one the last successful pass started from, and the pass running.
    let activity = OwnerActivity(owner: "people")
    /// What the last pass read, for `candidates(for:)`.
    private var lastRead: PeopleSnapshot?
    /// Every face's vector read so far; read on the first assignment or ranking that needs it.
    private var vectors = FaceVectors()
    /// The ranker over `lastRead` and `vectors`; nil until asked for, and after either changes.
    private var ranker: FaceRanker?
    /// The inputs whose assignment the catalog holds; read from the catalog by the first pass.
    private var settled: AssignmentInputs?
    /// The photos the changes asked for since the last read began, when every change named its
    /// rows; nil when one did not, and the next pass reads every face.
    private var owedRows: Set<MediaAssetID>? = []
    private var loopTask: Task<Void, Never>?

    /// True when every request has been covered by a successful pass and none is running.
    var isQuiescent: Bool {
        quiescence != nil
    }

    /// Runs each pass one heavy load at a time with the other owners' (`LoadAdmission`).
    private let admission: LoadAdmission

    init(store: CatalogStore, admission: LoadAdmission = LoadAdmission(isOpen: true)) {
        self.store = store
        self.admission = admission
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

    /// The catalog may have changed: People is owed a pass. `rows` are the photos the change
    /// named, when it named them and touched only their faces or tiles
    /// (`incrementalInputs`): the pass then reads only those photos' faces.
    func request(rows: CatalogChangedRows = .unnamed) {
        switch rows {
        case .unnamed: owedRows = nil
        case .none: break
        case let .named(photos): owedRows?.formUnion(photos.ids)
        }
        activity.request()
        doorbell.yield()
    }

    /// Asks for a pass with no rows named and no read owed again: the held read stands.
    func ringIdle() {
        request(rows: .none)
    }

    /// The facts a change can name rows of and still be read by key: the faces of those
    /// photos, and their dates, kinds and images (`.faceTiles`). Any other kind (which rows
    /// exist, copies, stacks, choices) can move what other photos stand for, so it is read whole.
    static let incrementalInputs: CatalogChangedFacts = [.faces, .faceTiles]

    /// Teardown, callable from anywhere: ends the loop.
    nonisolated func stop() {
        doorbell.finish()
    }

    /// The people each face of `photos` could be, from the last pass's read: a hidden
    /// person's face is not ranked, and a hidden person is never a candidate. The vectors owed
    /// are read first; nil when they cannot be read (logged), which is no ranking, not an
    /// empty one.
    func candidates(for photos: [MediaAssetID]) async -> [FaceID: [FaceCandidate]]? {
        guard let read = lastRead else {
            return [:]
        }
        do {
            try await syncVectors(for: read)
        } catch {
            OtosLog.catalog.errorOperation("people.candidates", phase: "vectorsFailed", fields: [
                "error": String(describing: error),
            ])
            return nil
        }
        // The read may have moved while the vectors were read: rank what is held now, from
        // values taken in this synchronous step.
        guard let current = lastRead else {
            return [:]
        }
        let ranker = ranker ?? Self.ranker(read: current, vectors: vectors)
        self.ranker = ranker
        return await Self.candidates(for: photos, read: current, vectors: vectors, ranker: ranker)
    }

    private func pass() async {
        guard activity.isOwed else { return }
        let startedFrom = activity.beginPass()
        var answered: UInt64?
        defer {
            activity.endPass(covering: answered)
            settleQuiescence()
        }
        do {
            // Before the catalog's first load there is nothing to read; the load is a catalog
            // change, so a request follows it.
            guard await store.loadedLibraries() != nil else {
                return
            }
            // The snapshot and the vectors are the largest load Otos holds: one at a time with
            // the other heavy loads, none before the window's first grid.
            try await admission.run(.people) {
                try await readThenAssign()
            }
        } catch is CancellationError {
            owedRows = nil
            return
        } catch {
            // What the failed read was to cover is owed again, whole.
            owedRows = nil
            OtosLog.catalog.errorOperation("people.pass", phase: "failed", fields: [
                "error": String(describing: error),
            ])
            return
        }
        answered = startedFrom
        if activity.requested != startedFrom {
            doorbell.yield()
        }
    }

    /// Steps 1 to 3 (see the guide). Returns whether assignment ran.
    @discardableResult
    private func readThenAssign() async throws -> Bool {
        let signpost = OtosSignpost.performance.beginInterval("PeopleAssignment")
        defer { OtosSignpost.performance.endInterval("PeopleAssignment", signpost) }
        let start = ContinuousClock.now
        // Taken in this synchronous step: a request during the read adds to the next pass's.
        let rows = owedRows
        owedRows = []
        let read: PeopleSnapshot = if let held = lastRead, let rows {
            try await held.replacing(rows, with: store.backgroundReads.peopleSnapshot(of: rows))
        } else {
            try await store.backgroundReads.peopleSnapshot()
        }
        // The rows a read returned are the faces of the photos it read: all of them for a
        // whole read, the named photos' for a keyed one.
        activity.read(rows: rows == nil || lastRead == nil ? read.faces.count : read.faces.count { rows?.contains($0.id.asset) == true })
        let readMs = DiagnosticsTiming.milliseconds(since: start)
        OtosLog.catalog.debugOperation("people.read", phase: rows == nil || lastRead == nil ? "whole" : "byKey", fields: [
            "photos": rows.map { "\($0.count)" } ?? "all", "ms": "\(readMs)",
        ])
        try Task.checkCancellation()
        // Synchronous from here to the next await: the read kept is the one ranked against.
        lastRead = read
        ranker = nil
        let (inputs, galleryFacts) = await Self.derive(read)
        let galleryRows = try await store.writePeopleGalleryFacts(galleryFacts, stored: read.galleryFacts)
        activity.wrote(galleryRows)
        if settled == nil {
            let stored = try await store.backgroundReads.settledPeopleAssignment()
            settled = settled ?? stored.map(AssignmentInputs.init(digest:))
        }
        guard inputs != settled else {
            OtosLog.catalog.debugOperation("people.pass", phase: "read", fields: [
                "faces": "\(read.faces.count)", "people": "\(read.people.count)", "readMs": "\(readMs)",
                "galleryRows": "\(galleryRows)", "assigned": "false",
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
        activity.wrote(written)
        // The photos written are owed a read by key, which the write's own change also asks.
        if written > 0 {
            owedRows?.formUnion(plan.photos)
        }
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
            "galleryRows": "\(galleryRows)",
            "readMs": "\(readMs)",
            "vectorsMs": "\(vectorsMs)",
            "assignMs": "\(assignMs)",
            "assigned": "true",
        ])
        return true
    }

    /// Reads the vectors `read` names that are not held, a page at a time, and forgets the
    /// ones no face names any more. Each page is applied in synchronous code and only above
    /// what is held then, so a ranking and a pass reading pages at once add each vector once.
    /// A vector whose bytes hold no embedding leaves its face out of assignment, and its
    /// photo owes its faces again, so a new reading replaces the row (ADR 0047).
    private func syncVectors(for read: PeopleSnapshot) async throws {
        var malformed: [Int64] = []
        while true {
            let page = try await store.backgroundReads.faceEmbeddings(after: vectors.owed, limit: FaceVectors.pageSize)
            let owed = vectors.owed
            let fresh = page.filter { $0.vector > owed }
            vectors.add(fresh)
            malformed += fresh.filter { $0.embedding == nil }.map(\.vector)
            ranker = nil
            if page.count < FaceVectors.pageSize {
                break
            }
        }
        vectors.keep(read.vectors, through: read.vectorHorizon)
        guard !malformed.isEmpty else { return }
        let bad = Set(malformed)
        try await store.oweFacesAgain(Set(read.faces.filter { bad.contains($0.vector) }.map(\.id.asset)))
    }
}

extension PeopleAssignment {
    /// What the last pass read and holds. Internal for the tests that compare it with a whole read.
    var heldRead: PeopleSnapshot? {
        lastRead
    }

    /// Runs passes as the loop would after each write's change, until one assigns nothing.
    /// Internal for the tests and benchmarks that run passes without the loop.
    func settle() async throws {
        while true {
            let startedFrom = activity.request()
            activity.beginPass()
            let assigned: Bool
            do {
                assigned = try await admission.run(.people) {
                    try await readThenAssign()
                }
            } catch {
                activity.endPass(covering: nil)
                throw error
            }
            activity.endPass(covering: startedFrom)
            if !assigned {
                return
            }
        }
    }

    /// What assignment reads of `read`, hashed, and every person's gallery facts, off the actor.
    @concurrent
    private static func derive(_ read: PeopleSnapshot) async -> (AssignmentInputs, [PersonID: PersonGalleryFacts]) {
        (AssignmentInputs(read), read.computedGalleryFacts)
    }

    /// Assignment, off the actor, with how many faces had no vector held.
    @concurrent
    private static func assign(_ read: PeopleSnapshot, vectors: FaceVectors) async -> (FaceAssignmentPlan, missing: Int) {
        let facts = read.facts(with: vectors)
        // A malformed vector is held as such: its face is left out on purpose, not missing.
        let missing = read.faces.count { vectors.vector($0.vector) == nil && !vectors.malformed.contains($0.vector) }
        return (FaceAssignmentPlan.assignment(of: read, facts: facts), missing)
    }

    /// The ranker over the faces of the people not hidden.
    private static func ranker(read: PeopleSnapshot, vectors: FaceVectors) -> FaceRanker {
        FaceRanker(faces: read.facts(with: vectors), people: read.personFacts, offered: Set(read.people.filter { !$0.isHidden }.map(\.id)))
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
        ranker: FaceRanker
    ) async -> [FaceID: [FaceCandidate]] {
        // A photo shows the named faces of its copies (`PhotoFaces.faces(of:)`), so those are
        // ranked too; each is ranked against the people of its own file.
        let asked = Set(photos)
        let wanted = asked.union(read.copies.filter { !asked.isDisjoint(with: $0) }.joined())
        let hidden = Set(read.people.filter(\.isHidden).map(\.id))
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

/// People Gallery guide
///
/// The window's read of the people (ADR 0047, "What the People UI reads"): what the People
/// gallery and every surface that names people show — the people, their names, photo counts,
/// covers, order and the facts the hard rules hold them to — and the unchecked tally, from one
/// read of the people and the faces that define them (`CatalogStore.peopleGallery`). It reads
/// none of what `PeopleAssignment` holds and waits for none of its work: it is not a heavy
/// load (`LoadAdmission`), so it runs at the window's priority as soon as the catalog is
/// loaded, and People paints from the facts the catalog stores while assignment reads.
///
/// `CatalogProjection` asks for a read with `request()` after a publication that took up a
/// catalog change of a kind the read reads (`inputs`), and after every People write the
/// window made (`requestPeopleBuild`). A request only adds to `requested`; a read records the
/// value it started from and publishes a state that covers it (`CatalogPeopleState.covers`),
/// so a People act the window shows ahead is retired by the first state read after its write.
/// One loop runs every read off a `bufferingNewest(1)` doorbell. A failed read publishes
/// nothing and leaves its request outstanding for the next one (ADR 0032 rule 4). The
/// requests, the read and its rows are kept in `OwnerActivity` (`QuiescentOwner`).
actor PeopleGallery: QuiescentOwner {
    typealias Builder = @Sendable (CatalogStore, [CatalogLibraryState]) async throws -> CatalogPeopleState?

    /// What the gallery's read reads: the people and their faces (`.faces`), which rows are
    /// shown (`.membership`), the images a cover is cut from (`.faceTiles`), and the facts
    /// People stores for each person (`.peopleGallery`).
    static let inputs: CatalogChangedFacts = [.faces, .membership, .faceTiles, .peopleGallery]

    /// Built states, each differing from the one before; only the newest matters. One
    /// consumer: `CatalogProjection`.
    nonisolated let builds: AsyncStream<CatalogPeopleState>
    private nonisolated let buildsContinuation: AsyncStream<CatalogPeopleState>.Continuation
    private nonisolated let bell: AsyncStream<Void>
    private nonisolated let doorbell: AsyncStream<Void>.Continuation
    private let store: CatalogStore
    /// Tests replace the read to hold it at its suspension; production reads the catalog.
    private let builder: Builder?
    let activity = OwnerActivity(owner: "peopleGallery")
    private var published: CatalogPeopleState?
    private var loopTask: Task<Void, Never>?

    var isQuiescent: Bool {
        quiescence != nil
    }

    init(store: CatalogStore, builder: Builder?) {
        self.store = store
        self.builder = builder
        (builds, buildsContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (bell, doorbell) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// Starts the loop. It holds this owner weakly and ends when the doorbell finishes.
    func start() {
        guard loopTask == nil else { return }
        let bell = bell
        loopTask = Task { [weak self] in
            for await _ in bell {
                guard let self else { return }
                await read()
            }
        }
    }

    /// The people may have changed: a read is owed. Returns the request, which every state
    /// read after it carries as `covers`.
    @discardableResult
    func request() -> UInt64 {
        let requested = activity.request()
        doorbell.yield()
        return requested
    }

    func ringIdle() {
        request()
    }

    /// Teardown, callable from anywhere: ends the loop and the stream of builds.
    nonisolated func stop() {
        doorbell.finish()
        buildsContinuation.finish()
    }

    private func read() async {
        guard activity.isOwed else { return }
        let startedFrom = activity.beginPass()
        var answered: UInt64?
        defer {
            activity.endPass(covering: answered)
            settleQuiescence()
        }
        let built: CatalogPeopleState?
        do {
            // Before the catalog's first load there is nothing to read; the load is a catalog
            // change, so a request follows it.
            guard let libraries = await store.loadedLibraries() else { return }
            let start = ContinuousClock.now
            if let builder {
                built = try await builder(store, libraries)
            } else {
                built = try await Self.read(store: store, libraries: libraries)
            }
            try Task.checkCancellation()
            activity.read(rows: built?.people.count ?? 0)
            OtosLog.catalog.debugOperation("people.gallery", phase: "read", fields: [
                "ms": "\(DiagnosticsTiming.milliseconds(since: start))",
                "people": built.map { "\($0.people.count)" } ?? "unknown",
            ])
        } catch is CancellationError {
            return
        } catch {
            OtosLog.catalog.errorOperation("people.gallery", phase: "failed", fields: [
                "error": String(describing: error),
            ])
            return
        }
        answered = startedFrom
        // A gallery not known yet (`peopleGallery` nil) is not published: the pane keeps
        // claiming nothing until People has written what it paints from.
        if var built {
            built.covers = startedFrom
            if built != published {
                published = built
                buildsContinuation.yield(built)
            }
        }
        if activity.requested != startedFrom {
            doorbell.yield()
        }
    }

    @concurrent
    private static func read(store: CatalogStore, libraries: [CatalogLibraryState]) async throws -> CatalogPeopleState? {
        try await store.windowReads.peopleGallery(availableLibraryPaths: CatalogWindowPolicy.availablePaths(from: libraries))
            .map { CatalogPeopleState(gallery: $0) }
    }
}

/// Face vectors guide
///
/// The face vectors People holds (ADR 0047): every stored face's embedding at half precision
/// (`FaceVector`), read from the catalog once and afterwards only as new readings write them
/// (`FaceEmbeddingSQL`), kept in fixed-size chunks of contiguous rows so a vector handed out is
/// a view into its chunk, never a copy: about 105 MB for the owner's 103k faces.
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

    private var chunks: [[Float16]] = []
    /// Each vector's chunk and row, and whether the model can tell anyone by it.
    private var places: [Int64: Place] = [:]
    private var emptyRows = 0
    /// The vectors whose bytes hold no embedding.
    private(set) var malformed: Set<Int64> = []
    /// The largest vector number read; the catalog's rows above it are not held.
    private(set) var owed: Int64 = 0

    private struct Place: Sendable {
        let chunk: Int
        let row: Int
        let isRecognisable: Bool
    }

    /// The vectors held.
    var count: Int {
        places.count
    }

    /// The face's vector, a view into its chunk; nil when the vector is not held.
    func vector(_ vector: Int64) -> FaceVector? {
        guard let place = places[vector] else { return nil }
        let start = place.row * Self.dimensions
        return FaceVector(view: chunks[place.chunk][start ..< start + Self.dimensions], isRecognisable: place.isRecognisable)
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
            append(read.vector, FaceVector(embedding))
        }
    }

    private mutating func append(_ vector: Int64, _ face: FaceVector) {
        if chunks.isEmpty || chunks[chunks.count - 1].count == Self.chunkRows * Self.dimensions {
            var chunk: [Float16] = []
            chunk.reserveCapacity(Self.chunkRows * Self.dimensions)
            chunks.append(chunk)
        }
        let chunk = chunks.count - 1
        places[vector] = Place(chunk: chunk, row: chunks[chunk].count / Self.dimensions, isRecognisable: face.isRecognisable)
        chunks[chunk].append(contentsOf: face.values)
    }

    /// Keeps only `vectors`, the ones a snapshot's faces name, among the vectors numbered up to
    /// `horizon`, the largest number that snapshot could see: a vector written after it is
    /// some face's newer reading, which a later snapshot names, so it stays.
    mutating func keep(_ vectors: Set<Int64>, through horizon: Int64) {
        let gone = places.keys.filter { $0 <= horizon && !vectors.contains($0) }
        for vector in gone {
            places[vector] = nil
        }
        malformed = malformed.filter { $0 > horizon || vectors.contains($0) }
        emptyRows += gone.count
        guard emptyRows * 4 > places.count + emptyRows else { return }
        var compacted = FaceVectors()
        for vector in places.keys.sorted() {
            if let face = self.vector(vector) {
                compacted.append(vector, face)
            }
        }
        compacted.malformed = malformed
        compacted.owed = owed
        self = compacted
    }
}
