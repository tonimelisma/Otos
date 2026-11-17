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
///
/// **No room for the vectors** (ADR 0027, ADR 0032 rule 8). When the vectors a pass owes would
/// take the volume below the free-space floor, or their write finds it full, the owner holds
/// that fact (`spaceHold`), logs it once (`op=people.vectors phase=floorHeld`) and arms one
/// wake, a backoff (`time: backoff`: nothing reports when space comes back). Until the wake
/// finds room, a pass reads nothing and assigns nothing: a change only adds the photos it names
/// to what the next read owes. What People shows meanwhile is what the catalog holds — the
/// guesses and gallery facts last written, and the read held (`lastRead`), so ranking goes on
/// over the vectors held and a face whose vector is not held is offered no candidates. Nothing
/// is published as empty. When the wake finds room it says so (`phase=floorCleared`) and owes
/// one pass, which reads by key what changed since and assigns.
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
    private var vectorStore: FaceVectorStore
    /// The vectors held, as every reader takes them.
    private var vectors: FaceVectors {
        vectorStore.vectors
    }

    /// The volume had no room for the vectors owed: no pass reads until the wake finds room.
    private var spaceHold: SpaceHold?
    private var spaceRetry: Task<Void, Never>?
    private let spaceBackoff: (first: Duration, last: Duration)

    private struct SpaceHold {
        /// The pause before the wake after the next.
        var next: Duration
    }

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

    /// `vectorSpace` is where the vectors' file is made and the free space its volume reports;
    /// `spaceBackoff` the first and the longest pause before a wake looks for room again.
    init(
        store: CatalogStore,
        vectorSpace: FaceVectorFile.Space,
        admission: LoadAdmission = LoadAdmission(isOpen: true),
        spaceBackoff: (first: Duration, last: Duration) = (.seconds(30), .seconds(900))
    ) {
        self.store = store
        self.admission = admission
        self.spaceBackoff = spaceBackoff
        vectorStore = FaceVectorStore(space: vectorSpace)
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

    /// Teardown, callable from anywhere: ends the loop. A wake waiting for room holds this
    /// owner weakly and is cancelled when it goes.
    nonisolated func stop() {
        doorbell.finish()
    }

    deinit {
        spaceRetry?.cancel()
    }

    /// The people each face of `photos` could be, from the last pass's read: a hidden
    /// person's face is not ranked, and a hidden person is never a candidate. The vectors owed
    /// are read first; nil when they cannot be read (logged), which is no ranking, not an
    /// empty one.
    func candidates(for photos: [MediaAssetID]) async -> [FaceID: [FaceCandidate]]? {
        guard let read = lastRead else {
            return [:]
        }
        // At the floor the vectors held are ranked: a face whose vector is not held gets none.
        if spaceHold == nil {
            do {
                try await syncVectors(for: read)
            } catch let failure as FaceVectorFile.Failure where failure.isNoSpace {
                holdForSpace(failure)
            } catch {
                OtosLog.catalog.errorOperation("people.candidates", phase: "vectorsFailed", fields: [
                    "error": String(describing: error),
                ])
                return nil
            }
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
        // No room for the vectors: the wake that finds room owes the pass; this one reads
        // nothing, and the photos a change named wait in `owedRows`.
        guard spaceHold == nil else {
            answered = startedFrom
            return
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
        } catch let failure as FaceVectorFile.Failure where failure.isNoSpace {
            // The read stands (`lastRead`), and what changed since it is in `owedRows`: the
            // pass is held, not failed, so it covers the request and the wake owes the next.
            holdForSpace(failure)
            answered = startedFrom
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
            let page = try await store.backgroundReads.faceEmbeddings(after: vectors.owed, limit: FaceVectorStore.pageSize)
            let owed = vectors.owed
            let fresh = page.filter { $0.vector > owed }
            try vectorStore.add(fresh)
            malformed += fresh.filter { $0.embedding == nil }.map(\.vector)
            ranker = nil
            if page.count < FaceVectorStore.pageSize {
                break
            }
        }
        try vectorStore.keep(read.vectors, through: read.vectorHorizon)
        guard !malformed.isEmpty else { return }
        let bad = Set(malformed)
        try await store.oweFacesAgain(Set(MappedArrayBuilder.collect(read.faces) { bad.contains($0.vector) ? $0.id.asset : nil }))
    }
}

extension PeopleAssignment {
    /// Holds "no room for the vectors" and arms the wake that looks for room; logged once,
    /// when the hold begins.
    private func holdForSpace(_ failure: FaceVectorFile.Failure) {
        guard spaceHold == nil else { return }
        spaceHold = SpaceHold(next: spaceBackoff.first)
        OtosLog.catalog.noticeOperation("people.vectors", phase: "floorHeld", fields: [
            "reason": "\(failure)", "vectors": "\(vectors.count)",
        ])
        armSpaceRetry()
    }

    /// One wake at a time; each waits twice as long as the last, up to `spaceBackoff.last`.
    private func armSpaceRetry() {
        guard var hold = spaceHold, spaceRetry == nil else { return }
        let delay = hold.next
        hold.next = min(hold.next * 2, spaceBackoff.last)
        spaceHold = hold
        activity.wake = OwnerWake(kind: .backoff, at: ContinuousClock.now.advanced(by: delay))
        spaceRetry = Task { [weak self] in
            // time: backoff — the volume was at the free-space floor; nothing reports when
            // space comes back
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await spaceRetryFired()
        }
    }

    /// The wake: when the volume has room for a page of vectors again, the hold ends and one
    /// pass is owed; otherwise the wake is armed again and nothing is read. Internal so a test
    /// delivers the wake at its point rather than waiting for it.
    func spaceRetryFired() {
        spaceRetry = nil
        activity.wake = nil
        guard spaceHold != nil else { return }
        do {
            try vectorStore.space.admit(bytes: FaceVectorStore.pageSize * FaceVector.byteCount)
        } catch {
            armSpaceRetry()
            settleQuiescence()
            return
        }
        spaceHold = nil
        OtosLog.catalog.noticeOperation("people.vectors", phase: "floorCleared", fields: [
            "vectors": "\(vectors.count)",
        ])
        request(rows: .none)
    }

    /// Whether the owner holds "no room for the vectors": what a test checks.
    var isHeldForSpace: Bool {
        spaceHold != nil
    }

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
/// Two types, so that only one value can write the file:
/// - **`FaceVectorStore`** is the one writer: non-copyable, held by `PeopleAssignment`, it owns
///   the file and is the only value that appends to it or compacts it.
/// - **`FaceVectors`** is what readers take (assignment, ranking, a pass's facts): the slots
///   written so far and their mapping, copyable and holding no file, so a copy reads what it
///   was made with and cannot write anything. A copy a pass still reads keeps the mapping it
///   was made with: an append writes past it, and a compaction writes another file.
///
/// - **Slots:** each vector is one slot of `FaceEmbeddingModel.dimensions` Float16 values,
///   appended in vector-number order, so `numbers` is ascending and a vector is found by binary
///   search. A vector handed out is a slice of the mapping (`FaceVector`), never a copy.
/// - **Reading:** `owed` is the number above which the catalog may hold vectors this does not.
///   `CatalogStore.faceEmbeddings(after:limit:)` reads them `pageSize` at a time, each page its
///   own short read, and `add(_:)` writes a page's slots to the file and maps it again. A
///   reading's vector is never rewritten in place: a new reading writes a new row with a higher
///   number, so nothing at or below `owed` changes, and a slot once written never changes.
/// - **Free space:** a page's slots are written only while the volume keeps the free-space
///   floor after them (ADR 0027, `FreeSpaceFloor`); otherwise, and when the write itself finds
///   the volume full, `add(_:)` throws a failure that `isNoSpace` and holds what it held.
/// - **Forgetting:** `keep(_:through:)` drops every vector no stored face names. A dropped slot
///   stays in the file until a compaction, which runs when a quarter of the slots are dropped
///   and writes the slots kept into a new file; at the floor no compaction runs, and the
///   dropped slots stay unread in the file they are in.
/// - **Malformed rows:** a vector whose bytes are no embedding is held as malformed, so its
///   face is left out of assignment and its photo owes its faces again (`malformed`).
nonisolated struct FaceVectors: Sendable {
    /// Every slot written, mapped read-only.
    fileprivate(set) var mapped = Data()
    /// Each slot's vector number, ascending.
    fileprivate(set) var numbers: [Int64] = []
    /// Each slot's state: `recognisableFlag`, `droppedFlag`.
    fileprivate(set) var states: [UInt8] = []
    fileprivate(set) var dropped = 0
    /// The vectors whose bytes hold no embedding.
    fileprivate(set) var malformed: Set<Int64> = []
    /// The largest vector number read; the catalog's rows above it are not held.
    fileprivate(set) var owed: Int64 = 0

    fileprivate static let recognisableFlag: UInt8 = 1
    fileprivate static let droppedFlag: UInt8 = 2

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
}

/// The one writer of People's vector file (see the face vectors guide). Non-copyable, so no
/// second value can append to the file it owns: everyone else reads `vectors`.
nonisolated struct FaceVectorStore: ~Copyable, Sendable {
    /// One row of the vector table as read: its number, and its embedding, nil when its bytes
    /// hold none.
    nonisolated struct Read: Sendable, Equatable {
        let vector: Int64
        let embedding: FaceEmbedding?
    }

    /// Vectors per read: 4 MB of rows, one short read each.
    static let pageSize = 2048

    /// Where the file is made and the free space its volume reports (ADR 0027).
    let space: FaceVectorFile.Space
    /// The file the slots are written to; nil until the first is written.
    private var file: FaceVectorFile?
    /// What the file holds, for every reader.
    private(set) var vectors = FaceVectors()

    init(space: FaceVectorFile.Space) {
        self.space = space
    }

    /// Writes the slots of a page read in number order above `owed`; rows at or below it are
    /// already held and are passed over. A write that fails, or that the free-space floor
    /// refuses, leaves what is held as it was.
    mutating func add(_ page: [Read]) throws(FaceVectorFile.Failure) {
        var owed = vectors.owed
        var malformed = vectors.malformed
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
            let bytes = fresh.count * FaceVector.byteCount
            try space.admit(bytes: bytes)
            // The page's slots, made once in a region of their own and unmapped as this returns.
            let slots = ScratchBuffer<Float16>(count: fresh.count * FaceEmbeddingModel.dimensions)
            for (index, read) in fresh.enumerated() {
                FaceVector.halve(read.embedding.values, into: slots.base + index * FaceEmbeddingModel.dimensions)
            }
            let file: FaceVectorFile = if let held = self.file {
                held
            } else {
                try FaceVectorFile(in: space.directory)
            }
            let length = vectors.numbers.count * FaceVector.byteCount
            try file.write(UnsafeRawBufferPointer(start: slots.base, count: bytes), at: length)
            vectors.mapped = try file.map(length: length + bytes)
            self.file = file
            vectors.numbers += fresh.map(\.vector)
            vectors.states += fresh.map { FaceRecognisability.isRecognisable($0.embedding) ? FaceVectors.recognisableFlag : 0 }
        }
        vectors.owed = owed
        vectors.malformed = malformed
    }

    /// Keeps only `named`, the vectors a snapshot's faces name, among the vectors numbered up to
    /// `horizon`, the largest number that snapshot could see: a vector written after it is
    /// some face's newer reading, which a later snapshot names, so it stays. A compaction the
    /// floor refuses, or whose write finds the volume full, is not run: the dropped slots stay
    /// in the file, unread.
    mutating func keep(_ named: Set<Int64>, through horizon: Int64) throws(FaceVectorFile.Failure) {
        var kept = vectors
        for slot in kept.numbers.indices where kept.numbers[slot] <= horizon && kept.states[slot] & FaceVectors.droppedFlag == 0 {
            if !named.contains(kept.numbers[slot]) {
                kept.states[slot] |= FaceVectors.droppedFlag
                kept.dropped += 1
            }
        }
        kept.malformed = kept.malformed.filter { $0 > horizon || named.contains($0) }
        guard kept.dropped * 4 > kept.numbers.count else {
            vectors = kept
            return
        }
        do {
            (file, vectors) = try Self.compacted(kept, space: space)
        } catch where error.isNoSpace {
            vectors = kept
        }
    }

    /// The slots of `held` not dropped, in order, written into a new file.
    private static func compacted(
        _ held: FaceVectors, space: FaceVectorFile.Space
    ) throws(FaceVectorFile.Failure) -> (FaceVectorFile?, FaceVectors) {
        var compacted = FaceVectors()
        compacted.owed = held.owed
        compacted.malformed = held.malformed
        let kept = held.numbers.indices.filter { held.states[$0] & FaceVectors.droppedFlag == 0 }
        guard !kept.isEmpty else { return (nil, compacted) }
        try space.admit(bytes: kept.count * FaceVector.byteCount)
        let file = try FaceVectorFile(in: space.directory)
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
            try held.mapped.withUnsafeBytes { (source: UnsafeRawBufferPointer) throws(FaceVectorFile.Failure) in
                try file.write(UnsafeRawBufferPointer(rebasing: source[from ..< from + bytes]), at: written)
            }
            written += bytes
            start = end
        }
        compacted.mapped = try file.map(length: written)
        compacted.numbers = kept.map { held.numbers[$0] }
        compacted.states = kept.map { held.states[$0] }
        return (file, compacted)
    }
}

/// Face vector file guide
///
/// The file `FaceVectorStore` writes its slots to: created in the user's temporary directory
/// and unlinked at once, so it has no name, lives exactly as long as the process holds it, and
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
        /// The write would take the volume below the free-space floor (ADR 0027).
        case floorReached

        /// The volume has no room for the write: the floor refused it, or the system did.
        var isNoSpace: Bool {
            switch self {
            case .floorReached, .create(errno: ENOSPC), .write(errno: ENOSPC): true
            default: false
            }
        }
    }

    /// Where vector files are made, and the free space its volume reports: the real disk's in
    /// the app (`FreeSpaceFloor.availableBytes`), a test's own figure in a test.
    nonisolated struct Space: Sendable {
        let directory: URL
        let availableBytes: VolumeCapacityReader

        /// In the user's temporary directory, whose volume `availableBytes` is asked about.
        static func temporary(availableBytes: @escaping VolumeCapacityReader) -> Space {
            Space(directory: FileManager.default.temporaryDirectory, availableBytes: availableBytes)
        }

        /// Whether writing `bytes` more keeps the volume at the floor; throws `floorReached`
        /// when it would not. An unknown capacity admits, and the write's `ENOSPC` is the
        /// backstop (`FreeSpaceFloor.admits`).
        func admit(bytes: Int) throws(Failure) {
            guard FreeSpaceFloor.admits(Int64(bytes), available: availableBytes(directory)) else {
                throw .floorReached
            }
        }
    }

    private let descriptor: Int32

    init(in directory: URL) throws(Failure) {
        let path = directory.appending(path: "otos-face-vectors-\(UUID().uuidString)").path(percentEncoded: false)
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
