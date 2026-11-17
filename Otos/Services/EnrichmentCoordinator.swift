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
/// viewport, ready/enriching claims, the `freshly` hand-off, the pending-apply buffer, and
/// an `EnrichmentSchedule` — the value that holds materialization demands, the pacing
/// ledger, readiness rechecks and the catalog-write retry. Every wait that schedule holds
/// wakes the loop through one owned deadline (`armWake(after:)`).
///
/// A bounded readiness pass asks the shared materializer where each original is
/// (`locality(of:)`) before ready admission.
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
///
/// Each signal is a request (`OwnerActivity`) a pass covers, so the coordinator reports when
/// it owes nothing (`QuiescentOwner`): every signal covered, every Store change acted on, no
/// claim queued or being read, no transfer in flight and no result waiting to be written. The
/// schedule's earliest wait is then its wake.
actor EnrichmentCoordinator: QuiescentOwner {
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
        let captureLocalTime: CaptureLocalTime?
        let isDeviceStaging: Bool
        /// What this enrichment reads and produces, as the Store's claim decided it.
        let scope: EnrichmentScope
    }

    nonisolated struct DownloadWork: Equatable, Sendable {
        let id: MediaAssetID
        let url: URL
        let sourceSize: Int64?
        let captureLocalTime: CaptureLocalTime?
        let isVideo: Bool
        let isDeviceStaging: Bool
        let attemptCount: Int
        let retryNotBefore: ContinuousClock.Instant?

        init(
            id: MediaAssetID,
            url: URL,
            sourceSize: Int64?,
            captureLocalTime: CaptureLocalTime?,
            isVideo: Bool,
            isDeviceStaging: Bool = false,
            attemptCount: Int = 0,
            retryNotBefore: ContinuousClock.Instant? = nil
        ) {
            self.id = id
            self.url = url
            self.sourceSize = sourceSize
            self.captureLocalTime = captureLocalTime
            self.isVideo = isVideo
            self.isDeviceStaging = isDeviceStaging
            self.attemptCount = attemptCount
            self.retryNotBefore = retryNotBefore
        }
    }

    struct DeviceStagingSeed {
        let id: MediaAssetID
        let sourceSize: Int64?
        let captureLocalTime: CaptureLocalTime?
        let isVideo: Bool
    }

    /// Pacing-only fact for a background materialization that exhausted its
    /// in-window retry attempts: no work payload (unlike `ClaimedWorkRecord`), so
    /// holding one per permanently-failing identity is far cheaper than the
    /// claim-window slot it replaces.
    nonisolated struct RetryLedgerEntry: Equatable, Sendable {
        let notBefore: ContinuousClock.Instant
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

    var viewport: [MediaAssetID] = []
    var freshly: [MediaAssetID] = []
    var readyClaims: [MediaAssetID: ClaimedWorkRecord] = [:]
    var schedule: EnrichmentSchedule
    /// Callers of `drainWork(under:)` waiting for a root's work to end, resumed by
    /// `resumeDrainedWaiters()` whenever a piece of work finishes.
    var drainWaiters: [UUID: (rootPath: LibraryRootPath, continuation: CheckedContinuation<Void, Never>)] = [:]
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
    var pendingApply: [EnrichmentResult] = []
    var diagnosedThumbnailLifecycleIDs: Set<MediaAssetID> = []
    var isShuttingDown = false
    var lastEnrichmentAdmissionSnapshot: AdmissionDiagnosticSnapshot?
    var enrichmentAdmissionTransitionCount = 0
    /// Resolves a device root to its live session, so a camera row can be enriched from
    /// ranges instead of from a downloaded copy. Nil when no camera is attached, or in
    /// tests that do not exercise the device path.
    let cameraRangeAccess: CameraRangeAccess?
    /// Resolves an account row to its server's ranged reads while the server answers, so
    /// its metadata is read without downloading the original (ADR 0046 §5).
    let remoteRangeAccess: RemoteRangeAccess?
    /// Device roots proven to answer ranged reads, decided once per attach.
    ///
    /// `GetPartialObject` is optional in MTP and devices that advertise it are documented
    /// failing it, so this is measured rather than assumed. A root absent from this set
    /// stages, which is what every device did before this path existed.
    var rangeCapableRootPaths: Set<LibraryRootPath> = []
    /// Bumped by every Store change this coordinator hears and every claim it gives back: the
    /// facts a background claim's answer depends on (ADR 0032 rule 2).
    var claimInputsRevision: UInt64 = 0
    /// Signals, passes and the work they did (`QuiescentOwner`).
    let activity = OwnerActivity(owner: "enrichment")
    /// Set by a pass whose candidate read failed, so the pass covers nothing (ADR 0032 rule 4).
    var claimReadFailed = false
    /// The revision and video-faces admission a background claim last found nothing at. While
    /// both stand, another claim would find nothing again, so none is asked: an empty claim is
    /// still a write transaction, and an idle coordinator writes nothing (plan 0116).
    var exhaustedClaims: (revision: UInt64, videoFaces: VideoFacesAdmission)?
    /// What the next pass asks the Store of the demanded rows (`reconcileDemandSources`): the
    /// rows a membership change named or a deadline brought back from parking, and, after a
    /// change that named no rows, every active demand. A demand ends when its row does, not
    /// when its transfer next fails. Parked rows are asked of when named or when they come
    /// back, never all at once: a failing library can park every row.
    var demandRowsToCheck: Set<MediaAssetID> = []
    var activeDemandsToCheck = false
    /// The roots the last pass found enrichable: parked demands are asked of a root's facts
    /// only when this set changes.
    var lastEnrichableRoots: Set<LibraryRootPath>?
    /// The priority rows (on screen, freshly local) the Store last answered owe nothing, so
    /// a pass asks the Store only of the rest (`PriorityAnswers`).
    var priorityAnswers = PriorityAnswers()

    private var supervisor: Task<Void, Never>?
    private var changeConsumer: Task<Void, Never>?
    /// The one apply in flight, if any. Results that complete while it writes wait in
    /// `pendingApply` and the next apply takes them all, so batching comes from the
    /// write itself rather than from a timer: a write measured ~0.4 ms for one row and
    /// ~0.1 ms a row in larger batches (`docs/research/2026-10-23-cadence-audit.md`).
    var applyFlushTask: Task<Void, Never>?
    /// The one sleep toward the schedule's earliest wait, and the instant it wakes at.
    /// Re-armed only when that instant changes.
    private var wakeTask: Task<Void, Never>?
    private var wakeAt: ContinuousClock.Instant?
    private let signalStream: AsyncStream<Void>
    private let signalContinuation: AsyncStream<Void>.Continuation

    init(
        store: CatalogStore,
        enricher: MediaEnricher,
        materializationRequester: (any MaterializationRequesting)? = nil,
        cameraRangeAccess: CameraRangeAccess? = nil,
        remoteRangeAccess: RemoteRangeAccess? = nil,
        materialize: @escaping @Sendable (URL) async -> MaterializationResult = { _ in .cancelled },
        originalStatus: @escaping @Sendable (URL) -> FileMaterializationStatus = FileMaterialization.status(of:),
        enrichConcurrency: Int = EnrichmentAdmissionPolicy.production.enrichConcurrency,
        claimBatchSize: Int = 32,
        schedule: EnrichmentSchedule = EnrichmentSchedule(retrySchedule: .production),
        admissionPolicy: EnrichmentAdmissionPolicy = .production,
        handoffPolicy: EnrichmentMaterializationHandoffPolicy = .production(),
        claimWindowLimit: Int = 32
    ) {
        self.store = store
        self.enricher = enricher
        self.cameraRangeAccess = cameraRangeAccess
        self.remoteRangeAccess = remoteRangeAccess
        self.materializationRequester = materializationRequester
            ?? ClosureMaterializationRequester(status: originalStatus, operation: materialize)
        var policy = admissionPolicy
        policy.enrichConcurrency = enrichConcurrency
        self.admissionPolicy = policy
        self.enrichConcurrency = enrichConcurrency
        self.claimBatchSize = max(claimBatchSize, enrichConcurrency)
        self.schedule = schedule
        self.handoffPolicy = handoffPolicy
        self.claimWindowLimit = max(claimWindowLimit, enrichConcurrency)
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        signalStream = stream
        signalContinuation = continuation
    }
}

extension EnrichmentCoordinator {
    /// Returns once the coordinator hears every later Store change. The subscription comes
    /// before the first pass: an apply that pass starts notifies only those already
    /// subscribed, and a lost notification leaves follow-up work (a card's rendering pass
    /// after its metadata) unclaimed until some unrelated change.
    func start() async {
        guard supervisor == nil else {
            return
        }
        let changes = await store.changeNotifications(deliveries: activity.deliveries)
        // A concurrent `start()` may have won while this one subscribed; its stream is
        // dropped here, which ends that subscription.
        guard supervisor == nil else {
            return
        }
        OtosLog.metadata.info("Enrichment coordinator started")
        changeConsumer = Task { [weak self] in
            for await change in changes {
                guard let self else {
                    return
                }
                await actOnDelivered(change)
            }
        }
        supervisor = Task { await self.runLoop() }
        signal()
    }

    func shutdown() async {
        isShuttingDown = true
        let supervisor = supervisor
        let capturedChangeConsumer = changeConsumer
        let capturedApplyFlushTask = applyFlushTask
        let capturedWakeTask = wakeTask
        supervisor?.cancel()
        capturedChangeConsumer?.cancel()
        changeConsumer = nil
        capturedApplyFlushTask?.cancel()
        applyFlushTask = nil
        capturedWakeTask?.cancel()
        wakeTask = nil
        wakeAt = nil
        activity.wake = nil
        await supervisor?.value
        await capturedChangeConsumer?.value
        await capturedApplyFlushTask?.value
        await capturedWakeTask?.value
        self.supervisor = nil
        await releaseOutstandingClaimsForShutdown()
        readyClaims.removeAll()
        schedule = EnrichmentSchedule(retrySchedule: schedule.retrySchedule)
        pendingApplyClaimIDs.removeAll()
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
        if work.scope.isReadableInRanges, let remoteRangeAccess, let size = work.sourceSize, size > 0,
           let reader = await remoteRangeAccess.reader(for: work.id, size: UInt64(size))
        {
            return .remoteRanges(reader, relativePath: work.id.relativePath)
        }
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
            if schedule.hasDemand(for: seed.id) {
                continue
            }
            guard schedule.outstandingCount < handoffPolicy.globalOutstandingLimit else {
                remaining.append(seed)
                continue
            }
            // Device staging has no Store enrichment claim.
            schedule.demand(
                DownloadWork(
                    id: seed.id,
                    url: seed.id.fileURL,
                    sourceSize: seed.sourceSize,
                    captureLocalTime: seed.captureLocalTime,
                    isVideo: seed.isVideo,
                    isDeviceStaging: true
                ),
                ownsStoreClaim: false,
                outstandingLimit: handoffPolicy.globalOutstandingLimit
            )
            admitted += 1
        }
        pendingDeviceSeeds = remaining
        let queued = pendingDeviceSeeds.count
        let outstanding = schedule.outstandingCount
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
    /// flight in `schedule` from submission until its result comes back, so a root with no
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
        // A transfer still running ends withdrawn, so its result neither retries nor holds a
        // row of a source being ejected.
        dropped += schedule.withdraw { id, _ in id.libraryRootPath == rootPath }.dropped
        let seedsBefore = pendingDeviceSeeds.count
        pendingDeviceSeeds.removeAll { $0.id.libraryRootPath == rootPath }
        return dropped + seedsBefore - pendingDeviceSeeds.count
    }

    private func runningWorkCount(under rootPath: LibraryRootPath) -> Int {
        let enriching = readyClaims.count { id, record in
            guard id.libraryRootPath == rootPath, case .enriching = record.state else { return false }
            return true
        }
        return enriching + schedule.inFlightCount(under: rootPath)
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
        return local || schedule.hasInFlightWork(under: rootPath)
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
            materializationPending: schedule.waitingCount,
            materializationInFlight: schedule.inFlightCount,
            deviceSeedsQueued: pendingDeviceSeeds.count
        )
    }
}

extension EnrichmentCoordinator {
    /// A Store change: new claim inputs, and, when it may have removed, moved or resized a
    /// demanded row — a membership change that names one, or names none — a question for the
    /// next pass of which demanded rows the Store still offers (`reconcileDemandSources`); and
    /// the priority rows it may have made owe work are asked of again (`PriorityAnswers`).
    func noteStoreChange(_ change: CatalogStoreChange) {
        priorityAnswers.heard(change.rows)
        if case let .changed(facts, rows) = change, facts.contains(.membership), schedule.hasDemands {
            switch rows {
            case .unnamed:
                activeDemandsToCheck = true
            case let .named(rows):
                demandRowsToCheck.formUnion(rows.ids.filter(schedule.hasDemand(for:)))
            case .none:
                break
            }
        }
        markDirtyAndSignal()
    }

    /// A change the Store delivered to this coordinator's subscription: noted, and counted as
    /// acted on in the same step.
    private func actOnDelivered(_ change: CatalogStoreChange) {
        noteStoreChange(change)
        activity.actedOnChange()
        settleQuiescence()
    }

    /// Work the coordinator holds beyond its passes: a claim queued or being read, a transfer
    /// in flight, a result waiting to be written, a device seed waiting for room.
    var holdsWork: Bool {
        !readyClaims.isEmpty || schedule.inFlightCount > 0 || !pendingApply.isEmpty || applyFlushTask != nil
            || !pendingDeviceSeeds.isEmpty
    }

    func ringIdle() {
        signal()
    }

    /// Asks the Store which of the rows to check it still offers, and ends the demands of rows
    /// it no longer has (`EnrichmentSchedule.reconcile`). A failed read leaves the rows to
    /// check for the next pass.
    func reconcileDemandSources() async {
        let checksActive = activeDemandsToCheck
        let named = demandRowsToCheck
        activeDemandsToCheck = false
        demandRowsToCheck = []
        let checked = Array(named.filter(schedule.hasDemand(for:)).union(checksActive ? schedule.activeIDs : []))
        guard !checked.isEmpty else {
            return
        }
        let sources: [MediaAssetID: Int64?]
        do {
            sources = try await store.backgroundReads.enrichmentDemandSources(checked)
        } catch {
            OtosLog.metadata.errorOperation("enrichment.demandSources", phase: "readFailed", fields: [
                "count": "\(checked.count)", "error": String(describing: error),
            ])
            activeDemandsToCheck = activeDemandsToCheck || checksActive
            demandRowsToCheck.formUnion(named)
            return
        }
        activity.read(rows: sources.count)
        guard !isShuttingDown else {
            return
        }
        let claims = schedule.reconcile(sources: sources, checked: checked)
        OtosLog.metadata.noticeOperation("enrichment.demandSources", phase: "reconciled", fields: [
            "checked": "\(checked.count)", "gone": "\(checked.count - sources.count)",
        ])
        if !claims.isEmpty {
            await releaseClaims(claims)
        }
    }

    func markDirtyAndSignal() {
        guard !isShuttingDown else {
            return
        }
        claimInputsRevision &+= 1
        signal()
    }

    func signal() {
        guard !isShuttingDown else {
            return
        }
        activity.request()
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
    ///
    /// Each pass decides what is due against the one instant it started from, and ends by
    /// arming the wake for the earliest wait still ahead of that instant: anything at or
    /// behind it was this pass's to act on.
    func runLoop() async {
        await withDiscardingTaskGroup { group in
            for await _ in signalStream {
                if Task.isCancelled {
                    break
                }
                let answering = activity.beginPass()
                claimReadFailed = false
                let passStart = ContinuousClock.now
                for work in await dequeueEnrichmentWork(now: passStart) {
                    if work.sourceSize == 0 {
                        group.addTask {
                            await self.finishEmptySource(work)
                        }
                        continue
                    }
                    let enricher = enricher
                    let store = store
                    let access = await byteAccess(for: work)
                    group.addTask {
                        // The photo's edit is rendered into its thumbnail and preview, and
                        // the result names the revision it applied (ADR 0036). A recipe that
                        // cannot be read is not guessed at: the work is retried.
                        let recipe: StoredEditRecipe?
                        do {
                            recipe = try await store.backgroundReads.editRecipe(for: work.id)
                        } catch {
                            OtosLog.metadata.errorOperation("enrichment.editRecipe", phase: "readFailed", fields: [
                                "relativePath": work.id.relativePath.rawValue,
                                "error": String(describing: error),
                            ])
                            await self.finishEnrich(work, .transient)
                            return
                        }
                        let outcome = await enricher.enrich(
                            work.id, access, work.sourceSize, work.sourceMTimeSeconds, work.scope, recipe
                        )
                        await self.finishEnrich(work, outcome)
                    }
                }
                for work in await dequeueMaterializationSubmissions(now: passStart) {
                    let requester = materializationRequester
                    group.addTask {
                        let start = ContinuousClock.now
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
                schedule.endPass(at: passStart)
                armWake(after: passStart)
                activity.endPass(covering: claimReadFailed ? nil : answering)
                settleQuiescence()
            }
        }
    }

    /// Points the one wake at the schedule's earliest wait after `now`, or cancels it when
    /// nothing waits. Unchanged when that instant is the one already armed.
    func armWake(after now: ContinuousClock.Instant) {
        let next = schedule.nextWake(after: now)
        guard next != wakeAt else {
            return
        }
        wakeTask?.cancel()
        wakeTask = nil
        wakeAt = nil
        activity.wake = nil
        guard let next, !isShuttingDown else {
            return
        }
        wakeAt = next
        activity.wake = OwnerWake(kind: .backoff, at: next)
        wakeTask = Task { [weak self] in
            do {
                // time: backoff — the earliest retry, recheck or pacing the schedule holds
                try await ContinuousClock().sleep(until: next)
            } catch {
                return
            }
            await self?.wakeFired(at: next)
        }
    }

    private func wakeFired(at instant: ContinuousClock.Instant) {
        if wakeAt == instant {
            wakeAt = nil
            wakeTask = nil
            activity.wake = nil
        }
        signal()
    }
}
