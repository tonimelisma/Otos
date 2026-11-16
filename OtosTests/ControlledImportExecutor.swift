import Foundation
@testable import OtosKit

/// An `ImportExecuting` a coordinator test drives: it records what ran, can hold a
/// source's execution until the test resumes it with a chosen result, and otherwise
/// completes at once, or hands off to a live executor when one is given.
actor ControlledExecutionControl {
    private var suspendNext: [LibraryRootPath: Int] = [:]
    private var pending: [LibraryRootPath: [CheckedContinuation<MediaImportExecutionResult, Never>]] = [:]
    private(set) var cancelled: Set<LibraryRootPath> = []
    private(set) var executed: [LibraryRootPath] = []
    private var progressCallbacks: [LibraryRootPath: @Sendable (MediaOperationProgress) -> Void] = [:]

    /// Delivers `progress` through the `onProgress` callback `execute()` was
    /// called with for `source`, letting a test observe how the coordinator's
    /// presentation reflects live progress mid-execution — before any
    /// terminal result — without needing a real executor.
    func sendProgress(_ progress: MediaOperationProgress, for source: LibraryRootPath) {
        progressCallbacks[source]?(progress)
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
    private let liveFallback: LiveImportExecutor?
    private var activeLive: LiveImportExecutor?

    init(control: ControlledExecutionControl, liveFallback: LiveImportExecutor? = nil) {
        self.control = control
        self.liveFallback = liveFallback
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
        if let liveFallback {
            return await liveFallback.execute(
                plan: plan,
                batch: batch,
                sourceKind: sourceKind,
                sourceDeviceIdentity: sourceDeviceIdentity,
                deleteSourceRequested: deleteSourceRequested,
                runID: runID,
                onProgress: onProgress
            )
        }
        // No fallback: synthesize a minimal completed result so ledger tests can proceed without real I/O.
        return .completed(.nothingAttempted, incompleteItems: [], erase: nil)
    }

    func cancel() async {
        // Cancellation is observed via withTaskCancellationHandler in execute.
        // Also record for tests that call cancelImport explicitly.
        // No underlying live to cancel unless we delegated.
        if let activeLive {
            await activeLive.cancel()
        }
    }
}
