import Foundation
@testable import OtosKit

/// An `ImportExecuting` a coordinator test drives: it records what ran, can hold a
/// source's execution until the test resumes it with a chosen result, and otherwise
/// completes at once, or hands off to a live executor when one is given. With a live
/// executor it can also hold the run at its start, before the live executor's `execute`
/// begins, so a test delivers an event at that suspension.
actor ControlledExecutionControl {
    private var suspendNext: [LibraryRootPath: Int] = [:]
    private var holdNextStart: Set<LibraryRootPath> = []
    private var heldStarts: [LibraryRootPath: CheckedContinuation<Void, Never>] = [:]
    private var pending: [LibraryRootPath: [CheckedContinuation<MediaImportExecutionResult, Never>]] = [:]
    private(set) var cancelled: Set<LibraryRootPath> = []
    private(set) var executed: [LibraryRootPath] = []
    private var progressCallbacks: [LibraryRootPath: @Sendable (MediaOperationProgress) -> Void] = [:]
    /// Every result a live executor returned, in order: the run's own report that it ended,
    /// which a test waits on instead of sampling a presentation that a later re-plan replaces.
    nonisolated let liveResults = AsyncValueRecorder<MediaImportExecutionResult>()

    /// Delivers `progress` through the `onProgress` callback `execute()` was
    /// called with for `source`, letting a test observe how the coordinator's
    /// presentation reflects live progress mid-execution — before any
    /// terminal result — without needing a real executor.
    func sendProgress(_ progress: MediaOperationProgress, for source: LibraryRootPath) {
        progressCallbacks[source]?(progress)
    }

    /// The next run for `source` waits at its start, before the live executor's `execute`
    /// begins, until `releaseStart(for:)`.
    func holdStartOfNextExecution(for source: LibraryRootPath) {
        holdNextStart.insert(source)
    }

    func heldStartSources() -> Set<LibraryRootPath> {
        Set(heldStarts.keys)
    }

    func releaseStart(for source: LibraryRootPath) {
        heldStarts.removeValue(forKey: source)?.resume()
    }

    fileprivate func waitAtStartIfHeld(for source: LibraryRootPath) async {
        guard holdNextStart.remove(source) != nil else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            heldStarts[source] = continuation
        }
    }

    func suspendNextExecution(for source: LibraryRootPath) {
        suspendNext[source, default: 0] += 1
    }

    func pendingSources() -> [LibraryRootPath] {
        pending.filter { !$0.value.isEmpty }.map(\.key)
    }

    func pendingCount(for source: LibraryRootPath) -> Int {
        pending[source]?.count ?? 0
    }

    func recordedCancelled() -> Set<LibraryRootPath> {
        cancelled
    }

    func recordedExecuted() -> [LibraryRootPath] {
        executed
    }

    func resumePending(for source: LibraryRootPath, with result: MediaImportExecutionResult) {
        guard var queue = pending[source], !queue.isEmpty else { return }
        let cont = queue.removeFirst()
        if queue.isEmpty {
            pending.removeValue(forKey: source)
        } else {
            pending[source] = queue
        }
        cont.resume(returning: result)
    }

    func resumeAllPending(with result: MediaImportExecutionResult) {
        let keys = Array(pending.keys)
        for key in keys {
            while let queued = pending[key], !queued.isEmpty {
                resumePending(for: key, with: result)
            }
        }
    }

    fileprivate func shouldSuspend(for source: LibraryRootPath) -> Bool {
        (suspendNext[source] ?? 0) > 0
    }

    fileprivate func takeSuspend(for source: LibraryRootPath) -> Bool {
        guard let count = suspendNext[source], count > 0 else { return false }
        if count == 1 {
            suspendNext.removeValue(forKey: source)
        } else {
            suspendNext[source] = count - 1
        }
        return true
    }

    private func registerPending(
        for source: LibraryRootPath,
        continuation: CheckedContinuation<MediaImportExecutionResult, Never>
    ) {
        var queue = pending[source] ?? []
        queue.append(continuation)
        pending[source] = queue
    }

    private func recordCancel(for source: LibraryRootPath) {
        cancelled.insert(source)
    }

    fileprivate func recordExecuted(for source: LibraryRootPath) {
        executed.append(source)
    }

    fileprivate func registerProgressCallback(
        for source: LibraryRootPath,
        _ callback: @escaping @Sendable (MediaOperationProgress) -> Void
    ) {
        progressCallbacks[source] = callback
    }

    private func resumeOnePendingWithCancellation(for source: LibraryRootPath) {
        guard var queue = pending[source], !queue.isEmpty else { return }
        let cont = queue.removeFirst()
        if queue.isEmpty {
            pending.removeValue(forKey: source)
        } else {
            pending[source] = queue
        }
        cont.resume(returning: .stopped(.user, .nothingAttempted))
    }

    /// Suspend the caller's task until `resumePending` is called or cancellation
    /// resumes with a dummy cancelled result. This keeps the suspension and its
    /// bookkeeping on the same actor, avoiding the cross-actor Task race where
    /// `withCheckedContinuation`'s synchronous closure cannot `await` a different
    /// actor's `registerPending`.
    func suspendAndWait(for source: LibraryRootPath) async -> MediaImportExecutionResult {
        await withTaskCancellationHandler(
            operation: {
                await withCheckedContinuation { (continuation: CheckedContinuation<
                    MediaImportExecutionResult,
                    Never
                >) in
                    var queue = pending[source] ?? []
                    queue.append(continuation)
                    pending[source] = queue
                }
            },
            onCancel: {
                Task {
                    await self.recordCancel(for: source)
                    await self.resumeOnePendingWithCancellation(for: source)
                }
            }
        )
    }
}

actor ControlledImportExecutor: ImportExecuting {
    private let control: ControlledExecutionControl
    private let live: MediaImportExecutor?

    init(control: ControlledExecutionControl, live: MediaImportExecutor? = nil) {
        self.control = control
        self.live = live
    }

    func execute(
        plan: MediaOperationPlan,
        batch: ImportBatchID,
        sourceKind: LibraryRootKind,
        sourceDeviceIdentity: DeviceIdentity?,
        deleteSourceRequested: Bool,
        runID: String,
        onProgress: @Sendable @escaping (MediaOperationProgress) -> Void
    ) async -> MediaImportExecutionResult {
        guard case let .import(source, _) = plan.mode else {
            return .failed(.unexpected(detail: "notAnImportPlan"), publishedCount: 0)
        }
        await control.recordExecuted(for: source)
        await control.registerProgressCallback(for: source, onProgress)
        let shouldSuspend = await control.takeSuspend(for: source)
        if shouldSuspend {
            return await control.suspendAndWait(for: source)
        }
        if let live {
            await control.waitAtStartIfHeld(for: source)
            let result = await live.execute(
                plan: plan,
                batch: batch,
                sourceKind: sourceKind,
                sourceDeviceIdentity: sourceDeviceIdentity,
                deleteSourceRequested: deleteSourceRequested,
                runID: runID,
                onProgress: onProgress
            )
            await control.liveResults.append(result)
            return result
        }
        // No live executor: synthesize a minimal completed result so ledger tests can proceed without real I/O.
        return .completed(.nothingAttempted, incompleteItems: [], erase: nil)
    }

    /// Forwards to the live executor. A held run with no live executor observes cancellation
    /// only as its task's (`suspendAndWait`).
    nonisolated func cancel() {
        live?.cancel()
    }
}
