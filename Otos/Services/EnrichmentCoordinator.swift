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
/// of claimed candidates. Store gives visible work priority, then connected removable
/// sources before fixed-library fallback work. MTP devices can also seed temporary
/// staging downloads, ordered still/image items before video, without creating a second
/// durable queue. The coordinator keeps only the runtime state it cannot derive: the
/// viewport, a small process-local queue of already-claimed work used to avoid one
/// SQLite claim query per worker slot, in-flight guards, the just-downloaded `freshly`
/// hand-off, the pending dataless download work discovered so far, the pending-apply
/// buffer, and one `eagerMode` latch.
///
/// Materialization status is not checked on this actor. The enricher checks it off-actor
/// immediately before any read (the ADR 0008 safety gate) and reports `.notMaterialized`
/// for a dataless file; the coordinator routes those to the download pool. So the enrich
/// pool both enriches materialized files and discovers dataless ones, and the download
/// pool materializes them (then hands them back through `freshly`). Non-viewport eager
/// downloads wait for the latch and reserve the final download slot for viewport work;
/// viewport-dataless downloads run immediately.
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
    struct AdmissionDiagnosticSnapshot: Equatable {
        let rejections: [EnrichmentAdmissionPolicy.Rejection: Int]
        let admitted: Int
        let pending: Int
        let inFlight: Int
        let bytes: Int64
        let videoInFlight: Int

        static func == (lhs: AdmissionDiagnosticSnapshot, rhs: AdmissionDiagnosticSnapshot) -> Bool {
            Set(lhs.rejections.keys) == Set(rhs.rejections.keys)
                && lhs.inFlight == rhs.inFlight
                && lhs.bytes == rhs.bytes
                && lhs.videoInFlight == rhs.videoInFlight
        }
    }

    struct EnrichWork {
        let id: MediaAssetID
        let url: URL
        let sourceSize: Int64?
        let sourceMTimeSeconds: Int?
        let isVideo: Bool
    }

    struct DownloadWork {
        let id: MediaAssetID
        let url: URL
        let sourceSize: Int64?
        let captureDate: Date?
        let isVideo: Bool
        let isDeviceStaging: Bool
        let attemptCount: Int
        let retryNotBefore: Date?

        init(
            id: MediaAssetID,
            url: URL,
            sourceSize: Int64?,
            captureDate: Date?,
            isVideo: Bool,
            isDeviceStaging: Bool = false,
            attemptCount: Int = 0,
            retryNotBefore: Date? = nil
        ) {
            self.id = id
            self.url = url
            self.sourceSize = sourceSize
            self.captureDate = captureDate
            self.isVideo = isVideo
            self.isDeviceStaging = isDeviceStaging
            self.attemptCount = attemptCount
            self.retryNotBefore = retryNotBefore
        }
    }

    struct DeviceStagingSeed {
        let id: MediaAssetID
        let sourceSize: Int64?
        let captureDate: Date?
        let isVideo: Bool
    }

    let store: CatalogStore
    let enricher: MediaEnricher
    let materializationRequester: any MaterializationRequesting
    let enrichConcurrency: Int
    let claimBatchSize: Int
    let applyFlushInterval: Duration
    let applyFlushSleep: @Sendable (Duration) async -> Void
    let admissionPolicy: EnrichmentAdmissionPolicy

    var viewport: [MediaAssetID] = []
    var freshly: [MediaAssetID] = []
    var claimedEnrichQueue: [EnrichWork] = []
    var datalessPending: [MediaAssetID: DownloadWork] = [:]
    var inFlightEnrich: Set<MediaAssetID> = []
    /// IDs submitted to the shared materialization owner whose results enrichment awaits.
    var submittedMaterializations: Set<MediaAssetID> = []
    var inFlightEnrichBytes: [MediaAssetID: Int64] = [:]
    var inFlightEnrichVideoCount = 0
    var pendingApply: [EnrichmentResult] = []
    var pendingApplyIDs: Set<MediaAssetID> = []
    var diagnosedThumbnailLifecycleIDs: Set<MediaAssetID> = []
    var eagerMode = false
    var isShuttingDown = false
    var lastDownloadCandidateEvaluationCount = 0
    var lastEnrichmentAdmissionSnapshot: AdmissionDiagnosticSnapshot?
    var enrichmentAdmissionTransitionCount = 0

    let writeFailureBackoff: Duration

    private var supervisor: Task<Void, Never>?
    private var changeConsumer: Task<Void, Never>?
    var applyFlushTask: Task<Void, Never>?
    var writeRetryTask: Task<Void, Never>?
    var downloadRetryTask: Task<Void, Never>?
    private let signalStream: AsyncStream<Void>
    private let signalContinuation: AsyncStream<Void>.Continuation

    init(
        store: CatalogStore,
        enricher: MediaEnricher,
        materializationRequester: (any MaterializationRequesting)? = nil,
        materialize: @escaping @Sendable (URL) async -> MaterializationResult = { _ in .cancelled },
        enrichConcurrency: Int = EnrichmentAdmissionPolicy.production.enrichConcurrency,
        claimBatchSize: Int = 32,
        applyFlushInterval: Duration = .seconds(1),
        applyFlushSleep: @escaping @Sendable (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        },
        writeFailureBackoff: Duration = .seconds(5),
        admissionPolicy: EnrichmentAdmissionPolicy = .production
    ) {
        self.store = store
        self.enricher = enricher
        self.materializationRequester = materializationRequester
            ?? ClosureMaterializationRequester(operation: materialize)
        var policy = admissionPolicy
        policy.enrichConcurrency = enrichConcurrency
        self.admissionPolicy = policy
        self.enrichConcurrency = enrichConcurrency
        self.claimBatchSize = max(claimBatchSize, enrichConcurrency)
        self.applyFlushInterval = applyFlushInterval
        self.applyFlushSleep = applyFlushSleep
        self.writeFailureBackoff = writeFailureBackoff
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        signalStream = stream
        signalContinuation = continuation
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
        downloadRetryTask?.cancel()
        downloadRetryTask = nil
        await releaseOutstandingClaimsForShutdown()
        claimedEnrichQueue.removeAll()
        datalessPending.removeAll()
        inFlightEnrich.removeAll()
        submittedMaterializations.removeAll()
        inFlightEnrichBytes.removeAll()
        inFlightEnrichVideoCount = 0
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

    func stageDevice(_ seeds: [DeviceStagingSeed]) {
        guard !isShuttingDown else {
            return
        }
        for seed in seeds {
            guard !FileManager.default.fileExists(atPath: seed.id.fileURL.path(percentEncoded: false)) else {
                continue
            }
            datalessPending[seed.id] = DownloadWork(
                id: seed.id,
                url: seed.id.fileURL,
                sourceSize: seed.sourceSize,
                captureDate: seed.captureDate,
                isVideo: seed.isVideo,
                isDeviceStaging: true
            )
        }
        signal()
    }

    /// Waits until no enrichment/download work remains under `rootPath`, or until
    /// `timeout`. Returns `true` when drained, `false` when work was still in flight
    /// at the deadline (callers log the timeout; eject still proceeds and may fail busy).
    @discardableResult
    func drainWork(under rootPath: LibraryRootPath, timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeout.components.seconds))
        while hasInFlightWork(under: rootPath), Date() < deadline {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return !hasInFlightWork(under: rootPath)
            }
        }
        return !hasInFlightWork(under: rootPath)
    }

    private func hasInFlightWork(under rootPath: LibraryRootPath) -> Bool {
        inFlightEnrich.contains { $0.libraryRootPath == rootPath }
            || submittedMaterializations.contains { $0.libraryRootPath == rootPath }
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
    /// Zero-byte claimed assets short-circuit before materialization or the enricher:
    /// they cannot contain media, so a definitive empty stamp is synthesized instead.
    func runLoop() async {
        await withDiscardingTaskGroup { group in
            for await _ in signalStream {
                if Task.isCancelled {
                    break
                }
                for work in await dequeueEnrichmentWork() {
                    if work.sourceSize == 0 {
                        group.addTask {
                            await self.finishEmptySource(work)
                        }
                        continue
                    }
                    let enricher = enricher
                    group.addTask {
                        let outcome = await enricher.enrich(
                            work.id, work.url, work.sourceSize, work.sourceMTimeSeconds
                        )
                        await self.finishEnrich(work, outcome)
                    }
                }
                for work in await dequeueDownloadWork() {
                    let requester = materializationRequester
                    group.addTask {
                        let start = Date()
                        let result = await requester.materialize(
                            MaterializationCoordinator.Request(
                                id: work.id,
                                sourceSize: work.sourceSize,
                                isVideo: work.isVideo,
                                priority: work.isDeviceStaging ? .device : .background
                            )
                        )
                        await self.finishDownload(
                            work,
                            result: result,
                            attemptMs: DiagnosticsTiming.milliseconds(since: start)
                        )
                    }
                }
            }
        }
    }
}
