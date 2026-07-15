import Foundation
import OSLog

/// Shared materialization request boundary used by preview and enrichment consumers.
nonisolated protocol MaterializationRequesting: Sendable {
    func materialize(_ request: MaterializationCoordinator.Request) async -> MaterializationResult
}

/// Process-lifetime owner of every deliberate materialization request.
///
/// The coordinator owns priority, physical-transfer coalescing, admission, Store event
/// suppression, and task lifetime. `FileMaterialization` remains the mechanism for one
/// URL; preview and enrichment remain consumers that decide why bytes are needed.
actor MaterializationCoordinator: MaterializationRequesting {
    enum Priority: Int, Sendable, Comparable {
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
        let priority: Priority
        let rejections: [MaterializationAdmissionPolicy.Rejection: Int]
        let admitted: Int
        let pendingInteractive: Int
        let pendingDevice: Int
        let pendingBackground: Int
        let inFlight: Int
        let bytes: Int64

        static func == (lhs: AdmissionSnapshot, rhs: AdmissionSnapshot) -> Bool {
            lhs.priority == rhs.priority
                && Set(lhs.rejections.keys) == Set(rhs.rejections.keys)
                && lhs.inFlight == rhs.inFlight
                && lhs.bytes == rhs.bytes
        }
    }

    typealias Executor = @Sendable (URL) async -> MaterializationResult
    typealias DiagnosticSink = @Sendable (AdmissionSnapshot?) -> Void

    private struct Pending {
        var request: Request
        var waiters: [UInt64: CheckedContinuation<MaterializationResult, Never>]
    }

    private struct InFlight {
        let request: Request
        let estimatedBytes: Int64
        var waiters: [UInt64: CheckedContinuation<MaterializationResult, Never>]
        var task: Task<Void, Never>?
    }

    private let store: CatalogStore
    private let executor: Executor
    private let policy: MaterializationAdmissionPolicy
    private let diagnosticSink: DiagnosticSink?
    private var pending: [Pending] = []
    private var inFlight: [MediaAssetID: InFlight] = [:]
    private var lastBlockedSnapshot: AdmissionSnapshot?
    private var isShuttingDown = false
    private var nextWaiter = 0 as UInt64

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
    }

    func materialize(_ request: Request) async -> MaterializationResult {
        guard !isShuttingDown else {
            return .cancelled
        }
        nextWaiter &+= 1
        let waiter = nextWaiter
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                } else {
                    enqueue(request, waiter: waiter, continuation: continuation)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiter, for: request.id) }
        }
    }

    func shutdown() async {
        guard !isShuttingDown else {
            return
        }
        isShuttingDown = true
        let cancelled = MaterializationResult.cancelled
        for entry in pending {
            entry.waiters.values.forEach { $0.resume(returning: cancelled) }
        }
        pending.removeAll()
        let active = inFlight.values
        inFlight.removeAll()
        for entry in active {
            entry.task?.cancel()
            entry.waiters.values.forEach { $0.resume(returning: cancelled) }
        }
        publishUnblockedIfNeeded()
    }

    /// Internal observation seam for deterministic scheduler tests.
    func queuedRequestCount() -> Int {
        pending.count
    }

    private func enqueue(
        _ request: Request,
        waiter: UInt64,
        continuation: CheckedContinuation<MaterializationResult, Never>
    ) {
        if var active = inFlight.removeValue(forKey: request.id) {
            active.waiters[waiter] = continuation
            inFlight[request.id] = active
            let path = request.id.relativePath.rawValue
            let priority = request.priority.description
            OtosLog.mediaIO.notice(
                "op=materialization.request phase=joinedInFlight priority=\(priority, privacy: .public) relativePath=\(path, privacy: .public)"
            )
            return
        }
        if let index = pending.firstIndex(where: { $0.request.id == request.id }) {
            pending[index].waiters[waiter] = continuation
            if pending[index].request.priority < request.priority {
                pending[index].request = request
                let path = request.id.relativePath.rawValue
                let priority = request.priority.description
                OtosLog.mediaIO.notice(
                    "op=materialization.request phase=promoted priority=\(priority, privacy: .public) relativePath=\(path, privacy: .public)"
                )
            }
        } else {
            pending.append(Pending(request: request, waiters: [waiter: continuation]))
            let path = request.id.relativePath.rawValue
            let priority = request.priority.description
            OtosLog.mediaIO.notice(
                "op=materialization.request phase=queued priority=\(priority, privacy: .public) relativePath=\(path, privacy: .public)"
            )
        }
        schedule()
    }

    private func cancelWaiter(_ waiter: UInt64, for id: MediaAssetID) {
        if let index = pending.firstIndex(where: { $0.request.id == id }),
           let continuation = pending[index].waiters.removeValue(forKey: waiter)
        {
            continuation.resume(returning: .cancelled)
            if pending[index].waiters.isEmpty {
                pending.remove(at: index)
                OtosLog.mediaIO.notice(
                    "op=materialization.request phase=cancelled relativePath=\(id.relativePath.rawValue, privacy: .public)"
                )
            }
            schedule()
            return
        }
        if var active = inFlight.removeValue(forKey: id) {
            if let continuation = active.waiters.removeValue(forKey: waiter) {
                continuation.resume(returning: .cancelled)
            }
            inFlight[id] = active
        }
    }

    private func schedule() {
        guard !isShuttingDown else {
            return
        }
        var admitted = 0
        var rejections: [MaterializationAdmissionPolicy.Rejection: Int] = [:]
        let hasInteractiveInFlight = inFlight.values.contains {
            $0.request.priority == .interactive
        }
        let highestPending = hasInteractiveInFlight
            ? Priority.interactive
            : pending.map(\.request.priority).max()
        var index = 0
        while index < pending.count {
            let entry = pending[index]
            if let highestPending, entry.request.priority != highestPending {
                if highestPending == .interactive {
                    rejections[.interactivePriority, default: 0] += 1
                }
                index += 1
                continue
            }
            let snapshot = currentSnapshot()
            if let rejection = policy.rejection(for: entry.request, inFlight: snapshot) {
                rejections[rejection, default: 0] += 1
                index += 1
                continue
            }
            pending.remove(at: index)
            dispatch(entry)
            admitted += 1
        }
        recordAdmission(priority: highestPending, rejections: rejections, admitted: admitted)
    }

    private func dispatch(_ entry: Pending) {
        let request = entry.request
        let estimatedBytes = policy.estimatedBytes(request.sourceSize)
        let executor = executor
        let store = store
        inFlight[request.id] = InFlight(
            request: request,
            estimatedBytes: estimatedBytes,
            waiters: entry.waiters,
            task: nil
        )
        let task = Task { [weak self, request, executor, store] in
            await store.beginKnownMaterialization(for: request.id)
            let result = await executor(request.id.fileURL)
            await store.endKnownMaterialization(for: request.id, success: result.isMaterialized)
            await self?.finish(request.id, result: result)
        }
        inFlight[request.id]?.task = task
        let path = request.id.relativePath.rawValue
        let priority = request.priority.description
        let inFlightCount = inFlight.count
        OtosLog.mediaIO.notice(
            """
            op=materialization.request phase=dispatched priority=\(priority, privacy: .public) \
            relativePath=\(path, privacy: .public) inFlight=\(inFlightCount, privacy: .public)
            """
        )
    }

    private func finish(_ id: MediaAssetID, result: MaterializationResult) {
        guard let entry = inFlight.removeValue(forKey: id) else {
            return
        }
        entry.waiters.values.forEach { $0.resume(returning: result) }
        let path = id.relativePath.rawValue
        let priority = entry.request.priority.description
        let outcome = result.outcome.diagnosticDescription
        OtosLog.mediaIO.notice(
            """
            op=materialization.request phase=completed priority=\(priority, privacy: .public) \
            relativePath=\(path, privacy: .public) outcome=\(outcome, privacy: .public) \
            elapsedMs=\(result.elapsedMs, privacy: .public) rerequestCount=\(result.rerequestCount, privacy: .public)
            """
        )
        schedule()
    }

    private func currentSnapshot() -> MaterializationAdmissionPolicy.Snapshot {
        var snapshot = MaterializationAdmissionPolicy.Snapshot.empty
        snapshot.count = inFlight.count
        for entry in inFlight.values {
            snapshot.bytes += entry.estimatedBytes
            if policy.isLargeVideo(entry.request) {
                snapshot.largeVideoCount += 1
            }
            if entry.request.priority == .background {
                snapshot.backgroundByRoot[entry.request.id.libraryRootPath, default: 0] += 1
            }
        }
        return snapshot
    }

    private func recordAdmission(
        priority: Priority?,
        rejections: [MaterializationAdmissionPolicy.Rejection: Int],
        admitted: Int
    ) {
        guard let priority, !rejections.isEmpty else {
            publishUnblockedIfNeeded()
            return
        }
        let counts = pendingCounts()
        let state = currentSnapshot()
        let snapshot = AdmissionSnapshot(
            priority: priority,
            rejections: rejections,
            admitted: admitted,
            pendingInteractive: counts.interactive,
            pendingDevice: counts.device,
            pendingBackground: counts.background,
            inFlight: state.count,
            bytes: state.bytes
        )
        guard snapshot != lastBlockedSnapshot else {
            return
        }
        lastBlockedSnapshot = snapshot
        diagnosticSink?(snapshot)
        for (reason, count) in rejections.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            OtosLog.mediaIO.notice(
                """
                op=materialization.admission phase=blocked priority=\(priority.description, privacy: .public) \
                reason=\(reason.rawValue, privacy: .public) rejected=\(count, privacy: .public) \
                admitted=\(admitted, privacy: .public) pendingInteractive=\(counts.interactive, privacy: .public) \
                pendingDevice=\(counts.device, privacy: .public) pendingBackground=\(counts.background, privacy: .public) \
                inFlight=\(state.count, privacy: .public) bytes=\(state.bytes, privacy: .public)
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

    private func pendingCounts() -> (interactive: Int, device: Int, background: Int) {
        (
            pending.count(where: { $0.request.priority == .interactive }),
            pending.count(where: { $0.request.priority == .device }),
            pending.count(where: { $0.request.priority == .background })
        )
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
nonisolated struct ClosureMaterializationRequester: MaterializationRequesting {
    let operation: @Sendable (URL) async -> MaterializationResult

    func materialize(_ request: MaterializationCoordinator.Request) async -> MaterializationResult {
        await operation(request.id.fileURL)
    }
}
