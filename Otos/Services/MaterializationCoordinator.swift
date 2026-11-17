import Foundation
import OSLog

/// Shared boundary every byte reader asks before it reads an original: where the bytes
/// are (`locality(of:)`), and a deliberate download when they are not local
/// (`materialize`, or `ensureLocal`, which does both).
nonisolated protocol MaterializationRequesting: Sendable {
    func materialize(_ request: MaterializationCoordinator.Request) async -> MaterializationResult
    func locality(of id: MediaAssetID) async -> OriginalLocality
}

/// Where an original's bytes are right now (ADR 0046 §4). Transient, like the
/// `FileMaterializationStatus` it is read from: a reader still re-checks the file
/// synchronously right before it reads (ADR 0008).
nonisolated enum OriginalLocality: Equatable, Sendable {
    /// The bytes are on this Mac; reading them downloads nothing.
    case local
    /// The bytes are not here, and a deliberate transfer can bring them: a dataless
    /// cloud placeholder, or a staged original not yet copied from its source.
    case fetchable
    /// The bytes are not here, and their source sends them only for work the user is
    /// waiting on (`MaterializationCoordinator.Priority.isUserWork`): an Immich account's
    /// original, downloaded for a zoom, an edit, an export or a hand-off and never to
    /// enrich a library (ADR 0046 §4). Background and device work never asks for it.
    case fetchableForUserWork
    /// The original cannot be read or fetched: a missing in-place file, or an unreadable
    /// status.
    case unreachable

    /// Locality of a file read in place, from its `SF_DATALESS` status.
    static func inPlace(_ status: FileMaterializationStatus) -> OriginalLocality {
        switch status {
        case .materialized: .local
        case .dataless: .fetchable
        case .unknown: .unreachable
        }
    }

    /// Locality of a root's original. A root that stages its originals keeps them in an
    /// Otos folder that holds only what has been copied so far, so a file absent there is
    /// one the source has yet to send, not a missing original. Whether the source can
    /// send it now is the executor's answer (`deviceUnavailable`), not a guess here; whether
    /// it sends it for this work is the kind's (`sendsOriginalsOnlyForUserWork`).
    static func of(kind: LibraryRootKind?, status: FileMaterializationStatus) -> OriginalLocality {
        guard let kind, kind.stagesOriginals else {
            return inPlace(status)
        }
        guard status != .materialized else {
            return .local
        }
        return kind.sendsOriginalsOnlyForUserWork ? .fetchableForUserWork : .fetchable
    }

    /// Whether a transfer at `priority` may bring the bytes here.
    func isFetchable(at priority: MaterializationCoordinator.Priority) -> Bool {
        switch self {
        case .fetchable: true
        case .fetchableForUserWork: priority.isUserWork
        case .local, .unreachable: false
        }
    }
}

/// What `ensureLocal` found: the original is local, or why it is not.
nonisolated enum EnsureLocalOutcome: Equatable, Sendable {
    case local
    case unreachable
    case notMaterialized(MaterializationOutcome)
    /// The source sends this original only for the user's work, and the request was not
    /// (`OriginalLocality.fetchableForUserWork`). Nothing was asked of it.
    case userWorkOnly

    var isLocal: Bool {
        self == .local
    }
}

extension MaterializationRequesting {
    /// Makes an original's bytes local before a decode, a render, an export or a
    /// hand-off reads them: a deliberate transfer at the request's priority when it is
    /// fetchable, then its locality once more (ADR 0008). The caller still
    /// re-checks right before its read; this answer can go stale across its next await.
    @concurrent
    func ensureLocal(_ request: MaterializationCoordinator.Request) async -> EnsureLocalOutcome {
        switch await locality(of: request.id) {
        case .local:
            break
        case .unreachable:
            OtosLog.mediaIO.noticeOperation("original.ensureLocal", phase: "unreachable", fields: [
                "id": request.id.relativePath.rawValue,
            ])
            return .unreachable
        case .fetchableForUserWork where !request.priority.isUserWork:
            OtosLog.mediaIO.noticeOperation("original.ensureLocal", phase: "userWorkOnly", fields: [
                "id": request.id.relativePath.rawValue, "priority": "\(request.priority)",
            ])
            return .userWorkOnly
        case .fetchable, .fetchableForUserWork:
            let result = await materialize(request)
            guard result.isMaterialized else {
                OtosLog.mediaIO.noticeOperation("original.ensureLocal", phase: "notMaterialized", fields: [
                    "id": request.id.relativePath.rawValue, "outcome": result.outcome.diagnosticDescription,
                ])
                return .notMaterialized(result.outcome)
            }
        }
        guard await locality(of: request.id) == .local else {
            OtosLog.mediaIO.noticeOperation("original.ensureLocal", phase: "unreachable", fields: [
                "id": request.id.relativePath.rawValue,
            ])
            return .unreachable
        }
        return .local
    }
}

/// Whether the loupe and Compare may download an original they need: a cloud-only photo's
/// full-resolution decode, or a still with no stored preview. Always, except in a read-only
/// tour (`SmokeTour`), which shows only what is on this Mac or stored.
nonisolated enum PaneOriginalDownloads: Equatable, Sendable {
    case whenNeeded
    case never
}

/// The panes' requester in a read-only tour: locality is the shared coordinator's own
/// answer, and a download is never asked for (`MaterializationOutcome.refusedReadOnly`), so
/// the panes show the stored preview and nothing more.
nonisolated struct ReadOnlyOriginals: MaterializationRequesting {
    let coordinator: any MaterializationRequesting

    func materialize(_ request: MaterializationCoordinator.Request) async -> MaterializationResult {
        OtosLog.mediaIO.noticeOperation("original.download", phase: "refusedReadOnly", fields: [
            "id": request.id.relativePath.rawValue, "priority": "\(request.priority)",
        ])
        return MaterializationResult(outcome: .refusedReadOnly, rerequestCount: 0, elapsedMs: 0)
    }

    func locality(of id: MediaAssetID) async -> OriginalLocality {
        await coordinator.locality(of: id)
    }
}

/// Process-lifetime owner of every deliberate provider or device materialization.
///
/// Callers only register demand. One actor-owned supervisor performs priority selection
/// and physical admission after coalesced wakes, so background producers cannot make
/// enqueue cost grow with the library. Per-ID waiters carry their own priority: joining
/// interactive demand raises an active background transfer's effective priority without
/// pretending that the provider itself can reprioritize the already-issued request.
///
/// Each wake is a request a scheduling pass covers (`OwnerActivity`), so the coordinator
/// reports when it owes nothing (`QuiescentOwner`): every wake through admission, no transfer
/// in flight, and nothing pending but what an open provider breaker holds, whose cooldown is
/// then its wake.
actor MaterializationCoordinator: MaterializationRequesting, QuiescentOwner {
    /// `command` is user-commanded work nobody is watching on screen (Move to Trash
    /// downloading a dataless member). It outranks device and background so a library's
    /// enrichment backlog cannot starve it, is exempt from the background per-root cap,
    /// yields to interactive work, and — unlike interactive — runs under the bounded
    /// background `Persistence`, because no on-screen demand will ever cancel it.
    enum Priority: Int, Sendable, Comparable, CaseIterable {
        case background
        case device
        case command
        case interactive

        /// Demand-bounded priorities stop their transfer when the last waiter leaves.
        /// Background and device keep polling on purpose (ENR-008 wants those bytes).
        var cancelsWhenUnwaited: Bool {
            self == .interactive || self == .command
        }

        /// Work the user asked for: on screen (`interactive`) or commanded (`command`). A
        /// source that sends originals only for the user's work sends them for these.
        var isUserWork: Bool {
            self == .interactive || self == .command
        }

        static func < (lhs: Priority, rhs: Priority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    struct Request: Sendable, Equatable {
        let id: MediaAssetID
        let sourceSize: Int64?
        let isVideo: Bool
        let priority: Priority
    }

    struct AdmissionSnapshot: Equatable, Sendable {
        let priority: Priority?
        let rejections: [MaterializationAdmissionPolicy.Rejection: Int]
        let admitted: Int
        let pendingInteractive: Int
        let pendingCommand: Int
        let pendingDevice: Int
        let pendingBackground: Int
        let inFlight: Int
        let bytes: Int64
        let largeVideos: Int
        let effectiveInteractive: Int
        let backgroundByRoot: [LibraryRootPath: Int]
    }

    struct StateSnapshot: Equatable, Sendable {
        let pending: Int
        let inFlight: Int
        let waiters: Int
        let bytes: Int64
        let largeVideos: Int
        let effectiveInteractive: Int
        let backgroundByRoot: [LibraryRootPath: Int]
    }

    /// Takes the whole `Request`, not a bare URL: which provider can serve an asset
    /// is a typed fact about its root, and narrowing to a path forced the executor to
    /// re-derive it by string-matching — which silently sent every camera file to the
    /// cloud provider for the life of the MTP code (APP-018).
    typealias Executor = @Sendable (Request) async -> MaterializationResult
    typealias DiagnosticSink = @Sendable (AdmissionSnapshot?) -> Void

    private struct Waiter {
        let priority: Priority
        let requestedAt: ContinuousClock.Instant
        let continuation: CheckedContinuation<MaterializationResult, Never>
    }

    private struct PendingEntry {
        var request: Request
        var effectivePriority: Priority
        var waiters: [UInt64: Waiter]
        let enqueuedAt: ContinuousClock.Instant
    }

    private struct InFlightEntry {
        let request: Request
        var effectivePriority: Priority
        var waiters: [UInt64: Waiter]
        let estimatedBytes: Int64
        let dispatchedAt: ContinuousClock.Instant
        var task: Task<Void, Never>?
        /// What this download committed to its volume's `FreeSpaceLedger`, once the task
        /// has read the volume's figure and been admitted; `nil` before that.
        var floorCommit: (volume: URL, bytes: Int64)?
    }

    private let store: CatalogStore
    private let executor: Executor
    /// The `SF_DATALESS` detector `locality(of:)` reads a file's status with: the one place
    /// that status decides where an original is (ADR 0046 §4).
    private let status: @Sendable (URL) -> FileMaterializationStatus
    /// Reads a volume's free space for the floor every background and device download
    /// keeps (ADR 0027). Injected because the floor is otherwise untestable.
    private let volumeCapacity: VolumeCapacityReader
    private let policy: MaterializationAdmissionPolicy
    private let diagnosticSink: DiagnosticSink?
    private let clock = ContinuousClock()
    private let wakeStream: AsyncStream<Void>
    private let wakeContinuation: AsyncStream<Void>.Continuation
    /// Wakes sent, and the newest one a scheduling pass has covered. The wake stream
    /// keeps only the newest value, so the counts — not the stream — say whether every
    /// registration, release and cancellation so far has been through admission.
    let activity = OwnerActivity(owner: "materialization")

    private var pendingByID: [MediaAssetID: PendingEntry] = [:]
    private var interactiveQueue: [MediaAssetID] = []
    private var commandQueue: [MediaAssetID] = []
    private var deviceQueue: [MediaAssetID] = []
    private var backgroundQueue: [MediaAssetID] = []
    private var inFlightByID: [MediaAssetID: InFlightEntry] = [:]
    /// One `FreeSpaceLedger` per volume with a committed download in flight, dropped when
    /// the last one settles, so the next stretch of downloads reads the figure afresh.
    private var ledgers: [URL: FreeSpaceLedger] = [:]

    private var inFlightCount = 0
    private var inFlightBytes: Int64 = 0
    private var inFlightLargeVideos = 0
    /// Device transfers currently handed to ImageCaptureCore. Capped at one by
    /// `MaterializationAdmissionPolicy.deviceConcurrency` because the framework serialises
    /// them anyway; counting them here is what lets the policy see that.
    private var inFlightDeviceCount = 0
    private var effectiveInteractiveCount = 0
    private var backgroundByRoot: [LibraryRootPath: Int] = [:]

    private var supervisor: Task<Void, Never>?
    private var lastBlockedSnapshot: AdmissionSnapshot?
    private var isShuttingDown = false
    private var nextWaiter: UInt64 = 0

    // Per-root breaker for definite provider refusal (ETIMEDOUT). Two consecutive
    // `providerUnavailable` on one root at device/background priority open a 60s window
    // where further device/background admissions on that root report `providerBreakerOpen`
    // instead of dispatching and blocking a `backgroundPerRootCap` slot for 2s each.
    //
    // Invariant: interactive demand is never suppressed. A user click both must not be
    // dropped and is the cheapest probe that the provider recovered — an interactive
    // success closes the breaker, an interactive failure neither opens nor extends it.
    private var providerUnavailableStreakByRoot: [LibraryRootPath: Int] = [:]
    private var breakerOpenUntilByRoot: [LibraryRootPath: ContinuousClock.Instant] = [:]
    private var breakerWakeTask: Task<Void, Never>?
    private let breakerThreshold = 2
    private let breakerCooldown: Duration = .seconds(60)

    init(
        store: CatalogStore,
        executor: @escaping Executor,
        volumeCapacity: @escaping VolumeCapacityReader,
        policy: MaterializationAdmissionPolicy = .production,
        diagnosticSink: DiagnosticSink? = nil,
        status: @escaping @Sendable (URL) -> FileMaterializationStatus = FileMaterialization.status(of:)
    ) {
        self.store = store
        self.executor = executor
        self.status = status
        self.volumeCapacity = volumeCapacity
        self.policy = policy
        self.diagnosticSink = diagnosticSink
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wakeStream = stream
        wakeContinuation = continuation
    }

    func start() {
        guard supervisor == nil, !isShuttingDown else {
            return
        }
        supervisor = Task { [weak self] in
            await self?.runSupervisor()
        }
        wake()
    }

    func materialize(_ request: Request) async -> MaterializationResult {
        guard !isShuttingDown else {
            return .cancelled
        }
        start()
        nextWaiter &+= 1
        let token = nextWaiter
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                    return
                }
                register(
                    request,
                    token: token,
                    waiter: Waiter(
                        priority: request.priority,
                        requestedAt: clock.now,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            Task { await self.cancelWaiter(token, for: request.id) }
        }
    }

    /// Asks the Store what the root is, then reads the file's status off this actor: it
    /// touches no coordinator state, and the status read is a filesystem call.
    @concurrent
    nonisolated func locality(of id: MediaAssetID) async -> OriginalLocality {
        let kind = await store.rootKind(for: id.libraryRootPath)
        return OriginalLocality.of(kind: kind, status: status(id.fileURL))
    }

    func shutdown() async {
        guard !isShuttingDown else {
            if let supervisor {
                await supervisor.value
            }
            return
        }
        isShuttingDown = true
        breakerWakeTask?.cancel()
        breakerWakeTask = nil
        wakeContinuation.finish()

        let cancelled = MaterializationResult.cancelled
        for entry in pendingByID.values {
            entry.waiters.values.forEach { $0.continuation.resume(returning: cancelled) }
        }
        pendingByID.removeAll()
        interactiveQueue.removeAll()
        commandQueue.removeAll()
        deviceQueue.removeAll()
        backgroundQueue.removeAll()

        let operationTasks = inFlightByID.values.compactMap(\.task)
        for id in Array(inFlightByID.keys) {
            guard var entry = inFlightByID[id] else {
                continue
            }
            entry.waiters.values.forEach { $0.continuation.resume(returning: cancelled) }
            entry.waiters.removeAll()
            inFlightByID[id] = entry
        }
        operationTasks.forEach { $0.cancel() }
        supervisor?.cancel()

        for task in operationTasks {
            await task.value
        }
        if let supervisor {
            await supervisor.value
        }
        supervisor = nil

        // Every physical task completes through finishOperation(), which owns the
        // suppression close and incremental counter removal even during shutdown.
        precondition(inFlightByID.isEmpty)
        precondition(inFlightCount == 0)
        precondition(inFlightBytes == 0)
        precondition(inFlightLargeVideos == 0)
        precondition(inFlightDeviceCount == 0)
        precondition(effectiveInteractiveCount == 0)
        precondition(backgroundByRoot.isEmpty)
        publishUnblockedIfNeeded()
    }

    func stateSnapshot() -> StateSnapshot {
        StateSnapshot(
            pending: pendingByID.count,
            inFlight: inFlightCount,
            waiters: pendingByID.values.reduce(0) { $0 + $1.waiters.count }
                + inFlightByID.values.reduce(0) { $0 + $1.waiters.count },
            bytes: inFlightBytes,
            largeVideos: inFlightLargeVideos,
            effectiveInteractive: effectiveInteractiveCount,
            backgroundByRoot: backgroundByRoot
        )
    }

    func queuedRequestCount() -> Int {
        pendingByID.count
    }

    /// True once every wake sent so far has been handled by a scheduling pass, so a
    /// caller can assert what admission decided — including that it started nothing —
    /// instead of guessing how long admission takes.
    var isQuiescent: Bool {
        !activity.isOwed
    }

    /// A transfer in flight, or a request pending that no open breaker holds back.
    var holdsWork: Bool {
        !inFlightByID.isEmpty || (!pendingByID.isEmpty && breakerOpenUntilByRoot.isEmpty)
    }

    /// Its backlog is enrichment's: background downloads of the originals the walk owes. Every
    /// wake handled and every pending or in-flight transfer at background priority — none a
    /// person waits on, a command needs or a device stages.
    var worksBacklog: Bool {
        activity.owesNothing
            && pendingByID.values.allSatisfy { $0.effectivePriority == .background }
            && inFlightByID.values.allSatisfy { $0.effectivePriority == .background }
    }

    /// Nothing outside a request rings admission: a wake with nothing pending admits nothing.
    func ringIdle() {
        wake()
    }

    private func register(_ request: Request, token: UInt64, waiter: Waiter) {
        if var active = inFlightByID.removeValue(forKey: request.id) {
            let previous = active.effectivePriority
            active.waiters[token] = waiter
            active.effectivePriority = maximumPriority(in: active.waiters)
            adjustEffectiveInteractive(from: previous, to: active.effectivePriority)
            inFlightByID[request.id] = active
            logLifecycle(
                phase: "joinedInFlight",
                request: request,
                effectivePriority: active.effectivePriority,
                isNotice: true
            )
            wake()
            return
        }

        if var entry = pendingByID.removeValue(forKey: request.id) {
            let previous = entry.effectivePriority
            entry.waiters[token] = waiter
            entry.effectivePriority = maximumPriority(in: entry.waiters)
            entry.request = Request(
                id: request.id,
                sourceSize: request.sourceSize ?? entry.request.sourceSize,
                isVideo: request.isVideo || entry.request.isVideo,
                priority: entry.effectivePriority
            )
            pendingByID[request.id] = entry
            if previous < entry.effectivePriority {
                removeFromQueue(request.id, priority: previous)
                appendToQueue(request.id, priority: entry.effectivePriority)
                logLifecycle(
                    phase: "promoted",
                    request: request,
                    effectivePriority: entry.effectivePriority,
                    isNotice: true
                )
            }
            wake()
            return
        }

        pendingByID[request.id] = PendingEntry(
            request: request,
            effectivePriority: request.priority,
            waiters: [token: waiter],
            enqueuedAt: clock.now
        )
        appendToQueue(request.id, priority: request.priority)
        logLifecycle(
            phase: "queued",
            request: request,
            effectivePriority: request.priority,
            isNotice: request.priority != .background
        )
        wake()
    }

    private func cancelWaiter(_ token: UInt64, for id: MediaAssetID) {
        if var pending = pendingByID.removeValue(forKey: id) {
            guard let waiter = pending.waiters.removeValue(forKey: token) else {
                pendingByID[id] = pending
                return
            }
            waiter.continuation.resume(returning: .cancelled)
            let previous = pending.effectivePriority
            if pending.waiters.isEmpty {
                removeFromQueue(id, priority: previous)
                logLifecycle(
                    phase: "cancelled",
                    request: pending.request,
                    effectivePriority: previous,
                    isNotice: previous != .background
                )
            } else {
                pending.effectivePriority = maximumPriority(in: pending.waiters)
                pending.request = Request(
                    id: pending.request.id,
                    sourceSize: pending.request.sourceSize,
                    isVideo: pending.request.isVideo,
                    priority: pending.effectivePriority
                )
                pendingByID[id] = pending
                if previous != pending.effectivePriority {
                    removeFromQueue(id, priority: previous)
                    appendToQueue(id, priority: pending.effectivePriority)
                }
            }
            wake()
            return
        }

        guard var active = inFlightByID.removeValue(forKey: id) else {
            return
        }
        guard let waiter = active.waiters.removeValue(forKey: token) else {
            inFlightByID[id] = active
            return
        }
        waiter.continuation.resume(returning: .cancelled)
        let previous = active.effectivePriority
        active.effectivePriority = maximumPriority(in: active.waiters, fallback: active.request.priority)
        adjustEffectiveInteractive(from: previous, to: active.effectivePriority)
        // An interactive transfer polls without a deadline, so the last waiter leaving is
        // the only thing that ends it. Without this the poll outlives every consumer and
        // runs for the life of the process. A command transfer is bounded, but its waiter
        // leaving means the command was withdrawn (an undone Move to Trash), so it stops too.
        //
        // Nothing is lost by stopping: the provider download continues regardless (we hold
        // no handle on it, research 2026-07-14), and the next request finds the file either
        // materialized or worth watching again. Background entries keep polling on purpose —
        // ENR-008 wants those bytes whether or not anyone is still asking.
        if active.waiters.isEmpty, previous.cancelsWhenUnwaited, active.request.priority == previous {
            // Cancel only. The entry stays: the cancelled task still unwinds through
            // `finishOperation`, which is the one place that closes the Store
            // known-materialization suppression window (ARC-036), releases admission
            // accounting, and records the breaker outcome. Removing the entry here would
            // make that unwind a no-op and strand all three.
            active.task?.cancel()
            logLifecycle(
                phase: "abandonedByLastWaiter",
                request: active.request,
                effectivePriority: previous,
                isNotice: true
            )
        }
        inFlightByID[id] = active
        wake()
    }

    private func runSupervisor() async {
        for await _ in wakeStream {
            if Task.isCancelled || isShuttingDown {
                break
            }
            schedulePass()
            settleQuiescence()
        }
    }

    private func schedulePass() {
        guard !isShuttingDown else {
            return
        }
        // A pass sees every state change made before it starts; a wake raised during
        // the pass gets a later pass.
        activity.endPass(covering: activity.beginPass())
        var admitted = 0
        var rejections: [MaterializationAdmissionPolicy.Rejection: Int] = [:]
        let selectedPriority = selectedPendingPriority()

        if let selectedPriority {
            var index = 0
            while index < queue(for: selectedPriority).count {
                let id = queue(for: selectedPriority)[index]
                guard let entry = pendingByID[id], !entry.waiters.isEmpty else {
                    removeFromQueue(id, priority: selectedPriority)
                    pendingByID[id] = nil
                    continue
                }
                // The breaker exists to stop a background storm on a dead provider — it must never
                // swallow a direct user action. An interactive request is both the thing the user
                // is waiting on and the cheapest probe of whether the provider recovered; suppressing
                // it left loupe and click-to-play silently dead for up to 60s with no way to retry.
                // ENR-008 and APP-023 both say background only.
                if entry.effectivePriority != .interactive,
                   isBreakerOpen(for: entry.request.id.libraryRootPath)
                {
                    rejections[.providerBreakerOpen, default: 0] += 1
                    index += 1
                    continue
                }
                let snapshot = currentAdmissionSnapshot()
                if let rejection = policy.rejection(for: entry.request, inFlight: snapshot) {
                    rejections[rejection, default: 0] += 1
                    index += 1
                    continue
                }
                removeFromQueue(id, priority: selectedPriority)
                pendingByID[id] = nil
                dispatch(entry)
                admitted += 1
            }
        } else if effectiveInteractiveCount > 0 {
            // No pending interactive waiter, but an in-flight transfer's effective
            // priority is interactive (a waiter joined it): device/background stay
            // deferred by design. Record that truthfully instead of falling through
            // to publishUnblockedIfNeeded, which would clear the blocked diagnostic
            // during exactly the starvation window it exists to expose.
            let deferred = commandQueue.count + deviceQueue.count + backgroundQueue.count
            if deferred > 0 {
                rejections[.interactivePriority] = deferred
            }
        }
        recordAdmission(priority: selectedPriority, rejections: rejections, admitted: admitted)
    }

    private func selectedPendingPriority() -> Priority? {
        if !interactiveQueue.isEmpty {
            return .interactive
        }
        if effectiveInteractiveCount > 0 {
            return nil
        }
        if !commandQueue.isEmpty {
            return .command
        }
        if !deviceQueue.isEmpty {
            return .device
        }
        return backgroundQueue.isEmpty ? nil : .background
    }

    private func dispatch(_ entry: PendingEntry) {
        // A transfer is this owner's read.
        activity.read(rows: 1)
        let request = entry.request
        let estimatedBytes = policy.estimatedBytes(request.sourceSize)
        let now = clock.now
        // Work nobody is looking at keeps the free-space floor; the photo on screen and
        // a command the user gave do not wait for it, but still commit their bytes so the
        // work that waits counts them.
        let floorApplies = entry.effectivePriority == .background || entry.effectivePriority == .device
        inFlightCount += 1
        inFlightBytes += estimatedBytes
        if policy.isLargeVideo(request) {
            inFlightLargeVideos += 1
        }
        if request.priority == .device {
            inFlightDeviceCount += 1
        }
        if request.priority == .background {
            backgroundByRoot[request.id.libraryRootPath, default: 0] += 1
        }
        if entry.effectivePriority == .interactive {
            effectiveInteractiveCount += 1
        }

        inFlightByID[request.id] = InFlightEntry(
            request: request,
            effectivePriority: entry.effectivePriority,
            waiters: entry.waiters,
            estimatedBytes: estimatedBytes,
            dispatchedAt: now,
            task: nil
        )
        let executor = executor
        let volumeCapacity = volumeCapacity
        let store = store
        let task = Task { [weak self, request, executor, volumeCapacity, store] in
            guard !Task.isCancelled else {
                await self?.finishOperation(
                    request.id,
                    result: .cancelled,
                    providerFinishedAt: ContinuousClock().now
                )
                return
            }
            let reading = await Self.floorReading(
                volumeCapacity,
                for: request.id.libraryRootPath.url,
                readsCapacity: floorApplies
            )
            guard let admitted = await self?.commitDownload(request.id, reading: reading, waitsForFloor: floorApplies)
            else { return }
            guard admitted else {
                // Held at the floor, or no longer in flight (then this settles nothing).
                await self?.finishOperation(
                    request.id,
                    result: MaterializationResult(outcome: .insufficientLocalSpace, rerequestCount: 0, elapsedMs: 0),
                    providerFinishedAt: ContinuousClock().now
                )
                return
            }
            await store.beginKnownMaterialization(for: request.id)
            let result = await executor(request)
            await store.endKnownMaterialization(for: request.id, success: result.isMaterialized)
            await self?.finishOperation(
                request.id,
                result: result,
                providerFinishedAt: ContinuousClock().now
            )
        }
        inFlightByID[request.id]?.task = task

        let queueWaitMs = DiagnosticsTiming.milliseconds(from: entry.enqueuedAt, to: now)
        let currentInFlight = inFlightCount
        let currentBytes = inFlightBytes
        let sameRootBackground = backgroundByRoot[request.id.libraryRootPath, default: 0]
        OtosLog.mediaIO.notice(
            """
            op=materialization.request phase=dispatched priority=\(request.priority.description, privacy: .public) \
            effectivePriority=\(entry.effectivePriority.description, privacy: .public) \
            rootPath=\(request.id.libraryRootPath.rawValue, privacy: .public) \
            relativePath=\(request.id.relativePath.rawValue, privacy: .public) \
            queueWaitMs=\(queueWaitMs, privacy: .public) inFlight=\(currentInFlight, privacy: .public) \
            inFlightBytes=\(currentBytes, privacy: .public) \
            sameRootBackground=\(sameRootBackground, privacy: .public)
            """
        )
    }

    /// The volume a download writes to and, for one that waits for the floor, its
    /// figure. Read off the actor: CacheDelete answers the figure over XPC and may be
    /// recalculating (ADR 0032 rule 6).
    @concurrent
    private static func floorReading(
        _ volumeCapacity: VolumeCapacityReader,
        for url: URL,
        readsCapacity: Bool
    ) async -> (volume: URL, reported: Int64?) {
        (FreeSpaceFloor.volume(of: url), readsCapacity ? volumeCapacity(url) : nil)
    }

    /// Admits a download against its volume's ledger and commits its bytes, applied
    /// synchronously after the read so no other admission interleaves. A download that
    /// does not wait for the floor is committed without the check. Returns `false` when
    /// the floor holds the download, or when it is no longer in flight.
    private func commitDownload(
        _ id: MediaAssetID,
        reading: (volume: URL, reported: Int64?),
        waitsForFloor: Bool
    ) -> Bool {
        guard var entry = inFlightByID[id] else {
            return false
        }
        let bytes = entry.request.sourceSize ?? 0
        var ledger = ledgers[reading.volume] ?? FreeSpaceLedger()
        if waitsForFloor {
            guard ledger.admit(bytes, reported: reading.reported) else {
                OtosLog.mediaIO.notice(
                    """
                    op=materialization.request phase=floorHeld priority=\(entry.request.priority.description, privacy: .public) \
                    rootPath=\(id.libraryRootPath.rawValue, privacy: .public) \
                    relativePath=\(id.relativePath.rawValue, privacy: .public) \
                    sourceSize=\(entry.request.sourceSize ?? -1, privacy: .public) \
                    inFlightBytes=\(ledger.inFlightBytes, privacy: .public) \
                    reported=\(reading.reported ?? -1, privacy: .public) \
                    available=\(ledger.available(reported: reading.reported) ?? -1, privacy: .public) \
                    floor=\(FreeSpaceFloor.bytes, privacy: .public)
                    """
                )
                return false
            }
        } else {
            ledger.commit(bytes)
        }
        ledgers[reading.volume] = ledger
        entry.floorCommit = (reading.volume, bytes)
        inFlightByID[id] = entry
        return true
    }

    /// Settles a download's commitment with the bytes its outcome landed (all of them when
    /// it downloaded the file, none when the file was already local or nothing arrived), and
    /// drops the volume's ledger once nothing committed is in flight there.
    private func settleCommitment(of entry: InFlightEntry, outcome: MaterializationOutcome) {
        guard let commit = entry.floorCommit else { return }
        ledgers[commit.volume]?.settle(committed: commit.bytes, landed: outcome.landedBytes(of: commit.bytes))
        if !inFlightByID.values.contains(where: { $0.floorCommit?.volume == commit.volume }) {
            ledgers[commit.volume] = nil
        }
    }

    private func finishOperation(
        _ id: MediaAssetID,
        result: MaterializationResult,
        providerFinishedAt: ContinuousClock.Instant
    ) {
        guard let entry = inFlightByID.removeValue(forKey: id) else {
            return
        }
        recordProviderBreakerOutcome(
            result.outcome,
            rootPath: id.libraryRootPath,
            effectivePriority: entry.effectivePriority
        )
        removeAccounting(for: entry)
        settleCommitment(of: entry, outcome: result.outcome)
        let deliveredAt = clock.now
        let providerMs = DiagnosticsTiming.milliseconds(from: entry.dispatchedAt, to: providerFinishedAt)
        let completionDeliveryMs = DiagnosticsTiming.milliseconds(from: providerFinishedAt, to: deliveredAt)
        for waiter in entry.waiters.values {
            waiter.continuation.resume(returning: result)
        }
        let totalMs = entry.waiters.values
            .map { DiagnosticsTiming.milliseconds(from: $0.requestedAt, to: deliveredAt) }
            .max() ?? providerMs
        let outcome = result.outcome.diagnosticDescription
        let phase = result.isMaterialized ? "completed" : "failed"
        let currentInFlight = inFlightCount
        let currentBytes = inFlightBytes
        OtosLog.mediaIO.notice(
            """
            op=materialization.request phase=\(phase, privacy: .public) \
            priority=\(entry.request.priority.description, privacy: .public) \
            effectivePriority=\(entry.effectivePriority.description, privacy: .public) \
            rootPath=\(id.libraryRootPath.rawValue, privacy: .public) \
            relativePath=\(id.relativePath.rawValue, privacy: .public) \
            providerMs=\(providerMs, privacy: .public) completionDeliveryMs=\(completionDeliveryMs, privacy: .public) \
            totalMs=\(totalMs, privacy: .public) outcome=\(outcome, privacy: .public) \
            rerequestCount=\(result.rerequestCount, privacy: .public) inFlight=\(currentInFlight, privacy: .public) \
            inFlightBytes=\(currentBytes, privacy: .public)
            """
        )
        wake()
    }

    private func removeAccounting(for entry: InFlightEntry) {
        inFlightCount -= 1
        inFlightBytes -= entry.estimatedBytes
        if policy.isLargeVideo(entry.request) {
            inFlightLargeVideos -= 1
        }
        if entry.request.priority == .device {
            inFlightDeviceCount -= 1
        }
        if entry.request.priority == .background {
            let root = entry.request.id.libraryRootPath
            let next = backgroundByRoot[root, default: 0] - 1
            if next > 0 {
                backgroundByRoot[root] = next
            } else {
                backgroundByRoot[root] = nil
            }
        }
        if entry.effectivePriority == .interactive {
            effectiveInteractiveCount -= 1
        }
    }

    private func adjustEffectiveInteractive(from old: Priority, to new: Priority) {
        if old != .interactive, new == .interactive {
            effectiveInteractiveCount += 1
        } else if old == .interactive, new != .interactive {
            effectiveInteractiveCount -= 1
        }
    }

    // MARK: - Provider breaker (per-root, process-local)

    private func isBreakerOpen(for rootPath: LibraryRootPath) -> Bool {
        guard let until = breakerOpenUntilByRoot[rootPath] else {
            return false
        }
        if until > clock.now {
            return true
        }
        breakerOpenUntilByRoot[rootPath] = nil
        return false
    }

    private func recordProviderBreakerOutcome(
        _ outcome: MaterializationOutcome,
        rootPath: LibraryRootPath,
        effectivePriority: Priority
    ) {
        switch outcome {
        case .providerUnavailable:
            // Only background/device failures open the breaker. A user's own click
            // failing must never lengthen a suppression window.
            guard effectivePriority != .interactive else { return }
            let next = (providerUnavailableStreakByRoot[rootPath] ?? 0) + 1
            providerUnavailableStreakByRoot[rootPath] = next
            guard next >= breakerThreshold else {
                return
            }
            providerUnavailableStreakByRoot[rootPath] = 0
            let cooldown = breakerCooldown
            let until = clock.now.advanced(by: breakerCooldown)
            breakerOpenUntilByRoot[rootPath] = until
            OtosLog.mediaIO.notice(
                """
                op=materialization.providerBreaker phase=opened rootPath=\(rootPath.rawValue, privacy: .public) \
                streak=\(next, privacy: .public) cooldownMs=\(DiagnosticsTiming.milliseconds(cooldown), privacy: .public)
                """
            )
            scheduleBreakerWake()
        case .materialized, .alreadyMaterialized:
            // Any success closes it, including an interactive one — that is the
            // implicit retry path.
            let hadBreaker = breakerOpenUntilByRoot[rootPath] != nil
            let hadStreak = (providerUnavailableStreakByRoot[rootPath] ?? 0) > 0
            if hadBreaker || hadStreak {
                providerUnavailableStreakByRoot[rootPath] = nil
                breakerOpenUntilByRoot[rootPath] = nil
                OtosLog.mediaIO.notice(
                    "op=materialization.providerBreaker phase=closed rootPath=\(rootPath.rawValue, privacy: .public)"
                )
                wake()
            }
        case .requestFailed, .timedOut, .insufficientLocalSpace, .cancelled, .statusUnavailable,
             .deviceUnavailable, .serverUnreachable, .refusedReadOnly:
            // Inconclusive / slow / cancelled: neither opens nor closes the breaker.
            // `deviceUnavailable` and `serverUnreachable` belong here rather than with the
            // failures: an absent camera or a silent server says nothing about a
            // *provider's* health, and letting it open the breaker would suppress a root
            // for a reason unrelated to it.
            break
        }
    }

    private func scheduleBreakerWake() {
        guard !isShuttingDown else {
            return
        }
        guard let nextUntil = breakerOpenUntilByRoot.values.min() else {
            breakerWakeTask?.cancel()
            breakerWakeTask = nil
            activity.wake = nil
            return
        }
        breakerWakeTask?.cancel()
        activity.wake = OwnerWake(kind: .backoff, at: nextUntil)
        breakerWakeTask = Task { [weak self, clock, nextUntil] in
            do {
                // time: backoff — the per-root breaker after a provider stopped serving
                try await clock.sleep(until: nextUntil, tolerance: .milliseconds(250))
            } catch {
                return
            }
            await self?.handleBreakerCooldownFired()
        }
    }

    private func handleBreakerCooldownFired() {
        breakerWakeTask = nil
        // Expire any breaker whose window elapsed; keep future ones armed.
        let now = clock.now
        let expiredRoots = breakerOpenUntilByRoot.filter { $0.value <= now }.map(\.key)
        for root in expiredRoots {
            breakerOpenUntilByRoot[root] = nil
            OtosLog.mediaIO.notice(
                "op=materialization.providerBreaker phase=cooldownExpired rootPath=\(root.rawValue, privacy: .public)"
            )
        }
        scheduleBreakerWake()
        wake()
    }

    private func currentAdmissionSnapshot() -> MaterializationAdmissionPolicy.Snapshot {
        MaterializationAdmissionPolicy.Snapshot(
            count: inFlightCount,
            bytes: inFlightBytes,
            largeVideoCount: inFlightLargeVideos,
            deviceCount: inFlightDeviceCount,
            backgroundByRoot: backgroundByRoot
        )
    }

    private func recordAdmission(
        priority: Priority?,
        rejections: [MaterializationAdmissionPolicy.Rejection: Int],
        admitted: Int
    ) {
        let snapshot = AdmissionSnapshot(
            priority: priority,
            rejections: rejections,
            admitted: admitted,
            pendingInteractive: interactiveQueue.count,
            pendingCommand: commandQueue.count,
            pendingDevice: deviceQueue.count,
            pendingBackground: backgroundQueue.count,
            inFlight: inFlightCount,
            bytes: inFlightBytes,
            largeVideos: inFlightLargeVideos,
            effectiveInteractive: effectiveInteractiveCount,
            backgroundByRoot: backgroundByRoot
        )
        if admitted > 0 {
            let pendingInteractive = interactiveQueue.count
            let pendingCommand = commandQueue.count
            let pendingDevice = deviceQueue.count
            let pendingBackground = backgroundQueue.count
            let currentInFlight = inFlightCount
            let currentBytes = inFlightBytes
            OtosLog.mediaIO.notice(
                """
                op=materialization.admission phase=dispatched \
                priority=\(priority?.description ?? "none", privacy: .public) \
                admitted=\(admitted, privacy: .public) pendingInteractive=\(pendingInteractive, privacy: .public) \
                pendingCommand=\(pendingCommand, privacy: .public) pendingDevice=\(pendingDevice, privacy: .public) \
                pendingBackground=\(pendingBackground, privacy: .public) \
                inFlight=\(currentInFlight, privacy: .public) bytes=\(currentBytes, privacy: .public)
                """
            )
        }
        guard !rejections.isEmpty else {
            publishUnblockedIfNeeded()
            return
        }
        guard snapshot != lastBlockedSnapshot else {
            return
        }
        lastBlockedSnapshot = snapshot
        diagnosticSink?(snapshot)
        let pendingInteractive = interactiveQueue.count
        let pendingCommand = commandQueue.count
        let pendingDevice = deviceQueue.count
        let pendingBackground = backgroundQueue.count
        let currentInFlight = inFlightCount
        let currentBytes = inFlightBytes
        let currentInteractive = effectiveInteractiveCount
        for (reason, count) in rejections.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            OtosLog.mediaIO.notice(
                """
                op=materialization.admission phase=blocked \
                priority=\(priority?.description ?? "none", privacy: .public) \
                reason=\(reason.rawValue, privacy: .public) rejected=\(count, privacy: .public) \
                admitted=\(admitted, privacy: .public) pendingInteractive=\(pendingInteractive, privacy: .public) \
                pendingCommand=\(pendingCommand, privacy: .public) pendingDevice=\(pendingDevice, privacy: .public) \
                pendingBackground=\(pendingBackground, privacy: .public) \
                inFlight=\(currentInFlight, privacy: .public) bytes=\(currentBytes, privacy: .public) \
                effectiveInteractive=\(currentInteractive, privacy: .public)
                """
            )
        }
    }

    private func publishUnblockedIfNeeded() {
        guard lastBlockedSnapshot != nil else {
            return
        }
        lastBlockedSnapshot = nil
        diagnosticSink?(nil)
        OtosLog.mediaIO.notice("op=materialization.admission phase=unblocked")
    }

    private func wake() {
        guard !isShuttingDown else {
            return
        }
        activity.request()
        wakeContinuation.yield()
    }

    private func queue(for priority: Priority) -> [MediaAssetID] {
        switch priority {
        case .interactive: interactiveQueue
        case .command: commandQueue
        case .device: deviceQueue
        case .background: backgroundQueue
        }
    }

    private func appendToQueue(_ id: MediaAssetID, priority: Priority) {
        switch priority {
        case .interactive: interactiveQueue.append(id)
        case .command: commandQueue.append(id)
        case .device: deviceQueue.append(id)
        case .background: backgroundQueue.append(id)
        }
    }

    private func removeFromQueue(_ id: MediaAssetID, priority: Priority) {
        switch priority {
        case .interactive: interactiveQueue.removeAll { $0 == id }
        case .command: commandQueue.removeAll { $0 == id }
        case .device: deviceQueue.removeAll { $0 == id }
        case .background: backgroundQueue.removeAll { $0 == id }
        }
    }

    private func maximumPriority(
        in waiters: [UInt64: Waiter],
        fallback: Priority = .background
    ) -> Priority {
        waiters.values.map(\.priority).max() ?? fallback
    }

    private func logLifecycle(
        phase: String,
        request: Request,
        effectivePriority: Priority,
        isNotice: Bool
    ) {
        let fields = [
            "priority": request.priority.description,
            "effectivePriority": effectivePriority.description,
            "rootPath": request.id.libraryRootPath.rawValue,
            "relativePath": request.id.relativePath.rawValue,
        ]
        if isNotice {
            OtosLog.mediaIO.noticeOperation("materialization.request", phase: phase, fields: fields)
        } else {
            OtosLog.mediaIO.debugOperation("materialization.request", phase: phase, fields: fields)
        }
    }
}

private extension MaterializationCoordinator.Priority {
    nonisolated var description: String {
        switch self {
        case .interactive: "interactive"
        case .command: "command"
        case .device: "device"
        case .background: "background"
        }
    }
}

extension MaterializationResult {
    nonisolated static var cancelled: MaterializationResult {
        MaterializationResult(outcome: .cancelled, rerequestCount: 0, elapsedMs: 0)
    }
}

/// Closure adapter for focused tests: in-place files only, with an injectable status so a
/// test can stand in for a dataless placeholder. It tracks no requests of its own.
nonisolated struct ClosureMaterializationRequester: MaterializationRequesting {
    let status: @Sendable (URL) -> FileMaterializationStatus
    let operation: @Sendable (URL) async -> MaterializationResult

    init(
        status: @escaping @Sendable (URL) -> FileMaterializationStatus = FileMaterialization.status(of:),
        operation: @escaping @Sendable (URL) async -> MaterializationResult
    ) {
        self.status = status
        self.operation = operation
    }

    func materialize(_ request: MaterializationCoordinator.Request) async -> MaterializationResult {
        await operation(request.id.fileURL)
    }

    func locality(of id: MediaAssetID) async -> OriginalLocality {
        .inPlace(status(id.fileURL))
    }
}
