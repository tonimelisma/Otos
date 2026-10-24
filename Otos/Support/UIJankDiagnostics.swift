import AppKit
import Foundation
import OSLog

/// UI jank diagnostics guide
///
/// The monitor samples the active app's main run loop in debug builds. The
/// ViewModel supplies only the latest scalar grid handoff, so a delayed timer can
/// be correlated with catalog work without retaining a `CatalogWindowState` or
/// its asset dictionary. Frequent state and collection activity uses OSLog
/// (`op=`/`key=value`) for the agent and interval signposts for Instruments; a
/// main-thread stall emits one structured `.fault op=mainThreadStall` line.
///
/// Attribution: this monitor *flags* a stall with the state around it
/// (bracketedOp, currentOperation, lastLongOperation). Naming the code that
/// stalled is `script/profile.sh` with Time Profiler — the repo's documented
/// division of labour. A bracketedOp field states a fact (no bracketed
/// operation was in flight or recently completed) rather than implying a cause,
/// and a stall without a bracket is not a finding of "nothing was running."
nonisolated struct CatalogGridHandoff: Equatable {
    let updateID: Int
    let itemCount: Int
    let previousItemCount: Int
    let itemDelta: Int
    let selection: String
    let emptyState: String
    let mediaIdentityChanged: Bool
    let detailRefreshGeneration: UInt64
    let timestamp: ContinuousClock.Instant
}

nonisolated struct MainRunLoopOperationToken: Equatable {
    fileprivate let id: Int
}

@MainActor
final class MainRunLoopStallMonitor {
    private struct OperationRecord {
        let id: Int
        let name: String
        let startedAt: ContinuousClock.Instant
    }

    private struct CompletedOperationRecord {
        let name: String
        let durationMs: Int
        let finishedAt: ContinuousClock.Instant
    }

    /// One in-flight sidebar/filter/sort intent awaiting the structural apply that
    /// renders it. Begins in `CatalogWindowViewModel.setQueryDescriptor` when the
    /// scope changes and completes in the grid controller's `completeStructuralApply`
    /// for the same scope, so click→paint latency is measurable end to end.
    /// A newer intent abandons a pending one — its interval is closed and logged
    /// as abandoned, so a navigation the user moved on from never reads as one
    /// that hung. A pending that never reaches an apply of its scope and is never
    /// superseded holds at most one interval open.
    private struct PendingIntentToPaint {
        let signpost: OSSignpostIntervalState
        let scope: SidebarSelection
        let startedAt: ContinuousClock.Instant
    }

    private var timer: Timer?
    private var expectedFire: ContinuousClock.Instant?
    private var nextUpdateID = 0
    private var nextOperationID = 0
    private var latestHandoff: CatalogGridHandoff?
    private var operationStack: [OperationRecord] = []
    private var lastLongOperation: CompletedOperationRecord?
    private var pendingIntentToPaint: PendingIntentToPaint?
    /// Optional MainActor-safe extra fields (e.g. mutation-gate exclusivity) sampled at stall time.
    var additionalStallFields: (() -> [String: String])?
    // time: measurement — the sampling period of the stall monitor
    private let interval = Duration.milliseconds(100)
    private let stallThreshold = Duration.milliseconds(100)
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

    /// Starts the click→paint interval for a sidebar/scope intent. Called from the
    /// single query-descriptor writer when the scope changes on a user intent.
    /// Returns whether a still-pending intent was abandoned to make room.
    @discardableResult
    func beginIntentToPaint(scope: SidebarSelection) -> Bool {
        let abandoned = pendingIntentToPaint != nil
        if let pending = pendingIntentToPaint {
            pendingIntentToPaint = nil
            OtosSignpost.ui.endInterval("SidebarSelectionToPaint", pending.signpost)
            OtosLog.ui.noticeOperation(
                "ui.sidebarSelectionToPaint",
                phase: "abandoned",
                fields: [
                    "scope": pending.scope.diagnosticDescription,
                    "supersededBy": scope.diagnosticDescription,
                    "ms": "\(DiagnosticsTiming.milliseconds(since: pending.startedAt))",
                ]
            )
        }
        pendingIntentToPaint = PendingIntentToPaint(
            signpost: OtosSignpost.ui.beginInterval("SidebarSelectionToPaint"),
            scope: scope,
            startedAt: .now
        )
        OtosLog.ui.noticeOperation(
            "ui.sidebarSelectionToPaint",
            phase: "start",
            fields: ["scope": scope.diagnosticDescription]
        )
        return abandoned
    }

    /// Ends the click→paint interval when a structural apply renders the intent's
    /// scope. Returns whether a pending measurement was completed; a non-matching
    /// scope (an unrelated enrichment/scroll apply) leaves the pending interval
    /// untouched.
    @discardableResult
    func completeIntentToPaint(appliedScope: SidebarSelection) -> Bool {
        guard let pending = pendingIntentToPaint, pending.scope == appliedScope else {
            return false
        }
        pendingIntentToPaint = nil
        OtosSignpost.ui.endInterval("SidebarSelectionToPaint", pending.signpost)
        let ms = DiagnosticsTiming.milliseconds(since: pending.startedAt)
        OtosLog.ui.noticeOperation(
            "ui.sidebarSelectionToPaint",
            phase: "finish",
            fields: ["scope": appliedScope.diagnosticDescription, "ms": "\(ms)"]
        )
        return true
    }

    func beginOperation(_ name: String, now: ContinuousClock.Instant = .now) -> MainRunLoopOperationToken {
        nextOperationID += 1
        let record = OperationRecord(id: nextOperationID, name: name, startedAt: now)
        operationStack.append(record)
        return MainRunLoopOperationToken(id: record.id)
    }

    func endOperation(_ token: MainRunLoopOperationToken, now: ContinuousClock.Instant = .now) {
        guard let index = operationStack.lastIndex(where: { $0.id == token.id }) else {
            return
        }
        let record = operationStack.remove(at: index)
        let durationMs = DiagnosticsTiming.milliseconds(from: record.startedAt, to: now)
        lastLongOperation = CompletedOperationRecord(
            name: record.name,
            durationMs: durationMs,
            finishedAt: now
        )
    }

    func start() {
        #if DEBUG
            guard timer == nil else {
                return
            }

            expectedFire = ContinuousClock.now.advanced(by: interval)
            // The timer is scheduled on the main run loop, so its block already runs on
            // the main thread: ticking there directly measures the run loop's lateness,
            // where a `Task` hop would add its own scheduling delay to every sample.
            let timer = Timer(timeInterval: DiagnosticsTiming.seconds(interval), repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.tick()
                }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
            OtosLog.performance.debug("Main run loop stall monitor started")
        #else
            return
        #endif
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        expectedFire = nil
        latestHandoff = nil
        operationStack.removeAll()
        lastLongOperation = nil
        pendingIntentToPaint = nil
    }

    private func tick(now: ContinuousClock.Instant = .now) {
        guard let expectedFire = activeExpectedFire(now: now) else {
            return
        }

        let lateness = expectedFire.duration(to: now)
        self.expectedFire = now.advanced(by: interval)
        guard lateness >= stallThreshold else {
            return
        }

        recordStall(stallMs: DiagnosticsTiming.milliseconds(lateness), now: now)
    }

    private func activeExpectedFire(now: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        // Inactive apps are eligible for timer coalescing and App Nap. A late
        // main-run-loop timer in that state is not evidence of user-visible
        // jank, so reset the baseline until the app is active again.
        guard NSApplication.shared.isActive else {
            expectedFire = now.advanced(by: interval)
            return nil
        }

        guard let expectedFire else {
            expectedFire = now.advanced(by: interval)
            return nil
        }
        return expectedFire
    }

    private func recordStall(stallMs: Int, now: ContinuousClock.Instant) {
        let latestHandoff = latestHandoff
        let currentOperation = operationStack.last
        let lastLongOperation = lastLongOperation
        let extraFields = additionalStallFields?() ?? [:]
        let fields = stallFields(
            stallMs: stallMs,
            now: now,
            latestHandoff: latestHandoff,
            currentOperation: currentOperation,
            lastLongOperation: lastLongOperation,
            extraFields: extraFields
        )
        recordStallDiagnostic(fields)
    }

    private func stallFields(
        stallMs: Int,
        now: ContinuousClock.Instant,
        latestHandoff: CatalogGridHandoff?,
        currentOperation: OperationRecord?,
        lastLongOperation: CompletedOperationRecord?,
        extraFields: [String: String]
    ) -> [String: String] {
        var fields = [
            "stallMs": "\(stallMs)",
            "thresholdMs": "\(DiagnosticsTiming.milliseconds(stallThreshold))",
            "intervalMs": "\(DiagnosticsTiming.milliseconds(interval))",
        ]
        if let latestHandoff {
            fields["latestUpdateID"] = "\(latestHandoff.updateID)"
            fields["latestItems"] = "\(latestHandoff.itemCount)"
            fields["latestPreviousItems"] = "\(latestHandoff.previousItemCount)"
            fields["latestItemDelta"] = "\(latestHandoff.itemDelta)"
            fields["latestSelection"] = latestHandoff.selection
            fields["latestEmptyState"] = latestHandoff.emptyState
            fields["mediaIdentityChanged"] = "\(latestHandoff.mediaIdentityChanged)"
            fields["detailRefreshGeneration"] = "\(latestHandoff.detailRefreshGeneration)"
            fields["latestHandoffAgeMs"] = "\(DiagnosticsTiming.milliseconds(since: latestHandoff.timestamp, now: now))"
        }
        // Prefer the in-flight operation over a finished long op so stalls during
        // reconfigure are not blamed on a completed applyStructure.
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
        for (key, value) in extraFields {
            fields[key] = value
        }
        return fields
    }

    private func recordStallDiagnostic(_ fields: [String: String]) {
        let bracketedOp = fields["currentOperation"] ?? fields["lastLongOperation"] ?? "unattributed"
        OtosLog.performance.fault(
            "op=mainThreadStall bracketedOp=\(bracketedOp, privacy: .public) \(otosLogFields(fields), privacy: .public)"
        )
    }
}
