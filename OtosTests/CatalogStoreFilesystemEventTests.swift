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

    /// Plan 0064 Stage 2: Otos's own `.otos-import-staging` files are written into the
    /// watched destination root while importing and must not schedule reconciliation,
    /// record namespace mutations, or bump occupancy — that self-inflicted churn fired
    /// a reconcile + replan on every staging write. A real media event still reconciles.
    @Test func importStagingEventsDoNotTriggerReconciliation() async throws {
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
        let baseline = await recorder.invocations().count

        let stagingURL = root.appending(path: ".08ADC04C-98C9.otos-import-staging")
        try Data("staging".utf8).write(to: stagingURL)
        emit(FilesystemEvent(path: stagingURL.path, flags: 0))
        try await assertInvocationCountStays(recorder, baseline: baseline, duration: .milliseconds(300))

        // Control: a real media-file event for the same root still reconciles.
        let mediaURL = root.appending(path: "real.jpg")
        try Data("jpg".utf8).write(to: mediaURL)
        emit(FilesystemEvent(path: mediaURL.path, flags: 0))
        try await waitForFilesystemRescan(
            store: store,
            recorder: recorder,
            baseline: baseline,
            expectedAdditional: 1
        )
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

    @Test func safeFileEventDuringActiveScanDoesNotForceFullRescan() async throws {
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
        try await probe.waitForInvocationCount(1)
        // Keep the initial addLibrary scan hanging so a safe file event accumulates
        // as file dirt rather than starting another full-root scan.
        let during = root.appending(path: "during.jpg")
        try writeCatalogStoreFile(during, contents: "jpeg")
        emit(
            FilesystemEvent(
                path: during.path,
                flags: UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
            )
        )
        try await debounceGate.waitForSleepRequestCount(1)
        await debounceGate.releaseNext()

        await probe.release(1)
        _ = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.contains { $0.relativePath.rawValue == "during.jpg" }
        }
        #expect(await recorder.invocations().count == 1)
    }

    @Test func subtreeDirectoryEventReconcilesWithoutSiblingMutation() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let left = root.appending(path: "a/b", directoryHint: .isDirectory)
        let sibling = root.appending(path: "a/b2", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try writeCatalogStoreFile(left.appending(path: "keep.jpg"), contents: "jpeg")
        try writeCatalogStoreFile(sibling.appending(path: "sibling.jpg"), contents: "jpeg")

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
            !snapshot.isScanning && snapshot.testAssets.count == 2
        }
        let baseline = await recorder.invocations().count

        try writeCatalogStoreFile(left.appending(path: "new.jpg"), contents: "jpeg")
        emit(
            FilesystemEvent(
                path: left.path,
                flags: UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsDir)
            )
        )

        let reconciled = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.count == 3
        }
        let names = Set(reconciled.testAssets.map(\.relativePath.rawValue))
        #expect(names.contains("a/b/keep.jpg"))
        #expect(names.contains("a/b/new.jpg"))
        #expect(names.contains("a/b2/sibling.jpg"))
        #expect(await recorder.invocations().count == baseline)
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

    @Test func fileDirtSurvivesQueuedOtherRootScan() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let rootA = temp.appending(path: "A", directoryHint: .isDirectory)
        let rootB = temp.appending(path: "B", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        try writeCatalogStoreFile(rootA.appending(path: "seed.jpg"), contents: "jpeg")
        try writeCatalogStoreFile(rootB.appending(path: "seed.jpg"), contents: "jpeg")

        let pathA = try CatalogPath.normalizedDirectoryPath(for: rootA)
        let pathB = try CatalogPath.normalizedDirectoryPath(for: rootB)
        let snapshot = FilesystemScanNameSnapshot()
        await snapshot.set(pathA, ["seed.jpg"])
        await snapshot.set(pathB, ["seed.jpg"])

        let probe = FilesystemScanProbe()
        let recorder = FilesystemEventScanInvocationRecorder()
        let debounceGate = ManualSleepGate()
        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        let store = CatalogStore(
            location: .inMemory,
            scanner: snapshotHangingScanner(
                snapshot: snapshot,
                probe: probe,
                recorder: recorder,
                hangRoot: pathA
            ),
            filesystemWatcher: watcher,
            filesystemEventDebounce: .milliseconds(20),
            filesystemEventSleep: { duration in
                await debounceGate.sleep(for: duration)
            }
        )

        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: rootA)
        try await store.addLibrary(url: rootB)
        _ = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.count == 2
        }

        // Force a full-root scan of A that hangs and cannot observe later file dirt.
        emit(FilesystemEvent(path: rootA.path, flags: 0))
        try await debounceGate.waitForSleepRequestCount(1)
        await debounceGate.releaseNext()
        try await probe.waitForInvocationCount(3)

        try writeCatalogStoreFile(rootA.appending(path: "during.jpg"), contents: "jpeg")
        emit(
            FilesystemEvent(
                path: rootA.appending(path: "during.jpg").path,
                flags: UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
            )
        )
        // Queue a full-root scan of B while A still holds the lease.
        emit(FilesystemEvent(path: rootB.path, flags: 0))
        try await debounceGate.waitForSleepRequestCount(3)
        await debounceGate.releaseAll()

        await probe.release(3)
        let settled = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning
                && snapshot.testAssets.contains { $0.relativePath.rawValue == "during.jpg" }
        }
        let names = Set(settled.testAssets.map(\.relativePath.rawValue))
        #expect(names.contains("during.jpg"))
        #expect(names.contains("seed.jpg"))
    }

    @Test func removedDirectoryPurgesSubtreeRowsAndCompanions() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let album = root.appending(path: "album", directoryHint: .isDirectory)
        let sibling = root.appending(path: "keep", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try writeCatalogStoreFile(album.appending(path: "photo.jpg"), contents: "jpeg")
        try writeCatalogStoreFile(album.appending(path: "photo.xmp"), contents: "<xmp/>")
        try writeCatalogStoreFile(sibling.appending(path: "keep.jpg"), contents: "jpeg")

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
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        _ = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.count == 2
        }
        let companionsBefore = try await store.companions(in: rootPath)
        #expect(companionsBefore.map(\.relativePath.rawValue) == ["album/photo.xmp"])
        let baseline = await recorder.invocations().count

        try FileManager.default.removeItem(at: album)
        emit(
            FilesystemEvent(
                path: album.path,
                flags: UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsDir)
            )
        )

        let settled = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning
                && snapshot.testAssets.map(\.relativePath.rawValue) == ["keep/keep.jpg"]
        }
        #expect(settled.testAssets.map(\.relativePath.rawValue) == ["keep/keep.jpg"])
        let companionsAfter = try await store.companions(in: rootPath)
        #expect(companionsAfter.isEmpty)
        #expect(await recorder.invocations().count == baseline)
    }

    @Test func renamedDirectoryEscalatesToRootAndAvoidsDuplicates() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let oldDir = root.appending(path: "old", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try writeCatalogStoreFile(oldDir.appending(path: "shot.jpg"), contents: "jpeg")

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

        let newDir = root.appending(path: "new", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: oldDir, to: newDir)
        emit(
            FilesystemEvent(
                path: oldDir.path,
                flags: UInt32(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsDir)
            )
        )

        let settled = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning
                && snapshot.testAssets.map(\.relativePath.rawValue) == ["new/shot.jpg"]
        }
        #expect(settled.testAssets.map(\.relativePath.rawValue) == ["new/shot.jpg"])
        #expect(await recorder.invocations().count == baseline + 1)
    }
}
