import Foundation
@testable import Otos
import Testing

struct CatalogStoreAvailabilityTests {
    @Test func databaseLoadedRootBeginsUnknownWhenScanningIsDisabled() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let firstStore = CatalogStore(location: .databaseFile(databaseURL), diagnostics: nil)
        try await firstStore.start(scansSavedLibraries: false)
        try await firstStore.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(firstStore) { !$0.isScanning }

        let reloadedStore = CatalogStore(location: .databaseFile(databaseURL), diagnostics: nil)
        try await reloadedStore.start(scansSavedLibraries: false)
        let loaded = try await catalogStoreTestState(reloadedStore)

        #expect(loaded.libraries.first?.availability == .unknown)
    }

    @Test func unavailableLaunchRootPreservesRowsAndMarksLibraryUnavailable() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "a.jpg"), contents: "jpeg")

        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let firstStore = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await firstStore.start(scansSavedLibraries: false)
        try await firstStore.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(firstStore) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.map(\.relativePath.rawValue) == ["a.jpg"]
        }

        try FileManager.default.removeItem(at: root)

        let secondStore = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await secondStore.start()

        let unavailable = try await waitForCatalogStoreState(secondStore) { snapshot in
            snapshot.libraries.first?.availability == .unavailable
                && snapshot.testAssets.map(\.relativePath.rawValue) == ["a.jpg"]
        }
        #expect(unavailable.libraries.first?.availability == .unavailable)
        #expect(unavailable.testAssets.map(\.relativePath.rawValue) == ["a.jpg"])
    }

    @Test func scanFailureRechecksRootBeforeMarkingUnavailable() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "a.jpg"), contents: "jpeg")

        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let firstStore = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await firstStore.start(scansSavedLibraries: false)
        try await firstStore.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(firstStore) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.map(\.relativePath.rawValue) == ["a.jpg"]
        }

        let disappearingScanner = CatalogScanner { rootPath, _, _, _ in
            try FileManager.default.removeItem(at: rootPath.url)
            throw CatalogScanError.filesystemErrorsEncountered(1)
        }
        let secondStore = CatalogStore(
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
