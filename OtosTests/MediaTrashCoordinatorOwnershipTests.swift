import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// The trash queue works from a snapshot of pending items across awaits, and reads the Store
/// to decide what it publishes. These pin the rules that keep that honest: a failed read
/// publishes nothing, an item the user took back is never moved, and an unreadable overlay
/// defers a move instead of losing the user's choice.
@Suite(.testScope)
struct MediaTrashCoordinatorOwnershipTests {
    private struct InjectedReadFailure: Error {}

    private static let retry = MediaTrashCoordinator.RetryPolicy(delays: [.milliseconds(20)])

    private final class Log: Sendable {
        private let storage = Mutex<[String]>([])

        func append(_ entry: String) {
            storage.withLock { $0.append(entry) }
        }

        var entries: [String] {
            storage.withLock { $0 }
        }
    }

    private final class StateLog: Sendable {
        private let storage = Mutex<[MediaTrashCoordinator.QueueState]>([])

        init(_ coordinator: MediaTrashCoordinator) {
            let events = coordinator.events
            Task { [self] in
                for await event in events {
                    if case let .state(state) = event {
                        storage.withLock { $0.append(state) }
                    }
                }
            }
        }

        var states: [MediaTrashCoordinator.QueueState] {
            storage.withLock { $0 }
        }
    }

    /// How a hook the coordinator holds reaches that coordinator. The reference is weak: a
    /// strong one closes a cycle (coordinator → hook → reference → coordinator) that keeps the
    /// queue, its finished drain task and every task the hook made in the test host for the
    /// rest of the run, where `swift-inspect dump-concurrency` lists them with the backtrace
    /// of their last suspension, as if they were still parked.
    private struct CoordinatorReference {
        weak var coordinator: MediaTrashCoordinator?
    }

    private struct Fixture {
        let store: CatalogStore
        let root: URL
        let ids: [MediaAssetID]
        let trash: URL

        static func make(names: [String]) async throws -> Fixture {
            let temp = try makeTestDirectory()
            let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
            let trash = temp.appending(path: "Trash", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            for name in names {
                try writeCatalogStoreFile(root.appending(path: name), contents: "jpeg")
            }
            let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
            try await store.start(scansSavedLibraries: false)
            try await store.addLibrary(url: root)
            let scanned = try await waitForCatalogStoreState(store) {
                !$0.isScanning && $0.testAssets.count == names.count
            }
            return Fixture(store: store, root: root, ids: scanned.testAssets.map(\.id).sorted {
                $0.relativePath.rawValue < $1.relativePath.rawValue
            }, trash: trash)
        }

        /// Moves the file into a stand-in Trash, as the system does.
        func trashing(_ log: Log) -> MediaTrashCoordinator.TrashExecutor {
            { [trash] url in
                log.append("trash \(url.lastPathComponent)")
                let destination = trash.appending(path: url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            }
        }
    }

    // Validates: ARC-058
    /// A failing read must not turn into an empty queue. The item is mid-download, so the
    /// bar says one item is pending; two failed reads in a row must leave that standing.
    @Test func aFailedPendingReadPublishesNothingAndTheNextWakeRetries() async throws {
        let fixture = try await Fixture.make(names: ["a.jpg"])
        let failuresLeft = Mutex(0)
        let successfulReadsSinceFailure = Mutex(0)
        let store = fixture.store
        let reads = MediaTrashCoordinator.StoreReads(
            pendingItems: {
                let fail = failuresLeft.withLock { left in
                    if left > 0 {
                        left -= 1
                        return true
                    }
                    return false
                }
                if fail {
                    throw InjectedReadFailure()
                }
                successfulReadsSinceFailure.withLock { $0 += 1 }
                return try await store.windowReads.pendingTrashItems()
            },
            trashItems: { try await store.windowReads.mediaTrashItems(for: $0) }
        )
        // The file is cloud-only and its download never finishes, so the item stays pending.
        let coordinator = MediaTrashCoordinator(
            store: store,
            materializationRequester: ClosureMaterializationRequester { _ in
                await suspendUntilCancelled()
                return MaterializationResult(outcome: .cancelled, rerequestCount: 0, elapsedMs: 0)
            },
            files: .refusing,
            status: { _ in .dataless },
            volumeCapacity: ampleVolumeCapacity,
            retryPolicy: Self.retry,
            reads: reads
        )
        let stateLog = StateLog(coordinator)
        _ = try await fixture.store.markPendingTrash([fixture.ids[0]], batch: MediaTrashBatchID())
        await coordinator.start()
        try await waitUntil { stateLog.states.last?.pendingCount == 1 }

        failuresLeft.withLock { $0 = 2 }
        successfulReadsSinceFailure.withLock { $0 = 0 }
        try await waitUntil {
            coordinator.kick()
            return failuresLeft.withLock { $0 } == 0 && successfulReadsSinceFailure.withLock { $0 } >= 1
        }

        #expect(!stateLog.states.contains { $0.pendingCount == 0 })
        await coordinator.shutdown()
    }

    // Validates: ARC-058
    /// Shutdown lands while a pass is suspended in its pending-item read, after shutdown has
    /// already cancelled the download in flight and that download has cleared its slot. The
    /// pass then resumes holding a snapshot in which the item looks un-downloaded; it must not
    /// start a download that shutdown will never cancel or await.
    @Test func aPassSuspendedWhenShutdownLandsStartsNoDownloadThatOutlivesIt() async throws {
        let released = try await passSuspendedWhenShutdownLands()
        // Once the test lets go of the queue, nothing it made holds it: not its hooks, not the
        // shutdown task a hook started.
        #expect(released.coordinator == nil)
    }

    private func passSuspendedWhenShutdownLands() async throws -> CoordinatorReference {
        let fixture = try await Fixture.make(names: ["a.jpg"])
        let store = fixture.store
        let box = Mutex(CoordinatorReference())
        let started = Mutex(0)
        let returned = Mutex(0)
        let startedAfterShutdown = Mutex(0)
        let shutdownBegun = Mutex(false)
        let armed = Mutex(false)
        let shutdownTask = Mutex<Task<Void, Never>?>(nil)
        let firstDownloadEnded = ReleaseSignal()
        let reads = MediaTrashCoordinator.StoreReads(
            pendingItems: {
                let deliver = armed.withLock { isArmed in
                    defer { isArmed = false }
                    return isArmed
                }
                let items = try await store.windowReads.pendingTrashItems()
                if deliver, let coordinator = box.withLock({ $0.coordinator }) {
                    shutdownBegun.withLock { $0 = true }
                    shutdownTask.withLock { $0 = Task { await coordinator.shutdown() } }
                    // Shutdown has cancelled the download and it has ended: the snapshot
                    // this read returns is now stale about it.
                    await firstDownloadEnded.wait()
                }
                return items
            },
            trashItems: { try await store.windowReads.mediaTrashItems(for: $0) }
        )
        let coordinator = MediaTrashCoordinator(
            store: store,
            materializationRequester: ClosureMaterializationRequester { _ in
                started.withLock { $0 += 1 }
                if shutdownBegun.withLock({ $0 }) {
                    startedAfterShutdown.withLock { $0 += 1 }
                }
                await suspendUntilCancelled()
                returned.withLock { $0 += 1 }
                await firstDownloadEnded.release()
                return MaterializationResult(outcome: .cancelled, rerequestCount: 0, elapsedMs: 0)
            },
            files: .refusing,
            status: { _ in .dataless },
            volumeCapacity: ampleVolumeCapacity,
            retryPolicy: Self.retry,
            reads: reads
        )
        box.withLock { $0.coordinator = coordinator }
        let stateLog = StateLog(coordinator)
        _ = try await store.markPendingTrash([fixture.ids[0]], batch: MediaTrashBatchID())
        await coordinator.start()
        // The first pass started the download and published its state, so the next read
        // belongs to the pass the kick below starts.
        try await waitUntil { started.withLock { $0 } == 1 && stateLog.states.last?.pendingCount == 1 }

        armed.withLock { $0 = true }
        coordinator.kick()
        try await waitUntil { shutdownTask.withLock { $0 } != nil }
        await shutdownTask.withLock { $0 }?.value

        #expect(startedAfterShutdown.withLock { $0 } == 0)
        #expect(started.withLock { $0 } == returned.withLock { $0 })
        return box.withLock { $0 }
    }

    // Validates: ARC-058
    /// The user takes an item back while a pass is partway through its snapshot: the pass
    /// must skip it. The hook delivers `restore` at exactly the suspension a real answer
    /// could land in.
    @Test func anItemTheUserTookBackDuringAPassIsNeverMoved() async throws {
        let fixture = try await Fixture.make(names: ["a.jpg", "b.jpg"])
        let log = Log()
        let box = Mutex(CoordinatorReference())
        let handled = Mutex<[MediaAssetID]>([])
        let ids = fixture.ids
        let coordinator = MediaTrashCoordinator(
            store: fixture.store,
            materializationRequester: nil,
            files: .testing(trash: fixture.trashing(log)),
            volumeCapacity: ampleVolumeCapacity,
            retryPolicy: Self.retry,
            willHandleItem: { id in
                let isFirst = handled.withLock { seen in
                    seen.append(id)
                    return seen.count == 1
                }
                guard isFirst, let other = ids.first(where: { $0 != id }),
                      let coordinator = box.withLock({ $0.coordinator })
                else {
                    return
                }
                await coordinator.restore([other])
            }
        )
        box.withLock { $0.coordinator = coordinator }
        _ = try await fixture.store.markPendingTrash(fixture.ids, batch: MediaTrashBatchID())
        await coordinator.start()

        try await waitUntil { try await fixture.store.windowReads.pendingTrashItems().isEmpty }
        try await waitUntil { log.entries.count >= 1 }

        let first = try #require(handled.withLock { $0.first })
        let other = try #require(ids.first { $0 != first })
        #expect(log.entries == ["trash \(first.relativePath.rawValue)"])
        #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: other.relativePath.rawValue).path))
        #expect(try await fixture.store.windowReads.mediaAssets(for: [other]).keys.contains(other))
        await coordinator.shutdown()
    }

    // Validates: ARC-058
    @Test func aDownloadSizeThatCannotBeReadIsUnknownNotZero() async throws {
        let fixture = try await Fixture.make(names: ["a.jpg"])
        let store = fixture.store
        let reads = MediaTrashCoordinator.StoreReads(
            pendingItems: { try await store.windowReads.pendingTrashItems() },
            trashItems: { _ in throw InjectedReadFailure() }
        )
        // The file is cloud-only, so its size is read from the catalog, and that read fails.
        let coordinator = MediaTrashCoordinator(
            store: store,
            materializationRequester: nil,
            files: .refusing,
            status: { _ in .dataless },
            volumeCapacity: ampleVolumeCapacity,
            reads: reads
        )

        #expect(await coordinator.downloadBytes(for: fixture.ids) == nil)
        await coordinator.shutdown()
    }

    // Validates: APP-045, APP-085
    /// A command whose files are all local is sized from their own flags: the catalog is not
    /// read, so the common Move to Trash never waits on it (APP-045).
    @Test func aLocalCommandIsSizedWithoutReadingTheCatalog() async throws {
        let fixture = try await Fixture.make(names: ["a.jpg"])
        let store = fixture.store
        let reads = MediaTrashCoordinator.StoreReads(
            pendingItems: { try await store.windowReads.pendingTrashItems() },
            trashItems: { _ in throw InjectedReadFailure() }
        )
        let coordinator = MediaTrashCoordinator(
            store: store,
            materializationRequester: nil,
            files: .refusing,
            status: { _ in .materialized },
            volumeCapacity: ampleVolumeCapacity,
            reads: reads
        )

        #expect(await coordinator.downloadBytes(for: fixture.ids) == .zero)
        await coordinator.shutdown()
    }
}
