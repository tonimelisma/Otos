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
    /// The assets compared: those with a current embedding.
    let searchedCount: Int
}

/// Photo search index guide (ADR 0048)
///
/// The one owner of keyword search over the catalog: it makes the search embeddings, keeps
/// them in memory and answers queries.
///
/// - **Embedding** is one loop, woken by a doorbell (ADR 0032 rule 3) that the Store's change
///   notifications ring. Each wake reconciles memory with the catalog — embeddings whose asset
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
/// - **A query** goes through `SearchQueryEncoder` (language, translation, text tower); the
///   photos `SearchCutoff` keeps match.
///
/// `changes` yields after memory gains or loses embeddings, so a projection showing results
/// can ask again. The forwarder and the loop hold this actor weakly and end with it.
actor PhotoSearchIndex {
    private let store: CatalogStore
    private let thumbnailDirectory: URL?
    private let embedder: SearchImageEmbedder
    private let encoder: SearchQueryEncoder
    private let pageSize: Int
    private let cutoff: SearchCutoff

    private var ids: [MediaAssetID] = []
    private var rowOf: [MediaAssetID: Int] = [:]
    private var vectors: [Float] = []
    /// Each row's scene labels, index-paired with `ids`.
    private var labels: [[String: Float]] = []
    private var vocabulary: SearchLabelVocabulary?
    /// Every non-empty text reading, by asset (`SearchTextReading`).
    private var texts: [MediaAssetID: String] = [:]
    private let textReader = SearchTextReader()
    private let bundle: Bundle
    private var loaded = false

    private var loop: Task<Void, Never>?
    private var forwarder: Task<Void, Never>?
    private var ring: AsyncStream<Void>.Continuation?
    private var retry: Task<Void, Never>?
    private let backoff: (first: Duration, last: Duration)
    private var nextRetry: Duration
    /// How many retries were scheduled: what a test waits on.
    private(set) var retriesScheduled = 0
    private var changeContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    init(
        store: CatalogStore,
        thumbnailDirectory: URL?,
        bundle: Bundle,
        pageSize: Int = 16,
        cutoff: SearchCutoff = .calibrated,
        backoff: (first: Duration, last: Duration) = (.seconds(30), .seconds(900))
    ) {
        self.store = store
        self.backoff = backoff
        nextRetry = backoff.first
        self.bundle = bundle
        self.cutoff = cutoff
        self.thumbnailDirectory = thumbnailDirectory
        embedder = SearchImageEmbedder(bundle: bundle)
        encoder = SearchQueryEncoder(bundle: bundle)
        self.pageSize = pageSize
    }

    func start() async {
        guard loop == nil else { return }
        let (doorbell, ring) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let changes = await store.changeNotifications()
        self.ring = ring
        ring.yield()
        forwarder = Task { [weak self] in
            for await _ in changes {
                guard self != nil else { break }
                ring.yield()
            }
            ring.finish()
        }
        loop = Task { [weak self] in
            for await _ in doorbell {
                guard let self else { return }
                await refresh()
            }
        }
    }

    /// Ends the loop now — a test's teardown; in the app, the loops end with the actor.
    func shutdown() {
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

    /// The assets `text` matches among those with a current embedding.
    /// `preferring`: the languages the user searches in, favoured when recognising the text's.
    func matches(for text: String, preferring languages: [String] = []) async throws -> SearchMatches {
        let people = try await store.namedPeople()
        let encoding = try await encoder.encode(text, preferring: languages, people: people)
        let start = ContinuousClock.now
        let count = ids.count
        var matched: [MediaAssetID: Float]?
        var named: [String] = []
        var textMatches = 0
        if let query = encoding.embedding {
            let scores = Self.scores(vectors, count: count, query: query)
            let best = scores.max() ?? 0
            let threshold = cutoff.threshold(best: best)
            named = labelVocabulary()?.labels(namedBy: query) ?? []
            var picture: [MediaAssetID: Float] = [:]
            for (row, score) in scores.enumerated()
                where score >= threshold && SearchLabelGate.keeps(score: score, best: best, labels: labels[row], named: named)
            {
                picture[ids[row]] = score
            }
            // A photo showing the words matches, whatever the cut. A query naming no scene label
            // ("according", "presenting") is about the words, so those photos rank first; one
            // naming a thing ("dog", "lake") is about the picture, and a sign saying DOG keeps
            // its picture's place (research §9: word queries 0.13 → 0.84 recall@10, picture
            // queries unchanged at 0.846). The words are tried as typed and as the English.
            let lift = named.isEmpty ? Self.textMatchScore : 0
            for (id, reading) in texts
                where SearchTextReading.matches(query: encoding.text, in: reading)
                || SearchTextReading.matches(query: encoding.pictureText, in: reading)
            {
                picture[id] = lift + (rowOf[id].map { scores[$0] } ?? 0)
                textMatches += 1
            }
            matched = picture
        }
        let allowed = encoding.facts.isEmpty ? nil : try await store.searchFactMatches(encoding.facts)
        OtosLog.catalog.noticeOperation("search.match", phase: "done", fields: [
            "searched": "\(count)",
            "matched": "\(matched.map { "\($0.count)" } ?? "unnarrowed")",
            "allowed": "\(allowed.map { "\($0.count)" } ?? "unnarrowed")",
            "labels": "\(named.count)",
            "textMatches": "\(textMatches)",
            "reading": encoding.reading.rawValue,
            "ms": "\(DiagnosticsTiming.milliseconds(since: start))",
        ])
        return SearchMatches(encoding: encoding, scores: matched, allowed: allowed, searchedCount: count)
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
        ids.count
    }

    private func refresh() async {
        var settled = false
        do {
            try await reconcile()
            let embedded = try await drain()
            try await reconcileTexts()
            settled = try await drainTexts() && embedded
        } catch {
            OtosLog.thumbnails.errorOperation("search.index", phase: "failed", fields: [
                "error": String(describing: error),
            ])
        }
        guard !Task.isCancelled else { return }
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
        ring?.yield()
    }

    /// Brings memory in line with the catalog's current embeddings.
    private func reconcile() async throws {
        if !loaded {
            let all = try await store.currentSearchEmbeddings()
            ids = []
            rowOf = [:]
            vectors = []
            labels = []
            insert(all)
            loaded = true
            OtosLog.thumbnails.noticeOperation("search.index", phase: "loaded", fields: ["count": "\(all.count)"])
            announce()
            return
        }
        let current = try await store.currentSearchEmbeddingIDs()
        let gone = Set(ids).subtracting(current)
        let missing = current.subtracting(ids)
        let added = missing.isEmpty ? [] : try await store.currentSearchEmbeddings(for: missing)
        guard !gone.isEmpty || !added.isEmpty else { return }
        remove(gone)
        insert(added)
        announce()
    }

    /// Embeds every asset whose thumbnail has no current embedding, a page at a time, until
    /// none is left or a page wrote nothing (a model or a prediction failed, or its
    /// thumbnails all changed meanwhile). True when none is left.
    private func drain() async throws -> Bool {
        var embedded = 0
        let start = ContinuousClock.now
        while !Task.isCancelled {
            let page = try await store.searchEmbeddingCandidates(limit: pageSize)
            guard !page.isEmpty else {
                logEmbedded(embedded, since: start)
                return true
            }
            let results = await embedder.embed(page, thumbnailDirectory: thumbnailDirectory)
            let written = try await store.applySearchEmbeddings(results)
            guard !written.isEmpty else { break }
            let stored = written.compactMap { result in
                result.embedding.map { StoredSearchEmbedding(id: result.id, embedding: $0, labels: result.labels) }
            }
            remove(Set(stored.map(\.id)))
            insert(stored)
            announce()
            embedded += written.count
        }
        logEmbedded(embedded, since: start)
        return false
    }

    private func logEmbedded(_ embedded: Int, since start: ContinuousClock.Instant) {
        guard embedded > 0 else { return }
        OtosLog.thumbnails.noticeOperation("search.index", phase: "embedded", fields: [
            "count": "\(embedded)",
            "total": "\(ids.count)",
            "ms": "\(DiagnosticsTiming.milliseconds(since: start))",
        ])
    }

    private func reconcileTexts() async throws {
        let current = try await store.currentSearchTexts()
        guard current != texts else { return }
        texts = current
        announce()
    }

    /// Reads every owed preview for text, a page at a time, after every embedding is made: a
    /// photo is searchable by picture first, and a reading costs far more. True when none is
    /// left, or when it stops for new embeddings (whose thumbnail's change rang already);
    /// false when a page wrote nothing.
    private func drainTexts() async throws -> Bool {
        var read = 0, withText = 0
        var settled = false
        let start = ContinuousClock.now
        while !Task.isCancelled {
            let page = try await store.searchTextCandidates(limit: 8)
            guard !page.isEmpty else {
                settled = true
                break
            }
            let results = await textReader.read(page, directory: thumbnailDirectory)
            let written = try await store.applySearchTexts(results)
            guard !written.isEmpty else { break }
            for result in written {
                texts[result.id] = result.text.isEmpty ? nil : result.text
                withText += result.text.isEmpty ? 0 : 1
            }
            announce()
            read += written.count
            // New embeddings come first: a thumbnail written meanwhile is embedded before more
            // previews are read.
            if try await !store.searchEmbeddingCandidates(limit: 1).isEmpty {
                settled = true
                break
            }
        }
        if read > 0 {
            OtosLog.thumbnails.noticeOperation("search.text", phase: "read", fields: [
                "count": "\(read)", "withText": "\(withText)", "ms": "\(DiagnosticsTiming.milliseconds(since: start))",
            ])
        }
        return settled
    }

    private func insert(_ embeddings: [StoredSearchEmbedding]) {
        vectors.reserveCapacity(vectors.count + embeddings.count * SearchEmbedding.dimensions)
        for embedding in embeddings where rowOf[embedding.id] == nil {
            rowOf[embedding.id] = ids.count
            ids.append(embedding.id)
            vectors.append(contentsOf: embedding.embedding)
            labels.append(embedding.labels)
        }
    }

    /// Removes by moving the last row into each gap, so a removal is O(dimensions).
    private func remove(_ gone: Set<MediaAssetID>) {
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

    private func announce() {
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

    /// One result per candidate: its embedding and scene labels, or none when its thumbnail
    /// does not decode.
    /// A model that does not load embeds nothing and records nothing, so the candidates stay
    /// owed.
    func embed(_ page: [SearchEmbeddingCandidate], thumbnailDirectory: URL?) -> [SearchEmbeddingResult] {
        do {
            if model == nil {
                model = try SearchImageModel(bundle: bundle)
            }
        } catch {
            OtosLog.thumbnails.errorOperation("search.model", phase: "loadFailed", fields: [
                "error": String(describing: error),
            ])
            return []
        }
        guard let model, let thumbnailDirectory else { return [] }
        return page.compactMap { candidate in
            let url = thumbnailDirectory.appending(path: candidate.thumbnailPath)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                return SearchEmbeddingResult(id: candidate.id, source: candidate.source, embedding: nil)
            }
            do {
                return try SearchEmbeddingResult(
                    id: candidate.id,
                    source: candidate.source,
                    embedding: model.embedding(of: image),
                    labels: SearchSceneLabels.classify(image)
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
