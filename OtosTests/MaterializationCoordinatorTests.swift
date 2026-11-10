import Foundation
@testable import OtosKit
import Synchronization
import Testing

struct MaterializationCoordinatorTests {
    /// ADR 0046 §4: an in-place original's locality is its `SF_DATALESS` status; a staged
    /// root's file absent from its staging folder is one its source has yet to send.
    @Test func localityReadsAStagedRootsAbsentFileAsFetchable() {
        #expect(OriginalLocality.of(stagesOriginals: false, status: .materialized) == .local)
        #expect(OriginalLocality.of(stagesOriginals: false, status: .dataless) == .fetchable)
        #expect(OriginalLocality.of(stagesOriginals: false, status: .unknown) == .unreachable)
        #expect(OriginalLocality.of(stagesOriginals: true, status: .materialized) == .local)
        #expect(OriginalLocality.of(stagesOriginals: true, status: .unknown) == .fetchable)
        #expect(OriginalLocality.of(stagesOriginals: true, status: .dataless) == .fetchable)
    }

    /// An original that is neither local nor fetchable is answered without a transfer.
    @Test func ensureLocalNeverFetchesAnUnreachableOriginal() async {
        let calls = Mutex(0)
        let requester = ClosureMaterializationRequester(status: { _ in .unknown }) { _ in
            calls.withLock { $0 += 1 }
            return .cancelled
        }
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Library/Root"),
            relativePath: MediaRelativePath(rawValue: "gone.jpg")
        )
        let outcome = await requester.ensureLocal(.init(id: id, sourceSize: nil, isVideo: false, priority: .interactive))
        #expect(outcome == .unreachable)
        #expect(calls.withLock { $0 } == 0)
    }

    /// ENR-008 / ADR 0027: background and device downloads start only while the volume
    /// keeps the free-space floor after them; the photo on screen and a user command do
    /// not wait for it, and a volume that reports no capacity admits.
    @Test func backgroundAndDeviceDownloadsKeepTheFreeSpaceFloor() async {
        let started = Mutex<[String]>([])
        let available = Mutex<Int64?>(FreeSpaceFloor.bytes + 1000)
        let coordinator = MaterializationCoordinator(
            store: CatalogStore(location: .inMemory),
            executor: { request in
                started.withLock { $0.append(request.id.relativePath.rawValue) }
                return MaterializationResult(outcome: .materialized, rerequestCount: 0, elapsedMs: 0)
            },
            volumeCapacity: { _ in available.withLock { $0 } }
        )
        let held = await [
            coordinator.materialize(request("big-background.jpg", priority: .background, sourceSize: 2000)),
            coordinator.materialize(request("big-device.jpg", priority: .device, sourceSize: 2000)),
        ]
        #expect(held.map(\.outcome) == [.insufficientLocalSpace, .insufficientLocalSpace])
        let admitted = await [
            coordinator.materialize(request("small-background.jpg", priority: .background, sourceSize: 500)),
            coordinator.materialize(request("big-interactive.jpg", priority: .interactive, sourceSize: 2000)),
            coordinator.materialize(request("big-command.jpg", priority: .command, sourceSize: 2000)),
        ]
        #expect(admitted.map(\.isMaterialized) == [true, true, true])
        available.withLock { $0 = nil }
        #expect(await coordinator.materialize(request("unknown.jpg", priority: .background, sourceSize: 2000)).isMaterialized)
        let startedNames = started.withLock { $0 }
        #expect(startedNames == ["small-background.jpg", "big-interactive.jpg", "big-command.jpg", "unknown.jpg"])
        await coordinator.shutdown()
    }

    @Test func sameIDRequestsShareOnePhysicalTransfer() async throws {
        let executor = ControlledMaterializationExecutor()
        let coordinator = MaterializationCoordinator(
            store: CatalogStore(location: .inMemory),
            executor: { await executor.run($0.id.fileURL) },
            volumeCapacity: ampleVolumeCapacity
        )
        let shared = request("shared.jpg", priority: .background)
        let first = Task { await coordinator.materialize(shared) }
        try await executor.waitForStarts(1)
        let second = Task {
            await coordinator.materialize(
                request("shared.jpg", priority: .interactive)
            )
        }
        try await waitForAdmission(coordinator) { await coordinator.stateSnapshot().waiters == 2 }
        #expect(await executor.startedNames() == ["shared.jpg"])
        try await executor.releaseNext()
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
            volumeCapacity: ampleVolumeCapacity,
            policy: policy
        )
        let firstActive = Task { await coordinator.materialize(request("active-1.jpg", priority: .device)) }
        try await executor.waitForStarts(1)
        let secondActive = Task { await coordinator.materialize(request("active-2.jpg", priority: .device)) }
        try await executor.waitForStarts(2)

        // `queued.jpg` is queued strictly before `promoted.jpg`, so first-in-first-out
        // would start `queued.jpg` next; only promotion starts `promoted.jpg` first.
        let earlierBackground = Task {
            await coordinator.materialize(request("queued.jpg", priority: .background))
        }
        try await waitForAdmission(coordinator) { await coordinator.queuedRequestCount() == 1 }
        let laterBackground = Task {
            await coordinator.materialize(request("promoted.jpg", priority: .background))
        }
        try await waitForAdmission(coordinator) { await coordinator.queuedRequestCount() == 2 }
        let interactive = Task {
            await coordinator.materialize(request("promoted.jpg", priority: .interactive))
        }
        // Two device waiters, `queued.jpg`'s, and both of `promoted.jpg`'s on one entry.
        try await waitForAdmission(coordinator) { await coordinator.stateSnapshot().waiters == 5 }
        #expect(await coordinator.queuedRequestCount() == 2)

        // Freeing one slot admits exactly one request. Waiting for `active-1.jpg`'s
        // waiter to leave and admission to settle makes "admitted nothing" a failure
        // here rather than a hang in `waitForStarts`.
        try await executor.releaseNext()
        try await waitForAdmission(coordinator) { await coordinator.stateSnapshot().waiters == 4 }
        try #require(await coordinator.stateSnapshot().inFlight == 2)
        try await executor.waitForStarts(3)
        #expect(await executor.startedNames() == ["active-1.jpg", "active-2.jpg", "promoted.jpg"])

        try await executor.releaseNext()
        try await executor.releaseNext()
        try await executor.waitForStarts(4)
        #expect(await executor.startedNames() == ["active-1.jpg", "active-2.jpg", "promoted.jpg", "queued.jpg"])
        try await executor.releaseNext()
        let results = await (
            firstActive.value,
            secondActive.value,
            earlierBackground.value,
            laterBackground.value,
            interactive.value
        )
        #expect(results.3.isMaterialized)
        #expect(results.4.isMaterialized)
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
            executor: { await executor.run($0.id.fileURL) },
            volumeCapacity: ampleVolumeCapacity
        )
        let first = Task { await coordinator.materialize(request("first.arw", priority: .device)) }
        try await executor.waitForStarts(1)
        let second = Task { await coordinator.materialize(request("second.arw", priority: .device)) }
        try await waitForAdmission(coordinator) { await coordinator.queuedRequestCount() == 1 }

        #expect(
            await executor.startedNames() == ["first.arw"],
            "a second device transfer must wait in Otos's queue, not inside ImageCaptureCore"
        )

        try await executor.releaseNext()
        try await executor.waitForStarts(2)
        #expect(await executor.startedNames() == ["first.arw", "second.arw"])
        try await executor.releaseNext()
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
            executor: { await executor.run($0.id.fileURL) },
            volumeCapacity: ampleVolumeCapacity
        )
        let device = Task { await coordinator.materialize(request("card.arw", priority: .device)) }
        try await executor.waitForStarts(1)
        let cloud = Task { await coordinator.materialize(request("cloud.jpg", priority: .interactive)) }
        try await executor.waitForStarts(2)

        #expect(await executor.startedNames().sorted() == ["card.arw", "cloud.jpg"])

        try await executor.releaseNext()
        try await executor.releaseNext()
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

    @Test func backgroundIsLimitedToTheRootCap() async throws {
        let cap = MaterializationAdmissionPolicy.production.backgroundPerRootCap
        let executor = ControlledMaterializationExecutor()
        let coordinator = MaterializationCoordinator(
            store: CatalogStore(location: .inMemory),
            executor: { await executor.run($0.id.fileURL) },
            volumeCapacity: ampleVolumeCapacity
        )
        let admitted = (0 ..< cap).map { "admitted-\($0).jpg" }
        var tasks: [Task<MaterializationResult, Never>] = []
        for name in admitted {
            tasks.append(Task { await coordinator.materialize(request(name, priority: .background)) })
        }
        try await executor.waitForStarts(cap)
        tasks.append(Task { await coordinator.materialize(request("over-cap.jpg", priority: .background)) })
        try await waitForAdmission(coordinator) { await coordinator.queuedRequestCount() == 1 }
        #expect(await executor.startedNames().sorted() == admitted.sorted())
        try await executor.releaseNext()
        try await executor.waitForStarts(cap + 1)
        #expect(await executor.startedNames().contains("over-cap.jpg"))
        for _ in 0 ..< cap {
            try await executor.releaseNext()
        }
        for task in tasks {
            _ = await task.value
        }
        await coordinator.shutdown()
    }

    /// A Move to Trash download must not queue behind the library's enrichment backlog:
    /// `command` is exempt from the background per-root cap that a background transfer
    /// already holds, and is selected ahead of queued background work.
    @Test func commandIsAdmittedPastTheBackgroundRootCap() async throws {
        let cap = MaterializationAdmissionPolicy.production.backgroundPerRootCap
        let executor = ControlledMaterializationExecutor()
        let coordinator = MaterializationCoordinator(
            store: CatalogStore(location: .inMemory),
            executor: { await executor.run($0.id.fileURL) },
            volumeCapacity: ampleVolumeCapacity
        )
        var tasks: [Task<MaterializationResult, Never>] = []
        for index in 0 ..< cap {
            tasks.append(Task { await coordinator.materialize(request("admitted-\(index).jpg", priority: .background)) })
        }
        try await executor.waitForStarts(cap)
        tasks.append(Task { await coordinator.materialize(request("queued.jpg", priority: .background)) })
        try await waitForAdmission(coordinator) { await coordinator.queuedRequestCount() == 1 }
        tasks.append(Task { await coordinator.materialize(request("trash.jpg", priority: .command)) })
        try await executor.waitForStarts(cap + 1)
        #expect(await executor.startedNames().contains("trash.jpg"))
        #expect(await !(executor.startedNames().contains("queued.jpg")))
        for _ in 0 ..< (cap + 1) {
            try await executor.releaseNext()
        }
        try await executor.waitForStarts(cap + 2)
        try await executor.releaseNext()
        for task in tasks {
            _ = await task.value
        }
        await coordinator.shutdown()
    }

    @Test func commandRunsUnderTheBoundedPersistence() {
        #expect(FileMaterialization.Persistence.forPriority(.command) == .background)
        #expect(FileMaterialization.Persistence.forPriority(.interactive) == .interactive)
    }

    @Test func theLastCommandWaiterLeavingEndsTheTransferAndReleasesAccounting() async throws {
        let executor = HeldInteractiveExecutor()
        let coordinator = MaterializationCoordinator(
            store: CatalogStore(location: .inMemory),
            executor: { await executor.run($0.id.fileURL) },
            volumeCapacity: ampleVolumeCapacity
        )
        await coordinator.start()
        let waiting = Task { await coordinator.materialize(request("trash.jpg", priority: .command)) }
        try await executor.waitForStart()
        #expect(await coordinator.stateSnapshot().inFlight == 1)

        waiting.cancel()
        _ = await waiting.value

        try await waitUntil { await coordinator.stateSnapshot().inFlight == 0 }
        #expect(await coordinator.stateSnapshot().bytes == 0)
        await coordinator.shutdown()
    }

    @Test func backgroundFromAnotherRootUsesAvailableCapacity() async throws {
        var policy = MaterializationAdmissionPolicy.production
        policy.globalConcurrency = 3
        let executor = ControlledMaterializationExecutor()
        let coordinator = MaterializationCoordinator(
            store: CatalogStore(location: .inMemory),
            executor: { await executor.run($0.id.fileURL) },
            volumeCapacity: ampleVolumeCapacity,
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
        try await executor.releaseNext()
        try await executor.releaseNext()
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
            volumeCapacity: ampleVolumeCapacity,
            policy: policy
        )
        let active = Task { await coordinator.materialize(request("active.jpg", priority: .device)) }
        try await executor.waitForStarts(1)
        let queued = Task { await coordinator.materialize(request("cancel.jpg", priority: .background)) }
        try await waitUntil(every: .milliseconds(10)) { await coordinator.queuedRequestCount() >= 1 }
        queued.cancel()
        #expect(await !(queued.value).isMaterialized)
        #expect(await coordinator.queuedRequestCount() == 0)
        try await executor.releaseNext()
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
            volumeCapacity: ampleVolumeCapacity,
            policy: policy,
            diagnosticSink: { diagnostics.record($0) }
        )
        let active = Task { await coordinator.materialize(request("active.jpg", priority: .interactive)) }
        try await executor.waitForStarts(1)
        let queued = Task { await coordinator.materialize(request("queued.jpg", priority: .interactive)) }
        try await waitForAdmission(coordinator) { await coordinator.queuedRequestCount() == 1 }
        #expect(diagnostics.blockedCount() == 1)
        try await executor.releaseNext()
        try await executor.waitForStarts(2)
        try await executor.releaseNext()
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
            volumeCapacity: ampleVolumeCapacity,
            policy: policy
        )
        let background = Task {
            await coordinator.materialize(request("active.jpg", priority: .background))
        }
        try await executor.waitForStarts(1)
        let interactive = Task {
            await coordinator.materialize(request("active.jpg", priority: .interactive))
        }
        try await waitUntil(every: .milliseconds(10)) { await coordinator.stateSnapshot().effectiveInteractive == 1 }
        let device = Task {
            await coordinator.materialize(request("device.jpg", priority: .device))
        }
        try await waitForAdmission(coordinator) { await coordinator.queuedRequestCount() == 1 }
        #expect(await executor.startedNames() == ["active.jpg"])

        interactive.cancel()
        #expect(await !(interactive.value).isMaterialized)
        try await executor.waitForStarts(2)
        #expect(await executor.startedNames() == ["active.jpg", "device.jpg"])

        try await executor.releaseNext()
        try await executor.releaseNext()
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
            volumeCapacity: ampleVolumeCapacity,
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
        try await waitUntil(every: .milliseconds(10)) { await coordinator.queuedRequestCount() >= 1 }
        interactive.cancel()
        #expect(await !(interactive.value).isMaterialized)

        try await executor.releaseNext()
        try await executor.waitForStarts(2)
        try await waitUntil { await coordinator.isQuiescent }
        #expect(await executor.startedNames().count == 2)

        try await executor.releaseNext()
        try await executor.waitForStarts(3)
        #expect(await (executor.startedNames()).last == "restored.jpg")
        try await executor.releaseNext()
        _ = await (first.value, second.value, background.value)
        await coordinator.shutdown()
    }

    // MARK: - Interactive and background admission

    @Test func interactiveJoinBlocksBackgroundWithTruthfulBlockedDiagnostic() async throws {
        var policy = MaterializationAdmissionPolicy.production
        policy.globalConcurrency = 3
        let executor = ControlledMaterializationExecutor()
        let diagnostics = AdmissionDiagnosticRecorder()
        let coordinator = MaterializationCoordinator(
            store: CatalogStore(location: .inMemory),
            executor: { await executor.run($0.id.fileURL) },
            volumeCapacity: ampleVolumeCapacity,
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
        try await waitUntil(every: .milliseconds(10)) { await coordinator.stateSnapshot().effectiveInteractive == 1 }
        let queued = Task {
            await coordinator.materialize(request("queued.jpg", root: "/other-library", priority: .background))
        }
        try await waitForAdmission(coordinator) { await coordinator.queuedRequestCount() >= 1 }
        #expect(diagnostics.blockedCount() >= 1)
        #expect(diagnostics.unblockedCount() == 0)

        interactive.cancel()
        #expect(await !(interactive.value).isMaterialized)
        try await executor.waitForStarts(2)
        #expect(await executor.startedNames() == ["active.jpg", "queued.jpg"])

        try await executor.releaseNext()
        try await executor.releaseNext()
        _ = await (active.value, queued.value)
        #expect(diagnostics.unblockedCount() >= 1)
        await coordinator.shutdown()
    }

    private func request(
        _ name: String,
        root: String = "/library",
        priority: MaterializationCoordinator.Priority,
        sourceSize: Int64 = 1
    ) -> MaterializationCoordinator.Request {
        MaterializationCoordinator.Request(
            id: MediaAssetID(
                libraryRootPath: LibraryRootPath(rawValue: root),
                relativePath: MediaRelativePath(rawValue: name)
            ),
            sourceSize: sourceSize,
            isVideo: false,
            priority: priority
        )
    }

    /// Withdrawal is what makes an interactive transfer safe to run without a deadline.
    ///
    /// Interactive persistence polls until the bytes arrive, so the last waiter leaving is
    /// the only thing that can end it. Without this the poll outlives every consumer and
    /// runs for the life of the process — the hazard the 120 s timeout used to cover by
    /// accident.
    ///
    /// Cancelling must not shortcut the unwind: `finishOperation` is the single owner of
    /// the Store suppression close (ARC-036) and of admission accounting, so the entry has
    /// to survive until the cancelled task reaches it. An earlier draft removed the entry
    /// here instead, which left `inFlightBytes` and `backgroundByRoot` non-zero and tripped
    /// `shutdown()`'s preconditions — a trap that killed the test host and reported as 362
    /// unrelated failures.
    @Test func theLastInteractiveWaiterLeavingEndsTheTransferAndReleasesAccounting() async throws {
        let store = CatalogStore(location: .inMemory)
        let executor = HeldInteractiveExecutor()
        let coordinator = MaterializationCoordinator(
            store: store,
            executor: { await executor.run($0.id.fileURL) },
            volumeCapacity: ampleVolumeCapacity
        )
        await coordinator.start()

        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/library"),
            relativePath: MediaRelativePath(rawValue: "loupe.arw")
        )
        let waiting = Task {
            await coordinator.materialize(
                MaterializationCoordinator.Request(
                    id: id, sourceSize: 4096, isVideo: false, priority: .interactive
                )
            )
        }
        try await executor.waitForStart()
        #expect(await coordinator.stateSnapshot().inFlight == 1)

        waiting.cancel()
        _ = await waiting.value

        try await waitUntil { await coordinator.stateSnapshot().inFlight == 0 }
        let settled = await coordinator.stateSnapshot()
        #expect(settled.waiters == 0)
        #expect(settled.bytes == 0)
        #expect(settled.effectiveInteractive == 0)
        #expect(settled.backgroundByRoot.isEmpty)

        // Passes only because accounting actually reached zero, not because nothing ran.
        await coordinator.shutdown()
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

    func releaseNext() async throws {
        try await waitUntil { !releases.isEmpty }
        releases.removeFirst().resume()
    }

    func waitForStarts(_ count: Int) async throws {
        try await waitUntil { startedCount() >= count }
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

/// Holds a transfer open until cancelled, so the test observes withdrawal rather than a
/// race with a fast completion.
private actor HeldInteractiveExecutor {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run(_: URL) async -> MaterializationResult {
        started = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        await suspendUntilCancelled()
        return .cancelled
    }

    func waitForStart() async throws {
        try await waitUntil { hasStarted() }
    }

    func hasStarted() -> Bool {
        started
    }
}

/// Waits until `registered` holds and admission has run since, so what admission
/// decided about the request — including that it started nothing — is final.
private func waitForAdmission(
    _ coordinator: MaterializationCoordinator,
    after registered: () async -> Bool
) async throws {
    try await waitUntil { await registered() }
    try await waitUntil { await coordinator.isQuiescent }
}
