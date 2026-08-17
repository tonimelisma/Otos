import CoreServices
import Foundation
@testable import OtosKit
import Testing

struct CatalogStoreTargetedEligibilityTests {
    @Test func targetedFileEventDeletesCatalogRowWhenPathBecomesIneligible() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "changed.jpg")
        try writeCatalogStoreFile(file, contents: "jpeg")

        let recorder = FilesystemEventScanInvocationRecorder()
        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        let store = CatalogStore(
            location: .inMemory,
            scanner: recordingLiveScanner(recorder),
            filesystemWatcher: watcher,
            scanCadence: .milliseconds(10),
            filesystemEventDebounce: .milliseconds(30)
        )

        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.count == 1
        }
        let baseline = await recorder.invocations().count

        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        emit(
            FilesystemEvent(
                path: file.path,
                flags: UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
            )
        )

        _ = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.isEmpty
        }
        #expect(await recorder.invocations().count == baseline)
    }
}
