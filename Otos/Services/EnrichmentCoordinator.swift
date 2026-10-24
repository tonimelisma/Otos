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
/// viewport, ready/enriching claims, independent materialization demands, the
/// `freshly` hand-off, and the pending-apply buffer.
///
/// A bounded readiness pass checks live materialization status before ready admission.
/// The enricher repeats the final byte-read gate for provider races; physical transfer
/// admission and priority remain entirely inside the shared materializer.
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
        let readyQueued: Int
        let enriching: Int
        let pendingApply: Int
        let materializationPending: Int
        let materializationInFlight: Int
        /// Device seeds offered but not yet admitted as demands. Non-zero means a
        /// camera is larger than the outstanding limit and the rest are waiting their
        /// turn, not dropped.
        let deviceSeedsQueued: Int

        var claimed: Int {
            readyQueued + enriching
        }

        var awaitingMaterialization: Int {
            materializationPending
        }

        var materializing: Int {
            materializationInFlight
        }

        var awaitingApply: Int {
            pendingApply
        }
    }

    enum ClaimedWorkState {
        case queuedEnrichment(EnrichWork)
        case enriching(EnrichWork, estimatedBytes: Int64)
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
        /// False only for `.removableVolume` sources (ADR 0018): hashing
        /// them in place would force a full read of the whole card merely to
        /// checksum it. Populated in `makeWork` from `removableRootPaths`.
        let shouldHash: Bool
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
    /// in-window retry attempts: no work payload (unlike `ClaimedWorkRecord`), so
    /// holding one per permanently-failing identity is far cheaper than the
    /// claim-window slot it replaces.
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
    let admissionPolicy: EnrichmentAdmissionPolicy
    let handoffPolicy: EnrichmentMaterializationHandoffPolicy
    let claimWindowLimit: Int
    let claimRefreshInterval: Duration
    let claimRefreshSleep: @Sendable (Duration) async -> Void
    let readinessChecker: any EnrichmentReadinessChecking

    var viewport: [MediaAssetID] = []
    var freshly: [MediaAssetID] = []
    var readyClaims: [MediaAssetID: ClaimedWorkRecord] = [:]
    var materializationDemands: [MediaAssetID: DownloadWork] = [:]
    var materializingIDs: Set<MediaAssetID> = []
    /// Callers of `drainWork(under:)` waiting for a root's work to end, resumed by
    /// `resumeDrainedWaiters()` whenever a piece of work finishes.
    var drainWaiters: [UUID: (rootPath: LibraryRootPath, continuation: CheckedContinuation<Void, Never>)] = [:]
    var materializationClaimIDs: Set<MediaAssetID> = []
    var pendingApplyClaimIDs: Set<MediaAssetID> = []
    var deviceRootPaths: Set<LibraryRootPath> = []
    /// Device seeds offered but not yet admitted as materialization demands.
    ///
    /// A camera attach offers *every* catalog item at once, while only
    /// `globalOutstandingLimit` (16) may be outstanding. The overflow waits here and
    /// is admitted as capacity frees. It cannot be dropped, because nothing would
    /// recover it: the catalog flow runs once per attach, and an unstaged device
    /// file fails `lstat`, so readiness routing answers `.unknown` and retries
    /// readiness rather than creating a demand. A camera with more than ~16 items
    /// would never fully stage, and so never fully enrich — contradicting ENR-011's
    /// eager-staging intent.
    var pendingDeviceSeeds: [DeviceStagingSeed] = []
    var nextClaimSequence: UInt64 = 0
    var retryLedger: [MediaAssetID: RetryLedgerEntry] = [:]
    var pendingApply: [EnrichmentResult] = []
    var diagnosedThumbnailLifecycleIDs: Set<MediaAssetID> = []
    var isShuttingDown = false
    var lastDownloadCandidateEvaluationCount = 0
    var lastEnrichmentAdmissionSnapshot: AdmissionDiagnosticSnapshot?
    var enrichmentAdmissionTransitionCount = 0
    var readinessRetryNotBefore: [MediaAssetID: Date] = [:]
    /// Resolves a device root to its live session, so a camera row can be enriched from
    /// ranges instead of from a downloaded copy. Nil when no camera is attached, or in
    /// tests that do not exercise the device path.
    let cameraRangeAccess: CameraRangeAccess?
    /// Device roots proven to answer ranged reads, decided once per attach.
    ///
    /// `GetPartialObject` is optional in MTP and devices that advertise it are documented
    /// failing it, so this is measured rather than assumed. A root absent from this set
    /// stages, which is what every device did before this path existed.
    var rangeCapableRootPaths: Set<LibraryRootPath> = []
    /// Last emitted scheduler-route facts, and how many identical passes have been
    /// collapsed since (B1). The route line was unconditional, so a scheduler spinning at
    /// zero delay emitted hundreds of identical `dispatched=0` lines per second: the
    /// 2026-08-30 camera session peaked at 2,336 lines/second and the unified log dropped
    /// ~836 download completions, which produced a false diagnosis of a wedged pipeline.
    /// Logging on change keeps every transition and costs one line per steady state.
    var lastSchedulerRoute: SchedulerRouteFacts?
    var suppressedSchedulerRoutes = 0

    let writeFailureBackoff: Duration

    private var supervisor: Task<Void, Never>?
    private var changeConsumer: Task<Void, Never>?
    /// The one apply in flight, if any. Results that complete while it writes wait in
    /// `pendingApply` and the next apply takes them all, so batching comes from the
    /// write itself rather than from a timer: a write measured ~0.4 ms for one row and
    /// ~0.1 ms a row in larger batches (`docs/research/2026-10-23-cadence-audit.md`).
    var applyFlushTask: Task<Void, Never>?
    var writeRetryTask: Task<Void, Never>?
    var downloadRetryTask: Task<Void, Never>?
    var claimRefreshTask: Task<Void, Never>?
    var ledgerRetryTask: Task<Void, Never>?
    var readinessRetryTask: Task<Void, Never>?
    private let signalStream: AsyncStream<Void>
    private let signalContinuation: AsyncStream<Void>.Continuation

    init(
        store: CatalogStore,
        enricher: MediaEnricher,
        materializationRequester: (any MaterializationRequesting)? = nil,
        cameraRangeAccess: CameraRangeAccess? = nil,
        materialize: @escaping @Sendable (URL) async -> MaterializationResult = { _ in .cancelled },
        readinessChecker: any EnrichmentReadinessChecking = LiveEnrichmentReadinessChecker(),
        enrichConcurrency: Int = EnrichmentAdmissionPolicy.production.enrichConcurrency,
        claimBatchSize: Int = 32,
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
        self.cameraRangeAccess = cameraRangeAccess
        self.materializationRequester = materializationRequester
            ?? ClosureMaterializationRequester(operation: materialize)
        var policy = admissionPolicy
        policy.enrichConcurrency = enrichConcurrency
        self.admissionPolicy = policy
        self.enrichConcurrency = enrichConcurrency
        self.claimBatchSize = max(claimBatchSize, enrichConcurrency)
        self.writeFailureBackoff = writeFailureBackoff
        self.handoffPolicy = handoffPolicy
        self.claimWindowLimit = max(claimWindowLimit, enrichConcurrency)
        self.claimRefreshInterval = claimRefreshInterval
        self.claimRefreshSleep = claimRefreshSleep
        self.readinessChecker = readinessChecker
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
        let capturedLedgerRetryTask = ledgerRetryTask
        let capturedReadinessRetryTask = readinessRetryTask
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
        capturedLedgerRetryTask?.cancel()
        ledgerRetryTask = nil
        capturedReadinessRetryTask?.cancel()
        readinessRetryTask = nil
        await supervisor?.value
        await capturedChangeConsumer?.value
        await capturedApplyFlushTask?.value
        await capturedWriteRetryTask?.value
        await capturedDownloadRetryTask?.value
        await capturedClaimRefreshTask?.value
        await capturedLedgerRetryTask?.value
        await capturedReadinessRetryTask?.value
        self.supervisor = nil
        await releaseOutstandingClaimsForShutdown()
        readyClaims.removeAll()
        materializationDemands.removeAll()
        materializingIDs.removeAll()
        materializationClaimIDs.removeAll()
        pendingApplyClaimIDs.removeAll()
        retryLedger.removeAll()
        readinessRetryNotBefore.removeAll()
        pendingApply.removeAll()
        pendingDeviceSeeds.removeAll()
        diagnosedThumbnailLifecycleIDs.removeAll()
        freshly.removeAll()
        signalContinuation.finish()
        resumeDrainedWaiters()
    }

    func updateViewport(_ ids: [MediaAssetID]) {
        viewport = ids
        signal()
    }

    /// How this row's bytes are reachable.
    ///
    /// A local file unless the row is on a device root that has proven it answers ranged
    /// reads *and* its session is still attached. Both conditions are checked here rather
    /// than assumed at seeding time, because a camera can leave between the two.
    func byteAccess(for work: EnrichWork) async -> EnrichmentByteAccess {
        guard rangeCapableRootPaths.contains(work.id.libraryRootPath),
              let cameraRangeAccess,
              let session = await cameraRangeAccess.session(for: work.id.libraryRootPath),
              let size = work.sourceSize,
              size > 0
        else {
            return .localFile(work.url)
        }
        return .cameraRanges(
            session: session,
            relativePath: work.id.relativePath,
            size: UInt64(size)
        )
    }

    /// Records that a device root answers ranged reads, so its rows enrich without being
    /// downloaded first.
    func markRangeCapable(_ rootPath: LibraryRootPath) {
        rangeCapableRootPaths.insert(rootPath)
        signal()
    }

    func stageDevice(_ seeds: [DeviceStagingSeed]) {
        guard !isShuttingDown else {
            return
        }
        // Device staging has no Store enrichment claim. It is an independent
        // materialization demand and therefore cannot consume ready capacity.
        deviceRootPaths.formUnion(seeds.map(\.id.libraryRootPath))

        // A root that answers ranged reads is not seeded at all. Its rows enrich from a few
        // kilobytes each, so downloading them first would be transferring the whole card to
        // read a date that is 4 KB in — the 36.5 GB and ~45 minutes this path removes.
        //
        // Filtered here rather than at the call site because capability is decided per
        // attach and this is the one place that turns items into transfers. A row still
        // reaches staging when it needs to: a container the reader cannot index, a ranged
        // read that keeps failing, or a loupe open all route one item through
        // `DeviceStagingRegistry.materialize`, which is untouched.
        let seedsNeedingBytes = seeds.filter { !rangeCapableRootPaths.contains($0.id.libraryRootPath) }
        let skipped = seeds.count - seedsNeedingBytes.count
        if skipped > 0 {
            OtosLog.metadata.noticeOperation("enrichment.stageDevice", phase: "rangedInstead", fields: [
                "skipped": "\(skipped)",
                "seeded": "\(seedsNeedingBytes.count)",
            ])
        }
        pendingDeviceSeeds.append(contentsOf: seedsNeedingBytes)
        admitPendingDeviceSeeds()
        signal()
    }

    /// Moves as many queued device seeds into materialization demands as capacity
    /// allows, keeping the remainder queued. Called on every seed offer and whenever a
    /// download completes, so the queue drains instead of being truncated once.
    func admitPendingDeviceSeeds() {
        guard !pendingDeviceSeeds.isEmpty else {
            return
        }
        let offered = pendingDeviceSeeds.count
        var admitted = 0
        var remaining: [DeviceStagingSeed] = []
        remaining.reserveCapacity(pendingDeviceSeeds.count)
        for seed in pendingDeviceSeeds {
            // Already staged, or already demanded: settled either way, not overflow.
            if FileManager.default.fileExists(atPath: seed.id.fileURL.path(percentEncoded: false)) {
                continue
            }
            if materializationDemands[seed.id] != nil {
                continue
            }
            guard materializationDemands.count < handoffPolicy.globalOutstandingLimit else {
                remaining.append(seed)
                continue
            }
            materializationDemands[seed.id] = DownloadWork(
                id: seed.id,
                url: seed.id.fileURL,
                sourceSize: seed.sourceSize,
                captureDate: seed.captureDate,
                isVideo: seed.isVideo,
                isDeviceStaging: true
            )
            admitted += 1
        }
        pendingDeviceSeeds = remaining
        let queued = pendingDeviceSeeds.count
        let outstanding = materializationDemands.count
        OtosLog.metadata.notice(
            "op=enrichment.stageDevice phase=admit offered=\(offered, privacy: .public) admitted=\(admitted, privacy: .public) queued=\(queued, privacy: .public) outstanding=\(outstanding, privacy: .public)"
        )
    }

    /// Stops starting work under `rootPath` and waits until none it started is still
    /// running. Eject calls it after quiescing the source: the Store then offers no new
    /// claims there, and the work this drops was never started, so what remains is
    /// finite and the wait ends when the last piece finishes, not after a guessed
    /// interval. The shared materialization
    /// coordinator needs no separate check: every request this coordinator submits is in
    /// `materializingIDs` from submission until its result comes back, so a root with no
    /// local work has no enrichment-origin transfer either (interactive previews never
    /// counted). A cancelled caller stops waiting at once.
    func drainWork(under rootPath: LibraryRootPath) async {
        let dropped = dropQueuedWork(under: rootPath)
        let running = runningWorkCount(under: rootPath)
        OtosLog.metadata.notice(
            "op=enrichment.drain phase=start rootPath=\(rootPath.rawValue, privacy: .public) dropped=\(dropped, privacy: .public) running=\(running, privacy: .public)"
        )
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard hasInFlightWork(under: rootPath), !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                drainWaiters[id] = (rootPath, continuation)
            }
        } onCancel: {
            Task { await self.resumeDrainWaiter(id) }
        }
    }

    /// Drops the work claimed under `rootPath` but not started: queued enrichment,
    /// downloads not yet submitted, and device-staging seeds. The Store released those
    /// claims when it quiesced the source, so nothing is owed for them.
    /// Returns how many pieces of work it dropped.
    private func dropQueuedWork(under rootPath: LibraryRootPath) -> Int {
        var dropped = 0
        for (id, record) in readyClaims where id.libraryRootPath == rootPath {
            if case .queuedEnrichment = record.state {
                readyClaims[id] = nil
                dropped += 1
            }
        }
        for id in materializationDemands.keys where id.libraryRootPath == rootPath && !materializingIDs.contains(id) {
            materializationDemands[id] = nil
            materializationClaimIDs.remove(id)
            dropped += 1
        }
        let seedsBefore = pendingDeviceSeeds.count
        pendingDeviceSeeds.removeAll { $0.id.libraryRootPath == rootPath }
        return dropped + seedsBefore - pendingDeviceSeeds.count
    }

    private func runningWorkCount(under rootPath: LibraryRootPath) -> Int {
        let enriching = readyClaims.count { id, record in
            guard id.libraryRootPath == rootPath, case .enriching = record.state else { return false }
            return true
        }
        return enriching + materializingIDs.count { $0.libraryRootPath == rootPath }
    }

    /// Resumes every drain waiter whose root has no work left. Called whenever a piece
    /// of work finishes and at shutdown.
    func resumeDrainedWaiters() {
        for (id, waiter) in drainWaiters where isShuttingDown || !hasInFlightWork(under: waiter.rootPath) {
            drainWaiters.removeValue(forKey: id)?.continuation.resume()
            OtosLog.metadata.notice(
                "op=enrichment.drain phase=finish rootPath=\(waiter.rootPath.rawValue, privacy: .public) shutdown=\(self.isShuttingDown, privacy: .public)"
            )
        }
    }

    /// Callers currently waiting in `drainWork(under:)`.
    var drainWaiterCount: Int {
        drainWaiters.count
    }

    private func resumeDrainWaiter(_ id: UUID) {
        drainWaiters.removeValue(forKey: id)?.continuation.resume()
    }

    private func hasInFlightWork(under rootPath: LibraryRootPath) -> Bool {
        let local = readyClaims.contains { id, record in
            guard id.libraryRootPath == rootPath else { return false }
            if case .enriching = record.state {
                return true
            }
            return false
        }
        let localMaterialization = materializingIDs.contains { id in id.libraryRootPath == rootPath }
        return local || localMaterialization
    }

    func workStateSnapshot() -> WorkStateSnapshot {
        var queued = 0
        var enriching = 0
        for record in readyClaims.values {
            switch record.state {
            case .queuedEnrichment:
                queued += 1
            case .enriching:
                enriching += 1
            }
        }
        return WorkStateSnapshot(
            readyQueued: queued,
            enriching: enriching,
            pendingApply: pendingApply.count,
            materializationPending: max(materializationDemands.count - materializingIDs.count, 0),
            materializationInFlight: materializingIDs.count,
            deviceSeedsQueued: pendingDeviceSeeds.count
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
    /// The worker child tasks (task-group children) run the heavy work and hop back through `finish*`,
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
                    let access = await byteAccess(for: work)
                    group.addTask {
                        let outcome = await enricher.enrich(
                            work.id, access, work.sourceSize, work.sourceMTimeSeconds, work.shouldHash
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
