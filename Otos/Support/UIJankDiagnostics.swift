import AppKit
import Foundation
import OSLog

/// UI jank diagnostics guide
///
/// The monitor samples the active app's main run loop in debug builds. The
/// ViewModel supplies only the latest scalar grid handoff, so a delayed timer can
/// be correlated with catalog work without retaining a `CatalogWindowState` or
/// its asset dictionary. Frequent state and collection activity is measured with
/// Logger/signposts; JSONL is written only when an actual active-app stall is
/// detected.
nonisolated struct CatalogGridHandoff: Equatable {
    let updateID: Int
    let itemCount: Int
    let previousItemCount: Int
    let itemDelta: Int
    let selection: String
    let emptyState: String
    let timestamp: Date
}

nonisolated struct MainRunLoopOperationToken: Equatable {
    fileprivate let id: Int
}

@MainActor
final class MainRunLoopStallMonitor {
    private struct OperationRecord {
        let id: Int
        let name: String
        let startedAt: Date
    }

    private struct CompletedOperationRecord {
        let name: String
        let durationMs: Int
        let finishedAt: Date
    }

    private var timer: Timer?
    private var expectedFireDate: Date?
    private var diagnostics: CatalogDiagnostics?
    private var nextUpdateID = 0
    private var nextOperationID = 0
    private var latestHandoff: CatalogGridHandoff?
    private var operationStack: [OperationRecord] = []
    private var lastLongOperation: CompletedOperationRecord?
    private let interval: TimeInterval = 0.1
    private let stallThreshold: TimeInterval = 0.1
    private let longOperationThresholdMs = 100

    isolated deinit {
        timer?.invalidate()
    }

    func reserveUpdateID() -> Int {
        nextUpdateID += 1
        return nextUpdateID
    }

    func recordGridHandoff(_ handoff: CatalogGridHandoff) {
        latestHandoff = handoff
    }

    func beginOperation(_ name: String, now: Date = Date()) -> MainRunLoopOperationToken {
        nextOperationID += 1
        let record = OperationRecord(id: nextOperationID, name: name, startedAt: now)
        operationStack.append(record)
        return MainRunLoopOperationToken(id: record.id)
    }

    func endOperation(_ token: MainRunLoopOperationToken, now: Date = Date()) {
        guard let index = operationStack.lastIndex(where: { $0.id == token.id }) else {
            return
        }
        let record = operationStack.remove(at: index)
        let durationMs = DiagnosticsTiming.milliseconds(from: record.startedAt, to: now)
        guard durationMs >= longOperationThresholdMs else {
            return
        }
        lastLongOperation = CompletedOperationRecord(
            name: record.name,
            durationMs: durationMs,
            finishedAt: now
        )
    }

    func start(diagnostics: CatalogDiagnostics? = .shared) {
        #if DEBUG
            guard timer == nil else {
                return
            }

            self.diagnostics = diagnostics
            expectedFireDate = Date().addingTimeInterval(interval)
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.tick()
                }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
            OtosLog.performance.debug("Main run loop stall monitor started")
        #else
            _ = diagnostics
        #endif
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        expectedFireDate = nil
        diagnostics = nil
        latestHandoff = nil
        operationStack.removeAll()
        lastLongOperation = nil
    }

    private func tick(now: Date = Date()) {
        guard let expectedFireDate = activeExpectedFireDate(now: now) else {
            return
        }

        let lateness = now.timeIntervalSince(expectedFireDate)
        self.expectedFireDate = now.addingTimeInterval(interval)
        guard lateness >= stallThreshold else {
            return
        }

        let stallMs = max(0, Int((lateness * 1000).rounded()))
        recordStall(stallMs: stallMs, now: now)
    }

    private func activeExpectedFireDate(now: Date) -> Date? {
        // Inactive apps are eligible for timer coalescing and App Nap. A late
        // main-run-loop timer in that state is not evidence of user-visible
        // jank, so reset the baseline until the app is active again.
        guard NSApplication.shared.isActive else {
            expectedFireDate = now.addingTimeInterval(interval)
            return nil
        }

        guard let expectedFireDate else {
            expectedFireDate = now.addingTimeInterval(interval)
            return nil
        }
        return expectedFireDate
    }

    private func recordStall(stallMs: Int, now: Date) {
        let latestHandoff = latestHandoff
        let currentOperation = operationStack.last
        let lastLongOperation = lastLongOperation
        OtosLog.performance.error(
            """
            Main run loop stall detected ms=\(stallMs, privacy: .public) \
            latestUpdateID=\(latestHandoff?.updateID ?? 0, privacy: .public) \
            latestItems=\(latestHandoff?.itemCount ?? 0, privacy: .public) \
            currentOperation=\(currentOperation?.name ?? "none", privacy: .public) \
            lastLongOperation=\(lastLongOperation?.name ?? "none", privacy: .public)
            """
        )

        let fields = stallFields(
            stallMs: stallMs,
            now: now,
            latestHandoff: latestHandoff,
            currentOperation: currentOperation,
            lastLongOperation: lastLongOperation
        )
        recordStallDiagnostic(fields)
    }

    private func stallFields(
        stallMs: Int,
        now: Date,
        latestHandoff: CatalogGridHandoff?,
        currentOperation: OperationRecord?,
        lastLongOperation: CompletedOperationRecord?
    ) -> [String: String] {
        var fields = [
            "stallMs": "\(stallMs)",
            "thresholdMs": "\(Int((stallThreshold * 1000).rounded()))",
            "intervalMs": "\(Int((interval * 1000).rounded()))",
        ]
        if let latestHandoff {
            fields["latestUpdateID"] = "\(latestHandoff.updateID)"
            fields["latestItems"] = "\(latestHandoff.itemCount)"
            fields["latestPreviousItems"] = "\(latestHandoff.previousItemCount)"
            fields["latestItemDelta"] = "\(latestHandoff.itemDelta)"
            fields["latestSelection"] = latestHandoff.selection
            fields["latestEmptyState"] = latestHandoff.emptyState
            fields["latestHandoffAgeMs"] = "\(DiagnosticsTiming.milliseconds(since: latestHandoff.timestamp, now: now))"
        }
        if let currentOperation {
            let ageMs = DiagnosticsTiming.milliseconds(since: currentOperation.startedAt, now: now)
            fields["currentOperation"] = currentOperation.name
            fields["currentOperationAgeMs"] = "\(ageMs)"
        }
        if let lastLongOperation {
            let ageMs = DiagnosticsTiming.milliseconds(since: lastLongOperation.finishedAt, now: now)
            fields["lastLongOperation"] = lastLongOperation.name
            fields["lastLongOperationMs"] = "\(lastLongOperation.durationMs)"
            fields["lastLongOperationAgeMs"] = "\(ageMs)"
        }
        return fields
    }

    private func recordStallDiagnostic(_ fields: [String: String]) {
        let diagnostics = diagnostics
        // Stalls are rare boundary events rather than the high-frequency UI path. Capture
        // only the completed scalar payload so this best-effort diagnostic task
        // cannot retain catalog state while waiting for the JSONL actor.
        Task {
            await diagnostics?.record(
                operation: "ui.mainRunLoop.stall",
                phase: "detected",
                fields: fields
            )
        }
    }
}
