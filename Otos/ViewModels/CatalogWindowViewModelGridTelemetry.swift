import Foundation
import OSLog

/// Grid telemetry recording guide
///
/// `GridTelemetry` counters are process-local rendering facts, not catalog truth.
/// The ViewModel owns when those counters become durable JSONL: a startup marker,
/// one early interval for quick smoke runs, coarse later intervals, and a bounded
/// app-termination flush. Termination recording captures only scalar snapshots and
/// waits on the diagnostics actor from a detached task so the MainActor is not part
/// of the awaited write.
extension CatalogWindowViewModel {
    func recordGridTelemetryForTermination(timeout: TimeInterval = 2) {
        guard !didRecordTerminationGridTelemetry else {
            return
        }
        didRecordTerminationGridTelemetry = true
        gridTelemetryTask?.cancel()

        let diagnostics = diagnostics
        let finalCounters = GridTelemetry.snapshot()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .utility) { [diagnostics, finalCounters] in
            await Self.recordGridTelemetrySnapshot(
                diagnostics: diagnostics,
                phase: "willTerminate",
                delta: GridTelemetrySnapshot(),
                total: finalCounters
            )
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            OtosLog.performance.error("Timed out recording grid telemetry before termination")
        }
    }

    func startGridTelemetryRecording(diagnostics: CatalogDiagnostics?) {
        let initialSnapshot = GridTelemetry.snapshot()
        gridTelemetryTask = Task.detached(priority: .utility) { [diagnostics] in
            var previousSnapshot = initialSnapshot
            await Self.recordGridTelemetrySnapshot(
                diagnostics: diagnostics,
                phase: "start",
                delta: GridTelemetrySnapshot(),
                total: previousSnapshot
            )
            var sleepDuration: Duration = .seconds(15)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: sleepDuration)
                } catch {
                    break
                }
                let currentSnapshot = GridTelemetry.snapshot()
                await Self.recordGridTelemetrySnapshot(
                    diagnostics: diagnostics,
                    phase: "interval",
                    delta: currentSnapshot.delta(since: previousSnapshot),
                    total: currentSnapshot
                )
                previousSnapshot = currentSnapshot
                sleepDuration = .seconds(60)
            }
        }
    }

    private nonisolated static func recordGridTelemetrySnapshot(
        diagnostics: CatalogDiagnostics?,
        phase: String,
        delta: GridTelemetrySnapshot,
        total: GridTelemetrySnapshot
    ) async {
        var fields = delta.diagnosticFields()
        fields.merge(total.diagnosticFields(prefix: "total")) { _, new in new }
        await diagnostics?.record(
            operation: "ui.grid.counters",
            phase: phase,
            fields: fields
        )
    }
}
