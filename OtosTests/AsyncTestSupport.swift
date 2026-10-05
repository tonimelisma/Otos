import Foundation
@testable import OtosKit

extension MaterializationResult {
    static var testMaterialized: MaterializationResult {
        MaterializationResult(outcome: .materialized, rerequestCount: 0, elapsedMs: 0)
    }
}

enum AsyncTestTimeoutError: Error, CustomStringConvertible {
    case streamEnded(String)

    var description: String {
        switch self {
        case let .streamEnded(label):
            "Stream ended while waiting for \(label)"
        }
    }
}

/// Waits until `condition` holds, re-checking it every `interval`.
///
/// There is deliberately no deadline. A wall-clock limit on a wait for progress
/// measures machine load, not correctness: under the full parallel suite the awaited
/// work can lag for seconds, and the limit then fails a test whose state was still on
/// its way. A condition that never holds is a hang. The wait sleeps between checks, so
/// a hung test host consumes almost no CPU and `script/check.sh`'s stall detector
/// reports it. Never replace the sleep with `Task.yield()`: a spinning wait keeps the
/// host busy and hides the hang from that detector.
func waitUntil(
    every interval: Duration = .milliseconds(5),
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async throws -> Bool
) async throws {
    try await waitForValue(every: interval) { try await condition() ? () : nil }
}

/// Waits until `produce` returns a value, re-asking every `interval`, and returns it.
/// The same no-deadline rule as `waitUntil` applies.
func waitForValue<Value>(
    every interval: Duration = .milliseconds(5),
    isolation: isolated (any Actor)? = #isolation,
    _ produce: () async throws -> Value?
) async throws -> Value {
    while true {
        if let value = try await produce() {
            return value
        }
        try await Task.sleep(for: interval)
    }
}

/// Turns the main run loop until the grid controller shows `expectedIDs` with no
/// apply in flight, then turns it once more so the apply's completion block has run.
/// It is synchronous because diffable apply completion advances only while the run
/// loop turns. Like `waitUntil`, it has no deadline: each turn parks the thread for
/// 10 ms, so a hang leaves the host idle for `script/check.sh` to report.
@MainActor
func awaitGridApply(_ controller: MediaGridViewController, expectedIDs: [MediaAssetID]) {
    while controller.mutationGate.displayedOrderedIDs != expectedIDs
        || controller.mutationGate.inFlight != .none
    {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
}

/// Waits until the projection has no pending or in-flight publication, so a test can
/// assert on a settled `orderQueryCount` without guessing a sleep duration.
func waitForProjectionQuiescence(_ projection: CatalogProjection) async throws {
    try await waitUntil { await projection.isQuiescent }
}

actor AsyncValueRecorder<Value: Sendable> {
    private struct Waiter {
        let predicate: @Sendable ([Value]) -> Bool
        let continuation: CheckedContinuation<[Value], Never>
    }

    private var values: [Value] = []
    private var waiters: [UUID: Waiter] = [:]

    func append(_ value: Value) {
        values.append(value)
        resumeSatisfiedWaiters()
    }

    func snapshot() -> [Value] {
        values
    }

    func count() -> Int {
        values.count
    }

    func waitForValues(
        matching predicate: @escaping @Sendable ([Value]) -> Bool
    ) async -> [Value] {
        if predicate(values) {
            return values
        }

        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiters[id] = Waiter(predicate: predicate, continuation: continuation)
            resumeSatisfiedWaiters()
        }
    }

    private func resumeSatisfiedWaiters() {
        let satisfiedIDs = waiters.compactMap { id, waiter in
            waiter.predicate(values) ? id : nil
        }
        for id in satisfiedIDs {
            waiters.removeValue(forKey: id)?.continuation.resume(returning: values)
        }
    }
}

actor ManualSleepGate {
    private var sleepRequestCount = 0
    private var sleepers: [CheckedContinuation<Void, Never>] = []
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func sleep(for _: Duration) async {
        sleepRequestCount += 1
        resumeCountWaiters()
        await withCheckedContinuation { continuation in
            sleepers.append(continuation)
        }
    }

    func waitForSleepRequestCount(_ expectedCount: Int) async {
        if sleepRequestCount >= expectedCount {
            return
        }
        await withCheckedContinuation { continuation in
            countWaiters.append((expectedCount, continuation))
            resumeCountWaiters()
        }
    }

    func releaseNext() {
        guard !sleepers.isEmpty else {
            return
        }
        sleepers.removeFirst().resume()
    }

    func releaseAll() {
        let currentSleepers = sleepers
        sleepers.removeAll()
        for sleeper in currentSleepers {
            sleeper.resume()
        }
    }

    private func resumeCountWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in countWaiters {
            if sleepRequestCount >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        countWaiters = remaining
    }
}
