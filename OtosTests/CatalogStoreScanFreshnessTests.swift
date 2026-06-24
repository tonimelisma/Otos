import Foundation
@testable import Otos
import Testing

/// The in-memory catalog must always mirror the latest scanned filesystem facts so
/// `currentSnapshot()` never serves stale values, even when the no-op-scan
/// notification suppression (FND-062) decides the change is not worth publishing.
struct CatalogStoreScanFreshnessTests {
    @Test func reScanRefreshesInMemoryDatesWhenOnlySizeUnchanged() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "a.jpg")
        try writeCatalogStoreFile(file, contents: "jpeg")

        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let firstStore = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await firstStore.start(scansSavedLibraries: false)
        try await firstStore.addLibrary(url: root)
        let firstScan = try await waitForCatalogStoreSnapshot(firstStore) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.count == 1
        }
        let originalSize = try #require(firstScan.testAssets.first?.byteSize)
        let originalModified = try #require(firstScan.testAssets.first?.contentModifiedAt)

        // Change only the modification date. The bytes, and therefore the name,
        // content type, and size, are untouched, which is exactly the case the
        // name/type/size no-op suppression must not let mask a date change.
        let touchedDate = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: touchedDate],
            ofItemAtPath: file.path(percentEncoded: false)
        )

        // A fresh store reloads the stale date from SQLite, then the launch scan
        // re-observes the file. The scan suppresses its projection notification
        // (name/type/size unchanged) but must still refresh the in-memory value.
        let secondStore = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await secondStore.start()
        let reScanned = try await waitForCatalogStoreSnapshot(secondStore) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.count == 1
        }
        let refreshed = try #require(reScanned.testAssets.first)
        let refreshedModified = try #require(refreshed.contentModifiedAt)
        #expect(refreshed.byteSize == originalSize)
        #expect(abs(refreshedModified.timeIntervalSince1970 - touchedDate.timeIntervalSince1970) < 2)
        #expect(abs(refreshedModified.timeIntervalSince1970 - originalModified.timeIntervalSince1970) > 60)
    }
}
