import CoreServices
import Foundation
@testable import Otos
import Testing

struct FilesystemEventDiagnosticTests {
    @Test func filesystemEventsRecordDecodedBatchSummaryInsteadOfReceiveSpam() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let outputURL = temp.appending(path: "filesystem-event-diagnostics.jsonl")
        let diagnostics = CatalogDiagnostics(outputURL: outputURL, isEnabled: true)
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appending(path: "first.jpg")
        try writeCatalogStoreFile(first, contents: "jpeg")

        let recorder = FilesystemEventScanInvocationRecorder()
        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        let store = CatalogStore(
            location: .inMemory,
            scanner: recordingLiveScanner(recorder),
            filesystemWatcher: watcher,
            scanCadence: .milliseconds(10),
            filesystemEventDebounce: .milliseconds(30),
            diagnostics: diagnostics
        )

        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.count == 1
        }
        let second = root.appending(path: "second.jpg")
        try writeCatalogStoreFile(second, contents: "jpeg")

        emit(
            FilesystemEvent(
                path: second.path,
                flags: UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
            )
        )

        let event = try await waitForFilesystemDiagnostic(outputURL) { event in
            event.operation == "catalog.filesystemEvent" && event.phase == "reconcile"
        }
        let contents = try #require(String(data: Data(contentsOf: outputURL), encoding: .utf8))
        #expect(event.fields["mode"] == "targeted")
        #expect(event.fields["eventCount"] == "1")
        #expect(event.fields["uniquePathCount"] == "1")
        #expect(event.fields["actions"] == "upsert:1")
        #expect(event.fields["flags"]?.contains("itemCreated:1") == true)
        #expect(event.fields["flags"]?.contains("itemIsFile:1") == true)
        #expect(event.fields["samplePaths"]?.contains("second.jpg") == true)
        #expect(!contents.contains("\"phase\":\"receive\""))
        #expect(!contents.contains("\"phase\":\"debounce\""))
    }
}
