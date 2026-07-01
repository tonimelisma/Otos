import Foundation
import OSLog

/// Enrichment coordinator guide
///
/// This actor is the write-side satellite of the catalog, the mirror of
/// `CatalogProjection`: where Projection reads catalog truth into UI state, the
/// coordinator asks Store for enrichment candidates and writes the results back.
/// It owns the scheduling and the two worker pools; it owns no catalog truth (Store
/// queries candidates from SQLite) and no media logic (it calls `MediaEnricher`).
///
/// Why an actor: the scheduling state (what is in flight, what has been routed, the
/// viewport) is shared across the worker tasks and must be mutated without races. The
/// heavy work — reading bytes, decoding, downloading — runs OFF this actor inside the
/// worker tasks; only scheduling and the fast result hand-off run on the actor.
///
/// Scheduling is cursorless: there is no maintained backlog of "what needs enrichment".
/// Store derives that from queryable source/enrichment stamps and returns only the next
/// bounded set of candidates. The coordinator keeps only the runtime state it cannot
/// derive: the viewport, in-flight guards, the just-downloaded `freshly` hand-off, the
/// set of dataless ids discovered so far, the pending-apply buffer, and one `eagerMode`
/// latch.
///
/// Materialization status is not checked on this actor. The enricher checks it off-actor
/// immediately before any read (the ADR 0008 safety gate) and reports `.notMaterialized`
/// for a dataless file; the coordinator routes those to the download pool. So the enrich
/// pool both enriches materialized files and discovers dataless ones, and the download
/// pool materializes them (then hands them back through `freshly`). Non-viewport eager
/// downloads wait for the latch — every materialized file is enriched (or being enriched)
/// first; viewport-dataless downloads run immediately.
///
/// Writes are batched (`CatalogStore.applyEnrichmentBatch`): a per-asset transaction
/// across a whole library would crawl, and a notification per asset would re-sort the
/// catalog in Projection on every completion. Completed results may carry staged
/// thumbnails; Store validates the SQLite source signature and promotes only the staged
/// files it stamps current.
///
/// Lifecycle mirrors `CatalogStore`: it is a process-lifetime owner started by the
/// ViewModel; `shutdown()` cancels its tasks (tests use it to stop cleanly).
actor EnrichmentCoordinator {
    private struct EnrichWork {
        let id: MediaAssetID
        let url: URL
        let sourceSize: Int64?
        let sourceMTimeSeconds: Int?
    }

    private let store: CatalogStore
    private let enricher: MediaEnricher
    private let materialize: @Sendable (URL) async -> Bool
    private let enrichConcurrency: Int
    private let downloadConcurrency: Int
    private let applyBatchSize: Int
    private let diagnostics: CatalogDiagnostics?

    private var viewport: [MediaAssetID] = []
    private var freshly: [MediaAssetID] = []
    private var datalessPending: Set<MediaAssetID> = []
    private var inFlightEnrich: Set<MediaAssetID> = []
    private var inFlightDownload: Set<MediaAssetID> = []
    private var pendingApply: [EnrichmentResult] = []
    private var pendingApplyIDs: Set<MediaAssetID> = []
    private var eagerMode = false

    private let writeFailureBackoff: Duration

    private var supervisor: Task<Void, Never>?
    private var changeConsumer: Task<Void, Never>?
    private var writeRetryTask: Task<Void, Never>?
    private let signalStream: AsyncStream<Void>
    private let signalContinuation: AsyncStream<Void>.Continuation

    init(
        store: CatalogStore,
        enricher: MediaEnricher,
        materialize: @escaping @Sendable (URL) async -> Bool = { await EnrichmentCoordinator.liveMaterialize($0) },
        enrichConcurrency: Int = 4,
        downloadConcurrency: Int = 4,
        applyBatchSize: Int = 64,
        writeFailureBackoff: Duration = .seconds(5),
        diagnostics: CatalogDiagnostics? = .shared
    ) {
        self.store = store
        self.enricher = enricher
        self.materialize = materialize
        self.enrichConcurrency = enrichConcurrency
        self.downloadConcurrency = downloadConcurrency
        self.applyBatchSize = applyBatchSize
        self.writeFailureBackoff = writeFailureBackoff
        self.diagnostics = diagnostics
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        signalStream = stream
        signalContinuation = continuation
    }

    static func liveMaterialize(_ url: URL) async -> Bool {
        switch await FileMaterialization.materialize(url) {
        case .materialized, .alreadyMaterialized:
            true
        default:
            false
        }
    }
}

extension EnrichmentCoordinator {
    func start() {
        guard supervisor == nil else {
            return
        }
        OtosLog.metadata.info("Enrichment coordinator started")
        changeConsumer = Task { [weak self] in
            guard let store = self?.store else {
                return
            }
            for await _ in await store.changeNotifications() {
                await self?.markDirtyAndSignal()
            }
        }
        supervisor = Task { await self.runLoop() }
        signal()
    }

    func shutdown() {
        supervisor?.cancel()
        supervisor = nil
        changeConsumer?.cancel()
        changeConsumer = nil
        writeRetryTask?.cancel()
        writeRetryTask = nil
        signalContinuation.finish()
    }

    func updateViewport(_ ids: [MediaAssetID]) {
        viewport = ids
        signal()
    }
}

private extension EnrichmentCoordinator {
    func markDirtyAndSignal() {
        signal()
    }

    func signal() {
        signalContinuation.yield()
    }

    /// One owned task drives both pools. Each yielded signal is a wake: it tops both
    /// pools up to their caps through bounded Store queries and flushes the apply buffer.
    /// The worker child tasks run the heavy work off-actor and hop back through `finish*`,
    /// each yielding another signal; cancelling the supervisor finishes the stream, so the
    /// `for await` returns and the group drains.
    ///
    /// The signal stream is consumed inline here (not via a stored iterator) because an
    /// actor cannot call a mutating `next()` on one of its own stored properties.
    func runLoop() async {
        await withDiscardingTaskGroup { group in
            for await _ in signalStream {
                if Task.isCancelled {
                    break
                }
                for work in await dequeueEnrichmentWork() {
                    let enricher = enricher
                    group.addTask {
                        let outcome = await enricher.enrich(
                            work.id, work.url, work.sourceSize, work.sourceMTimeSeconds
                        )
                        await self.finishEnrich(work.id, outcome)
                    }
                }
                for id in dequeueDownloadWork() {
                    let url = url(for: id)
                    let materialize = materialize
                    group.addTask {
                        let materialized = await materialize(url)
                        await self.finishDownload(id, materialized: materialized)
                    }
                }
                await flushPendingApply(force: !hasEnrichmentWorkRemaining())
            }
        }
    }

    /// Claims up to the free enrich slots, marking each in-flight so the next claim skips it.
    private func dequeueEnrichmentWork() async -> [EnrichWork] {
        let availableSlots = enrichConcurrency - inFlightEnrich.count
        guard availableSlots > 0 else {
            return []
        }
        do {
            let candidates = try await store.enrichmentCandidates(
                prioritizing: prioritizedEnrichmentIDs(),
                limit: availableSlots
            )
            if candidates.isEmpty {
                eagerMode = true
            }
            var items: [EnrichWork] = []
            items.reserveCapacity(candidates.count)
            let claimedIDs = Set(candidates.map(\.id))
            freshly.removeAll { claimedIDs.contains($0) }
            for asset in candidates where !inFlightEnrich.contains(asset.id) {
                inFlightEnrich.insert(asset.id)
                items.append(makeWork(asset))
            }
            return items
        } catch {
            OtosLog.metadata.error("Enrichment candidate query failed")
            await diagnostics?.record(
                operation: "catalog.enrichment.coordinator",
                phase: "queryError",
                fields: ["error": String(describing: error)]
            )
            return []
        }
    }

    private func dequeueDownloadWork() -> [MediaAssetID] {
        var ids: [MediaAssetID] = []
        while inFlightDownload.count < downloadConcurrency, let id = nextDownloadID() {
            inFlightDownload.insert(id)
            ids.append(id)
        }
        return ids
    }
}

// MARK: - Work selection (cursorless)

private extension EnrichmentCoordinator {
    func prioritizedEnrichmentIDs() -> [MediaAssetID] {
        var ids: [MediaAssetID] = []
        var seen: Set<MediaAssetID> = []
        ids.reserveCapacity(viewport.count + freshly.count)
        for id in viewport.reversed() where seen.insert(id).inserted {
            ids.append(id)
        }
        for id in freshly.reversed() where seen.insert(id).inserted {
            ids.append(id)
        }
        return ids
    }

    private func makeWork(_ asset: MediaAsset) -> EnrichWork {
        EnrichWork(
            id: asset.id,
            url: url(for: asset.id),
            sourceSize: asset.byteSize,
            sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt)
        )
    }

    func nextDownloadID() -> MediaAssetID? {
        for id in viewport.reversed() where datalessPending.contains(id) && !inFlightDownload.contains(id) {
            return id
        }
        guard eagerMode else {
            return nil
        }
        return datalessPending.first { !inFlightDownload.contains($0) }
    }

    func hasEnrichmentWorkRemaining() -> Bool {
        !inFlightEnrich.isEmpty
    }

    func url(for id: MediaAssetID) -> URL {
        id.libraryRootPath.url.appending(path: id.relativePath.rawValue, directoryHint: .notDirectory)
    }
}

// MARK: - Completion

private extension EnrichmentCoordinator {
    func finishEnrich(_ id: MediaAssetID, _ outcome: EnrichmentOutcome) async {
        inFlightEnrich.remove(id)
        switch outcome {
        case let .complete(result):
            pendingApply.append(result)
            pendingApplyIDs.insert(id)
        case .notMaterialized:
            datalessPending.insert(id)
            try? await store.refreshEnrichmentClaims([id])
        case .transient:
            try? await store.releaseEnrichmentClaims([id])
        }
        signal()
    }

    func finishDownload(_ id: MediaAssetID, materialized: Bool) async {
        inFlightDownload.remove(id)
        datalessPending.remove(id)
        try? await store.releaseEnrichmentClaims([id])
        if materialized {
            freshly.append(id)
        }
        signal()
    }

    func flushPendingApply(force: Bool) async {
        guard !pendingApply.isEmpty, force || pendingApply.count >= applyBatchSize else {
            return
        }
        let batch = pendingApply
        pendingApply.removeAll(keepingCapacity: true)
        pendingApplyIDs.removeAll(keepingCapacity: true)
        let outcome = await store.applyEnrichmentBatch(batch)
        await diagnostics?.record(
            operation: "catalog.enrichment.coordinator",
            phase: "flush",
            fields: ["count": "\(batch.count)", "outcome": "\(outcome)"]
        )
        switch outcome {
        case let .applied(count) where count < batch.count:
            // A *validated* drop (stale because a scan observed newer bytes, or
            // proven-deleted) leaves its asset `needsEnrichment`, but its scan notification
            // was already consumed while the id was in flight/pending. Re-wake against fresh
            // Store queries so a still-stale asset is re-dispatched immediately; a
            // proven-deleted one simply drops out of candidate results.
            markDirtyAndSignal()
        case .applied:
            break
        case .writeFailed:
            // Don't re-wake immediately (that would tight-loop the read/generate/fail cycle),
            // but don't drop the only wake either: if this failure was the last in-flight
            // work, nothing else would ever re-dispatch the still-`needsEnrichment` assets.
            // Schedule one coalesced delayed retry so they are re-attempted once storage may
            // have recovered.
            scheduleWriteFailureRetry()
        }
    }

    /// One pending backoff retry at a time. After the delay it re-wakes the loop, which
    /// re-dispatches any asset still `needsEnrichment` (including those a failed write left
    /// unstamped); a persistent failure simply reschedules, pacing the retries.
    private func scheduleWriteFailureRetry() {
        guard writeRetryTask == nil else {
            return
        }
        let backoff = writeFailureBackoff
        writeRetryTask = Task { [weak self] in
            try? await Task.sleep(for: backoff)
            await self?.fireWriteFailureRetry()
        }
    }

    private func fireWriteFailureRetry() {
        writeRetryTask = nil
        guard !Task.isCancelled else {
            return
        }
        markDirtyAndSignal()
    }
}
