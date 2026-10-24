import Foundation

/// The real substitution boundary between lifecycle ownership and filesystem
/// execution. The coordinator owns lifecycle;
/// the executor owns copy/journal mechanics. The live executor delegates to
/// `MediaImportExecutor`; the tests' controlled executor (`OtosTests`) can suspend a
/// selected source's execution until the test resumes it with a controlled terminal
/// result — reproducing the cancellation-insensitive boundary needed for adversarial
/// coordinator tests without adding test-only branches to production behavior.
nonisolated protocol ImportExecuting: Sendable {
    func execute(
        plan: MediaOperationPlan,
        batch: ImportBatchID,
        sourceKind: LibraryRootKind,
        sourceDeviceIdentity: DeviceIdentity?,
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
        sourceDeviceIdentity: DeviceIdentity?,
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
