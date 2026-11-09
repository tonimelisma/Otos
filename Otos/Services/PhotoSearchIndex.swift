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
    /// Every searched asset the index's cutoff keeps, with its score.
    let scores: [MediaAssetID: Float]
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
///   thumbnail is still the one read, and what was written joins memory. A failed read is
///   logged and waits for the next ring.
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
    private var loaded = false

    private var loop: Task<Void, Never>?
    private var forwarder: Task<Void, Never>?
    private var changeContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    init(
        store: CatalogStore,
        thumbnailDirectory: URL?,
        bundle: Bundle,
        pageSize: Int = 16,
        cutoff: SearchCutoff = .calibrated
    ) {
        self.store = store
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
        forwarder = nil
        loop = nil
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
    func matches(for text: String) async throws -> SearchMatches {
        let encoding = try await encoder.encode(text)
        let start = ContinuousClock.now
        let count = ids.count
        let scores = Self.scores(vectors, count: count, query: encoding.embedding)
        let threshold = cutoff.threshold(best: scores.max() ?? 0)
        var matched: [MediaAssetID: Float] = [:]
        for (row, score) in scores.enumerated() where score >= threshold {
            matched[ids[row]] = score
        }
        OtosLog.catalog.noticeOperation("search.match", phase: "done", fields: [
            "searched": "\(count)",
            "matched": "\(matched.count)",
            "reading": encoding.reading.rawValue,
            "ms": "\(DiagnosticsTiming.milliseconds(since: start))",
        ])
        return SearchMatches(encoding: encoding, scores: matched, searchedCount: count)
    }

    /// Every row's cosine with `query`: one matrix–vector product over the row-major matrix.
    static func scores(_ vectors: [Float], count: Int, query: [Float]) -> [Float] {
        var scores = [Float](repeating: 0, count: count)
        if count > 0 {
            vDSP_mmul(vectors, 1, query, 1, &scores, 1, vDSP_Length(count), 1, vDSP_Length(SearchEmbedding.dimensions))
        }
        return scores
    }

    /// The embeddings in memory: what a test waits on.
    var embeddedCount: Int {
        ids.count
    }

    private func refresh() async {
        do {
            try await reconcile()
            try await drain()
        } catch {
            OtosLog.thumbnails.errorOperation("search.index", phase: "failed", fields: [
                "error": String(describing: error),
            ])
        }
    }

    /// Brings memory in line with the catalog's current embeddings.
    private func reconcile() async throws {
        if !loaded {
            let all = try await store.currentSearchEmbeddings()
            ids = []
            rowOf = [:]
            vectors = []
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
    /// none is left or a page wrote nothing (its thumbnails all changed meanwhile: the next
    /// ring offers them again).
    private func drain() async throws {
        var embedded = 0
        let start = ContinuousClock.now
        while !Task.isCancelled {
            let page = try await store.searchEmbeddingCandidates(limit: pageSize)
            guard !page.isEmpty else { break }
            let results = await embedder.embed(page, thumbnailDirectory: thumbnailDirectory)
            let written = try await store.applySearchEmbeddings(results)
            guard !written.isEmpty else { break }
            let stored = written.compactMap { result in
                result.embedding.map { StoredSearchEmbedding(id: result.id, embedding: $0) }
            }
            remove(Set(stored.map(\.id)))
            insert(stored)
            announce()
            embedded += written.count
        }
        if embedded > 0 {
            OtosLog.thumbnails.noticeOperation("search.index", phase: "embedded", fields: [
                "count": "\(embedded)",
                "total": "\(ids.count)",
                "ms": "\(DiagnosticsTiming.milliseconds(since: start))",
            ])
        }
    }

    private func insert(_ embeddings: [StoredSearchEmbedding]) {
        vectors.reserveCapacity(vectors.count + embeddings.count * SearchEmbedding.dimensions)
        for embedding in embeddings where rowOf[embedding.id] == nil {
            rowOf[embedding.id] = ids.count
            ids.append(embedding.id)
            vectors.append(contentsOf: embedding.embedding)
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
                rowOf[moved] = row
                vectors.withUnsafeMutableBufferPointer { buffer in
                    for index in 0 ..< dimensions {
                        buffer[row * dimensions + index] = buffer[last * dimensions + index]
                    }
                }
            }
            ids.removeLast()
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

/// Reads stored thumbnails with the image tower, on its own serial queue: every prediction
/// blocks (ADR 0032 rule 6), and the 93 MB model loads on first use and never leaves it.
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

    /// One result per candidate: its embedding, or none when its thumbnail does not decode.
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
                return try SearchEmbeddingResult(id: candidate.id, source: candidate.source, embedding: model.embedding(of: image))
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
