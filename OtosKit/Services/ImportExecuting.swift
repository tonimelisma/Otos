import Foundation

/// The substitution boundary between lifecycle ownership and filesystem execution. The
/// coordinator owns lifecycle; the executor owns one run's copy and journal mechanics.
/// `MediaImportExecutor` is the live one; the tests' controlled executor (`OtosTests`) can
/// hold a source's run until the test resumes it with a chosen result, which reproduces the
/// interleavings an adversarial coordinator test needs without test-only branches in
/// production behavior.
///
/// An executor is made for one run (`MediaOperationCoordinator.startExecution`) and held by
/// the coordinator from that synchronous step on, before the run awaits anything. So a
/// `cancel()` always reaches the executor that will run, whenever it comes: before
/// `execute` has begun, it makes that run end stopped by the user without copying a byte.
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
    /// Asks the run to stop. Synchronous, so the cancel is recorded in the same step as the
    /// session transition that asked for it; it is never undone, and an `execute` that begins
    /// after it stops at once.
    func cancel()
}
