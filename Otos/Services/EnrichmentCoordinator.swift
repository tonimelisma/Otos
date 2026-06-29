import Foundation
import OSLog

/// Enrichment coordinator guide
///
/// This actor is the write-side satellite of the catalog, the mirror of
/// `CatalogProjection`: where Projection reads catalog truth into UI state, the
/// coordinator reads catalog truth into enrichment work and writes the results back.
/// It owns the scheduling and the two worker pools; it owns no catalog truth (it reads
/// snapshots) and no media logic (it calls `MediaEnricher`).
///
/// Why an actor: the scheduling state (what is in flight, what has been routed, the
/// viewport) is shared across the worker tasks and must be mutated without races. The
/// heavy work — reading bytes, decoding, downloading — runs OFF this actor inside the
/// worker tasks; only scheduling and the fast result hand-off run on the actor.
///
/// Scheduling is cursorless: there is no maintained backlog of "what needs enrichment"
/// — that is derived from the resident catalog snapshot by the cheap `needsEnrichment`
/// predicate. The coordinator keeps only the runtime state it cannot derive: the
/// viewport, in-flight guards, the just-downloaded `freshly` hand-off, the set of
/// dataless ids discovered so far, the pending-apply buffer, and one `eagerMode` latch.
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
/// catalog in Projection on every completion.
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

    private var latestSnapshot: CatalogSnapshot = .empty
    private var snapshotDirty = true
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
            guard let store = await self?.store else {
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
        snapshotDirty = true
        signal()
    }

    func signal() {
        signalContinuation.yield()
    }

    /// One owned task drives both pools. Each yielded signal is a wake: it refreshes the
    /// snapshot (at most once per tick — coalescing the O(N) rebuild), tops both pools up to
    /// their caps, and flushes the apply buffer. The worker child tasks run the heavy work
    /// off-actor and hop back through `finish*`, each yielding another signal; cancelling the
    /// supervisor finishes the stream, so the `for await` returns and the group drains.
    ///
    /// The signal stream is consumed inline here (not via a stored iterator) because an
    /// actor cannot call a mutating `next()` on one of its own stored properties.
    func runLoop() async {
        await withDiscardingTaskGroup { group in
            for await _ in signalStream {
                if Task.isCancelled {
                    break
                }
                if snapshotDirty {
                    snapshotDirty = false
                    latestSnapshot = await store.currentSnapshot()
                }
                for work in dequeueEnrichmentWork() {
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
    private func dequeueEnrichmentWork() -> [EnrichWork] {
        var items: [EnrichWork] = []
        while inFlightEnrich.count < enrichConcurrency, let work = nextEnrichmentWork() {
            inFlightEnrich.insert(work.id)
            items.append(work)
        }
        return items
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
    private func nextEnrichmentWork() -> EnrichWork? {
        for id in viewport.reversed() where isEnrichable(id) {
            return makeWork(id)
        }
        while let id = freshly.popLast() {
            if isEnrichable(id) {
                return makeWork(id)
            }
        }
        for asset in latestSnapshot.assetsByID.values where isEnrichable(asset.id) {
            return makeWork(asset.id)
        }
        // Nothing materialized-or-undiscovered remains to enrich: every catalog asset is
        // enriched, in flight, buffered, or known dataless. Open the eager-download gate.
        eagerMode = true
        return nil
    }

    func isEnrichable(_ id: MediaAssetID) -> Bool {
        guard let asset = latestSnapshot.assetsByID[id], asset.needsEnrichment else {
            return false
        }
        return !inFlightEnrich.contains(id)
            && !pendingApplyIDs.contains(id)
            && !datalessPending.contains(id)
    }

    private func makeWork(_ id: MediaAssetID) -> EnrichWork? {
        guard let asset = latestSnapshot.assetsByID[id] else {
            return nil
        }
        return EnrichWork(
            id: id,
            url: url(for: id),
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
        latestSnapshot.assetsByID.values.contains { isEnrichable($0.id) }
    }

    func url(for id: MediaAssetID) -> URL {
        id.libraryRootPath.url.appending(path: id.relativePath.rawValue, directoryHint: .notDirectory)
    }
}

// MARK: - Completion

private extension EnrichmentCoordinator {
    func finishEnrich(_ id: MediaAssetID, _ outcome: EnrichmentOutcome) {
        inFlightEnrich.remove(id)
        switch outcome {
        case let .complete(result):
            pendingApply.append(result)
            pendingApplyIDs.insert(id)
        case .notMaterialized:
            datalessPending.insert(id)
        case .transient:
            break
        }
        signal()
    }

    func finishDownload(_ id: MediaAssetID, materialized: Bool) {
        inFlightDownload.remove(id)
        datalessPending.remove(id)
        if materialized {
            // Hand the just-materialized file to the enrich pool, newest first.
            freshly.append(id)
        }
        // A failed download drops out of the pending set; a later snapshot refresh
        // re-discovers it as dataless if it is still needed.
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
            // truth so a still-stale asset is re-dispatched immediately; a proven-deleted one
            // simply drops out of the snapshot.
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
