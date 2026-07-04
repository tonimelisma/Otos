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
/// Scheduling is cursorless: there is no durable backlog of "what needs enrichment".
/// Store derives that from queryable source/enrichment stamps and returns a bounded set
/// of claimed candidates. The coordinator keeps only the runtime state it cannot
/// derive: the viewport, a small process-local queue of already-claimed work used to
/// avoid one SQLite claim query per worker slot, in-flight guards, the just-downloaded
/// `freshly` hand-off, the set of dataless ids discovered so far, the pending-apply
/// buffer, and one `eagerMode` latch.
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
/// catalog in Projection on every completion. The batch is time-based, so background
/// updates align with Projection's one-second publication cadence instead of flushing
/// by an arbitrary item count. Completed results may carry staged thumbnails; Store
/// validates the SQLite source signature and promotes only the staged files it stamps
/// current.
///
/// Lifecycle mirrors `CatalogStore`: it is a process-lifetime owner started by the
/// ViewModel; `shutdown()` cancels its tasks and releases process-local SQLite
/// claims before dropping queued work (tests use it to stop cleanly).
actor EnrichmentCoordinator {
    struct EnrichWork {
        let id: MediaAssetID
        let url: URL
        let sourceSize: Int64?
        let sourceMTimeSeconds: Int?
    }

    let store: CatalogStore
    let enricher: MediaEnricher
    let materialize: @Sendable (URL) async -> Bool
    let enrichConcurrency: Int
    let downloadConcurrency: Int
    let claimBatchSize: Int
    let applyFlushInterval: Duration
    let applyFlushSleep: @Sendable (Duration) async -> Void
    let diagnostics: CatalogDiagnostics?

    var viewport: [MediaAssetID] = []
    var freshly: [MediaAssetID] = []
    var claimedEnrichQueue: [EnrichWork] = []
    var datalessPending: Set<MediaAssetID> = []
    var inFlightEnrich: Set<MediaAssetID> = []
    var inFlightDownload: Set<MediaAssetID> = []
    var pendingApply: [EnrichmentResult] = []
    var pendingApplyIDs: Set<MediaAssetID> = []
    var diagnosedThumbnailLifecycleIDs: Set<MediaAssetID> = []
    var eagerMode = false
    var isShuttingDown = false

    let writeFailureBackoff: Duration

    private var supervisor: Task<Void, Never>?
    private var changeConsumer: Task<Void, Never>?
    var applyFlushTask: Task<Void, Never>?
    var writeRetryTask: Task<Void, Never>?
    private let signalStream: AsyncStream<Void>
    private let signalContinuation: AsyncStream<Void>.Continuation

    init(
        store: CatalogStore,
        enricher: MediaEnricher,
        materialize: @escaping @Sendable (URL) async -> Bool = { await EnrichmentCoordinator.liveMaterialize($0) },
        enrichConcurrency: Int = 4,
        downloadConcurrency: Int = 4,
        claimBatchSize: Int = 32,
        applyFlushInterval: Duration = .seconds(1),
        applyFlushSleep: @escaping @Sendable (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        },
        writeFailureBackoff: Duration = .seconds(5),
        diagnostics: CatalogDiagnostics? = .shared
    ) {
        self.store = store
        self.enricher = enricher
        self.materialize = materialize
        self.enrichConcurrency = enrichConcurrency
        self.downloadConcurrency = downloadConcurrency
        self.claimBatchSize = max(claimBatchSize, enrichConcurrency)
        self.applyFlushInterval = applyFlushInterval
        self.applyFlushSleep = applyFlushSleep
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

    func shutdown() async {
        isShuttingDown = true
        supervisor?.cancel()
        supervisor = nil
        changeConsumer?.cancel()
        changeConsumer = nil
        applyFlushTask?.cancel()
        applyFlushTask = nil
        writeRetryTask?.cancel()
        writeRetryTask = nil
        await releaseOutstandingClaimsForShutdown()
        claimedEnrichQueue.removeAll()
        datalessPending.removeAll()
        inFlightEnrich.removeAll()
        inFlightDownload.removeAll()
        pendingApply.removeAll()
        pendingApplyIDs.removeAll()
        diagnosedThumbnailLifecycleIDs.removeAll()
        freshly.removeAll()
        signalContinuation.finish()
    }

    func updateViewport(_ ids: [MediaAssetID]) {
        viewport = ids
        signal()
    }
}

extension EnrichmentCoordinator {
    func markDirtyAndSignal() {
        guard !isShuttingDown else {
            return
        }
        signal()
    }

    func signal() {
        guard !isShuttingDown else {
            return
        }
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
                    let url = id.fileURL
                    let materialize = materialize
                    group.addTask {
                        let materialized = await materialize(url)
                        await self.finishDownload(id, materialized: materialized)
                    }
                }
            }
        }
    }
}
