import Foundation
import OSLog

/// Shared materialization request boundary used by preview and enrichment consumers.
/// `activeRequestCount(under:)` has no default: a conformer that answers 0 without
/// tracking real demand would make `EnrichmentCoordinator.drainWork` silently
/// under-report in-flight work at the eject boundary, so every conformer must
/// answer explicitly (even test doubles with nothing to track).
nonisolated protocol MaterializationRequesting: Sendable {
    func materialize(_ request: MaterializationCoordinator.Request) async -> MaterializationResult
    func activeRequestCount(under rootPath: LibraryRootPath) async -> Int
}

/// Process-lifetime owner of every deliberate provider or device materialization.
///
/// Callers only register demand. One actor-owned supervisor performs priority selection
/// and physical admission after coalesced wakes, so background producers cannot make
/// enqueue cost grow with the library. Per-ID waiters carry their own priority: joining
/// interactive demand raises an active background transfer's effective priority without
/// pretending that the provider itself can reprioritize the already-issued request.
actor MaterializationCoordinator: MaterializationRequesting {
    enum Priority: Int, Sendable, Comparable, CaseIterable {
        case background
        case device
        case interactive

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

    typealias Executor = @Sendable (URL) async -> MaterializationResult
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
    }

    private let store: CatalogStore
    private let executor: Executor
    private let policy: MaterializationAdmissionPolicy
    private let diagnosticSink: DiagnosticSink?
    private let clock = ContinuousClock()
    private let wakeStream: AsyncStream<Void>
    private let wakeContinuation: AsyncStream<Void>.Continuation

    private var pendingByID: [MediaAssetID: PendingEntry] = [:]
    private var interactiveQueue: [MediaAssetID] = []
    private var deviceQueue: [MediaAssetID] = []
    private var backgroundQueue: [MediaAssetID] = []
    private var inFlightByID: [MediaAssetID: InFlightEntry] = [:]

    private var inFlightCount = 0
    private var inFlightBytes: Int64 = 0
    private var inFlightLargeVideos = 0
    private var effectiveInteractiveCount = 0
    private var backgroundByRoot: [LibraryRootPath: Int] = [:]

    private var supervisor: Task<Void, Never>?
    private var lastBlockedSnapshot: AdmissionSnapshot?
    private var isShuttingDown = false
    private var nextWaiter: UInt64 = 0

    init(
        store: CatalogStore,
        executor: @escaping Executor,
        policy: MaterializationAdmissionPolicy = .production,
        diagnosticSink: DiagnosticSink? = nil
    ) {
        self.store = store
        self.executor = executor
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

    func shutdown() async {
        guard !isShuttingDown else {
            if let supervisor {
                await supervisor.value
            }
            return
        }
        isShuttingDown = true
        wakeContinuation.finish()

        let cancelled = MaterializationResult.cancelled
        for entry in pendingByID.values {
            entry.waiters.values.forEach { $0.continuation.resume(returning: cancelled) }
        }
        pendingByID.removeAll()
        interactiveQueue.removeAll()
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

    /// Answers "has the work `EnrichmentCoordinator` is responsible for under this
    /// root exited?", not "is any consumer of the shared coordinator active under
    /// this root": an interactive-only entry (a `PreviewImageLoader` request with no
    /// device/background waiter) must not stall an eject drain. Each `Waiter` keeps
    /// its own submission priority even after a join raises the entry's
    /// `effectivePriority`, so this checks per-waiter priority rather than the
    /// entry's (which pending-entry promotion overwrites to the max across waiters).
    func activeRequestCount(under rootPath: LibraryRootPath) -> Int {
        let pendingMatches = pendingByID.values.count {
            $0.request.id.libraryRootPath == rootPath && hasEnrichmentOriginWaiter($0.waiters)
        }
        let inFlightMatches = inFlightByID.values.count {
            $0.request.id.libraryRootPath == rootPath && hasEnrichmentOriginWaiter($0.waiters)
        }
        return pendingMatches + inFlightMatches
    }

    private func hasEnrichmentOriginWaiter(_ waiters: [UInt64: Waiter]) -> Bool {
        waiters.values.contains { $0.priority != .interactive }
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
        inFlightByID[id] = active
        wake()
    }

    private func runSupervisor() async {
        for await _ in wakeStream {
            if Task.isCancelled || isShuttingDown {
                break
            }
            schedulePass()
        }
    }

    private func schedulePass() {
        guard !isShuttingDown else {
            return
        }
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
            let deferred = deviceQueue.count + backgroundQueue.count
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
        if !deviceQueue.isEmpty {
            return .device
        }
        return backgroundQueue.isEmpty ? nil : .background
    }

    private func dispatch(_ entry: PendingEntry) {
        let request = entry.request
        let estimatedBytes = policy.estimatedBytes(request.sourceSize)
        let now = clock.now
        inFlightCount += 1
        inFlightBytes += estimatedBytes
        if policy.isLargeVideo(request) {
            inFlightLargeVideos += 1
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
        let store = store
        let task = Task { [weak self, request, executor, store] in
            guard !Task.isCancelled else {
                await self?.finishOperation(
                    request.id,
                    result: .cancelled,
                    providerFinishedAt: ContinuousClock().now
                )
                return
            }
            await store.beginKnownMaterialization(for: request.id)
            let result = await executor(request.id.fileURL)
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

    private func finishOperation(
        _ id: MediaAssetID,
        result: MaterializationResult,
        providerFinishedAt: ContinuousClock.Instant
    ) {
        guard let entry = inFlightByID.removeValue(forKey: id) else {
            return
        }
        removeAccounting(for: entry)
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

    private func currentAdmissionSnapshot() -> MaterializationAdmissionPolicy.Snapshot {
        MaterializationAdmissionPolicy.Snapshot(
            count: inFlightCount,
            bytes: inFlightBytes,
            largeVideoCount: inFlightLargeVideos,
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
            let pendingDevice = deviceQueue.count
            let pendingBackground = backgroundQueue.count
            let currentInFlight = inFlightCount
            let currentBytes = inFlightBytes
            OtosLog.mediaIO.notice(
                """
                op=materialization.admission phase=dispatched \
                priority=\(priority?.description ?? "none", privacy: .public) \
                admitted=\(admitted, privacy: .public) pendingInteractive=\(pendingInteractive, privacy: .public) \
                pendingDevice=\(pendingDevice, privacy: .public) \
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
                pendingDevice=\(pendingDevice, privacy: .public) \
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
        wakeContinuation.yield()
    }

    private func queue(for priority: Priority) -> [MediaAssetID] {
        switch priority {
        case .interactive: interactiveQueue
        case .device: deviceQueue
        case .background: backgroundQueue
        }
    }

    private func appendToQueue(_ id: MediaAssetID, priority: Priority) {
        switch priority {
        case .interactive: interactiveQueue.append(id)
        case .device: deviceQueue.append(id)
        case .background: backgroundQueue.append(id)
        }
    }

    private func removeFromQueue(_ id: MediaAssetID, priority: Priority) {
        switch priority {
        case .interactive: interactiveQueue.removeAll { $0 == id }
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
            OtosLog.mediaIO.debug(
                "op=materialization.request phase=\(phase, privacy: .public) \(otosLogFields(fields), privacy: .public)"
            )
        }
    }
}

private extension MaterializationCoordinator.Priority {
    nonisolated var description: String {
        switch self {
        case .interactive: "interactive"
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

/// Closure adapter retained for focused tests; production composition injects the shared actor.
/// It tracks no requests of its own, so it truthfully answers zero rather than inheriting a
/// default that would mask a real conformer forgetting to implement this.
nonisolated struct ClosureMaterializationRequester: MaterializationRequesting {
    let operation: @Sendable (URL) async -> MaterializationResult

    func materialize(_ request: MaterializationCoordinator.Request) async -> MaterializationResult {
        await operation(request.id.fileURL)
    }

    func activeRequestCount(under rootPath: LibraryRootPath) async -> Int {
        _ = rootPath
        return 0
    }
}
