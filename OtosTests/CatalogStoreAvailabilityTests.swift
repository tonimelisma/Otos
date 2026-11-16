import Foundation
@testable import OtosKit
import Testing

@Suite(.testScope)
struct CatalogStoreAvailabilityTests {
    /// A saved library whose folder is there is available, and its rows shown, the moment the
    /// catalog loads: no scan has to start before the window shows what the catalog holds
    /// (ADR 0008). Scanning is disabled, so nothing but the load can have answered.
    @Test func aReachableSavedLibraryShowsItsRowsBeforeAnyScan() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "a.jpg"), contents: "jpeg")

        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let firstStore = makeTestStore(location: .databaseFile(databaseURL))
        try await firstStore.start(scansSavedLibraries: false)
        try await firstStore.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(firstStore) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.count == 1
        }
        await firstStore.shutdown()

        let reloadedStore = makeTestStore(location: .databaseFile(databaseURL))
        try await reloadedStore.start(scansSavedLibraries: false)
        let loaded = try await catalogStoreTestState(reloadedStore)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)

        #expect(loaded.libraries.first?.availability == .available)
        let shown = try await reloadedStore.orderedAssetIDs(for: .allMedia, availableLibraryPaths: [rootPath])
        #expect(shown.map(\.relativePath.rawValue) == ["a.jpg"])
        await reloadedStore.shutdown()
    }

    /// A saved library whose folder is gone loads unavailable, its rows kept.
    @Test func anUnreachableSavedLibraryLoadsUnavailable() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let firstStore = makeTestStore(location: .databaseFile(databaseURL))
        try await firstStore.start(scansSavedLibraries: false)
        try await firstStore.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(firstStore) { !$0.isScanning }
        await firstStore.shutdown()
        try FileManager.default.removeItem(at: root)

        let reloadedStore = makeTestStore(location: .databaseFile(databaseURL))
        try await reloadedStore.start(scansSavedLibraries: false)
        let loaded = try await catalogStoreTestState(reloadedStore)

        #expect(loaded.libraries.first?.availability == .unavailable)
        await reloadedStore.shutdown()
    }

    @Test func unavailableLaunchRootPreservesRowsAndMarksLibraryUnavailable() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "a.jpg"), contents: "jpeg")

        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let firstStore = makeTestStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await firstStore.start(scansSavedLibraries: false)
        try await firstStore.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(firstStore) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.map(\.relativePath.rawValue) == ["a.jpg"]
        }
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        let assetID = MediaAssetID(
            libraryRootPath: rootPath,
            relativePath: MediaRelativePath(rawValue: "a.jpg")
        )
        #expect(try await firstStore.setMediaChoice(.liked, for: [assetID]).changedCount == 1)

        try FileManager.default.removeItem(at: root)

        let secondStore = makeTestStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await secondStore.start()

        let unavailable = try await waitForCatalogStoreState(secondStore) { snapshot in
            snapshot.libraries.first?.availability == .unavailable
                && snapshot.testAssets.map(\.relativePath.rawValue) == ["a.jpg"]
        }
        #expect(unavailable.libraries.first?.availability == .unavailable)
        #expect(unavailable.testAssets.map(\.relativePath.rawValue) == ["a.jpg"])
        #expect(try await secondStore.mediaAssets(for: [assetID])[assetID]?.mediaChoice == .liked)
    }

    @Test func scanFailureRechecksRootBeforeMarkingUnavailable() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "a.jpg"), contents: "jpeg")

        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let firstStore = makeTestStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await firstStore.start(scansSavedLibraries: false)
        try await firstStore.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(firstStore) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.map(\.relativePath.rawValue) == ["a.jpg"]
        }

        let disappearingScanner = CatalogScanner { rootPath, _, _ in
            try FileManager.default.removeItem(at: rootPath.url)
            throw CatalogScanError.filesystemErrorsEncountered(count: 1, summaries: [])
        }
        let secondStore = makeTestStore(
            location: .databaseFile(databaseURL),
            scanner: disappearingScanner,
            scanCadence: .milliseconds(10)
        )
        try await secondStore.start()

        let unavailable = try await waitForCatalogStoreState(secondStore) { snapshot in
            snapshot.libraries.first?.availability == .unavailable
                && snapshot.testAssets.map(\.relativePath.rawValue) == ["a.jpg"]
        }
        #expect(unavailable.libraries.first?.availability == .unavailable)
        #expect(unavailable.testAssets.map(\.relativePath.rawValue) == ["a.jpg"])
    }
}
