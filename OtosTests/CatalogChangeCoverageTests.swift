import Foundation
@testable import OtosKit
import Testing

/// The change-coverage guard every test's Store carries (`CatalogChangeCoverage`): it finds a
/// write whose change was not sent, and finds nothing when it was.
@Suite(.testScope)
struct CatalogChangeCoverageTests {
    /// A Like's change names the choices it wrote; the guard that hears it owes nothing.
    @Test func aWriteItsChangeAnnouncesIsCovered() async throws {
        let coverage = CatalogChangeCoverage()
        let (store, ids) = try await storeWithTwoPhotos(coverage: coverage)
        #expect(try await store.setMediaChoice(.liked, for: ids).changedCount == 2)
        await store.shutdown()
        #expect(coverage.takeUncovered().isEmpty)
    }

    /// The same Like with its change dropped before the guard hears it: the guard names the
    /// operation that wrote the choices and the kind no change named. Shutdown's own change,
    /// which names every kind, pays for no write.
    @Test func aWriteWhoseChangeIsDroppedIsFound() async throws {
        let coverage = CatalogChangeCoverage(dropping: { $0 == .changed(.choices) })
        let (store, ids) = try await storeWithTwoPhotos(coverage: coverage)
        #expect(try await store.setMediaChoice(.liked, for: ids).changedCount == 2)
        await store.shutdown()
        let uncovered = coverage.takeUncovered()
        #expect(uncovered.count == 1)
        let found = try #require(uncovered.first)
        #expect(CatalogConnectionActivity.shortName(found.operation) == "setMediaChoices")
        #expect(found.missing == .choices)
        #expect(found.owing.contains { $0.write == .column("media_asset", "media_choice") && $0.facts.contains(.choices) })
    }

    private func storeWithTwoPhotos(coverage: CatalogChangeCoverage) async throws -> (CatalogStore, [MediaAssetID]) {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "a.jpg"), contents: "jpeg")
        try writeCatalogStoreFile(root.appending(path: "b.jpg"), contents: "jpeg")
        let store = makeTestStore(
            location: .databaseFile(temp.appending(path: "db/catalog.sqlite")),
            scanCadence: .milliseconds(10),
            changeCoverage: coverage
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 2 }
        return (store, scanned.testAssets.map(\.id))
    }
}
