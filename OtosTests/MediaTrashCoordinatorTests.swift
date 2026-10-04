import Foundation
@testable import OtosKit
import Synchronization
import Testing

private final class TrashCallRecorder: Sendable {
    private let storage = Mutex<[String]>([])

    func append(_ path: String) {
        storage.withLock { $0.append(path) }
    }

    var paths: [String] {
        storage.withLock { $0 }
    }
}

struct MediaTrashCoordinatorTests {
    @Test func movesCatalogedCompanionBeforePrimaryAndReportsPartialFailure() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "a.jpg"), contents: "jpeg")
        try writeCatalogStoreFile(root.appending(path: "a.xmp"), contents: "sidecar")

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        let id = try #require(scanned.testAssets.first?.id)
        let items = try await store.mediaTrashItems(for: [id])
        let item = try #require(items.first)
        #expect(item.members.map(\.role) == [.companion, .primary])

        let recorder = TrashCallRecorder()
        let coordinator = MediaTrashCoordinator(
            store: store,
            materializationRequester: nil,
            trashExecutor: { url in
                recorder.append(url.lastPathComponent)
                if url.pathExtension.lowercased() == "jpg" {
                    throw CocoaError(.fileNoSuchFile)
                }
            }
        )
        let result = await coordinator.moveToTrash(items)

        #expect(recorder.paths == ["a.xmp", "a.jpg"])
        #expect(result.successfulPaths.map(\.relativePath.rawValue) == ["a.xmp"])
        #expect(result.failedItems.map(\.id) == [id])
        #expect(result.movedItemCount == 0)
        #expect(await store.hasNamespaceMutationLease(for: item.root.path) == false)
    }

    @Test func datalessMembersMaterializeInteractivelyBeforeEachTrash() async throws {
        let (store, item) = try await makeCatalogedPairWithCompanion()
        let events = TrashCallRecorder()
        let local = Mutex<Set<String>>([])
        let requester = TrashMaterializationRecorder(events: events) { request in
            local.withLock { _ = $0.insert(request.id.relativePath.rawValue) }
            return MaterializationResult(outcome: .materialized, rerequestCount: 0, elapsedMs: 1)
        }
        let coordinator = MediaTrashCoordinator(
            store: store,
            materializationRequester: requester,
            status: { url in
                local.withLock { $0.contains(url.lastPathComponent) } ? .materialized : .dataless
            },
            trashExecutor: { url in events.append("trash \(url.lastPathComponent)") }
        )

        let result = await coordinator.moveToTrash([item])

        #expect(events.paths == ["materialize a.xmp", "trash a.xmp", "materialize a.jpg", "trash a.jpg"])
        #expect(requester.priorities == [.interactive, .interactive])
        #expect(result.failedItems.isEmpty)
        #expect(result.movedItemCount == 1)
        #expect(await store.hasNamespaceMutationLease(for: item.root.path) == false)
    }

    @Test func memberThatStaysDatalessFailsWithoutTrashCall() async throws {
        let (store, item) = try await makeCatalogedPairWithCompanion()
        let events = TrashCallRecorder()
        let requester = TrashMaterializationRecorder(events: events) { _ in
            MaterializationResult(outcome: .timedOut, rerequestCount: 3, elapsedMs: 120_000)
        }
        let coordinator = MediaTrashCoordinator(
            store: store,
            materializationRequester: requester,
            status: { url in url.pathExtension == "jpg" ? .dataless : .materialized },
            trashExecutor: { url in events.append("trash \(url.lastPathComponent)") }
        )

        let result = await coordinator.moveToTrash([item])

        #expect(events.paths == ["trash a.xmp", "materialize a.jpg"])
        #expect(result.successfulPaths.map(\.relativePath.rawValue) == ["a.xmp"])
        #expect(result.failedItems.map(\.id) == [item.id])
        #expect(result.movedItemCount == 0)
        #expect(await store.hasNamespaceMutationLease(for: item.root.path) == false)
    }

    private func makeCatalogedPairWithCompanion() async throws -> (CatalogStore, MediaTrashItem) {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "a.jpg"), contents: "jpeg")
        try writeCatalogStoreFile(root.appending(path: "a.xmp"), contents: "sidecar")

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        let id = try #require(scanned.testAssets.first?.id)
        let item = try #require(try await store.mediaTrashItems(for: [id]).first)
        return (store, item)
    }
}

private final class TrashMaterializationRecorder: MaterializationRequesting, Sendable {
    private let events: TrashCallRecorder
    private let priorityStorage = Mutex<[MaterializationCoordinator.Priority]>([])
    private let result: @Sendable (MaterializationCoordinator.Request) -> MaterializationResult

    init(
        events: TrashCallRecorder,
        result: @escaping @Sendable (MaterializationCoordinator.Request) -> MaterializationResult
    ) {
        self.events = events
        self.result = result
    }

    func materialize(_ request: MaterializationCoordinator.Request) async -> MaterializationResult {
        events.append("materialize \(request.id.relativePath.rawValue)")
        priorityStorage.withLock { $0.append(request.priority) }
        return result(request)
    }

    func activeRequestCount(under rootPath: LibraryRootPath) async -> Int {
        _ = rootPath
        return 0
    }

    var priorities: [MaterializationCoordinator.Priority] {
        priorityStorage.withLock { $0 }
    }
}
