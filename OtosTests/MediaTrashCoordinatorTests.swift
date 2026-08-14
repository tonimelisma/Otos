import Foundation
@testable import Otos
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
        let coordinator = MediaTrashCoordinator(store: store) { url in
            recorder.append(url.lastPathComponent)
            if url.pathExtension.lowercased() == "jpg" {
                throw CocoaError(.fileNoSuchFile)
            }
        }
        let result = await coordinator.moveToTrash(items)

        #expect(recorder.paths == ["a.xmp", "a.jpg"])
        #expect(result.successfulPaths.map(\.relativePath.rawValue) == ["a.xmp"])
        #expect(result.failedItems.map(\.id) == [id])
        #expect(result.movedItemCount == 0)
        #expect(await store.hasNamespaceMutationLease(for: item.root.path) == false)
    }
}
