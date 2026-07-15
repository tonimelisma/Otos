import Foundation
import OSLog

/// Enrichment coordinator guide
///
/// This actor is the write-side satellite of the catalog, the mirror of
/// `CatalogProjection`: where Projection reads catalog truth into UI state, the
/// coordinator asks Store for enrichment candidates and writes the results back.
/// It owns bounded catalog claims and the local enrichment workers; it owns no catalog truth (Store
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
/// viewport, one process-local state record per claimed identity, the just-downloaded
/// `freshly` hand-off, the pending-apply buffer, and one `eagerMode` latch.
///
/// Materialization status is not checked on this actor. The enricher checks it off-actor
/// immediately before any read (the ADR 0008 safety gate) and reports `.notMaterialized`
/// for a dataless file. A bounded handoff submits that demand to the shared materializer,
/// then returns successful identities through `freshly`; physical transfer admission
/// and priority remain entirely outside this actor.
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
    struct WorkStateSnapshot: Equatable, Sendable {
        let claimed: Int
        let enriching: Int
        let awaitingMaterialization: Int
        let materializing: Int
        let awaitingApply: Int
    }

    enum ClaimedWorkState {
        case queuedEnrichment(EnrichWork)
        case enriching(EnrichWork, estimatedBytes: Int64)
        case awaitingMaterialization(DownloadWork)
        case materializing(DownloadWork)
        case awaitingApply
    }

    struct ClaimedWorkRecord {
        var state: ClaimedWorkState
        let sequence: UInt64
        let ownsStoreClaim: Bool
    }

    struct AdmissionDiagnosticSnapshot: Equatable {
        let rejections: [EnrichmentAdmissionPolicy.Rejection: Int]
        let admitted: Int
        let pending: Int
        let inFlight: Int
        let bytes: Int64
        let videoInFlight: Int
    }

    struct EnrichWork {
        let id: MediaAssetID
        let url: URL
        let sourceSize: Int64?
        let sourceMTimeSeconds: Int?
        let isVideo: Bool
        let captureDate: Date?
        let isDeviceStaging: Bool
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

    /// Pacing-only fact for a background materialization that exhausted its
    /// in-window retry attempts: no work payload, so it costs nothing beyond the
    /// claim window's 32-item bound to keep around for the full backoff schedule.
    struct RetryLedgerEntry: Equatable {
        let notBefore: Date
        let attemptCount: Int
        let sourceSize: Int64?
    }

    let store: CatalogStore
    let enricher: MediaEnricher
    let materializationRequester: any MaterializationRequesting
    let enrichConcurrency: Int
    let claimBatchSize: Int
    let applyFlushInterval: Duration
    let applyFlushSleep: @Sendable (Duration) async -> Void
    let admissionPolicy: EnrichmentAdmissionPolicy
    let handoffPolicy: EnrichmentMaterializationHandoffPolicy
    let claimWindowLimit: Int
    let claimRefreshInterval: Duration
    let claimRefreshSleep: @Sendable (Duration) async -> Void

    var viewport: [MediaAssetID] = []
    var freshly: [MediaAssetID] = []
    var claimedWork: [MediaAssetID: ClaimedWorkRecord] = [:]
    var deviceRootPaths: Set<LibraryRootPath> = []
    var nextClaimSequence: UInt64 = 0
    var retryLedger: [MediaAssetID: RetryLedgerEntry] = [:]
    var pendingApply: [EnrichmentResult] = []
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
    var claimRefreshTask: Task<Void, Never>?
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
        admissionPolicy: EnrichmentAdmissionPolicy = .production,
        handoffPolicy: EnrichmentMaterializationHandoffPolicy = .production(),
        claimWindowLimit: Int = 32,
        claimRefreshInterval: Duration = .seconds(120),
        claimRefreshSleep: @escaping @Sendable (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        }
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
        self.handoffPolicy = handoffPolicy
        self.claimWindowLimit = max(claimWindowLimit, enrichConcurrency)
        self.claimRefreshInterval = claimRefreshInterval
        self.claimRefreshSleep = claimRefreshSleep
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
        let refreshSleep = claimRefreshSleep
        let refreshInterval = claimRefreshInterval
        claimRefreshTask = Task { [weak self, refreshSleep] in
            while !Task.isCancelled {
                await refreshSleep(refreshInterval)
                guard !Task.isCancelled else { break }
                await self?.refreshOutstandingMaterializationClaims()
            }
        }
        signal()
    }

    func shutdown() async {
        isShuttingDown = true
        let supervisor = supervisor
        let capturedChangeConsumer = changeConsumer
        let capturedApplyFlushTask = applyFlushTask
        let capturedWriteRetryTask = writeRetryTask
        let capturedDownloadRetryTask = downloadRetryTask
        let capturedClaimRefreshTask = claimRefreshTask
        supervisor?.cancel()
        capturedChangeConsumer?.cancel()
        changeConsumer = nil
        capturedApplyFlushTask?.cancel()
        applyFlushTask = nil
        capturedWriteRetryTask?.cancel()
        writeRetryTask = nil
        capturedDownloadRetryTask?.cancel()
        downloadRetryTask = nil
        capturedClaimRefreshTask?.cancel()
        claimRefreshTask = nil
        await supervisor?.value
        await capturedChangeConsumer?.value
        await capturedApplyFlushTask?.value
        await capturedWriteRetryTask?.value
        await capturedDownloadRetryTask?.value
        await capturedClaimRefreshTask?.value
        self.supervisor = nil
        await releaseOutstandingClaimsForShutdown()
        claimedWork.removeAll()
        retryLedger.removeAll()
        pendingApply.removeAll()
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
        // The catalog rows are the durable backlog. Seed only the open working
        // window; later rows return through ordinary cursorless claiming while the
        // root marker preserves device priority and staging semantics.
        deviceRootPaths.formUnion(seeds.map(\.id.libraryRootPath))
        let available = max(claimWindowLimit - claimedWork.count, 0)
        for seed in seeds.prefix(available) {
            guard !FileManager.default.fileExists(atPath: seed.id.fileURL.path(percentEncoded: false)) else {
                continue
            }
            // A `.tmp`-path staging write leaves `fileExists` false until completion, so a
            // reconnect re-running the catalog flow must not clobber the active record: it
            // already represents this seed's demand.
            if case .materializing = claimedWork[seed.id]?.state {
                continue
            }
            if case .awaitingMaterialization = claimedWork[seed.id]?.state {
                continue
            }
            nextClaimSequence &+= 1
            let work = DownloadWork(
                id: seed.id,
                url: seed.id.fileURL,
                sourceSize: seed.sourceSize,
                captureDate: seed.captureDate,
                isVideo: seed.isVideo,
                isDeviceStaging: true
            )
            claimedWork[seed.id] = ClaimedWorkRecord(
                state: .awaitingMaterialization(work),
                sequence: nextClaimSequence,
                ownsStoreClaim: false
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
        while await hasInFlightWork(under: rootPath), Date() < deadline {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return await !hasInFlightWork(under: rootPath)
            }
        }
        return await !hasInFlightWork(under: rootPath)
    }

    private func hasInFlightWork(under rootPath: LibraryRootPath) async -> Bool {
        let local = claimedWork.contains { id, record in
            guard id.libraryRootPath == rootPath else { return false }
            switch record.state {
            case .enriching, .materializing: return true
            case .queuedEnrichment, .awaitingMaterialization, .awaitingApply: return false
            }
        }
        let sharedActive = await materializationRequester.activeRequestCount(under: rootPath)
        return local || sharedActive > 0
    }

    func workStateSnapshot() -> WorkStateSnapshot {
        var enriching = 0
        var awaitingMaterialization = 0
        var materializing = 0
        var awaitingApply = 0
        for record in claimedWork.values {
            switch record.state {
            case .queuedEnrichment:
                break
            case .enriching:
                enriching += 1
            case .awaitingMaterialization:
                awaitingMaterialization += 1
            case .materializing:
                materializing += 1
            case .awaitingApply:
                awaitingApply += 1
            }
        }
        return WorkStateSnapshot(
            claimed: claimedWork.count,
            enriching: enriching,
            awaitingMaterialization: awaitingMaterialization,
            materializing: materializing,
            awaitingApply: awaitingApply
        )
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
                for work in await dequeueMaterializationSubmissions() {
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
