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
            try vectors.add(fresh)
            malformed += fresh.filter { $0.embedding == nil }.map(\.vector)
            ranker = nil
            if page.count < FaceVectors.pageSize {
                break
            }
        }
        try vectors.keep(read.vectors, through: read.vectorHorizon)
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
///
/// A ring is not a read owed (ADR 0032 rule 8): only `request()` owes one (`readsOwed`), and
/// the read that starts from it covers it (`readsCovered`). A ring that owes none — the idle
/// guard's — runs a pass that reads nothing and publishes nothing.
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
    /// Reads owed: one per `request()`, never cleared.
    private var readsOwed: UInt64 = 0
    /// The `readsOwed` value the last read that succeeded started from.
    private var readsCovered: UInt64 = 0
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
        readsOwed &+= 1
        return ring()
    }

    /// Rings the loop with no read owed: its pass reads nothing.
    func ringIdle() {
        ring()
    }

    private func ring() -> UInt64 {
        let requested = activity.request()
        doorbell.yield()
        return requested
    }

    /// Teardown, callable from anywhere: ends the loop and the stream of builds.
    nonisolated func stop() {
        doorbell.finish()
        buildsContinuation.finish()
    }

    private func read() async {
        guard activity.isOwed else { return }
        let startedFrom = activity.beginPass()
        let owed = readsOwed
        var answered: UInt64?
        defer {
            activity.endPass(covering: answered)
            settleQuiescence()
        }
        // A ring that owes no read: the state published stands.
        guard owed != readsCovered else {
            answered = startedFrom
            return
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
        readsCovered = owed
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
/// (`FaceVector`), read from the catalog once a launch and afterwards only as new readings write
/// them (`FaceEmbeddingSQL`). They live in a file of their own, never on the heap: a mapped
/// file's clean pages are not counted in the process's footprint, and the system may drop and
/// read them again (`FaceVectorFile`). About 105 MB for the owner's 103k faces, none of it in the
/// footprint.
///
/// - **Slots:** each vector is one slot of `FaceEmbeddingModel.dimensions` Float16 values,
///   appended in vector-number order, so `numbers` is ascending and a vector is found by binary
///   search. A vector handed out is a slice of the mapping (`FaceVector`), never a copy.
/// - **Reading:** `owed` is the number above which the catalog may hold vectors this does not.
///   `CatalogStore.faceEmbeddings(after:limit:)` reads them `pageSize` at a time, each page its
///   own short read, and `add(_:)` writes a page's slots to the file and maps it again. A
///   reading's vector is never rewritten in place: a new reading writes a new row with a higher
///   number, so nothing at or below `owed` changes, and a slot once written never changes.
/// - **Forgetting:** `keep(_:through:)` drops every vector no stored face names. A dropped slot
///   stays in the file until a compaction, which runs when a quarter of the slots are dropped
///   and writes the slots kept into a new file.
/// - **Copies:** a copy of this value shares the file and its mapping. A copy a pass still reads
///   keeps the mapping it was made with: an append writes past it, and a compaction writes
///   another file.
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

    /// The file the slots are written to; nil until the first is written.
    private var file: FaceVectorFile?
    /// Every slot written, mapped read-only.
    private var mapped = Data()
    /// Each slot's vector number, ascending.
    private var numbers: [Int64] = []
    /// Each slot's state: `recognisableFlag`, `droppedFlag`.
    private var states: [UInt8] = []
    private var dropped = 0
    /// The vectors whose bytes hold no embedding.
    private(set) var malformed: Set<Int64> = []
    /// The largest vector number read; the catalog's rows above it are not held.
    private(set) var owed: Int64 = 0

    private static let recognisableFlag: UInt8 = 1
    private static let droppedFlag: UInt8 = 2

    init() {}

    /// The vectors held.
    var count: Int {
        numbers.count - dropped
    }

    /// The slots written, dropped ones included: what the file holds.
    var slots: Int {
        numbers.count
    }

    /// What this value holds on the heap: each slot's number and state, about 9 bytes a
    /// vector. The vectors themselves are in the file, `slots * FaceVector.byteCount` bytes.
    var heapBytes: Int {
        numbers.capacity * MemoryLayout<Int64>.stride + states.capacity
    }

    /// The face's vector, a slice of the mapping; nil when the vector is not held.
    func vector(_ vector: Int64) -> FaceVector? {
        guard let slot = slot(of: vector) else { return nil }
        let start = slot * FaceVector.byteCount
        return FaceVector(bytes: mapped[start ..< start + FaceVector.byteCount], isRecognisable: states[slot] & Self.recognisableFlag != 0)
    }

    private func slot(of vector: Int64) -> Int? {
        var low = 0, high = numbers.count
        while low < high {
            let middle = (low + high) / 2
            if numbers[middle] < vector {
                low = middle + 1
            } else {
                high = middle
            }
        }
        guard low < numbers.count, numbers[low] == vector, states[low] & Self.droppedFlag == 0 else { return nil }
        return low
    }

    /// Writes the slots of a page read in number order above `owed`; rows at or below it are
    /// already held and are passed over. A write that fails leaves this value as it was.
    mutating func add(_ page: [Read]) throws {
        var owed = owed
        var malformed = malformed
        var fresh: [(vector: Int64, embedding: FaceEmbedding)] = []
        for read in page where read.vector > owed {
            owed = read.vector
            if let embedding = read.embedding {
                fresh.append((read.vector, embedding))
            } else {
                malformed.insert(read.vector)
            }
        }
        if !fresh.isEmpty {
            // The page's slots, made once in a region of their own and unmapped as this returns.
            let slots = ScratchBuffer<Float16>(count: fresh.count * FaceEmbeddingModel.dimensions)
            for (index, read) in fresh.enumerated() {
                FaceVector.halve(read.embedding.values, into: slots.base + index * FaceEmbeddingModel.dimensions)
            }
            let file = try file ?? FaceVectorFile()
            let length = numbers.count * FaceVector.byteCount
            let bytes = fresh.count * FaceVector.byteCount
            try file.write(UnsafeRawBufferPointer(start: slots.base, count: bytes), at: length)
            mapped = try file.map(length: length + bytes)
            self.file = file
            numbers += fresh.map(\.vector)
            states += fresh.map { FaceRecognisability.isRecognisable($0.embedding) ? Self.recognisableFlag : 0 }
        }
        self.owed = owed
        self.malformed = malformed
    }

    /// Keeps only `vectors`, the ones a snapshot's faces name, among the vectors numbered up to
    /// `horizon`, the largest number that snapshot could see: a vector written after it is
    /// some face's newer reading, which a later snapshot names, so it stays.
    mutating func keep(_ vectors: Set<Int64>, through horizon: Int64) throws {
        var states = states
        var dropped = dropped
        for slot in numbers.indices where numbers[slot] <= horizon && states[slot] & Self.droppedFlag == 0 {
            if !vectors.contains(numbers[slot]) {
                states[slot] |= Self.droppedFlag
                dropped += 1
            }
        }
        let malformed = malformed.filter { $0 > horizon || vectors.contains($0) }
        if dropped * 4 > numbers.count {
            self = try Self.compacted(numbers: numbers, states: states, mapped: mapped, owed: owed, malformed: malformed)
        } else {
            self.states = states
            self.dropped = dropped
            self.malformed = malformed
        }
    }

    /// The slots not dropped, in order, written into a new file.
    private static func compacted(
        numbers: [Int64], states: [UInt8], mapped: Data, owed: Int64, malformed: Set<Int64>
    ) throws -> FaceVectors {
        var compacted = FaceVectors()
        compacted.owed = owed
        compacted.malformed = malformed
        let kept = numbers.indices.filter { states[$0] & droppedFlag == 0 }
        guard !kept.isEmpty else { return compacted }
        let file = try FaceVectorFile()
        var written = 0
        var start = 0
        // Each run of kept slots is one write, straight from the old mapping.
        while start < kept.count {
            var end = start + 1
            while end < kept.count, kept[end] == kept[end - 1] + 1 {
                end += 1
            }
            let from = kept[start] * FaceVector.byteCount
            let bytes = (end - start) * FaceVector.byteCount
            try mapped.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                try file.write(UnsafeRawBufferPointer(rebasing: source[from ..< from + bytes]), at: written)
            }
            written += bytes
            start = end
        }
        compacted.file = file
        compacted.mapped = try file.map(length: written)
        compacted.numbers = kept.map { numbers[$0] }
        compacted.states = kept.map { states[$0] }
        return compacted
    }
}

/// Face vector file guide
///
/// The file `FaceVectors` writes its slots to: created in the user's temporary directory and
/// unlinked at once, so it has no name, lives exactly as long as the process holds it, and
/// leaves nothing on disk after a crash. It is made again from the catalog's `face_embedding`
/// rows every launch, so it is never stale and never a second source of truth (ADR 0047), and it
/// is never in a media folder. Slots are written with `pwrite(2)` and read through a read-only
/// shared mapping, so its pages are clean and file-backed: the system writes them out and drops
/// them under pressure, and `phys_footprint` never counts them.
///
/// A slot once written never changes, so a mapping made earlier stays valid while later slots
/// are written past it. The descriptor is closed when the last value holding the file goes;
/// each mapping is unmapped when the last `Data` slicing it goes.
final nonisolated class FaceVectorFile: Sendable {
    enum Failure: Error, Equatable {
        case create(errno: Int32)
        case write(errno: Int32)
        case map(errno: Int32)
    }

    private let descriptor: Int32

    init() throws(Failure) {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "otos-face-vectors-\(UUID().uuidString)").path(percentEncoded: false)
        let descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw .create(errno: errno)
        }
        unlink(path)
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    /// Writes every byte of `bytes` at `offset`.
    func write(_ bytes: UnsafeRawBufferPointer, at offset: Int) throws(Failure) {
        guard let base = bytes.baseAddress else { return }
        var done = 0
        while done < bytes.count {
            let result = pwrite(descriptor, base + done, bytes.count - done, off_t(offset + done))
            if result < 0 {
                guard errno == EINTR else { throw .write(errno: errno) }
                continue
            }
            done += result
        }
    }

    /// The file's first `length` bytes, mapped read-only; the `Data` owns the mapping.
    func map(length: Int) throws(Failure) -> Data {
        guard length > 0 else { return Data() }
        guard let region = mmap(nil, length, PROT_READ, MAP_SHARED | MAP_FILE, descriptor, 0), region != MAP_FAILED else {
            throw .map(errno: errno)
        }
        return Data(bytesNoCopy: region, count: length, deallocator: .custom { base, count in
            munmap(base, count)
        })
    }
}
