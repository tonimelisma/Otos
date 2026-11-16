import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import OSLog

/// Where a query's results stop (ADR 0048): a photo matches when its cosine is within
/// `margin` of the best photo's and at least `floor`. How well a photo can score depends on
/// the query — a short word scores lower than a precise phrase — so the cut follows the best
/// match; the floor keeps a query that matches nothing from showing its least bad photos.
nonisolated struct SearchCutoff: Sendable, Equatable {
    let floor: Float
    let margin: Float

    /// Calibrated on the owner's judged queries (`docs/research/2026-11-09-keyword-search.md`
    /// §8): 83% of the judged relevant photos kept, a median of 123 shown, against 84% and 140
    /// for the best single cosine, whose longest lists ran to 854 photos rather than 418.
    static let calibrated = SearchCutoff(floor: 0.08, margin: 0.04)

    /// Every photo, ranked: what a test of the ranking compares.
    static let none = SearchCutoff(floor: -.infinity, margin: .infinity)

    func threshold(best: Float) -> Float {
        max(floor, best - margin)
    }
}

/// The photos a query matches, and how well.
nonisolated struct SearchMatches: Sendable, Equatable {
    let encoding: SearchQueryEncoding
    /// Every asset the picture's words match, with its score; nil when the query has no
    /// picture words ("in September"), so the picture does not narrow it.
    let scores: [MediaAssetID: Float]?
    /// The assets the query's facts allow (when, where, who); nil when it names none.
    let allowed: Set<MediaAssetID>?
    /// The scope's assets compared: those with a current embedding.
    let searchedCount: Int
    /// The index's `revision` the answer was computed at.
    let indexRevision: UInt64
}

/// Photo search index guide (ADR 0048)
///
/// The one owner of keyword search over the catalog: it makes the search embeddings, keeps
/// them in memory and answers queries.
///
/// - **Embedding** is one loop, woken by a doorbell (ADR 0032 rule 3) that a Store change of a
///   kind a pass reads rings (`inputs`; its own writes do not). Each wake reconciles memory with the catalog — embeddings whose asset
///   moved, left or got a new thumbnail drop out, ones it does not hold are read in — then
///   embeds every asset whose stored thumbnail has no current embedding, a page at a time,
///   newest capture first (`SearchEmbeddingStorage`). The thumbnails are decoded and read by
///   `SearchImageEmbedder` on its own queue; the results are written only where the
///   thumbnail is still the one read, and what was written joins memory. A pass that leaves
///   work owed it could not do (a model that would not load, a prediction or a write that
///   failed) is logged and rings again after a backoff, 30 s doubling to 15 minutes: nothing
///   reports when the cause clears (a full disk, Core ML), and a settled catalog rings no
///   change, so without it a hidden Otos would stop reading until relaunch.
/// - **Memory** is every current embedding in one mapped file (`SearchVectorFile`): clean,
///   file-backed pages outside the process's footprint, so a query is one pass of Float16
///   rows times the query (about 14 ms over 165,000 photos) and never touches SQLite. A launch
///   with a current file maps it and reads no table; a missing, torn or stale one is rebuilt
///   from `search_embedding` while search shows what it has read, nothing.
/// - **A query** is read by `queries` (`SearchQueryReader`, which owns `SearchQueryEncoder`:
///   language, translation, text tower) and answered here from its encoding, among the scope's
///   assets: the cut follows the best match in the scope, so a folder whose best photo of a
///   dog scores below the library's best still shows it.
/// - **A read that cannot be made** (a thumbnail or preview that does not decode, a prediction
///   that fails) records nothing, so the asset stays owed; a pass pages past it to the rest and
///   tries it again after the backoff. A text reading whose session ends (Vision lost its
///   reader for the reading process, `SearchTextReader`) ends the pass's reading: every still
///   not read stays owed, and the retry after the backoff reads them in a new session.
///
/// `revision` moves whenever memory gains or loses an embedding or a text reading, and every
/// answer carries the revision it was computed at: the same query over the same scope and
/// facts at the same revision is the same answer, so a projection holding one need not ask
/// again (`CatalogProjectionReads.Search`). `changes` yields after it moves, so a projection
/// showing results can ask again. The forwarder and the loop hold this actor weakly and end
/// with it. `shutdown` also ends the text reader's child process, a reading in it or not,
/// and returns once it is gone; the still whose reading it cut short stays owed.
actor PhotoSearchIndex {
    typealias ReadTexts = @Sendable (Set<MediaAssetID>) async throws -> [MediaAssetID: String]

    private let store: CatalogStore
    private let thumbnailDirectory: URL?
    private let embedder: SearchImageEmbedder
    /// Reads what the user searches for, off the window's publication loop.
    nonisolated let queries: SearchQueryReader
    private let pageSize: Int
    private let cutoff: SearchCutoff

    /// Where the vector file lives (`CatalogStore.searchIndexDirectory`).
    private let vectorDirectory: URL
    /// Every embedding memory holds (`SearchVectorFile`); nil until the first pass has opened
    /// or built the file.
    private var vectors: SearchVectorFile?
    /// The last scope a query was answered among, as rows: one hash per asset when the scope
    /// or memory changes, none while the same scope is searched again.
    private var scoped: ScopedRows?
    private var vocabulary: SearchLabelVocabulary?
    /// Every non-empty text reading, by asset, folded once for matching
    /// (`SearchTextReading.folded`).
    private var texts: [MediaAssetID: String] = [:]
    /// Every current reading memory has taken in, empty ones included: what a reconcile
    /// compares with the catalog's current readings, so a reading with no text is not read
    /// again each pass. Nil until the first text reconcile has read them all.
    private var textsRead: Set<MediaAssetID>?
    /// Moves with every change to the embeddings and readings in memory (`announce()`), in the
    /// same step as the change: what an answer is computed from. Never reset, so an equal
    /// revision means the same memory.
    private(set) var revision: UInt64 = 0
    private let textReader: SearchTextReader
    /// Reads the current text readings of the ids memory lacks: the Store's, unless a test
    /// suspends the read to answer a query at that await.
    private let readTexts: ReadTexts
    private let bundle: Bundle
    /// Runs a build of the vector file one heavy load at a time with the other owners'
    /// (`LoadAdmission`).
    private let admission: LoadAdmission
    private var loaded = false

    private var loop: Task<Void, Never>?
    private var forwarder: Task<Void, Never>?
    private var ring: AsyncStream<Void>.Continuation?
    /// Passes asked for and the one the last finished pass answered (ADR 0032 rule 2); a test
    /// waits on `requested` to know a change asked for a pass.
    private(set) var requested: UInt64 = 0
    private var covered: UInt64 = 0
    private var retry: Task<Void, Never>?
    private let backoff: (first: Duration, last: Duration)
    private var nextRetry: Duration
    /// How many retries were scheduled: what a test waits on.
    private(set) var retriesScheduled = 0
    /// How many passes ran to their end: what a test waits on.
    private(set) var passesFinished = 0
    private var changeContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    init(
        store: CatalogStore,
        thumbnailDirectory: URL?,
        vectorDirectory: URL,
        bundle: Bundle,
        pageSize: Int = 16,
        cutoff: SearchCutoff = .calibrated,
        backoff: (first: Duration, last: Duration) = (.seconds(30), .seconds(900)),
        queries: SearchQueryReader? = nil,
        textReader: SearchTextReader = SearchTextReader(),
        readTexts: ReadTexts? = nil,
        admission: LoadAdmission = LoadAdmission(isOpen: true)
    ) {
        self.admission = admission
        self.store = store
        self.textReader = textReader
        self.readTexts = readTexts ?? { [store] ids in try await store.currentSearchTexts(for: ids) }
        self.backoff = backoff
        nextRetry = backoff.first
        self.bundle = bundle
        self.cutoff = cutoff
        self.thumbnailDirectory = thumbnailDirectory
        self.vectorDirectory = vectorDirectory
        embedder = SearchImageEmbedder(bundle: bundle)
        let encoder = SearchQueryEncoder(bundle: bundle)
        self.queries = queries ?? SearchQueryReader { try await encoder.encode($0) }
        self.pageSize = pageSize
    }

    func start() async {
        guard loop == nil else { return }
        let (doorbell, ring) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let changes = await store.changeNotifications()
        self.ring = ring
        ring.yield()
        requested &+= 1
        let inputs = await Self.inputs.facts(in: store, owner: "search.index")
        forwarder = Task { [weak self] in
            for await change in changes {
                guard let self else { break }
                await heard(change, inputs: inputs)
            }
            ring.finish()
        }
        loop = Task { [weak self] in
            for await _ in doorbell {
                guard let self else { return }
                await refreshIfRequested()
            }
        }
    }

    /// What a pass reads (`CatalogOwnerInputs`): its embedding and text walks and its
    /// reconciles, less what it writes itself (search content, and the labels On This Day
    /// reads), and which roots are reachable. A change of none of these asks for no pass.
    static let inputs = CatalogOwnerInputs(
        statements: [
            SearchEmbeddingStorage.candidatesSQL(rootCount: 1, position: "a.best_capture_local IS NOT NULL", order: ""),
            SearchTextStorage.candidatesSQL(rootCount: 1, position: "a.best_capture_local IS NOT NULL", order: ""),
            SearchEmbeddingStorage.currentEmbeddingIDsSQL(rootCount: 1),
            SearchEmbeddingStorage.storedRowsSQL, SearchEmbeddingStorage.currentEmbeddingByKeySQL,
            SearchTextStorage.currentReadingIDsSQL(rootCount: 1), SearchTextStorage.storedLinesSQL,
            SearchTextStorage.currentLinesByKeySQL,
        ],
        ownWrites: [.searchContent, .searchReadings],
        beyondSQL: .membership
    )

    /// Store changes heard: what a test waits on before it counts `requested`.
    private(set) var changesHeard = 0

    /// Asks for a pass when `change` is of a kind a pass reads.
    private func heard(_ change: CatalogStoreChange, inputs: CatalogChangedFacts) {
        changesHeard += 1
        if change.touches(inputs) {
            request()
        }
    }

    /// Asks for a pass (ADR 0032 rule 2). A pass under way answers it at its next page: an
    /// embedding walk starts again from the newest asset, and a text walk ends, so the pass
    /// that follows embeds what the change made owed before more previews are read.
    private func request() {
        requested &+= 1
        ring?.yield()
    }

    private func refreshIfRequested() async {
        guard requested != covered else { return }
        await refresh()
    }

    /// Ends the loop and the text reader's child now: the window's teardown and a test's. A
    /// quit needs none of it — the loops end with the process, and so does the child, whose
    /// input closes with Otos (`SearchTextChild`).
    func shutdown() async {
        await textReader.shutdown()
        await queries.shutdown()
        forwarder?.cancel()
        loop?.cancel()
        retry?.cancel()
        forwarder = nil
        loop = nil
        retry = nil
        ring = nil
        for continuation in changeContinuations.values {
            continuation.finish()
        }
        changeContinuations = [:]
    }

    /// Yields after the embeddings in memory change.
    func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        changeContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeChangeContinuation(id) }
        }
        return stream
    }

    /// The assets of `scope` that `encoding` matches, among those with a current embedding, and
    /// that the Store finds for `facts`: the query's facts as of the asker's now
    /// (`SearchFacts.filter(at:in:)`), nil when it names none. The cut and the label gate's
    /// near-best band follow the best match in the scope, not the library's: the scope is what
    /// the user asked to be searched. The vocabulary is loaded and memory read before the one
    /// await, so the answer is what the index held at the revision it carries.
    func matches(
        _ encoding: SearchQueryEncoding,
        facts: SearchFactFilter?,
        among scope: [MediaAssetID]
    ) async throws -> SearchMatches {
        let start = ContinuousClock.now
        let vocabulary = encoding.embedding == nil ? nil : labelVocabulary()
        let computedAt = revision
        let rows = scopedRows(scope)
        var matched: [MediaAssetID: Float]?
        var named: [String] = []
        var textMatches = 0
        if let query = encoding.embedding {
            let scores = vectors?.scores(query) ?? []
            let best = rows.rows.lazy.map { scores[Int($0)] }.max() ?? 0
            let threshold = cutoff.threshold(best: best)
            named = vocabulary?.labels(namedBy: query) ?? []
            var picture: [MediaAssetID: Float] = [:]
            if let vectors {
                for row in rows.rows.lazy.map({ Int($0) })
                    where scores[row] >= threshold
                    && SearchLabelGate.keeps(score: scores[row], best: best, named: named, confidence: { vectors.confidence(slot: row, of: $0) })
                {
                    picture[vectors.keys.slotIDs[row]] = scores[row]
                }
            }
            // A photo showing the words matches, whatever the cut. A query naming no scene label
            // ("according", "presenting") is about the words, so those photos rank first; one
            // naming a thing ("dog", "lake") is about the picture, and a sign saying DOG keeps
            // its picture's place (research §9: word queries 0.13 → 0.84 recall@10, picture
            // queries unchanged at 0.846). The words are tried as typed and as the English, once
            // when they are the same words.
            let lift = named.isEmpty ? Self.textMatchScore : 0
            let typed = SearchTextQuery(encoding.text), english = SearchTextQuery(encoding.pictureText)
            let englishDiffers = english != typed
            let rowOf = vectors?.rowOf
            for (id, folded) in texts
                where (typed.matches(folded: folded) || (englishDiffers && english.matches(folded: folded)))
                && rows.contains(id, rowOf: rowOf)
            {
                picture[id] = lift + (rowOf?[id].map { scores[Int($0)] } ?? 0)
                textMatches += 1
            }
            matched = picture
        }
        var allowed: Set<MediaAssetID>?
        if let facts {
            allowed = try await store.searchFactMatches(facts)
        }
        OtosLog.catalog.noticeOperation("search.match", phase: "done", fields: [
            "scope": "\(scope.count)",
            "searched": "\(rows.rows.count)",
            "scopeReused": "\(rows.reused)",
            "matched": "\(matched.map { "\($0.count)" } ?? "unnarrowed")",
            "allowed": "\(allowed.map { "\($0.count)" } ?? "unnarrowed")",
            "labels": "\(named.count)",
            "textMatches": "\(textMatches)",
            "reading": encoding.reading.rawValue,
            "ms": "\(DiagnosticsTiming.milliseconds(since: start))",
        ])
        return SearchMatches(
            encoding: encoding, scores: matched, allowed: allowed, searchedCount: rows.rows.count, indexRevision: computedAt
        )
    }

    /// `scope`'s assets as the slots memory holds them, and those it holds none for: the last
    /// answer while the scope and memory are what they were (`revision`), else read again.
    private func scopedRows(_ scope: [MediaAssetID]) -> ScopedRows {
        if var held = scoped, held.revision == revision, held.scope == scope {
            held.reused = true
            return held
        }
        var rows: [Int32] = []
        rows.reserveCapacity(scope.count)
        var member = [Bool](repeating: false, count: vectors?.slots ?? 0)
        var unrowed: Set<MediaAssetID> = []
        let rowOf = vectors?.rowOf ?? [:]
        for id in scope {
            if let row = rowOf[id] {
                rows.append(row)
                member[Int(row)] = true
            } else {
                unrowed.insert(id)
            }
        }
        let made = ScopedRows(scope: scope, revision: revision, rows: rows, member: member, unrowed: unrowed, reused: false)
        scoped = made
        return made
    }

    /// A scope's assets as memory's slots (`scopedRows`).
    nonisolated struct ScopedRows {
        let scope: [MediaAssetID]
        let revision: UInt64
        /// The live slot of every asset of the scope memory holds one for.
        let rows: [Int32]
        /// By slot, whether it is one of `rows`.
        let member: [Bool]
        /// The scope's assets memory holds no slot for.
        let unrowed: Set<MediaAssetID>
        var reused: Bool

        func contains(_ id: MediaAssetID, rowOf: [MediaAssetID: Int32]?) -> Bool {
            if let row = rowOf?[id] {
                return Int(row) < member.count && member[Int(row)]
            }
            return unrowed.contains(id)
        }
    }

    /// Added to a text match's picture score for a query about words, so it ranks above every
    /// cosine.
    static let textMatchScore: Float = 2

    /// Every row's cosine with `query`: one matrix–vector product over the row-major matrix.
    static func scores(_ vectors: [Float], count: Int, query: [Float]) -> [Float] {
        var scores = [Float](repeating: 0, count: count)
        if count > 0 {
            vDSP_mmul(vectors, 1, query, 1, &scores, 1, vDSP_Length(count), 1, vDSP_Length(SearchEmbedding.dimensions))
        }
        return scores
    }

    /// Loaded on first use; a vocabulary that does not load gates nothing, and says so.
    private func labelVocabulary() -> SearchLabelVocabulary? {
        if vocabulary == nil {
            do {
                vocabulary = try SearchLabelVocabulary(bundle: bundle)
            } catch {
                OtosLog.catalog.errorOperation("search.labels", phase: "loadFailed", fields: ["error": String(describing: error)])
            }
        }
        return vocabulary
    }

    /// The embeddings in memory: what a test waits on.
    var embeddedCount: Int {
        vectors?.live ?? 0
    }

    /// The vector file memory maps, and its slots, dead ones included: what a test inspects.
    var vectorFileSlots: (id: UUID, slots: Int)? {
        vectors.map { ($0.id, $0.slots) }
    }

    /// How the first pass came by the vector file: what a test waits on.
    private(set) var loadedFrom: LoadSource?

    nonisolated enum LoadSource: Sendable, Equatable {
        /// The file the catalog names, mapped with no table read.
        case file
        /// Built from `search_embedding`, because none was current (`SearchVectorFileInvalid`).
        case rebuilt
    }

    private func refresh() async {
        var settled = false
        let answering = requested
        do {
            try await reconcile()
            let embedding = try await drain()
            try await reconcileTexts()
            settled = try await drainTexts() && embedding.settled
            covered = answering
        } catch is CancellationError {
            // Teardown: the task, or the load admission it waited in, ended.
            return
        } catch {
            OtosLog.thumbnails.errorOperation("search.index", phase: "failed", fields: [
                "error": String(describing: error),
            ])
        }
        guard !Task.isCancelled else { return }
        passesFinished += 1
        if settled {
            retry?.cancel()
            retry = nil
            nextRetry = backoff.first
        } else {
            scheduleRetry()
        }
    }

    /// One retry at a time; each one waits twice as long as the last, up to `backoff.last`.
    private func scheduleRetry() {
        guard retry == nil, ring != nil else { return }
        let delay = nextRetry
        nextRetry = min(nextRetry * 2, backoff.last)
        retriesScheduled += 1
        OtosLog.thumbnails.noticeOperation("search.index", phase: "retryScheduled", fields: [
            "seconds": "\(delay.components.seconds)",
        ])
        retry = Task { [weak self] in
            // time: backoff — a read that failed; nothing reports when it would succeed
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await retryFired()
        }
    }

    private func retryFired() {
        retry = nil
        request()
    }

    /// Brings memory in line with the catalog's current embeddings. On the first pass memory is
    /// loaded (`load()`): a file built now is current, and the pass goes on; a file opened is
    /// memory as the last session left it, and is reconciled like any pass. Which embeddings are
    /// current is read from indexes alone (`CatalogStore.currentSearchEmbeddingIDs`), the ones
    /// memory lacks are sought by key and appended, and those no longer current go. A root not
    /// read now (a card out, a library offline) keeps its embeddings until it is back or
    /// forgotten. A file with many dead slots is then compacted.
    private func reconcile() async throws {
        if !loaded, try await load() == .rebuilt {
            return
        }
        guard let vectors else { return }
        let current = try await store.currentSearchEmbeddingIDs()
        let gone = vectors.rowOf.keys.filter { id in
            current.readRoots.contains(id.libraryRootPath)
                ? !current.ids.contains(id)
                : !current.catalogedRoots.contains(id.libraryRootPath)
        }
        let missing = current.ids.filter { vectors.rowOf[$0] == nil }
        let added = missing.isEmpty ? [] : try await store.currentSearchEmbeddings(for: Set(missing))
        guard !gone.isEmpty || !added.isEmpty else { return }
        vectors.remove(gone)
        if !added.isEmpty {
            try await store.addSearchVectorSlots(added.count)
            try await append(added, to: vectors)
        }
        announce()
        await compactIfOwed()
    }

    /// The first load. The file the catalog names is opened when it is current
    /// (`SearchVectorFile.open`: off the actor, no table read, the vectors mapped not read);
    /// otherwise it is built. Returns how memory came by it.
    private func load() async throws -> LoadSource {
        let start = ContinuousClock.now
        var source = LoadSource.file
        var stateMs = 0, openMs = 0
        do {
            guard let state = try await store.searchVectorFileState() else { throw SearchVectorFileInvalid.missing }
            stateMs = DiagnosticsTiming.milliseconds(since: start)
            let opening = ContinuousClock.now
            vectors = try await Self.open(directory: vectorDirectory, state: state)
            openMs = DiagnosticsTiming.milliseconds(since: opening)
        } catch let invalid as SearchVectorFileInvalid {
            OtosLog.thumbnails.noticeOperation("search.vectors", phase: "rebuilding", fields: ["reason": invalid.reason])
            vectors = nil
            // A build reads every stored vector: one heavy load at a time with the other
            // owners'. Opening a current file reads none and waits for no one.
            try await admission.run(.searchIndex) {
                try await rebuild()
            }
            source = .rebuilt
        }
        loaded = true
        loadedFrom = source
        let slots = vectors?.slots ?? 0
        let mappedMB = SearchVectorFormat.vectorsLength(slots: slots) / 1_048_576
        OtosLog.thumbnails.noticeOperation("search.index", phase: "loaded", fields: [
            "count": "\(embeddedCount)", "slots": "\(slots)", "mappedMB": "\(mappedMB)", "from": "\(source)",
            "stateMs": "\(stateMs)", "openMs": "\(openMs)", "ms": "\(DiagnosticsTiming.milliseconds(since: start))",
        ])
        ResourceCheckpoint.record("searchIndexLoaded", fields: ["mappedMB": "\(mappedMB)", "from": "\(source)"])
        announce()
        return source
    }

    @concurrent
    private static func open(directory: URL, state: SearchVectorFileState) async throws -> sending SearchVectorFile {
        try SearchVectorFile.open(directory: directory, state: state)
    }

    /// Builds a new file from the catalog's current embeddings: which are current, from indexes
    /// alone, then every stored embedding in pages of `loadPageSize`, each its own read, the
    /// current ones appended, so no read holds a connection long and no page outlives its
    /// append. The catalog names nothing while it is built, so no commit counts slots of it; it
    /// names the file once every byte is on the disk, and memory takes it then. Other files in
    /// the folder are removed. Paid once a model revision, or when a file was lost or cut short.
    private func rebuild() async throws {
        try await store.setSearchVectorFileState(nil)
        SearchVectorFile.removeOthers(in: vectorDirectory, keeping: nil)
        let file = try SearchVectorFile.create(directory: vectorDirectory, id: UUID())
        let current = try await store.currentSearchEmbeddingIDs()
        var cursor: AssetKeyCursor?
        repeat {
            let page = try await store.searchEmbeddingRows(after: cursor, limit: Self.loadPageSize)
            try await file.append(page.candidates.filter { current.ids.contains($0.id) })
            cursor = page.next
        } while cursor != nil
        try await SearchVectorFile.synchronize(file.descriptors)
        try await store.setSearchVectorFileState(SearchVectorFileState(id: file.id, slots: file.slots))
        vectors = file
    }

    /// Embeddings a build page reads: measured 32–90 ms a page of 2,000 on the owner's catalog
    /// (`docs/research/2026-11-16-plan-0116-due-diligence.md` §5), so no read holds a connection
    /// long.
    static let loadPageSize = 2000

    /// Appends rows the catalog has just committed slots for. A file that cannot take them is
    /// short of the catalog's count, so it is no longer current: memory lets it go and the next
    /// pass builds a new one.
    private func append(_ rows: [StoredSearchEmbeddingRow], to file: SearchVectorFile) async throws {
        do {
            try await file.append(rows)
        } catch {
            OtosLog.thumbnails.errorOperation("search.vectors", phase: "appendFailed", fields: [
                "error": String(describing: error), "rows": "\(rows.count)",
            ])
            vectors = nil
            loaded = false
            throw error
        }
    }

    /// Writes the live slots into a new file once dead ones are a quarter of the live and at
    /// least `compactionFloor`: dead slots cost each query their product and the disk their
    /// bytes. The catalog names the new file once its bytes are on the disk; until then the old
    /// one is current, so a crash at any point leaves one the catalog names. A compaction that
    /// fails keeps the old file and is logged.
    private func compactIfOwed() async {
        guard let old = vectors, old.dead >= Self.compactionFloor, old.dead * 4 >= old.live else { return }
        let start = ContinuousClock.now
        do {
            let file = try SearchVectorFile.create(directory: vectorDirectory, id: UUID())
            try await file.appendLive(of: old)
            try await SearchVectorFile.synchronize(file.descriptors)
            try await store.setSearchVectorFileState(SearchVectorFileState(id: file.id, slots: file.slots))
            vectors = file
            SearchVectorFile.removeOthers(in: vectorDirectory, keeping: file.id)
            OtosLog.thumbnails.noticeOperation("search.vectors", phase: "compacted", fields: [
                "dead": "\(old.dead)", "slots": "\(file.slots)", "ms": "\(DiagnosticsTiming.milliseconds(since: start))",
            ])
        } catch {
            SearchVectorFile.removeOthers(in: vectorDirectory, keeping: old.id)
            OtosLog.thumbnails.errorOperation("search.vectors", phase: "compactFailed", fields: ["error": String(describing: error)])
        }
    }

    static let compactionFloor = 1024

    /// Embeds every asset whose thumbnail has no current embedding, a page at a time, until
    /// none is left. An asset whose read made no embedding (a thumbnail that does not decode, a
    /// prediction that failed) or whose write was refused (its thumbnail changed meanwhile) is
    /// paged past for the rest of the pass, so it cannot hold up the assets after it; a model
    /// that does not load ends the pass. Settled when nothing is owed; `unread` is what was
    /// paged past, still owed.
    private func drain() async throws -> (settled: Bool, unread: Set<MediaAssetID>) {
        var embedded = 0
        var unread: Set<MediaAssetID> = []
        let start = ContinuousClock.now
        defer { logEmbedded(embedded, unread: unread.count, since: start) }
        var walking = requested
        var cursor: CaptureOrderCursor?
        while !Task.isCancelled {
            if requested != walking {
                walking = requested
                cursor = nil
            }
            let page = try await store.searchEmbeddingCandidates(after: cursor, limit: pageSize)
            let owed = page.candidates.filter { !unread.contains($0.id) }
            if !owed.isEmpty {
                guard let results = await embedder.embed(owed, thumbnailDirectory: thumbnailDirectory) else {
                    return (false, unread)
                }
                // The file takes what the catalog commits; a volume at the free-space floor
                // (ADR 0027) takes neither, and the page stays owed until the retry.
                guard let file = vectors, file.admits(rows: results.count) else {
                    OtosLog.thumbnails.noticeOperation("search.vectors", phase: "floorReached", fields: [
                        "rows": "\(results.count)",
                    ])
                    return (false, unread)
                }
                let written = try await store.applySearchEmbeddings(results)
                unread.formUnion(Set(owed.map(\.id)).subtracting(written.map(\.id)))
                if !written.isEmpty {
                    try await append(written.map(StoredSearchEmbeddingRow.init(result:)), to: file)
                    announce()
                }
                embedded += written.count
            }
            guard let next = page.next else {
                return (unread.isEmpty, unread)
            }
            cursor = next
        }
        return (false, unread)
    }

    private func logEmbedded(_ embedded: Int, unread: Int, since start: ContinuousClock.Instant) {
        guard embedded > 0 || unread > 0 else { return }
        OtosLog.thumbnails.noticeOperation("search.index", phase: "embedded", fields: [
            "count": "\(embedded)",
            "unread": "\(unread)",
            "total": "\(embeddedCount)",
            "ms": "\(DiagnosticsTiming.milliseconds(since: start))",
        ])
    }

    /// Brings the text readings in memory in line with the catalog's. Which readings are current
    /// is read from indexes alone (`CatalogStore.currentSearchTextIDs`, empty readings
    /// included). The first time, every stored reading is read in pages of `loadPageSize`, each
    /// its own read, and the current ones kept; after it, only the readings memory has not
    /// taken in are sought by key (`readTexts`), and those no longer current go. A root not
    /// read now keeps its readings. Every read finishes before memory changes: a query answered
    /// while they are awaited (`matches`) reads the memory its revision names, and the removal,
    /// the additions and the revision move in one step.
    private func reconcileTexts() async throws {
        let current = try await store.currentSearchTextIDs()
        guard let read = textsRead else {
            var loading: [MediaAssetID: String] = [:]
            var cursor: AssetKeyCursor?
            repeat {
                let page = try await store.searchTextRows(after: cursor, limit: Self.loadPageSize)
                for row in page.candidates where !row.text.isEmpty && current.ids.contains(row.id) {
                    loading[row.id] = SearchTextReading.folded(row.text)
                }
                cursor = page.next
            } while cursor != nil
            texts = loading
            textsRead = current.ids
            announce()
            return
        }
        let gone = read.filter { id in
            current.readRoots.contains(id.libraryRootPath)
                ? !current.ids.contains(id)
                : !current.catalogedRoots.contains(id.libraryRootPath)
        }
        let missing = current.ids.subtracting(read)
        guard !gone.isEmpty || !missing.isEmpty else { return }
        let added = missing.isEmpty ? [:] : try await readTexts(missing)
        for id in gone {
            texts.removeValue(forKey: id)
        }
        for (id, text) in added {
            texts[id] = SearchTextReading.folded(text)
        }
        textsRead = read.subtracting(gone).union(missing)
        announce()
    }

    /// Reads every owed preview for text in one newest-first walk, a page at a time, after
    /// every embedding is made: a photo is searchable by picture first, and a reading costs far
    /// more. A preview whose reading failed is passed by and stays owed. Settled when the walk
    /// ends with none unread, or when it stops at a page because a change asked for a new pass
    /// (`requested`), which embeds what the change made owed first. Not settled when the
    /// session reading it ends (`SearchTextReader`): what it read before is written, every
    /// other still stays owed, and the retry after the backoff reads them in a new session.
    private func drainTexts() async throws -> Bool {
        var read = 0, withText = 0
        var unread: Set<MediaAssetID> = []
        var settled = false
        var sessionEnded = false
        let start = ContinuousClock.now
        let walking = requested
        var cursor: CaptureOrderCursor?
        while !Task.isCancelled {
            let page = try await store.searchTextCandidates(after: cursor, limit: 8)
            let results: [SearchTextResult]
            if page.candidates.isEmpty {
                results = []
            } else {
                switch await textReader.read(page.candidates, directory: thumbnailDirectory) {
                case let .read(page):
                    results = page
                case let .sessionEnded(before):
                    results = before
                    sessionEnded = true
                }
            }
            let written = results.isEmpty ? [] : try await store.applySearchTexts(results)
            unread.formUnion(Set(page.candidates.map(\.id)).subtracting(written.map(\.id)))
            for result in written {
                texts[result.id] = result.lines.isEmpty ? nil : SearchTextReading.folded(SearchTextReading.searchable(result.lines))
                textsRead?.insert(result.id)
                withText += result.lines.isEmpty ? 0 : 1
            }
            if !written.isEmpty {
                announce()
            }
            read += written.count
            if sessionEnded {
                break
            }
            guard let next = page.next else {
                settled = unread.isEmpty
                break
            }
            // A change since the pass began comes first: the next pass embeds what it made owed
            // before more previews are read.
            if requested != walking {
                settled = true
                break
            }
            cursor = next
        }
        if read > 0 || !unread.isEmpty {
            OtosLog.thumbnails.noticeOperation("search.text", phase: "read", fields: [
                "count": "\(read)", "withText": "\(withText)", "unread": "\(unread.count)",
                "sessionEnded": "\(sessionEnded)", "ms": "\(DiagnosticsTiming.milliseconds(since: start))",
            ])
        }
        return settled
    }

    private func announce() {
        revision &+= 1
        for continuation in changeContinuations.values {
            continuation.yield()
        }
    }

    private func removeChangeContinuation(_ id: UUID) {
        changeContinuations.removeValue(forKey: id)
    }
}

/// Reads stored thumbnails with the image tower and Vision's scene classifier, on its own
/// serial queue: every prediction blocks (ADR 0032 rule 6), and the 94 MB model loads on first
/// use and never leaves it.
actor SearchImageEmbedder {
    private let queue = DispatchSerialQueue(label: "net.melisma.Otos.search.image", qos: .utility)
    private let bundle: Bundle
    private var model: SearchImageModel?

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    init(bundle: Bundle) {
        self.bundle = bundle
    }

    /// One result per candidate read: its embedding and scene labels. A thumbnail that does not
    /// decode, or a prediction that fails, is no reading of the picture: it has no result, so
    /// it stays owed. Nil when the model does not load (or no thumbnail directory is known), so
    /// the pass ends with every candidate owed.
    func embed(_ page: [SearchEmbeddingCandidate], thumbnailDirectory: URL?) -> [SearchEmbeddingResult]? {
        do {
            if model == nil {
                model = try SearchImageModel(bundle: bundle)
            }
        } catch {
            OtosLog.thumbnails.errorOperation("search.model", phase: "loadFailed", fields: [
                "error": String(describing: error),
            ])
            return nil
        }
        guard let model, let thumbnailDirectory else { return nil }
        return page.compactMap { candidate in
            let url = thumbnailDirectory.appending(path: candidate.thumbnailPath)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                OtosLog.thumbnails.errorOperation("search.embed", phase: "undecodable", fields: [
                    "id": candidate.id.relativePath.rawValue,
                ])
                return nil
            }
            do {
                let scene = try SearchSceneLabels.classify(image)
                return try SearchEmbeddingResult(
                    id: candidate.id,
                    source: candidate.source,
                    embedding: model.embedding(of: image),
                    labels: scene.labels,
                    confidentLabels: scene.confident
                )
            } catch {
                // A prediction that fails is not a fact about the thumbnail: nothing is
                // recorded, and the asset stays owed.
                OtosLog.thumbnails.errorOperation("search.embed", phase: "failed", fields: [
                    "error": String(describing: error),
                ])
                return nil
            }
        }
    }
}
