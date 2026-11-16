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
        let shown = try await reloadedStore.windowReads.orderedAssetIDs(for: .allMedia, availableLibraryPaths: [rootPath])
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
        #expect(try await secondStore.windowReads.mediaAssets(for: [assetID])[assetID]?.mediaChoice == .liked)
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

    /// A root whose availability moves changes which rows are in reach, so it is announced
    /// naming no rows (`CatalogChangedRows.unnamed`), never as the scan's own "no row changed"
    /// (`.none`): an owner whose reads are bound to the roots read, such as search, reads
    /// them again. Every availability change goes through the one setter that announces it, so
    /// a root found again mid-session is announced the same way.
    @Test func aRootThatComesOrGoesIsAnnouncedAsAChangeOfReach() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "a.jpg"), contents: "jpeg")
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let firstStore = makeTestStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await firstStore.start(scansSavedLibraries: false)
        try await firstStore.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(firstStore) { !$0.isScanning && $0.testAssets.count == 1 }
        await firstStore.shutdown()

        let disappearingScanner = CatalogScanner { rootPath, _, _ in
            try FileManager.default.removeItem(at: rootPath.url)
            throw CatalogScanError.filesystemErrorsEncountered(count: 1, summaries: [])
        }
        let store = makeTestStore(location: .databaseFile(databaseURL), scanner: disappearingScanner, scanCadence: .milliseconds(10))
        let changes = AsyncValueRecorder<CatalogStoreChange>()
        let stream = await store.changeNotifications()
        let recording = Task {
            for await change in stream {
                await changes.append(change)
            }
        }
        defer { recording.cancel() }
        try await store.start()

        // The scan's start and end each announce the root's own state (`.none`); the root the
        // failing scan lost, between them, is a change of reach.
        let rootOnly = CatalogStoreChange.changed(.membership, rows: .none)
        let heard = await changes.waitForValues { recorded in recorded.filter { $0 == rootOnly }.count == 2 }
        let start = try #require(heard.firstIndex(of: rootOnly))
        let end = try #require(heard.lastIndex(of: rootOnly))
        #expect(heard[start ..< end].contains(.changed(.membership)), "the root lost by the scan that failed")
        #expect(try await catalogStoreTestState(store).libraries.first?.availability == .unavailable)
        await store.shutdown()
    }
}
