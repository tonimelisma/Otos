import Foundation

/// The real substitution boundary between lifecycle ownership and filesystem
/// execution. The coordinator owns lifecycle;
/// the executor owns copy/journal mechanics. The live executor delegates to
/// `MediaImportExecutor`; the controlled test executor can suspend a selected
/// source's execution until the test resumes it with a controlled terminal
/// result — reproducing the cancellation-insensitive boundary needed for
/// adversarial coordinator tests without adding test-only branches to production
/// behavior.
nonisolated protocol ImportExecuting: Sendable {
    func execute(
        plan: MediaOperationPlan,
        batch: ImportBatchID,
        sourceKind: LibraryRootKind,
        sourceDeviceIdentity: String?,
        deleteSourceRequested: Bool,
        runID: String,
        onProgress: @Sendable @escaping (MediaOperationProgress) -> Void
    ) async -> MediaImportExecutionResult
    func cancel() async
}

// MARK: - Live

actor LiveImportExecutor: ImportExecuting {
    private let store: CatalogStore
    private let cameraImport: CameraImportAccess?
    private let materializationRequester: MaterializationRequesting?
    /// Forwarded to every `MediaImportExecutor` this creates — the floor's
    /// capacity reader (ADR 0027), substitutable so a coordinator-level test
    /// can drive a real copy into a volume that "runs out".
    private let volumeCapacity: @Sendable (URL) -> Int64?
    private var activeExecutor: MediaImportExecutor?

    init(
        store: CatalogStore,
        cameraImport: CameraImportAccess? = nil,
        materializationRequester: MaterializationRequesting? = nil,
        volumeCapacity: @escaping @Sendable (URL) -> Int64? = MediaImportExecutor.importantUsageCapacity
    ) {
        self.store = store
        self.cameraImport = cameraImport
        self.materializationRequester = materializationRequester
        self.volumeCapacity = volumeCapacity
    }

    func execute(
        plan: MediaOperationPlan,
        batch: ImportBatchID,
        sourceKind: LibraryRootKind,
        sourceDeviceIdentity: String?,
        deleteSourceRequested: Bool,
        runID: String,
        onProgress: @Sendable @escaping (MediaOperationProgress) -> Void
    ) async -> MediaImportExecutionResult {
        let executor = MediaImportExecutor(
            store: store,
            cameraImport: cameraImport,
            materializationRequester: materializationRequester,
            volumeCapacity: volumeCapacity
        )
        activeExecutor = executor
        defer { activeExecutor = nil }
        return await executor.execute(
            plan: plan,
            batch: batch,
            sourceKind: sourceKind,
            sourceDeviceIdentity: sourceDeviceIdentity,
            deleteSourceRequested: deleteSourceRequested,
            runID: runID,
            onProgress: onProgress
        )
    }

    func cancel() async {
        await activeExecutor?.cancel()
    }
}

// MARK: - Controlled (test)

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
        cont.resume(returning: .stopped(
            reason: .user,
            publishedCount: 0,
            hasBlockedEntries: false,
            hasEntryFailures: false,
            skippedForeignCount: 0,
            failedCount: 0
        ))
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
        sourceDeviceIdentity: String?,
        deleteSourceRequested: Bool,
        runID: String,
        onProgress: @Sendable @escaping (MediaOperationProgress) -> Void
    ) async -> MediaImportExecutionResult {
        guard case let .import(source, _, _) = plan.mode else {
            return .failed(reason: .unexpected(detail: "notAnImportPlan"))
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
        return .completed(
            publishedCount: 0,
            hasBlockedEntries: false,
            hasEntryFailures: false,
            skippedForeignCount: 0,
            failedCount: 0,
            incompleteItems: []
        )
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
