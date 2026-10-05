import Foundation
import GRDB
@testable import OtosKit
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

    @Test func twoConsecutiveProviderUnavailableOpensBreakerAndSuppressesNextFile() async throws {
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
            MaterializationCoordinator.Request(
                id: id(root: root, file: "a.jpg"),
                sourceSize: 1024,
                isVideo: false,
                priority: .background
            )
        )
        async let r2 = coordinator.materialize(
            MaterializationCoordinator.Request(
                id: id(root: root, file: "b.jpg"),
                sourceSize: 1024,
                isVideo: false,
                priority: .background
            )
        )
        // `finishOperation` records the breaker outcome before it resumes a waiter.
        _ = await (r1, r2)

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
        try await waitUntil { await coordinator.stateSnapshot().pending == 1 }
        try await waitUntil { await coordinator.isQuiescent }
        let snapshot = await coordinator.stateSnapshot()
        // Breaker-open: third file stays pending (not inFlight), no additional executor call yet.
        #expect(executorCalls.value == 2, "breaker should have suppressed the third dispatch")
        #expect(snapshot.pending == 1)
        #expect(snapshot.inFlight == 0)
        thirdTask.cancel()
        _ = await thirdTask.value
        await coordinator.shutdown()
    }

    @Test func mixedOutcomeResetsStreakAndDoesNotOpenBreaker() async throws {
        let root = "/Library/RootA"
        let callCount = AtomicCounter()
        let coordinator = makeCoordinator { _ in
            let callNumber = callCount.incrementAndGet()
            // Alternate: providerUnavailable, then success → streak never reaches 2.
            return callNumber == 1
                ? MaterializationResult(outcome: .providerUnavailable, rerequestCount: 2, elapsedMs: 2000)
                : MaterializationResult(outcome: .materialized, rerequestCount: 1, elapsedMs: 500)
        }
        await coordinator.start()

        _ = await coordinator.materialize(
            MaterializationCoordinator.Request(
                id: id(root: root, file: "a.jpg"),
                sourceSize: 1024,
                isVideo: false,
                priority: .background
            )
        )
        _ = await coordinator.materialize(
            MaterializationCoordinator.Request(
                id: id(root: root, file: "b.jpg"),
                sourceSize: 1024,
                isVideo: false,
                priority: .background
            )
        )

        // Success clears the streak: a later providerUnavailable is streak 1 again, not 2,
        // so the third file dispatches rather than waiting out a breaker cooldown.
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
        try await waitForDispatchedOrHeld(coordinator) { callCount.value == 3 }
        #expect(callCount.value == 3, "an open breaker held the third file")
        thirdTask.cancel()
        _ = await thirdTask.value
        await coordinator.shutdown()
    }

    @Test func breakerIsPerRoot() async throws {
        // providerUnavailable on root A must not block root B.
        let callsByRoot = Mutex<[String: Int]>([:])
        let coordinator = makeCoordinator { request in
            let path = request.id.fileURL.path
            callsByRoot.withLock { $0[path, default: 0] += 1 }
            // All files on A fail, files on B succeed.
            if path.contains("RootA") {
                return MaterializationResult(outcome: .providerUnavailable, rerequestCount: 2, elapsedMs: 2000)
            }
            return MaterializationResult(outcome: .materialized, rerequestCount: 1, elapsedMs: 500)
        }
        await coordinator.start()

        async let a1 = coordinator.materialize(
            MaterializationCoordinator.Request(
                id: id(root: "/Library/RootA", file: "a.jpg"),
                sourceSize: 1024,
                isVideo: false,
                priority: .background
            )
        )
        async let a2 = coordinator.materialize(
            MaterializationCoordinator.Request(
                id: id(root: "/Library/RootA", file: "b.jpg"),
                sourceSize: 1024,
                isVideo: false,
                priority: .background
            )
        )
        _ = await (a1, a2)

        // Root B file should still dispatch despite Root A breaker being open.
        let bTask = Task {
            await coordinator.materialize(
                MaterializationCoordinator.Request(
                    id: id(root: "/Library/RootB", file: "c.jpg"),
                    sourceSize: 1024,
                    isVideo: false,
                    priority: .background
                )
            )
        }
        try await waitForDispatchedOrHeld(coordinator) {
            callsByRoot.withLock { $0.keys.contains { $0.contains("RootB") } }
        }
        #expect(
            callsByRoot.withLock { $0.keys.contains { $0.contains("RootB") } },
            "root A's breaker held root B's file"
        )
        #expect(await bTask.value.outcome == .materialized)
        await coordinator.shutdown()
    }

    /// Waits until the newest request has either dispatched or been held by admission.
    /// A held request would still dispatch once a breaker cooldown ends, so waiting for
    /// the dispatch alone could not tell a correct coordinator from a held one.
    private func waitForDispatchedOrHeld(
        _ coordinator: MaterializationCoordinator,
        dispatched: () -> Bool
    ) async throws {
        try await waitUntil {
            if dispatched() {
                return true
            }
            let held = await coordinator.stateSnapshot().pending == 1
            let quiescent = await coordinator.isQuiescent
            return held && quiescent
        }
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
