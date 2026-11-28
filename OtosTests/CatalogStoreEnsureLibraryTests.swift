import Foundation
@testable import OtosKit
import Testing

@Suite(.testScope)
struct CatalogStoreEnsureLibraryTests {
    // Validates: ARC-029
    @Test func ensureLibraryAddsMissingRootAndNoOpsExistingRoot() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "a.jpg"), contents: "jpeg")

        let store = makeTestStore(
            location: .databaseFile(temp.appending(path: "db/catalog.sqlite")),
            scanCadence: .milliseconds(10)
        )
        try await store.start(scansSavedLibraries: false)

        try await store.ensureLibrary(url: root)
        let scanned = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning && snapshot.libraries.count == 1 && snapshot.testAssets.count == 1
        }
        try await store.ensureLibrary(url: root)

        let final = try await catalogStoreTestState(store)
        #expect(final.libraries.map(\.path) == scanned.libraries.map(\.path))
        #expect(final.testAssets.map(\.relativePath.rawValue) == ["a.jpg"])
    }
}
