import Foundation
@testable import OtosKit
import Synchronization
import Testing

struct MaterializationCoordinatorTests {
    @Test func sameIDRequestsShareOnePhysicalTransfer() async throws {
        let executor = ControlledMaterializationExecutor()
        let coordinator = MaterializationCoordinator(
            store: CatalogStore(location: .inMemory),
            executor: { await executor.run($0.id.fileURL) }
        )
        let shared = request("shared.jpg", priority: .background)
        let first = Task { await coordinator.materialize(shared) }
        try await executor.waitForStarts(1)
        let second = Task {
            await coordinator.materialize(
                request("shared.jpg", priority: .interactive)
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await executor.startedNames() == ["shared.jpg"])
        await executor.releaseNext()
        #expect(await (first.value).isMaterialized)
        #expect(await (second.value).isMaterialized)
        #expect(await executor.startedNames().count == 1)
        await coordinator.shutdown()
    }

    @Test func queuedBackgroundRequestIsPromotedWithoutDuplicateTransfer() async throws {
        var policy = MaterializationAdmissionPolicy.production
        policy.globalConcurrency = 2
        // Two device transfers run concurrently here only to occupy both slots; this
        // test's subject is background promotion, not device concurrency. Production caps
        // devices at one because ImageCaptureCore serialises them, so state the higher cap
        // explicitly rather than let the subject depend on the production value.
        policy.deviceConcurrency = 2
        let executor = ControlledMaterializationExecutor()
        let coordinator = MaterializationCoordinator(
            store: CatalogStore(location: .inMemory),
            executor: { await executor.run($0.id.fileURL) },
            policy: policy
        )
        let firstActive = Task { await coordinator.materialize(request("active-1.jpg", priority: .device)) }
        let secondActive = Task { await coordinator.materialize(request("active-2.jpg", priority: .device)) }
        try await executor.waitForStarts(2)
        let background = Task {
            await coordinator.materialize(request("promoted.jpg", priority: .background))
        }
        let lowerPriority = Task {
            await coordinator.materialize(request("queued.jpg", priority: .background))
        }
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while await coordinator.queuedRequestCount() < 2, ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let interactive = Task {
            await coordinator.materialize(request("promoted.jpg", priority: .interactive))
        }
        await executor.releaseNext()
        try await executor.waitForStarts(3)
        #expect(await (executor.startedNames()).last == "promoted.jpg")
        await executor.releaseNext()
        await executor.releaseNext()
        try await executor.waitForStarts(4)
        #expect(await (executor.startedNames()).last == "queued.jpg")
        await executor.releaseNext()
        _ = await (
            firstActive.value,
            secondActive.value,
            background.value,
            interactive.value,
            lowerPriority.value
        )
        #expect(await executor.startedNames().count == 4)
        await coordinator.shutdown()
    }

    /// E1. ImageCaptureCore funnels every request through one serial
    /// `ICDeviceCommandQueue`, so a second concurrent device transfer is not parallelism —
    /// it queues inside a framework Otos cannot observe, time, or cancel. The 2026-08-30
    /// session ran sixteen at once and measured 0.9-8.5 MB/s against 37-40 MB/s
    /// single-stream.
    @Test func onlyOneDeviceTransferRunsAtATime() async throws {
        let executor = ControlledMaterializationExecutor()
        let coordinator = MaterializationCoordinator(
            store: CatalogStore(location: .inMemory),
            executor: { await executor.run($0.id.fileURL) }
        )
        let first = Task { await coordinator.materialize(request("first.arw", priority: .device)) }
        try await executor.waitForStarts(1)
        let second = Task { await coordinator.materialize(request("second.arw", priority: .device)) }
        try await Task.sleep(for: .milliseconds(30))

        #expect(
            await executor.startedNames() == ["first.arw"],
            "a second device transfer must wait in Otos's queue, not inside ImageCaptureCore"
        )

        await executor.releaseNext()
        try await executor.waitForStarts(2)
        #expect(await executor.startedNames() == ["first.arw", "second.arw"])
        await executor.releaseNext()
        _ = await (first.value, second.value)
        await coordinator.shutdown()
    }

    /// The device cap is a transport limit, not a global one. Cloud and local
    /// materialization are genuinely concurrent and were never the finding, so lowering
    /// the global cap would have been the wrong fix.
    @Test func deviceCapDoesNotThrottleOtherTransports() async throws {
        let executor = ControlledMaterializationExecutor()
        let coordinator = MaterializationCoordinator(
            store: CatalogStore(location: .inMemory),
            executor: { await executor.run($0.id.fileURL) }
        )
        let device = Task { await coordinator.materialize(request("card.arw", priority: .device)) }
        try await executor.waitForStarts(1)
        let cloud = Task { await coordinator.materialize(request("cloud.jpg", priority: .interactive)) }
        try await executor.waitForStarts(2)

        #expect(await executor.startedNames().sorted() == ["card.arw", "cloud.jpg"])

        await executor.releaseNext()
        await executor.releaseNext()
        _ = await (device.value, cloud.value)
        await coordinator.shutdown()
    }

    /// The rejection is named, so a stalled camera is attributable in the admission log
    /// rather than looking like generic global-concurrency pressure.
    @Test func aSecondDeviceRequestIsRejectedAsDeviceConcurrency() {
        let policy = MaterializationAdmissionPolicy.production
        let inFlight = MaterializationAdmissionPolicy.Snapshot(
            count: 1, bytes: 0, largeVideoCount: 0, deviceCount: 1, backgroundByRoot: [:]
        )
        #expect(policy.rejection(for: request("next.arw", priority: .device), inFlight: inFlight) == .deviceConcurrency)
        #expect(policy.rejection(for: request("next.jpg", priority: .interactive), inFlight: inFlight) == nil)
    }

    @Test func backgroundIsLimitedToOneTransferPerRoot() async throws {
        let executor = ControlledMaterializationExecutor()
        let coordinator = MaterializationCoordinator(
            store: CatalogStore(location: .inMemory),
            executor: { await executor.run($0.id.fileURL) }
        )
        let first = Task { await coordinator.materialize(request("one.jpg", priority: .background)) }
        try await executor.waitForStarts(1)
        let second = Task { await coordinator.materialize(request("two.jpg", priority: .background)) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await executor.startedNames() == ["one.jpg"])
        await executor.releaseNext()
        try await executor.waitForStarts(2)
        #expect(await executor.startedNames() == ["one.jpg", "two.jpg"])
        await executor.releaseNext()
        _ = await (first.value, second.value)
        await coordinator.shutdown()
    }

    @Test func backgroundFromAnotherRootUsesAvailableCapacity() async throws {
        var policy = MaterializationAdmissionPolicy.production
        policy.globalConcurrency = 3
        let executor = ControlledMaterializationExecutor()
        let coordinator = MaterializationCoordinator(
            store: CatalogStore(location: .inMemory),
            executor: { await executor.run($0.id.fileURL) },
            policy: policy
        )
        let first = Task { await coordinator.materialize(request("one.jpg", priority: .background)) }
        try await executor.waitForStarts(1)
        let second = Task {
            await coordinator.materialize(
                request("two.jpg", root: "/other-library", priority: .background)
            )
        }
        try await executor.waitForStarts(2)
        #expect(await Set(executor.startedNames()) == ["one.jpg", "two.jpg"])
        await executor.releaseNext()
        await executor.releaseNext()
        _ = await (first.value, second.value)
        await coordinator.shutdown()
    }

    @Test func backgroundReserveAndOversizedSoloPolicy() {
        var policy = MaterializationAdmissionPolicy.production
        policy.globalConcurrency = 4
        let background = request("background.jpg", priority: .background)
        var snapshot = MaterializationAdmissionPolicy.Snapshot.empty
        snapshot.count = 3
        #expect(policy.rejection(for: background, inFlight: snapshot) == .backgroundReserve)

        snapshot = .empty
        let huge = MaterializationCoordinator.Request(
            id: background.id,
            sourceSize: 7 * 1024 * 1024 * 1024,
            isVideo: true,
            priority: .background
        )
        #expect(policy.rejection(for: huge, inFlight: snapshot) == nil)
    }

    @Test func cancellingLastQueuedWaiterDropsPhysicalRequest() async throws {
        var policy = MaterializationAdmissionPolicy.production
        policy.globalConcurrency = 1
        let executor = ControlledMaterializationExecutor()
        let coordinator = MaterializationCoordinator(
            store: CatalogStore(location: .inMemory),
            executor: { await executor.run($0.id.fileURL) },
            policy: policy
        )
        let active = Task { await coordinator.materialize(request("active.jpg", priority: .device)) }
        try await executor.waitForStarts(1)
        let queued = Task { await coordinator.materialize(request("cancel.jpg", priority: .background)) }
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while await coordinator.queuedRequestCount() < 1, ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        queued.cancel()
        #expect(await !(queued.value).isMaterialized)
        #expect(await coordinator.queuedRequestCount() == 0)
        await executor.releaseNext()
        _ = await active.value
        #expect(await executor.startedNames() == ["active.jpg"])
        await coordinator.shutdown()
    }

    @Test func unchangedBlockedAdmissionSnapshotIsDeduplicated() async throws {
        var policy = MaterializationAdmissionPolicy.production
        policy.globalConcurrency = 1
        let executor = ControlledMaterializationExecutor()
        let diagnostics = AdmissionDiagnosticRecorder()
        let coordinator = MaterializationCoordinator(
            store: CatalogStore(location: .inMemory),
            executor: { await executor.run($0.id.fileURL) },
            policy: policy,
            diagnosticSink: { diagnostics.record($0) }
        )
        let active = Task { await coordinator.materialize(request("active.jpg", priority: .interactive)) }
        try await executor.waitForStarts(1)
        let queued = Task { await coordinator.materialize(request("queued.jpg", priority: .interactive)) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(diagnostics.blockedCount() == 1)
        await executor.releaseNext()
        try await executor.waitForStarts(2)
        await executor.releaseNext()
        _ = await (active.value, queued.value)
        #expect(diagnostics.unblockedCount() == 1)
        await coordinator.shutdown()
    }

    @Test func interactiveJoinBlocksLowerPriorityUntilItsWaiterCancels() async throws {
        var policy = MaterializationAdmissionPolicy.production
        policy.globalConcurrency = 3
        let executor = ControlledMaterializationExecutor()
        let coordinator = MaterializationCoordinator(
            store: CatalogStore(location: .inMemory),
            executor: { await executor.run($0.id.fileURL) },
            policy: policy
        )
        let background = Task {
            await coordinator.materialize(request("active.jpg", priority: .background))
        }
        try await executor.waitForStarts(1)
        let interactive = Task {
            await coordinator.materialize(request("active.jpg", priority: .interactive))
        }
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while await coordinator.stateSnapshot().effectiveInteractive != 1,
              ContinuousClock().now < deadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        let device = Task {
            await coordinator.materialize(request("device.jpg", priority: .device))
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await executor.startedNames() == ["active.jpg"])

        interactive.cancel()
        #expect(await !(interactive.value).isMaterialized)
        try await executor.waitForStarts(2)
        #expect(await executor.startedNames() == ["active.jpg", "device.jpg"])

        await executor.releaseNext()
        await executor.releaseNext()
        _ = await (background.value, device.value)
        await coordinator.shutdown()
    }

    @Test func cancelledQueuedPromotionRestoresBackgroundAdmission() async throws {
        var policy = MaterializationAdmissionPolicy.production
        policy.globalConcurrency = 2
        // As above: two occupied slots are the fixture, not the subject (which is
        // restoring background admission after a queued promotion is cancelled).
        policy.deviceConcurrency = 2
        let executor = ControlledMaterializationExecutor()
        let coordinator = MaterializationCoordinator(
            store: CatalogStore(location: .inMemory),
            executor: { await executor.run($0.id.fileURL) },
            policy: policy
        )
        let first = Task { await coordinator.materialize(request("first.jpg", priority: .device)) }
        let second = Task { await coordinator.materialize(request("second.jpg", priority: .device)) }
        try await executor.waitForStarts(2)
        let background = Task {
            await coordinator.materialize(request("restored.jpg", priority: .background))
        }
        let interactive = Task {
            await coordinator.materialize(request("restored.jpg", priority: .interactive))
        }
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while await coordinator.queuedRequestCount() < 1, ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        interactive.cancel()
        #expect(await !(interactive.value).isMaterialized)

        await executor.releaseNext()
        try await Task.sleep(for: .milliseconds(30))
        #expect(await executor.startedNames().count == 2)

        await executor.releaseNext()
        try await executor.waitForStarts(3)
        #expect(await (executor.startedNames()).last == "restored.jpg")
        await executor.releaseNext()
        _ = await (first.value, second.value, background.value)
        await coordinator.shutdown()
    }

    // MARK: - Plan 0059 review fixes

    @Test func interactiveJoinBlocksBackgroundWithTruthfulBlockedDiagnostic() async throws {
        var policy = MaterializationAdmissionPolicy.production
        policy.globalConcurrency = 3
        let executor = ControlledMaterializationExecutor()
        let diagnostics = AdmissionDiagnosticRecorder()
        let coordinator = MaterializationCoordinator(
            store: CatalogStore(location: .inMemory),
            executor: { await executor.run($0.id.fileURL) },
            policy: policy,
            diagnosticSink: { diagnostics.record($0) }
        )
        let active = Task { await coordinator.materialize(request("active.jpg", priority: .background)) }
        try await executor.waitForStarts(1)
        // The interactive waiter joins the in-flight background transfer rather than
        // queuing: `effectiveInteractiveCount` rises with `interactiveQueue` empty.
        let interactive = Task {
            await coordinator.materialize(request("active.jpg", priority: .interactive))
        }
        let joinDeadline = ContinuousClock().now.advanced(by: .seconds(2))
        while await coordinator.stateSnapshot().effectiveInteractive != 1, ContinuousClock().now < joinDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let queued = Task {
            await coordinator.materialize(request("queued.jpg", root: "/other-library", priority: .background))
        }
        let queuedDeadline = ContinuousClock().now.advanced(by: .seconds(2))
        while await coordinator.queuedRequestCount() < 1, ContinuousClock().now < queuedDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(diagnostics.blockedCount() >= 1)
        #expect(diagnostics.unblockedCount() == 0)

        interactive.cancel()
        #expect(await !(interactive.value).isMaterialized)
        try await executor.waitForStarts(2)
        #expect(await executor.startedNames() == ["active.jpg", "queued.jpg"])

        await executor.releaseNext()
        await executor.releaseNext()
        _ = await (active.value, queued.value)
        #expect(diagnostics.unblockedCount() >= 1)
        await coordinator.shutdown()
    }

    @Test func closureMaterializationRequesterReportsNoActiveRequests() async {
        let requester = ClosureMaterializationRequester(operation: { _ in .testMaterialized })
        let count = await requester.activeRequestCount(under: LibraryRootPath(rawValue: "/library"))
        #expect(count == 0)
    }

    private func request(
        _ name: String,
        root: String = "/library",
        priority: MaterializationCoordinator.Priority
    ) -> MaterializationCoordinator.Request {
        MaterializationCoordinator.Request(
            id: MediaAssetID(
                libraryRootPath: LibraryRootPath(rawValue: root),
                relativePath: MediaRelativePath(rawValue: name)
            ),
            sourceSize: 1,
            isVideo: false,
            priority: priority
        )
    }
}

private actor ControlledMaterializationExecutor {
    private var starts: [String] = []
    private var releases: [CheckedContinuation<Void, Never>] = []

    func run(_ url: URL) async -> MaterializationResult {
        starts.append(url.lastPathComponent)
        await withCheckedContinuation { continuation in
            releases.append(continuation)
        }
        return MaterializationResult(outcome: .materialized, rerequestCount: 0, elapsedMs: 1)
    }

    func startedNames() -> [String] {
        starts
    }

    func releaseNext() async {
        while releases.isEmpty {
            await Task.yield()
        }
        releases.removeFirst().resume()
    }

    func waitForStarts(_ count: Int) async throws {
        try await withTestTimeout("controlled materialization starts \(count)") {
            while await self.startedCount() < count {
                await Task.yield()
            }
        }
    }

    private func startedCount() -> Int {
        starts.count
    }
}

private final class AdmissionDiagnosticRecorder: Sendable {
    private let storage = Mutex<[MaterializationCoordinator.AdmissionSnapshot?]>([])

    func record(_ value: MaterializationCoordinator.AdmissionSnapshot?) {
        storage.withLock { $0.append(value) }
    }

    func blockedCount() -> Int {
        storage.withLock { $0.compactMap(\.self).count }
    }

    func unblockedCount() -> Int {
        storage.withLock { $0.count(where: { $0 == nil }) }
    }
}
