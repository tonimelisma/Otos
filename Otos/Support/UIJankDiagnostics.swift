import AppKit
import Foundation
import OSLog

nonisolated struct CatalogGridHandoff: Equatable {
    let updateID: Int
    let itemCount: Int
    let previousItemCount: Int
    let itemDelta: Int
    let selection: String
    let emptyState: String
    let timestamp: Date
}

@MainActor
final class CatalogUIUpdateTracker {
    static let shared = CatalogUIUpdateTracker()

    private var nextID = 0
    private var latestHandoff: CatalogGridHandoff?

    func reserveUpdateID() -> Int {
        nextID += 1
        return nextID
    }

    func recordGridHandoff(_ handoff: CatalogGridHandoff) {
        latestHandoff = handoff
    }

    func latestGridHandoff() -> CatalogGridHandoff? {
        latestHandoff
    }
}

@MainActor
final class MainRunLoopStallMonitor {
    static let shared = MainRunLoopStallMonitor()

    private var timer: Timer?
    private var expectedFireDate: Date?
    private var diagnostics: CatalogDiagnostics?
    private let interval: TimeInterval = 0.1
    private let stallThreshold: TimeInterval = 0.1

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

    func stopForTesting() {
        timer?.invalidate()
        timer = nil
        expectedFireDate = nil
        diagnostics = nil
    }

    private func tick(now: Date = Date()) {
        // Inactive apps are eligible for timer coalescing and App Nap. A late
        // main-run-loop timer in that state is not evidence of user-visible
        // jank, so reset the baseline until the app is active again.
        guard NSApplication.shared.isActive else {
            expectedFireDate = now.addingTimeInterval(interval)
            return
        }

        guard let expectedFireDate else {
            expectedFireDate = now.addingTimeInterval(interval)
            return
        }

        let lateness = now.timeIntervalSince(expectedFireDate)
        self.expectedFireDate = now.addingTimeInterval(interval)
        guard lateness >= stallThreshold else {
            return
        }

        let stallMs = max(0, Int((lateness * 1000).rounded()))
        let latestHandoff = CatalogUIUpdateTracker.shared.latestGridHandoff()
        OtosLog.performance.error(
            """
            Main run loop stall detected ms=\(stallMs, privacy: .public) \
            latestUpdateID=\(latestHandoff?.updateID ?? 0, privacy: .public) \
            latestItems=\(latestHandoff?.itemCount ?? 0, privacy: .public)
            """
        )

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

        let diagnostics = diagnostics
        Task {
            await diagnostics?.record(
                operation: "ui.mainRunLoop.stall",
                phase: "detected",
                fields: fields
            )
        }
    }
}
