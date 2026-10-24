import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// The trash queue works from a snapshot of pending items across awaits, and reads the Store
/// to decide what it publishes. These pin the rules that keep that honest: a failed read
/// publishes nothing, an item the user took back is never moved, and an unreadable overlay
/// defers a move instead of losing the user's choice.
@Suite(.testDirectory)
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
            let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
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
                return try await store.pendingTrashItems()
            },
            trashedOverlay: { try await store.trashedOverlay(for: $0) },
            trashItems: { try await store.mediaTrashItems(for: $0) }
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

    /// The user takes an item back while a pass is partway through its snapshot: the pass
    /// must skip it. The hook delivers `restore` at exactly the suspension a real answer
    /// could land in.
    @Test func anItemTheUserTookBackDuringAPassIsNeverMoved() async throws {
        let fixture = try await Fixture.make(names: ["a.jpg", "b.jpg"])
        let log = Log()
        let box = Mutex<MediaTrashCoordinator?>(nil)
        let handled = Mutex<[MediaAssetID]>([])
        let ids = fixture.ids
        let coordinator = MediaTrashCoordinator(
            store: fixture.store,
            materializationRequester: nil,
            files: .testing(trash: fixture.trashing(log)),
            retryPolicy: Self.retry,
            willHandleItem: { id in
                let isFirst = handled.withLock { seen in
                    seen.append(id)
                    return seen.count == 1
                }
                guard isFirst, let other = ids.first(where: { $0 != id }),
                      let coordinator = box.withLock({ $0 })
                else {
                    return
                }
                await coordinator.restore([other])
            }
        )
        box.withLock { $0 = coordinator }
        _ = try await fixture.store.markPendingTrash(fixture.ids, batch: MediaTrashBatchID())
        await coordinator.start()

        try await waitUntil { try await fixture.store.pendingTrashItems().isEmpty }
        try await waitUntil { log.entries.count >= 1 }

        let first = try #require(handled.withLock { $0.first })
        let other = try #require(ids.first { $0 != first })
        #expect(log.entries == ["trash \(first.relativePath.rawValue)"])
        #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: other.relativePath.rawValue).path))
        #expect(try await fixture.store.mediaAssets(for: [other]).keys.contains(other))
        await coordinator.shutdown()
    }

    /// Undo puts back the choice an item had. If the overlay cannot be read, the item is not
    /// moved yet: moving it would lose the choice for good.
    @Test func anUnreadableOverlayDefersTheMoveInsteadOfLosingTheChoice() async throws {
        let fixture = try await Fixture.make(names: ["a.jpg"])
        let log = Log()
        let overlayReads = Mutex(0)
        let store = fixture.store
        let reads = MediaTrashCoordinator.StoreReads(
            pendingItems: { try await store.pendingTrashItems() },
            trashedOverlay: { ids in
                let attempt = overlayReads.withLock { count in
                    count += 1
                    return count
                }
                if attempt == 1 {
                    log.append("overlay#1 failed")
                    throw InjectedReadFailure()
                }
                log.append("overlay#\(attempt) ok")
                return try await store.trashedOverlay(for: ids)
            },
            trashItems: { try await store.mediaTrashItems(for: $0) }
        )
        let coordinator = MediaTrashCoordinator(
            store: store,
            materializationRequester: nil,
            files: .testing(trash: fixture.trashing(log)),
            retryPolicy: Self.retry,
            reads: reads
        )
        _ = try await fixture.store.markPendingTrash([fixture.ids[0]], batch: MediaTrashBatchID())
        await coordinator.start()

        try await waitUntil { try await fixture.store.pendingTrashItems().isEmpty }

        #expect(log.entries == ["overlay#1 failed", "overlay#2 ok", "trash a.jpg"])
        await coordinator.shutdown()
    }

    @Test func aDownloadSizeThatCannotBeReadIsUnknownNotZero() async throws {
        let fixture = try await Fixture.make(names: ["a.jpg"])
        let store = fixture.store
        let reads = MediaTrashCoordinator.StoreReads(
            pendingItems: { try await store.pendingTrashItems() },
            trashedOverlay: { try await store.trashedOverlay(for: $0) },
            trashItems: { _ in throw InjectedReadFailure() }
        )
        let coordinator = MediaTrashCoordinator(
            store: store,
            materializationRequester: nil,
            files: .refusing,
            reads: reads
        )

        #expect(await coordinator.downloadBytes(for: fixture.ids) == nil)
        await coordinator.shutdown()
    }
}
