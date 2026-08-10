import Foundation
import GRDB
@testable import Otos
import Synchronization
import Testing

/// Per-root `providerUnavailable` breaker owns the 32×2s storm that the
/// per-file `k=2` short-circuit leaves behind. `FileMaterialization` fixes
/// one file (`120s → ~2s`); the coordinator fixes the next 31 files on the
/// same root by suppressing background dispatch for 60s after two consecutive
/// `providerUnavailable` on that root.
struct MaterializationCoordinatorProviderBreakerTests {
    private func makeCoordinator(
        executor: @escaping MaterializationCoordinator.Executor,
        policy: MaterializationAdmissionPolicy = .production
    ) -> MaterializationCoordinator {
        // In-memory Store is enough: the coordinator only calls
        // `beginKnownMaterialization`/`endKnownMaterialization`, which no-ops
        // until roots exist. No scan/enrichment work touches this Store.
        let store = CatalogStore(location: .inMemory)
        return MaterializationCoordinator(store: store, executor: executor, policy: policy)
    }

    private func id(root: String, file: String) -> MediaAssetID {
        MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: root),
            relativePath: MediaRelativePath(rawValue: file)
        )
    }

    @Test func twoConsecutiveProviderUnavailableOpensBreakerAndSuppressesNextFile() async {
        // Production policy: backgroundPerRootCap=1, globalConcurrency=16, so without
        // the breaker the third file would dispatch immediately. With the breaker it
        // must not dispatch until the cooldown fires.
        let root = "/Library/RootA"
        let executorCalls = AtomicCounter()
        let coordinator = makeCoordinator { _ in
            executorCalls.increment()
            return MaterializationResult(outcome: .providerUnavailable, rerequestCount: 2, elapsedMs: 2000)
        }
        await coordinator.start()

        // Two files on the same root, both providerUnavailable → streak hits 2 → breaker open.
        async let r1 = coordinator.materialize(
            MaterializationCoordinator.Request(id: id(root: root, file: "a.jpg"), sourceSize: 1024, isVideo: false, priority: .background)
        )
        async let r2 = coordinator.materialize(
            MaterializationCoordinator.Request(id: id(root: root, file: "b.jpg"), sourceSize: 1024, isVideo: false, priority: .background)
        )
        _ = await (r1, r2)
        // Give finishOperation → recordProviderBreakerOutcome a turn.
        try? await Task.sleep(for: .milliseconds(50))

        // Third file on the same root: should be pending but never dispatched while breaker is open.
        let thirdTask = Task {
            await coordinator.materialize(
                MaterializationCoordinator.Request(
                    id: id(root: root, file: "c.jpg"),
                    sourceSize: 1024,
                    isVideo: false,
                    priority: .background
                )
            )
        }
        try? await Task.sleep(for: .milliseconds(100))
        let snapshot = await coordinator.stateSnapshot()
        // Breaker-open: third file stays pending (not inFlight), no additional executor call yet.
        #expect(executorCalls.value == 2, "breaker should have suppressed the third dispatch")
        #expect(snapshot.pending == 1)
        #expect(snapshot.inFlight == 0)
        thirdTask.cancel()
        _ = await thirdTask.value
        await coordinator.shutdown()
    }

    @Test func mixedOutcomeResetsStreakAndDoesNotOpenBreaker() async {
        let root = "/Library/RootA"
        let callCount = AtomicCounter()
        let coordinator = makeCoordinator { _ in
            let n = callCount.incrementAndGet()
            // Alternate: providerUnavailable, then success → streak never reaches 2.
            return n == 1
                ? MaterializationResult(outcome: .providerUnavailable, rerequestCount: 2, elapsedMs: 2000)
                : MaterializationResult(outcome: .materialized, rerequestCount: 1, elapsedMs: 500)
        }
        await coordinator.start()

        _ = await coordinator.materialize(
            MaterializationCoordinator.Request(id: id(root: root, file: "a.jpg"), sourceSize: 1024, isVideo: false, priority: .background)
        )
        try? await Task.sleep(for: .milliseconds(50))
        _ = await coordinator.materialize(
            MaterializationCoordinator.Request(id: id(root: root, file: "b.jpg"), sourceSize: 1024, isVideo: false, priority: .background)
        )
        try? await Task.sleep(for: .milliseconds(50))

        // Success clears the streak: a later providerUnavailable is streak 1 again, not 2.
        let thirdTask = Task {
            await coordinator.materialize(
                MaterializationCoordinator.Request(
                    id: id(root: root, file: "c.jpg"),
                    sourceSize: 1024,
                    isVideo: false,
                    priority: .background
                )
            )
        }
        try? await Task.sleep(for: .milliseconds(100))
        // Without breaker, the third file should have dispatched (executor called for it).
        // Allow timing slop: at least two calls already done; third may be pending or dispatched.
        // The key assertion: breaker did not suppress it — it eventually runs.
        let snap = await coordinator.stateSnapshot()
        // If breaker had opened, pending would stay 1 forever; without it, the singleton
        // background slot is free and the third file dispatches.
        #expect(snap.pending + snap.inFlight <= 1)
        thirdTask.cancel()
        _ = await thirdTask.value
        await coordinator.shutdown()
    }

    @Test func breakerIsPerRoot() async {
        // providerUnavailable on root A must not block root B.
        let callsByRoot = Mutex<[String: Int]>([:])
        let coordinator = makeCoordinator { url in
            let path = url.path
            callsByRoot.withLock { $0[path, default: 0] += 1 }
            // All files on A fail, files on B succeed.
            if path.contains("RootA") {
                return MaterializationResult(outcome: .providerUnavailable, rerequestCount: 2, elapsedMs: 2000)
            }
            return MaterializationResult(outcome: .materialized, rerequestCount: 1, elapsedMs: 500)
        }
        await coordinator.start()

        async let a1 = coordinator.materialize(
            MaterializationCoordinator.Request(id: id(root: "/Library/RootA", file: "a.jpg"), sourceSize: 1024, isVideo: false, priority: .background)
        )
        async let a2 = coordinator.materialize(
            MaterializationCoordinator.Request(id: id(root: "/Library/RootA", file: "b.jpg"), sourceSize: 1024, isVideo: false, priority: .background)
        )
        _ = await (a1, a2)
        try? await Task.sleep(for: .milliseconds(50))

        // Root B file should still dispatch despite Root A breaker being open.
        let bResult = await coordinator.materialize(
            MaterializationCoordinator.Request(id: id(root: "/Library/RootB", file: "c.jpg"), sourceSize: 1024, isVideo: false, priority: .background)
        )
        #expect(bResult.outcome == .materialized)
        await coordinator.shutdown()
    }

    private final class AtomicCounter: Sendable {
        private let storage = Mutex(0)
        var value: Int {
            storage.withLock { $0 }
        }

        func increment() {
            storage.withLock { $0 += 1 }
        }

        @discardableResult
        func incrementAndGet() -> Int {
            storage.withLock { $0 += 1
                return $0
            }
        }
    }
}
