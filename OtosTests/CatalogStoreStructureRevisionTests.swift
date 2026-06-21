import Foundation
@testable import Otos
import Testing

struct CatalogStoreStructureRevisionTests {
    @Test func assetStructureRevisionTracksOnlyMembershipChanges() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let emptyRoot = temp.appending(path: "Empty", directoryHint: .isDirectory)
        let mediaRoot = temp.appending(path: "Media", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mediaRoot, withIntermediateDirectories: true)
        try writeCatalogStoreFile(mediaRoot.appending(path: "one.jpg"), contents: "jpeg")

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10), diagnostics: nil)
        try await store.start(scansSavedLibraries: false)
        let loadedRevision = await store.currentSnapshot().assetStructureRevision
        #expect(loadedRevision == 1)

        try await store.addLibrary(url: emptyRoot)
        let emptyAdded = try await waitForCatalogStoreSnapshot(store) { snapshot in
            snapshot.libraries.count == 1 && !snapshot.isScanning
        }
        #expect(emptyAdded.assetStructureRevision == loadedRevision)

        try await store.addLibrary(url: mediaRoot)
        let inserted = try await waitForCatalogStoreSnapshot(store) { snapshot in
            snapshot.testAssets.count == 1 && !snapshot.isScanning
        }
        #expect(inserted.assetStructureRevision == loadedRevision + 1)

        let mediaPath = try CatalogPath.normalizedDirectoryPath(for: mediaRoot)
        try await store.removeLibrary(path: mediaPath)
        let removed = await store.currentSnapshot()
        #expect(removed.assetStructureRevision == loadedRevision + 2)

        let emptyPath = try CatalogPath.normalizedDirectoryPath(for: emptyRoot)
        try await store.removeLibrary(path: emptyPath)
        let emptyRemoved = await store.currentSnapshot()
        #expect(emptyRemoved.assetStructureRevision == loadedRevision + 2)

        await store.shutdown()
        let shutDown = await store.currentSnapshot()
        #expect(shutDown.assetStructureRevision == loadedRevision + 2)
    }

    @Test func detailOnlyScanUpdateDoesNotAdvanceAssetStructureRevision() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "one.jpg"), contents: "jpeg")
        let databaseURL = temp.appending(path: "catalog.sqlite")

        let firstStore = CatalogStore(
            location: .databaseFile(databaseURL),
            scanCadence: .milliseconds(10),
            diagnostics: nil
        )
        try await firstStore.start(scansSavedLibraries: false)
        try await firstStore.addLibrary(url: root)
        _ = try await waitForCatalogStoreSnapshot(firstStore) { snapshot in
            snapshot.testAssets.count == 1 && !snapshot.isScanning
        }

        let detailScanner = CatalogScanner { _, _, _, batchHandler in
            try await batchHandler([
                ScannedMediaFile(
                    relativePath: MediaRelativePath(rawValue: "one.jpg"),
                    name: "updated-name.jpg",
                    contentTypeIdentifier: "public.jpeg",
                    byteSize: 42,
                    createdAt: nil,
                    contentModifiedAt: nil
                ),
            ])
            return [MediaRelativePath(rawValue: "one.jpg")]
        }
        let reloadedStore = CatalogStore(
            location: .databaseFile(databaseURL),
            scanner: detailScanner,
            scanCadence: .milliseconds(10),
            diagnostics: nil
        )
        try await reloadedStore.start()
        let updated = try await waitForCatalogStoreSnapshot(reloadedStore) { snapshot in
            snapshot.testAssets.first?.name == "updated-name.jpg" && !snapshot.isScanning
        }

        #expect(updated.assetStructureRevision == 1)
        #expect(updated.testAssets.first?.byteSize == 42)
    }
}
