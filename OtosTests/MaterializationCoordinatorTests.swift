import Foundation
@testable import OtosKit
import Synchronization
import Testing

@Suite(.testScope)
struct MaterializationCoordinatorTests {
    /// ADR 0046 §4: an in-place original's locality is its `SF_DATALESS` status; a staged
    /// root's file absent from its staging folder is one its source has yet to send.
    @Test func localityReadsAStagedRootsAbsentFileAsFetchable() {
        #expect(OriginalLocality.of(kind: .library, status: .materialized) == .local)
        #expect(OriginalLocality.of(kind: .library, status: .dataless) == .fetchable)
        #expect(OriginalLocality.of(kind: .library, status: .unknown) == .unreachable)
        #expect(OriginalLocality.of(kind: nil, status: .dataless) == .fetchable)
        #expect(OriginalLocality.of(kind: .deviceMTP, status: .materialized) == .local)
        #expect(OriginalLocality.of(kind: .deviceMTP, status: .unknown) == .fetchable)
        #expect(OriginalLocality.of(kind: .deviceMTP, status: .dataless) == .fetchable)
    }

    /// An Immich account sends an original only for the user's work (ADR 0046 §4), so its
    /// locality says so, and only user work may fetch it: background and device work never
    /// ask its source, so it never refuses them.
    @Test func anAccountsUnstagedOriginalIsFetchableOnlyForUserWork() {
        let locality = OriginalLocality.of(kind: .immichAccount, status: .unknown)
        #expect(locality == .fetchableForUserWork)
        #expect(OriginalLocality.of(kind: .immichAccount, status: .materialized) == .local)
        #expect(locality.isFetchable(at: .interactive))
        #expect(locality.isFetchable(at: .command))
        #expect(!locality.isFetchable(at: .background))
        #expect(!locality.isFetchable(at: .device))
        #expect(OriginalLocality.fetchable.isFetchable(at: .background))
    }

    /// Background work that asks to make an account's original local is answered without a
    /// request: nothing is dispatched, so nothing is refused or logged as failed.
    @Test func ensureLocalAsksNothingOfAnAccountForBackgroundWork() async {
        let requester = UserWorkOnlyRequester()
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Account"),
            relativePath: MediaRelativePath(rawValue: "asset/clip.mp4")
        )
        let outcome = await requester.ensureLocal(.init(id: id, sourceSize: 10, isVideo: true, priority: .background))
        #expect(outcome == .userWorkOnly)
        #expect(requester.requests.withLock { $0 } == 0)
        _ = await requester.ensureLocal(.init(id: id, sourceSize: 10, isVideo: true, priority: .interactive))
        #expect(requester.requests.withLock { $0 } == 1)
    }

    /// The coordinator answers a folder's file from its own detector: a dataless file is
    /// fetchable, never local, and only a materialized one is local.
    @Test func aDatalessFolderFileIsFetchableNotLocal() async {
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Library/Root"),
            relativePath: MediaRelativePath(rawValue: "cloud.jpg")
        )
        for (status, locality) in [(FileMaterializationStatus.dataless, OriginalLocality.fetchable), (.materialized, .local)] {
            let coordinator = MaterializationCoordinator(
                store: makeTestStore(location: .inMemory),
                executor: { _ in .cancelled },
                volumeCapacity: { _ in nil },
                status: { _ in status }
            )
            #expect(await coordinator.locality(of: id) == locality)
        }
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
            store: makeTestStore(location: .inMemory),
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

    /// ADR 0027: a download that found its file already local wrote nothing, so the room
    /// it was committed is given back while other downloads are still in flight; only the
    /// bytes a download landed stay counted.
    @Test func aFileAlreadyLocalGivesItsRoomBackWhileOthersAreInFlight() async throws {
        let held = HeldInteractiveExecutor()
        let coordinator = MaterializationCoordinator(
            store: makeTestStore(location: .inMemory),
            executor: { request in
                switch request.id.relativePath.rawValue {
                case "held.jpg":
                    await held.run(request.id.fileURL)
                case "local.jpg":
                    MaterializationResult(outcome: .alreadyMaterialized, rerequestCount: 0, elapsedMs: 0)
                default:
                    MaterializationResult(outcome: .materialized, rerequestCount: 0, elapsedMs: 0)
                }
            },
            volumeCapacity: { _ in FreeSpaceFloor.bytes + 2500 }
        )
        await coordinator.start()
        let holding = Task {
            await coordinator.materialize(request("held.jpg", root: "/other", priority: .background, sourceSize: 500))
        }
        try await held.waitForStart()

        let local = await coordinator.materialize(request("local.jpg", priority: .background, sourceSize: 1000))
        #expect(local.outcome == .alreadyMaterialized)
        // 2500 free, 500 in flight: 2000 left for this one only if the local file's 1000
        // came back.
        let next = await coordinator.materialize(request("next.jpg", priority: .background, sourceSize: 1500))
        #expect(next.outcome == .materialized)

        await coordinator.shutdown()
        _ = await holding.value
    }

    /// ENR-008: a command (Move to Trash's download) runs under the bounded background
    /// persistence, through the executor the app gives the coordinator for a folder's file:
    /// a provider that refuses twice in a row ends it as `providerUnavailable`, where an
    /// interactive wait would keep going (`FileMaterializationTests`).
    @Test func aCommandRunsUnderTheBoundedBackgroundPersistence() async {
        let refusing = FileMaterializationProviders(
            status: { _ in .dataless },
            request: { _ in },
            probe: { _ async in .providerUnavailable },
            changes: { _ in AsyncStream { $0.finish() } }
        )
        let coordinator = MaterializationCoordinator(
            store: makeTestStore(location: .inMemory),
            executor: { await FileMaterialization.materialize($0, providers: refusing) },
            volumeCapacity: ampleVolumeCapacity
        )
        await coordinator.start()
        let result = await coordinator.materialize(request("trash.jpg", priority: .command))
        #expect(result.outcome == .providerUnavailable)
        await coordinator.shutdown()
    }

    @Test func sameIDRequestsShareOnePhysicalTransfer() async throws {
        let executor = ControlledMaterializationExecutor()
        let coordinator = MaterializationCoordinator(
            store: makeTestStore(location: .inMemory),
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
            store: makeTestStore(location: .inMemory),
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
            store: makeTestStore(location: .inMemory),
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
            store: makeTestStore(location: .inMemory),
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

    @Test func backgroundIsLimitedToTheRootCap() async throws {
        let cap = MaterializationAdmissionPolicy.production.backgroundPerRootCap
        let executor = ControlledMaterializationExecutor()
        let coordinator = MaterializationCoordinator(
            store: makeTestStore(location: .inMemory),
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
            store: makeTestStore(location: .inMemory),
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

    @Test func backgroundFromAnotherRootUsesAvailableCapacity() async throws {
        var policy = MaterializationAdmissionPolicy.production
        policy.globalConcurrency = 3
        let executor = ControlledMaterializationExecutor()
        let coordinator = MaterializationCoordinator(
            store: makeTestStore(location: .inMemory),
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
            store: makeTestStore(location: .inMemory),
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

    @Test func interactiveJoinBlocksLowerPriorityUntilItsWaiterCancels() async throws {
        var policy = MaterializationAdmissionPolicy.production
        policy.globalConcurrency = 3
        let executor = ControlledMaterializationExecutor()
        let coordinator = MaterializationCoordinator(
            store: makeTestStore(location: .inMemory),
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
            store: makeTestStore(location: .inMemory),
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

    /// ADR 0057: while the background room holds downloads, a background download waits,
    /// the owner's status names the hold, and the photo on screen does not wait; the waiting
    /// download starts once, in the step that opens the room.
    @Test func aBackgroundDownloadWaitsForTheRoomAndTheOnScreenOneDoesNot() async throws {
        let room = BackgroundRoom(conditions: MachineConditions(memory: .warning, thermal: .nominal, lowPower: false, userInApp: false))
        let started = Mutex<[String]>([])
        let coordinator = MaterializationCoordinator(
            store: makeTestStore(location: .inMemory),
            executor: { request in
                started.withLock { $0.append(request.id.relativePath.rawValue) }
                return MaterializationResult(outcome: .materialized, rerequestCount: 0, elapsedMs: 0)
            },
            volumeCapacity: { _ in nil },
            room: room
        )
        let background = Task { await coordinator.materialize(request("backlog.jpg", priority: .background)) }
        try await waitUntil { await coordinator.status.heldBy == OwnerHold(.memoryWarning) }
        #expect(await coordinator.materialize(request("on-screen.jpg", priority: .interactive)).isMaterialized)
        #expect(started.withLock { $0 } == ["on-screen.jpg"])

        room.deliver(.roomy)
        #expect(await background.value.isMaterialized)
        #expect(started.withLock { $0 } == ["on-screen.jpg", "backlog.jpg"])
        #expect(await coordinator.status.heldBy == nil)
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
    ///
    /// A command transfer (ENR-008) stops the same way: no on-screen demand outlives it, and
    /// a Move to Trash cancelled before its download lands leaves nothing running.
    @Test(arguments: [MaterializationCoordinator.Priority.interactive, .command])
    func theLastWaiterLeavingEndsTheTransferAndReleasesAccounting(priority: MaterializationCoordinator.Priority) async throws {
        let store = makeTestStore(location: .inMemory)
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
                    id: id, sourceSize: 4096, isVideo: false, priority: priority
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

/// A requester whose originals are an account's: fetchable for the user's work only. It
/// counts the transfers asked of it and never makes one land.
private final nonisolated class UserWorkOnlyRequester: MaterializationRequesting {
    let requests = Mutex(0)

    func materialize(_: MaterializationCoordinator.Request) async -> MaterializationResult {
        requests.withLock { $0 += 1 }
        return MaterializationResult(outcome: .requestFailed, rerequestCount: 0, elapsedMs: 0)
    }

    func locality(of _: MediaAssetID) async -> OriginalLocality {
        .fetchableForUserWork
    }
}
