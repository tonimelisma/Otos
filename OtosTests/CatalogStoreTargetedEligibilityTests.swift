import CoreServices
import Foundation
@testable import OtosKit
import Testing

@Suite(.testScope)
struct CatalogStoreTargetedEligibilityTests {
    // Validates: ARC-041
    @Test func targetedFileEventDeletesCatalogRowWhenPathBecomesIneligible() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "changed.jpg")
        try writeCatalogStoreFile(file, contents: "jpeg")

        let recorder = FilesystemEventScanInvocationRecorder()
        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        let store = makeTestStore(
            location: .inMemory,
            scanner: recordingLiveScanner(recorder),
            filesystemWatcher: watcher,
            scanCadence: .milliseconds(10)
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
