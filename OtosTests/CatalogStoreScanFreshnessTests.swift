import Foundation
@testable import OtosKit
import Testing

/// The catalog database must always store the latest scanned filesystem facts. A
/// whole-second date change affects Date sort and enrichment priority, so it
/// also republishes (ARC-038).
@Suite(.testScope)
struct CatalogStoreScanFreshnessTests {
    @Test func reScanRefreshesInMemoryDatesWhenOnlySizeUnchanged() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "a.jpg")
        try writeCatalogStoreFile(file, contents: "jpeg")

        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let firstStore = makeTestStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await firstStore.start(scansSavedLibraries: false)
        try await firstStore.addLibrary(url: root)
        let firstScan = try await waitForCatalogStoreState(firstStore) { snapshot in
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
        // re-observes the file and must refresh the row and republish.
        let secondStore = makeTestStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await secondStore.start()
        let reScanned = try await waitForCatalogStoreState(secondStore) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.count == 1
        }
        let refreshed = try #require(reScanned.testAssets.first)
        let refreshedModified = try #require(refreshed.contentModifiedAt)
        #expect(refreshed.byteSize == originalSize)
        #expect(abs(refreshedModified.timeIntervalSince1970 - touchedDate.timeIntervalSince1970) < 2)
        #expect(abs(refreshedModified.timeIntervalSince1970 - originalModified.timeIntervalSince1970) > 60)
    }

    /// A rescan that finds every file as the catalog holds it takes no write transaction,
    /// for its batches or its companions: only a file whose facts differ reaches the writer
    /// (`ScanBaseline`), and one changed file is one row written.
    @Test func anUnchangedRescanTakesNoWriterAndAChangedFileWritesOneRow() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "a.jpg"), contents: "jpeg")
        try writeCatalogStoreFile(root.appending(path: "a.xmp"), contents: "xmp")
        let changing = root.appending(path: "b.jpg")
        try writeCatalogStoreFile(changing, contents: "jpeg")
        let databaseURL = temp.appending(path: "db/catalog.sqlite")

        let firstStore = makeTestStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await firstStore.start(scansSavedLibraries: false)
        try await firstStore.addLibrary(url: root)
        try await waitUntil { await firstStore.isFilesystemQuiescent }
        #expect(try await catalogStoreTestState(firstStore).testAssets.count == 2)
        // Only the relaunched Stores may see the change below: a running one would reconcile it.
        await firstStore.shutdown()

        let unchanged = try await relaunchScanWrites(databaseURL: databaseURL)
        #expect(unchanged.isEmpty, "an unchanged rescan wrote: \(unchanged)")

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)],
            ofItemAtPath: changing.path(percentEncoded: false)
        )
        let changed = try await relaunchScanWrites(databaseURL: databaseURL)
        let batches = changed.filter { $0.operation == "recordScannedBatch" }
        #expect(batches.map(\.count) == [1])
        #expect(batches.map(\.mostRows) == [1])
    }

    /// The scan's write transactions in a fresh Store's launch scan of the catalog at `databaseURL`.
    private func relaunchScanWrites(databaseURL: URL) async throws -> [CatalogConnectionActivity.Hold] {
        let recorder = FilesystemEventScanInvocationRecorder()
        let store = makeTestStore(
            location: .databaseFile(databaseURL),
            scanner: recordingLiveScanner(recorder),
            scanCadence: .milliseconds(10)
        )
        try await store.start()
        try await waitUntil { await recorder.invocations().count == 1 }
        try await waitUntil { await store.isFilesystemQuiescent }
        await store.shutdown()
        return store.use().connections.holds.filter {
            $0.role == "main.writer" && ["recordScannedBatch", "applyAndReconcileCompanions"].contains($0.operation)
        }
    }
}
