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
/// - **Memory** is every current embedding as one row-major matrix, so a query is one
///   matrix–vector product (about 3 ms over 19,000 photos) and never touches SQLite.
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

    /// Every current embedding in memory (`SearchMatrix`).
    private var matrix = SearchMatrix()
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
        bundle: Bundle,
        pageSize: Int = 16,
        cutoff: SearchCutoff = .calibrated,
        backoff: (first: Duration, last: Duration) = (.seconds(30), .seconds(900)),
        queries: SearchQueryReader? = nil,
        textReader: SearchTextReader = SearchTextReader(),
        readTexts: ReadTexts? = nil
    ) {
        self.store = store
        self.textReader = textReader
        self.readTexts = readTexts ?? { [store] ids in try await store.currentSearchTexts(for: ids) }
        self.backoff = backoff
        nextRetry = backoff.first
        self.bundle = bundle
        self.cutoff = cutoff
        self.thumbnailDirectory = thumbnailDirectory
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
        let inScope = Set(scope)
        let rows = scope.compactMap { matrix.rowOf[$0] }
        var matched: [MediaAssetID: Float]?
        var named: [String] = []
        var textMatches = 0
        if let query = encoding.embedding {
            let scores = Self.scores(matrix.vectors, count: matrix.ids.count, query: query)
            let best = rows.lazy.map { scores[$0] }.max() ?? 0
            let threshold = cutoff.threshold(best: best)
            named = vocabulary?.labels(namedBy: query) ?? []
            var picture: [MediaAssetID: Float] = [:]
            for row in rows
                where scores[row] >= threshold
                && SearchLabelGate.keeps(score: scores[row], best: best, named: named, confidence: { matrix.confidence(row: row, of: $0) })
            {
                picture[matrix.ids[row]] = scores[row]
            }
            // A photo showing the words matches, whatever the cut. A query naming no scene label
            // ("according", "presenting") is about the words, so those photos rank first; one
            // naming a thing ("dog", "lake") is about the picture, and a sign saying DOG keeps
            // its picture's place (research §9: word queries 0.13 → 0.84 recall@10, picture
            // queries unchanged at 0.846). The words are tried as typed and as the English.
            let lift = named.isEmpty ? Self.textMatchScore : 0
            let typed = SearchTextQuery(encoding.text), english = SearchTextQuery(encoding.pictureText)
            for (id, folded) in texts where inScope.contains(id) && (typed.matches(folded: folded) || english.matches(folded: folded)) {
                picture[id] = lift + (matrix.rowOf[id].map { scores[$0] } ?? 0)
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
            "searched": "\(rows.count)",
            "matched": "\(matched.map { "\($0.count)" } ?? "unnarrowed")",
            "allowed": "\(allowed.map { "\($0.count)" } ?? "unnarrowed")",
            "labels": "\(named.count)",
            "textMatches": "\(textMatches)",
            "reading": encoding.reading.rawValue,
            "ms": "\(DiagnosticsTiming.milliseconds(since: start))",
        ])
        return SearchMatches(
            encoding: encoding, scores: matched, allowed: allowed, searchedCount: rows.count, indexRevision: computedAt
        )
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
        matrix.ids.count
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

    /// Brings memory in line with the catalog's current embeddings: on the first pass, the whole
    /// load (`load()`); after it, which embeddings are current is read from indexes alone
    /// (`CatalogStore.currentSearchEmbeddingIDs`), the ones memory lacks are sought by key, and
    /// those no longer current go. A root not read now (a card out, a library offline) keeps
    /// its embeddings until it is back or forgotten.
    private func reconcile() async throws {
        if !loaded {
            try await load()
            return
        }
        let current = try await store.currentSearchEmbeddingIDs()
        let gone = Set(matrix.ids.filter { id in
            current.readRoots.contains(id.libraryRootPath)
                ? !current.ids.contains(id)
                : !current.catalogedRoots.contains(id.libraryRootPath)
        })
        let missing = current.ids.filter { matrix.rowOf[$0] == nil }
        let added = missing.isEmpty ? [] : try await store.currentSearchEmbeddings(for: Set(missing))
        guard !gone.isEmpty || !added.isEmpty else { return }
        matrix.remove(gone)
        matrix.reserve(added.count)
        for row in added {
            matrix.append(row)
        }
        announce()
    }

    /// The first load: which embeddings are current, from indexes alone, then every stored
    /// embedding in pages of `loadPageSize`, each its own read, appended straight into a matrix
    /// sized once for them, so the load never holds a second copy of the vectors. Memory takes
    /// the matrix in one step at the end: a query answered while the load runs sees the empty
    /// index it saw before, as it did when the load was one read.
    private func load() async throws {
        let start = ContinuousClock.now
        let current = try await store.currentSearchEmbeddingIDs()
        var loading = SearchMatrix()
        loading.reserve(current.ids.count)
        var cursor: AssetKeyCursor?
        var pages = 0
        repeat {
            let page = try await store.searchEmbeddingRows(after: cursor, limit: Self.loadPageSize)
            for row in page.candidates where current.ids.contains(row.id) {
                loading.append(row)
            }
            pages += 1
            cursor = page.next
        } while cursor != nil
        matrix = loading
        loaded = true
        let matrixMB = matrix.vectors.count * MemoryLayout<Float>.size / 1_048_576
        OtosLog.thumbnails.noticeOperation("search.index", phase: "loaded", fields: [
            "count": "\(matrix.ids.count)", "matrixMB": "\(matrixMB)", "pages": "\(pages)",
            "ms": "\(DiagnosticsTiming.milliseconds(since: start))",
        ])
        ResourceCheckpoint.record("searchIndexLoaded", fields: ["matrixMB": "\(matrixMB)"])
        announce()
    }

    /// Embeddings a load page reads: measured 32–90 ms a page of 2,000 on the owner's catalog
    /// (`docs/research/2026-11-16-plan-0116-due-diligence.md` §5), so no read holds a connection
    /// long.
    static let loadPageSize = 2000

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
                let written = try await store.applySearchEmbeddings(results)
                unread.formUnion(Set(owed.map(\.id)).subtracting(written.map(\.id)))
                if !written.isEmpty {
                    matrix.remove(Set(written.map(\.id)))
                    matrix.reserve(written.count)
                    for result in written {
                        matrix.append(result)
                    }
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
            "total": "\(matrix.ids.count)",
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

/// Every current embedding the search index holds (ADR 0048): one row-major matrix of
/// `SearchEmbedding.dimensions` floats a row, the asset of each row, and each row's loose scene
/// labels, compact (`SearchLabelReadings`). The matrix grows geometrically, reserved only to
/// the count a load or a batch knows it will hold, so appending a page never copies the whole
/// matrix; a removal moves the last row into the gap.
nonisolated struct SearchMatrix: Sendable {
    private(set) var ids: [MediaAssetID] = []
    private(set) var rowOf: [MediaAssetID: Int] = [:]
    private(set) var vectors: [Float] = []
    private var labels: [SearchLabelReadings] = []
    private var labelNames = SearchLabelNames()

    /// Room for `count` more rows, grown at least geometrically.
    mutating func reserve(_ count: Int) {
        let needed = (ids.count + count) * SearchEmbedding.dimensions
        guard needed > vectors.capacity else { return }
        vectors.reserveCapacity(max(needed, vectors.capacity * 2))
        ids.reserveCapacity(ids.count + count)
        labels.reserveCapacity(labels.count + count)
    }

    /// A stored row: its vector's bytes appended as they are (little-endian Float32,
    /// `Float32Storage`), its labels' text read once.
    mutating func append(_ row: StoredSearchEmbeddingRow) {
        guard rowOf[row.id] == nil else { return }
        #if _endian(little)
            row.vector.withUnsafeBytes { bytes in
                vectors.append(contentsOf: bytes.bindMemory(to: Float.self))
            }
        #else
            guard let floats = SearchEmbeddingStorage.embedding(from: row.vector) else { return }
            vectors.append(contentsOf: floats)
        #endif
        appendKey(row.id, labels: row.labels)
    }

    /// An embedding just written, its labels as the catalog stored them.
    mutating func append(_ result: SearchEmbeddingResult) {
        guard rowOf[result.id] == nil, result.embedding.count == SearchEmbedding.dimensions else { return }
        vectors.append(contentsOf: result.embedding)
        appendKey(result.id, labels: SearchEmbeddingStorage.labelsText(result.labels))
    }

    private mutating func appendKey(_ id: MediaAssetID, labels text: String?) {
        rowOf[id] = ids.count
        ids.append(id)
        labels.append(SearchLabelReadings(text: text, names: &labelNames))
    }

    /// Row `row`'s confidence in the label `name`, nil when it has none.
    func confidence(row: Int, of name: String) -> Float? {
        labelNames.numbers[name].flatMap { labels[row].confidence(of: $0) }
    }

    /// Removes by moving the last row into each gap, so a removal is O(dimensions).
    mutating func remove(_ gone: Set<MediaAssetID>) {
        let dimensions = SearchEmbedding.dimensions
        for id in gone {
            guard let row = rowOf.removeValue(forKey: id) else { continue }
            let last = ids.count - 1
            if row != last {
                let moved = ids[last]
                ids[row] = moved
                labels[row] = labels[last]
                rowOf[moved] = row
                vectors.withUnsafeMutableBufferPointer { buffer in
                    for index in 0 ..< dimensions {
                        buffer[row * dimensions + index] = buffer[last * dimensions + index]
                    }
                }
            }
            ids.removeLast()
            labels.removeLast()
            vectors.removeLast(dimensions)
        }
    }
}
