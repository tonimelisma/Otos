import Foundation
@testable import Otos
import Testing

struct CatalogStoreEnsureLibraryTests {
    @Test func ensureLibraryAddsMissingRootAndNoOpsExistingRoot() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "a.jpg"), contents: "jpeg")

        let diagnosticsURL = temp.appending(path: "diagnostics/catalog-diagnostics.jsonl")
        let diagnostics = CatalogDiagnostics(outputURL: diagnosticsURL, isEnabled: true)
        let store = CatalogStore(
            location: .databaseFile(temp.appending(path: "db/catalog.sqlite")),
            scanCadence: .milliseconds(10),
            diagnostics: diagnostics
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

        let diagnosticsText = try #require(String(data: Data(contentsOf: diagnosticsURL), encoding: .utf8))
        #expect(diagnosticsText.contains("\"operation\":\"catalog.library.ensure\""))
        #expect(diagnosticsText.contains("\"phase\":\"finish\""))
        #expect(diagnosticsText.contains("\"phase\":\"exists\""))
    }
}
