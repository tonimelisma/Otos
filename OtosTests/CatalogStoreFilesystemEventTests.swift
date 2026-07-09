import CoreServices
import Foundation
@testable import Otos
import Testing

struct CatalogStoreFilesystemEventTests {
    @Test func eventRescansOnlyAffectedRoot() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let rootA = temp.appending(path: "A", directoryHint: .isDirectory)
        let rootB = temp.appending(path: "B", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)

        let recorder = FilesystemEventScanInvocationRecorder()
        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        let store = CatalogStore(
            location: .inMemory,
            scanner: recordingScanner(recorder),
            filesystemWatcher: watcher,
            filesystemEventDebounce: .milliseconds(20)
        )

        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: rootA)
        try await store.addLibrary(url: rootB)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }

        let pathA = try CatalogPath.normalizedDirectoryPath(for: rootA)
        let pathB = try CatalogPath.normalizedDirectoryPath(for: rootB)
        let baseline = await recorder.invocations().count

        emit(FilesystemEvent(path: rootA.appending(path: "new.jpg").path, flags: 0))
        try await waitForFilesystemRescan(
            store: store,
            recorder: recorder,
            baseline: baseline,
            expectedAdditional: 1
        )

        let invocations = await recorder.invocations()
        let newInvocations = invocations.dropFirst(baseline)
        #expect(newInvocations.contains(pathA))
        #expect(!newInvocations.contains(pathB))
    }

    @Test func debounceCoalescesBurst() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let recorder = FilesystemEventScanInvocationRecorder()
        let debounceGate = ManualSleepGate()
        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        let store = CatalogStore(
            location: .inMemory,
            scanner: recordingScanner(recorder),
            filesystemWatcher: watcher,
            filesystemEventDebounce: .seconds(1),
            filesystemEventSleep: { duration in
                await debounceGate.sleep(for: duration)
            }
        )

        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        let baseline = await recorder.invocations().count

        for index in 0 ..< 5 {
            emit(
                FilesystemEvent(
                    path: root.appending(path: "file-\(index).jpg").path,
                    flags: 0
                )
            )
        }

        try await debounceGate.waitForSleepRequestCount(5)
        await debounceGate.releaseAll()
        try await waitForFilesystemRescan(store: store, recorder: recorder, baseline: baseline, expectedAdditional: 1)
    }

    @Test func debounceResetsOnNewEvent() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let recorder = FilesystemEventScanInvocationRecorder()
        let debounceGate = ManualSleepGate()
        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        let store = CatalogStore(
            location: .inMemory,
            scanner: recordingScanner(recorder),
            filesystemWatcher: watcher,
            filesystemEventDebounce: .seconds(1),
            filesystemEventSleep: { duration in
                await debounceGate.sleep(for: duration)
            }
        )

        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        let baseline = await recorder.invocations().count

        emit(FilesystemEvent(path: root.appending(path: "first.jpg").path, flags: 0))
        try await debounceGate.waitForSleepRequestCount(1)
        emit(FilesystemEvent(path: root.appending(path: "second.jpg").path, flags: 0))
        try await debounceGate.waitForSleepRequestCount(2)

        await debounceGate.releaseNext()
        #expect(await recorder.invocations().count == baseline)

        await debounceGate.releaseNext()
        try await waitForFilesystemRescan(
            store: store,
            recorder: recorder,
            baseline: baseline,
            expectedAdditional: 1
        )
    }

    @Test func eventDuringActiveScanSchedulesFollowUp() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let probe = FilesystemScanProbe()
        let recorder = FilesystemEventScanInvocationRecorder()
        let debounceGate = ManualSleepGate()
        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        let store = CatalogStore(
            location: .inMemory,
            scanner: deferredHangingScanner(probe: probe, recorder: recorder),
            filesystemWatcher: watcher,
            filesystemEventDebounce: .seconds(1),
            filesystemEventSleep: { duration in
                await debounceGate.sleep(for: duration)
            }
        )

        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }

        emit(FilesystemEvent(path: root.appending(path: "trigger-second.jpg").path, flags: 0))
        try await debounceGate.waitForSleepRequestCount(1)
        await debounceGate.releaseNext()
        try await probe.waitForInvocationCount(2)

        emit(FilesystemEvent(path: root.appending(path: "during-second.jpg").path, flags: 0))
        try await debounceGate.waitForSleepRequestCount(2)
        await debounceGate.releaseNext()

        await probe.release(2)
        try await probe.waitForInvocationCount(3)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
    }

    @Test func eventsIgnoredBeforeFirstScanCompletes() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let probe = FilesystemScanProbe()
        let recorder = FilesystemEventScanInvocationRecorder()
        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        let store = CatalogStore(
            location: .inMemory,
            scanner: firstScanHangingScanner(probe: probe, recorder: recorder),
            filesystemWatcher: watcher,
            filesystemEventDebounce: .milliseconds(20)
        )

        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        try await probe.waitForInvocationCount(1)

        emit(FilesystemEvent(path: root.appending(path: "early.jpg").path, flags: 0))
        #expect(await recorder.invocations().count == 1)

        await probe.release(1)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }

        emit(FilesystemEvent(path: root.appending(path: "late.jpg").path, flags: 0))
        try await probe.waitForInvocationCount(2)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
    }

    @Test func removeLibraryStopsScheduling() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let recorder = FilesystemEventScanInvocationRecorder()
        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        let store = CatalogStore(
            location: .inMemory,
            scanner: recordingScanner(recorder),
            filesystemWatcher: watcher,
            filesystemEventDebounce: .milliseconds(20)
        )

        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        let baseline = await recorder.invocations().count

        try await store.removeLibrary(path: rootPath)
        emit(FilesystemEvent(path: root.appending(path: "after-remove.jpg").path, flags: 0))
        try await assertInvocationCountStays(recorder, baseline: baseline, duration: .milliseconds(80))
        #expect(await recorder.invocations().count == baseline)
    }

    @Test func targetedFileEventReconcilesWithoutFullScan() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
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
            filesystemEventDebounce: .milliseconds(30)
        )

        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let initial = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.count == 1
        }
        #expect(initial.testAssets.map(\.relativePath.rawValue) == ["first.jpg"])
        let baseline = await recorder.invocations().count

        let second = root.appending(path: "second.jpg")
        try writeCatalogStoreFile(second, contents: "jpeg")
        emit(
            FilesystemEvent(
                path: second.path,
                flags: UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
            )
        )

        let reconciled = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.count == 2
        }
        let names = Set(reconciled.testAssets.map(\.relativePath.rawValue))
        #expect(names == ["first.jpg", "second.jpg"])
        #expect(await recorder.invocations().count == baseline)
    }

    @Test func targetedFileRemovalDeletesWithoutFullScan() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "removed.jpg")
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
        emit(
            FilesystemEvent(
                path: file.path,
                flags: UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile)
            )
        )

        _ = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.isEmpty
        }
        #expect(await recorder.invocations().count == baseline)
    }

    @Test func diskChangeReconcilesAfterRescan() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appending(path: "first.jpg")
        try writeCatalogStoreFile(first, contents: "jpeg")

        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        let store = CatalogStore(
            location: .inMemory,
            filesystemWatcher: watcher,
            scanCadence: .milliseconds(10),
            filesystemEventDebounce: .milliseconds(30)
        )

        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let initial = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.count == 1
        }
        #expect(initial.testAssets.map(\.relativePath.rawValue) == ["first.jpg"])

        let second = root.appending(path: "second.jpg")
        try writeCatalogStoreFile(second, contents: "jpeg")
        emit(FilesystemEvent(path: second.path, flags: 0))

        let reconciled = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.count == 2
        }
        let names = Set(reconciled.testAssets.map(\.relativePath.rawValue))
        #expect(names == ["first.jpg", "second.jpg"])
    }
}
