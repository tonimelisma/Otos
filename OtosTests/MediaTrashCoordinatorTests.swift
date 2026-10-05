import Foundation
@testable import OtosKit
import Synchronization
import Testing

private final class TrashCallRecorder: Sendable {
    private let storage = Mutex<[String]>([])

    func append(_ entry: String) {
        storage.withLock { $0.append(entry) }
    }

    var entries: [String] {
        storage.withLock { $0 }
    }
}

private final class EventRecorder: Sendable {
    private let storage = Mutex<[MediaTrashCoordinator.Event]>([])

    init(_ coordinator: MediaTrashCoordinator) {
        let events = coordinator.events
        Task { [self] in
            for await event in events {
                storage.withLock { $0.append(event) }
            }
        }
    }

    var decisions: [MediaTrashCoordinator.Decision] {
        storage.withLock { events in
            events.compactMap {
                if case let .decision(decision) = $0 {
                    decision
                } else {
                    nil
                }
            }
        }
    }

    var moveFailures: [[MediaAssetID]] {
        storage.withLock { events in
            events.compactMap {
                if case let .moveFailed(ids) = $0 {
                    ids
                } else {
                    nil
                }
            }
        }
    }

    var states: [MediaTrashCoordinator.QueueState] {
        storage.withLock { events in
            events.compactMap {
                if case let .state(state) = $0 {
                    state
                } else {
                    nil
                }
            }
        }
    }
}

/// Mutable per-file "is it local" fact the fake provider flips when it materializes.
private final class LocalFiles: Sendable {
    private let dataless: Mutex<Set<String>>

    init(dataless: Set<String>) {
        self.dataless = Mutex(dataless)
    }

    func status(_ url: URL) -> FileMaterializationStatus {
        dataless.withLock { $0.contains(url.lastPathComponent) } ? .dataless : .materialized
    }

    func materialize(_ name: String) {
        _ = dataless.withLock { $0.remove(name) }
    }
}

private final class FakeRequester: MaterializationRequesting, Sendable {
    private let handler: @Sendable (MaterializationCoordinator.Request) async -> MaterializationResult
    private let priorityStorage = Mutex<[MaterializationCoordinator.Priority]>([])

    init(_ handler: @escaping @Sendable (MaterializationCoordinator.Request) async -> MaterializationResult) {
        self.handler = handler
    }

    func materialize(_ request: MaterializationCoordinator.Request) async -> MaterializationResult {
        priorityStorage.withLock { $0.append(request.priority) }
        return await handler(request)
    }

    func activeRequestCount(under rootPath: LibraryRootPath) async -> Int {
        _ = rootPath
        return 0
    }

    var priorities: [MaterializationCoordinator.Priority] {
        priorityStorage.withLock { $0 }
    }
}

private func result(_ outcome: MaterializationOutcome) -> MaterializationResult {
    MaterializationResult(outcome: outcome, rerequestCount: 0, elapsedMs: 1)
}

private let fastRetry = MediaTrashCoordinator.RetryPolicy(delays: [.milliseconds(20)])

struct MediaTrashCoordinatorTests {
    @Test func pendingItemsAreTrashedCompanionFirstAndTheirRowsLeave() async throws {
        let fixture = try await TrashFixture.make()
        let calls = TrashCallRecorder()
        // The rows leave because the files left: the fake moves each member out of the
        // root, as the Trash does, so the store's reconcile of these paths agrees with
        // the deletion instead of re-cataloging a file that is still there.
        let trash = try makeCatalogStoreTemporaryDirectory()
        let coordinator = MediaTrashCoordinator(
            store: fixture.store,
            materializationRequester: nil,
            trashExecutor: { url in
                calls.append(url.lastPathComponent)
                let destination = trash.appending(path: url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            }
        )
        _ = try await fixture.store.markPendingTrash([fixture.id], batch: MediaTrashBatchID())
        await coordinator.start()

        try await waitUntil { try await fixture.store.pendingTrashItems().isEmpty }
        #expect(calls.entries == ["a.xmp", "a.jpg"])
        #expect(try await fixture.store.mediaAssets(for: [fixture.id]).isEmpty)
        #expect(await fixture.store.hasNamespaceMutationLease(for: fixture.rootPath) == false)
        await coordinator.shutdown()
    }

    @Test func pendingItemsAreHiddenFromMediaQueriesUntilMoved() async throws {
        let fixture = try await TrashFixture.make()
        let hidden = try await fixture.store.markPendingTrash([fixture.id], batch: MediaTrashBatchID())
        #expect(hidden == [fixture.id])
        #expect(try await catalogStoreTestState(fixture.store).testAssets.isEmpty)
        // The file and its row are untouched while pending.
        #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: "a.jpg").path))
        #expect(try await fixture.store.pendingTrashItems().map(\.item.id) == [fixture.id])

        let restored = try await fixture.store.clearPendingTrash([fixture.id])
        #expect(restored == [fixture.id])
        #expect(try await catalogStoreTestState(fixture.store).testAssets.map(\.id) == [fixture.id])
    }

    @Test func aFailedMoveUnhidesTheItemAndReportsIt() async throws {
        let fixture = try await TrashFixture.make()
        let coordinator = MediaTrashCoordinator(
            store: fixture.store,
            materializationRequester: nil,
            trashExecutor: { url in
                if url.pathExtension == "jpg" {
                    throw CocoaError(.fileNoSuchFile)
                }
                return nil
            }
        )
        let events = EventRecorder(coordinator)
        _ = try await fixture.store.markPendingTrash([fixture.id], batch: MediaTrashBatchID())
        await coordinator.start()

        try await waitUntil { events.moveFailures == [[fixture.id]] }
        #expect(try await fixture.store.pendingTrashItems().isEmpty)
        #expect(try await catalogStoreTestState(fixture.store).testAssets.map(\.id) == [fixture.id])
        await coordinator.shutdown()
    }

    @Test func datalessMembersDownloadAtCommandPriorityWithoutHoldingTheLease() async throws {
        let fixture = try await TrashFixture.make()
        let local = LocalFiles(dataless: ["a.jpg", "a.xmp"])
        let leaseHeldDuringDownload = Mutex(false)
        let store = fixture.store
        let rootPath = fixture.rootPath
        let requester = FakeRequester { request in
            if await store.hasNamespaceMutationLease(for: rootPath) {
                leaseHeldDuringDownload.withLock { $0 = true }
            }
            local.materialize(request.id.relativePath.rawValue)
            return result(.materialized)
        }
        let calls = TrashCallRecorder()
        let coordinator = MediaTrashCoordinator(
            store: store,
            materializationRequester: requester,
            status: { local.status($0) },
            trashExecutor: { url in
                calls.append(url.lastPathComponent)
                return nil
            }
        )
        _ = try await store.markPendingTrash([fixture.id], batch: MediaTrashBatchID())
        await coordinator.start()

        try await waitUntil { try await store.pendingTrashItems().isEmpty }
        #expect(requester.priorities == [.command, .command])
        #expect(leaseHeldDuringDownload.withLock { $0 } == false)
        #expect(calls.entries == ["a.xmp", "a.jpg"])
        await coordinator.shutdown()
    }

    @Test func aTransientDownloadFailureStaysPendingAndRetries() async throws {
        let fixture = try await TrashFixture.make()
        let local = LocalFiles(dataless: ["a.jpg"])
        let attempts = Mutex(0)
        let requester = FakeRequester { request in
            let attempt = attempts.withLock { count in
                count += 1
                return count
            }
            guard attempt > 1 else { return result(.timedOut) }
            local.materialize(request.id.relativePath.rawValue)
            return result(.materialized)
        }
        let coordinator = MediaTrashCoordinator(
            store: fixture.store,
            materializationRequester: requester,
            status: { local.status($0) },
            trashExecutor: { _ in nil },
            retryPolicy: fastRetry
        )
        let events = EventRecorder(coordinator)
        _ = try await fixture.store.markPendingTrash([fixture.id], batch: MediaTrashBatchID())
        await coordinator.start()

        try await waitUntil { try await fixture.store.pendingTrashItems().isEmpty }
        #expect(attempts.withLock { $0 } == 2)
        #expect(events.decisions.isEmpty)
        await coordinator.shutdown()
    }

    @Test func aDefinitiveDownloadFailureAsksAndDeleteImmediatelyRemovesTheFiles() async throws {
        let fixture = try await TrashFixture.make()
        let local = LocalFiles(dataless: ["a.jpg"])
        let removed = TrashCallRecorder()
        let trashed = TrashCallRecorder()
        let coordinator = MediaTrashCoordinator(
            store: fixture.store,
            materializationRequester: FakeRequester { _ in result(.requestFailed) },
            status: { local.status($0) },
            trashExecutor: { url in
                trashed.append(url.lastPathComponent)
                return nil
            },
            removeExecutor: { url in removed.append(url.lastPathComponent) }
        )
        let events = EventRecorder(coordinator)
        _ = try await fixture.store.markPendingTrash([fixture.id], batch: MediaTrashBatchID())
        await coordinator.start()

        try await waitUntil { events.decisions == [.downloadFailed([fixture.id])] }
        // Still hidden and untouched while the question is open.
        #expect(try await fixture.store.pendingTrashItems().map(\.item.id) == [fixture.id])
        #expect(removed.entries.isEmpty)

        await coordinator.deleteImmediately([fixture.id])
        #expect(removed.entries == ["a.xmp", "a.jpg"])
        #expect(trashed.entries.isEmpty)
        #expect(try await fixture.store.pendingTrashItems().isEmpty)
        await coordinator.shutdown()
    }

    @Test func restoringAFailedDownloadUnhidesTheItem() async throws {
        let fixture = try await TrashFixture.make()
        let local = LocalFiles(dataless: ["a.jpg"])
        let removed = TrashCallRecorder()
        let coordinator = MediaTrashCoordinator(
            store: fixture.store,
            materializationRequester: FakeRequester { _ in result(.requestFailed) },
            status: { local.status($0) },
            trashExecutor: { _ in nil },
            removeExecutor: { url in removed.append(url.lastPathComponent) }
        )
        let events = EventRecorder(coordinator)
        _ = try await fixture.store.markPendingTrash([fixture.id], batch: MediaTrashBatchID())
        await coordinator.start()
        try await waitUntil { !events.decisions.isEmpty }

        await coordinator.restore([fixture.id])
        #expect(try await fixture.store.pendingTrashItems().isEmpty)
        #expect(try await catalogStoreTestState(fixture.store).testAssets.map(\.id) == [fixture.id])
        #expect(removed.entries.isEmpty)
        await coordinator.shutdown()
    }

    @Test func theDiskFloorAsksOnceAndKeepWaitingDownloadsWhenRoomAppears() async throws {
        let fixture = try await TrashFixture.make(primaryBytes: 1000)
        let local = LocalFiles(dataless: ["a.jpg"])
        let free = Mutex<Int64>(FreeSpaceFloor.bytes)
        let requester = FakeRequester { request in
            local.materialize(request.id.relativePath.rawValue)
            return result(.materialized)
        }
        let coordinator = MediaTrashCoordinator(
            store: fixture.store,
            materializationRequester: requester,
            status: { local.status($0) },
            capacity: { _ in free.withLock { $0 } },
            trashExecutor: { _ in nil },
            retryPolicy: fastRetry
        )
        let events = EventRecorder(coordinator)
        _ = try await fixture.store.markPendingTrash([fixture.id], batch: MediaTrashBatchID())
        await coordinator.start()

        try await waitUntil { events.decisions == [.diskFloor([fixture.id])] }
        #expect(requester.priorities.isEmpty)
        await coordinator.keepWaitingForSpace([fixture.id])
        try await waitUntil {
            events.states.last?.attention == .waitingForSpace
        }
        #expect(events.decisions.count == 1)

        free.withLock { $0 = FreeSpaceFloor.bytes * 2 }
        coordinator.kick()
        try await waitUntil { try await fixture.store.pendingTrashItems().isEmpty }
        #expect(events.decisions.count == 1)
        await coordinator.shutdown()
    }

    @Test func pendingItemsResumeInANewCoordinator() async throws {
        let fixture = try await TrashFixture.make()
        // The intent was recorded by an earlier session whose coordinator never ran.
        _ = try await fixture.store.markPendingTrash([fixture.id], batch: MediaTrashBatchID())
        let calls = TrashCallRecorder()
        let coordinator = MediaTrashCoordinator(
            store: fixture.store,
            materializationRequester: nil,
            trashExecutor: { url in
                calls.append(url.lastPathComponent)
                return nil
            }
        )
        await coordinator.start()
        try await waitUntil { try await fixture.store.pendingTrashItems().isEmpty }
        #expect(calls.entries == ["a.xmp", "a.jpg"])
        await coordinator.shutdown()
    }

    @Test func withdrawingAPendingDownloadUnhidesWithoutTouchingFiles() async throws {
        let fixture = try await TrashFixture.make()
        let local = LocalFiles(dataless: ["a.jpg"])
        let started = Mutex(false)
        let trashed = TrashCallRecorder()
        let requester = FakeRequester { _ in
            started.withLock { $0 = true }
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return .cancelled
            }
            return result(.materialized)
        }
        let coordinator = MediaTrashCoordinator(
            store: fixture.store,
            materializationRequester: requester,
            status: { local.status($0) },
            trashExecutor: { url in
                trashed.append(url.lastPathComponent)
                return nil
            }
        )
        _ = try await fixture.store.markPendingTrash([fixture.id], batch: MediaTrashBatchID())
        await coordinator.start()
        try await waitUntil { started.withLock { $0 } }

        let restored = await coordinator.withdraw([fixture.id])
        #expect(restored == [fixture.id])
        #expect(try await fixture.store.pendingTrashItems().isEmpty)
        #expect(try await catalogStoreTestState(fixture.store).testAssets.map(\.id) == [fixture.id])
        #expect(trashed.entries.isEmpty)
        await coordinator.shutdown()
    }
}

extension MediaTrashCoordinatorTests {
    /// A trash stand-in that really moves files into a scratch folder and reports where,
    /// so undo can be exercised without touching the user's Trash.
    private static func scratchTrash() throws -> (URL, MediaTrashCoordinator.TrashExecutor) {
        let trash = try makeCatalogStoreTemporaryDirectory()
        return (trash, { url in
            let destination = trash.appending(path: UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        })
    }

    @Test func undoPutsATrashedItemBackWithItsCurationChoice() async throws {
        let fixture = try await TrashFixture.make()
        _ = try await fixture.store.setMediaChoice(.liked, for: [fixture.id])
        let (_, executor) = try Self.scratchTrash()
        let coordinator = MediaTrashCoordinator(
            store: fixture.store,
            materializationRequester: nil,
            trashExecutor: executor
        )
        let batch = MediaTrashBatchID()
        _ = try await fixture.store.markPendingTrash([fixture.id], batch: batch)
        await coordinator.start()
        try await waitUntil { try await fixture.store.mediaAssets(for: [fixture.id]).isEmpty }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "a.jpg").path))

        let outcome = await coordinator.undo(batch: batch, ids: [fixture.id])

        #expect(outcome == MediaTrashCoordinator.UndoResult(restored: [fixture.id], failed: []))
        #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: "a.jpg").path))
        #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: "a.xmp").path))
        let restored = try await fixture.store.mediaAssets(for: [fixture.id])
        #expect(restored[fixture.id]?.mediaChoice == .liked)
        #expect(try await catalogStoreTestState(fixture.store).testAssets.map(\.id) == [fixture.id])
        await coordinator.shutdown()
    }

    @Test func undoOfAStillPendingItemWithdrawsIt() async throws {
        let fixture = try await TrashFixture.make()
        let local = LocalFiles(dataless: ["a.jpg"])
        let coordinator = MediaTrashCoordinator(
            store: fixture.store,
            materializationRequester: FakeRequester { _ in
                do { try await Task.sleep(for: .seconds(60)) } catch { return .cancelled }
                return result(.materialized)
            },
            status: { local.status($0) },
            trashExecutor: { _ in nil }
        )
        let batch = MediaTrashBatchID()
        _ = try await fixture.store.markPendingTrash([fixture.id], batch: batch)
        await coordinator.start()

        let outcome = await coordinator.undo(batch: batch, ids: [fixture.id])
        #expect(outcome.restored == [fixture.id])
        #expect(try await fixture.store.pendingTrashItems().isEmpty)
        await coordinator.shutdown()
    }

    @Test func undoNeverOverwritesAFileThatNowHasThePath() async throws {
        let fixture = try await TrashFixture.make()
        let (_, executor) = try Self.scratchTrash()
        let coordinator = MediaTrashCoordinator(
            store: fixture.store,
            materializationRequester: nil,
            trashExecutor: executor
        )
        let batch = MediaTrashBatchID()
        _ = try await fixture.store.markPendingTrash([fixture.id], batch: batch)
        await coordinator.start()
        try await waitUntil { try await fixture.store.mediaAssets(for: [fixture.id]).isEmpty }
        try writeCatalogStoreFile(fixture.root.appending(path: "a.jpg"), contents: "newer")

        let outcome = await coordinator.undo(batch: batch, ids: [fixture.id])

        #expect(outcome.failed == [fixture.id])
        #expect(try Data(contentsOf: fixture.root.appending(path: "a.jpg")) == Data("newer".utf8))
        await coordinator.shutdown()
    }
}

extension MediaTrashCoordinatorTests {
    /// Relaunch: a fresh Store on the same catalog file, not yet started by anyone, and a
    /// coordinator that starts first. The pending intent must still be found and drained.
    @Test func pendingItemsResumeBeforeTheCatalogIsStartedElsewhere() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "a.jpg"), contents: "jpeg")
        let database = temp.appending(path: "catalog.sqlite")

        let first = CatalogStore(location: .databaseFile(database), scanCadence: .milliseconds(10))
        try await first.start(scansSavedLibraries: false)
        try await first.addLibrary(url: root)
        let scanned = try await waitForCatalogStoreState(first) { !$0.isScanning && $0.testAssets.count == 1 }
        let id = try #require(scanned.testAssets.first?.id)
        _ = try await first.markPendingTrash([id], batch: MediaTrashBatchID())
        await first.shutdown()

        let relaunched = CatalogStore(location: .databaseFile(database), scanCadence: .milliseconds(10))
        let calls = TrashCallRecorder()
        let coordinator = MediaTrashCoordinator(
            store: relaunched,
            materializationRequester: nil,
            trashExecutor: { url in
                calls.append(url.lastPathComponent)
                return nil
            }
        )
        await coordinator.start()
        try await waitUntil { calls.entries == ["a.jpg"] }
        await coordinator.shutdown()
        await relaunched.shutdown()
    }

    @Test func downloadBytesCountOnlyCloudOnlyMembers() async throws {
        let fixture = try await TrashFixture.make(primaryBytes: 1000)
        let local = LocalFiles(dataless: ["a.jpg"])
        let coordinator = MediaTrashCoordinator(
            store: fixture.store,
            materializationRequester: nil,
            status: { local.status($0) }
        )
        #expect(await coordinator.downloadBytes(for: [fixture.id]) == 1000)
        local.materialize("a.jpg")
        #expect(await coordinator.downloadBytes(for: [fixture.id]) == 0)
    }
}

private struct TrashFixture {
    let store: CatalogStore
    let root: URL
    let rootPath: LibraryRootPath
    let id: MediaAssetID

    static func make(primaryBytes: Int = 4) async throws -> TrashFixture {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "a.jpg"), contents: String(repeating: "j", count: primaryBytes))
        try writeCatalogStoreFile(root.appending(path: "a.xmp"), contents: "sidecar")

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        let id = try #require(scanned.testAssets.first?.id)
        let items = try await store.mediaTrashItems(for: [id])
        #expect(items.first?.members.map(\.role) == [.companion, .primary])
        return TrashFixture(store: store, root: root, rootPath: id.libraryRootPath, id: id)
    }
}
