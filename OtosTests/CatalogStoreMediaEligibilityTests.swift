import Foundation
@testable import OtosKit
import Testing

@Suite(.testScope)
struct CatalogStoreMediaEligibilityTests {
    @Test func scanCatalogsImageAndVideoMediaAndSkipsNonMedia() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "photo.jpg"), contents: "jpeg")
        try writeCatalogStoreFile(root.appending(path: "clip.mp4"), contents: "mp4")
        try writeCatalogStoreFile(root.appending(path: "notes.txt"), contents: "text")
        try writeCatalogStoreFile(root.appending(path: "track.mp3"), contents: "mp3")

        let store = makeTestStore(
            location: .databaseFile(temp.appending(path: "db/catalog.sqlite")),
            scanCadence: .milliseconds(10)
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)

        let scanned = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.count == 2
        }
        #expect(
            Set(scanned.testAssets.map(\.relativePath.rawValue)) == ["clip.mp4", "photo.jpg"]
        )
    }

    @Test func scanSkipsHiddenAppleDoubleAndCameraJunkPaths() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Card", directoryHint: .isDirectory)
        let junkDirectories = [
            ".Trashes",
            ".Spotlight-V100",
            "AVF_INFO",
            "M4ROOT/SUB",
        ]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for directory in junkDirectories {
            try FileManager.default.createDirectory(
                at: root.appending(path: directory, directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
        }
        try writeCatalogStoreFile(root.appending(path: "visible.jpg"), contents: "jpeg")
        try writeCatalogStoreFile(root.appending(path: ".hidden.jpg"), contents: "jpeg")
        try writeCatalogStoreFile(root.appending(path: "._visible.jpg"), contents: "jpeg")
        try writeCatalogStoreFile(root.appending(path: ".Trashes/deleted.jpg"), contents: "jpeg")
        try writeCatalogStoreFile(root.appending(path: ".Spotlight-V100/index.jpg"), contents: "jpeg")
        try writeCatalogStoreFile(root.appending(path: "AVF_INFO/clip.jpg"), contents: "jpeg")
        try writeCatalogStoreFile(root.appending(path: "M4ROOT/SUB/proxy.jpg"), contents: "jpeg")

        let store = makeTestStore(
            location: .inMemory,
            scanCadence: .milliseconds(10)
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)

        let scanned = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.map(\.relativePath.rawValue) == ["visible.jpg"]
        }

        #expect(scanned.testAssets.map(\.relativePath.rawValue) == ["visible.jpg"])
    }
}
