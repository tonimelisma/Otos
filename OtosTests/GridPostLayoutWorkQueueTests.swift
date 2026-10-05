@testable import OtosKit
import Testing

@MainActor
struct GridPostLayoutWorkQueueTests {
    @Test func readySubmissionFlushesAndRunsImmediately() {
        var ready = true
        var flushes = 0
        var runs = 0
        let queue = GridPostLayoutWorkQueue(
            isReady: { ready },
            flushLayout: { flushes += 1 }
        )

        #expect(queue.submit(.detailAndPreheat, reason: "ready") { runs += 1 } == .ranNow)
        #expect(flushes == 1)
        #expect(runs == 1)
        ready = false
    }

    @Test func repeatedDeferredSubmissionRunsNewestOnceAfterOneLayoutTurn() async throws {
        var ready = false
        var runs: [String] = []
        let queue = GridPostLayoutWorkQueue(isReady: { ready }, flushLayout: {})

        _ = queue.submit(.detailAndPreheat, reason: "first") { runs.append("first") }
        _ = queue.submit(.detailAndPreheat, reason: "newest") { runs.append("newest") }
        queue.runDeferredWork()
        queue.runDeferredWork()
        ready = true
        try await waitUntil { !queue.hasDeferredTurnScheduled }

        #expect(runs == ["newest"])
    }

    @Test func differentKindsRemainIndependentlyCoalesced() async throws {
        var ready = false
        var runs = 0
        let queue = GridPostLayoutWorkQueue(isReady: { ready }, flushLayout: {})
        _ = queue.submit(.focusScroll, reason: "focus") { runs += 1 }
        _ = queue.submit(.detailAndPreheat, reason: "details") { runs += 1 }
        queue.runDeferredWork()
        ready = true
        try await waitUntil { !queue.hasDeferredTurnScheduled }
        #expect(runs == 2)
    }

    @Test func deferredWorkStaysPendingWhenLayoutTurnIsStillNotReady() async throws {
        var ready = false
        var runs = 0
        let queue = GridPostLayoutWorkQueue(isReady: { ready }, flushLayout: {})
        _ = queue.submit(.focusScroll, reason: "focus") { runs += 1 }
        queue.runDeferredWork()
        try await waitUntil { !queue.hasDeferredTurnScheduled }
        #expect(runs == 0)
        ready = true
        queue.runDeferredWork()
        try await waitUntil { !queue.hasDeferredTurnScheduled }
        #expect(runs == 1)
    }
}
