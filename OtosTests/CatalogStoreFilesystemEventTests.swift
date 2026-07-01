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

        let recorder = ScanInvocationRecorder()
        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        let store = CatalogStore(
            location: .inMemory,
            scanner: recordingScanner(recorder),
            filesystemWatcher: watcher,
            filesystemEventDebounce: .milliseconds(20),
            diagnostics: nil
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

        let recorder = ScanInvocationRecorder()
        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        // A wide debounce window keeps the whole burst (5 emits, ~10 ms apart) comfortably
        // inside one window even when Task.sleep overshoots under parallel-suite load, so the
        // burst coalesces to exactly one rescan deterministically.
        let store = CatalogStore(
            location: .inMemory,
            scanner: recordingScanner(recorder),
            filesystemWatcher: watcher,
            filesystemEventDebounce: .milliseconds(200),
            diagnostics: nil
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
            try await Task.sleep(for: .milliseconds(10))
        }

        try await waitForFilesystemRescan(store: store, recorder: recorder, baseline: baseline, expectedAdditional: 1)
    }

    @Test func debounceResetsOnNewEvent() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let recorder = ScanInvocationRecorder()
        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        let store = CatalogStore(
            location: .inMemory,
            scanner: recordingScanner(recorder),
            filesystemWatcher: watcher,
            // A wide window with a large margin: the second event must arrive (and reset
            // the timer) well before the first window elapses. At 200 ms, the ~40 ms re-emit
            // point stays far inside it even if Task.sleep overshoots under parallel-suite
            // load, so the first timer is reliably cancelled before it can fire.
            filesystemEventDebounce: .milliseconds(200),
            diagnostics: nil
        )

        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        let baseline = await recorder.invocations().count

        emit(FilesystemEvent(path: root.appending(path: "first.jpg").path, flags: 0))
        try await Task.sleep(for: .milliseconds(40))
        emit(FilesystemEvent(path: root.appending(path: "second.jpg").path, flags: 0))

        // The reset timer (200 ms from the second event) cannot have fired this early, and
        // the cancelled first timer never fires, so no rescan has happened yet.
        try await Task.sleep(for: .milliseconds(30))
        #expect(await recorder.invocations().count == baseline)

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
        let recorder = ScanInvocationRecorder()
        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        let store = CatalogStore(
            location: .inMemory,
            scanner: deferredHangingScanner(probe: probe, recorder: recorder),
            filesystemWatcher: watcher,
            filesystemEventDebounce: .milliseconds(20),
            diagnostics: nil
        )

        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }

        emit(FilesystemEvent(path: root.appending(path: "trigger-second.jpg").path, flags: 0))
        try await probe.waitForInvocationCount(2)

        emit(FilesystemEvent(path: root.appending(path: "during-second.jpg").path, flags: 0))
        try await Task.sleep(for: .milliseconds(40))

        await probe.release(2)
        try await probe.waitForInvocationCount(3)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
    }

    @Test func eventsIgnoredBeforeFirstScanCompletes() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let probe = FilesystemScanProbe()
        let recorder = ScanInvocationRecorder()
        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        let store = CatalogStore(
            location: .inMemory,
            scanner: firstScanHangingScanner(probe: probe, recorder: recorder),
            filesystemWatcher: watcher,
            filesystemEventDebounce: .milliseconds(20),
            diagnostics: nil
        )

        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        try await probe.waitForInvocationCount(1)

        emit(FilesystemEvent(path: root.appending(path: "early.jpg").path, flags: 0))
        try await Task.sleep(for: .milliseconds(40))
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

        let recorder = ScanInvocationRecorder()
        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        let store = CatalogStore(
            location: .inMemory,
            scanner: recordingScanner(recorder),
            filesystemWatcher: watcher,
            filesystemEventDebounce: .milliseconds(20),
            diagnostics: nil
        )

        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        let baseline = await recorder.invocations().count

        try await store.removeLibrary(path: rootPath)
        emit(FilesystemEvent(path: root.appending(path: "after-remove.jpg").path, flags: 0))
        try await Task.sleep(for: .milliseconds(80))
        #expect(await recorder.invocations().count == baseline)
    }

    @Test func targetedFileEventReconcilesWithoutFullScan() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appending(path: "first.jpg")
        try writeCatalogStoreFile(first, contents: "jpeg")

        let recorder = ScanInvocationRecorder()
        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        let store = CatalogStore(
            location: .inMemory,
            scanner: recordingLiveScanner(recorder),
            filesystemWatcher: watcher,
            scanCadence: .milliseconds(10),
            filesystemEventDebounce: .milliseconds(30),
            diagnostics: nil
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

        let recorder = ScanInvocationRecorder()
        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        let store = CatalogStore(
            location: .inMemory,
            scanner: recordingLiveScanner(recorder),
            filesystemWatcher: watcher,
            scanCadence: .milliseconds(10),
            filesystemEventDebounce: .milliseconds(30),
            diagnostics: nil
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
            filesystemEventDebounce: .milliseconds(30),
            diagnostics: nil
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

private func recordingScanner(_ recorder: ScanInvocationRecorder) -> CatalogScanner {
    CatalogScanner { rootPath, _, _, _ in
        await recorder.record(rootPath)
        return []
    }
}

private func recordingLiveScanner(_ recorder: ScanInvocationRecorder) -> CatalogScanner {
    CatalogScanner { rootPath, cadence, diagnostics, batchHandler in
        await recorder.record(rootPath)
        return try await CatalogScanner.live.scanRoot(rootPath, cadence, diagnostics, batchHandler)
    }
}

private func deferredHangingScanner(
    probe: FilesystemScanProbe,
    recorder: ScanInvocationRecorder
) -> CatalogScanner {
    CatalogScanner { rootPath, _, _, _ in
        let invocation = await probe.beginInvocation()
        await recorder.record(rootPath)
        if invocation == 2 {
            await probe.waitForRelease(invocation)
        }
        return []
    }
}

private func firstScanHangingScanner(
    probe: FilesystemScanProbe,
    recorder: ScanInvocationRecorder
) -> CatalogScanner {
    CatalogScanner { rootPath, _, _, _ in
        let invocation = await probe.beginInvocation()
        await recorder.record(rootPath)
        if invocation == 1 {
            await probe.waitForRelease(invocation)
        }
        return []
    }
}

private actor ScanInvocationRecorder {
    private var paths: [LibraryRootPath] = []

    func record(_ path: LibraryRootPath) {
        paths.append(path)
    }

    func invocations() -> [LibraryRootPath] {
        paths
    }
}

private actor FilesystemScanProbe {
    private var invocationCount = 0
    private var releasedInvocations = Set<Int>()
    private var releaseWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func beginInvocation() -> Int {
        invocationCount += 1
        return invocationCount
    }

    func waitForInvocationCount(_ expectedCount: Int) async throws {
        // Generous budget: the awaited scan invocation arrives via actor hops on the shared
        // cooperative pool, which the parallel test suite saturates — the work is not slow,
        // its scheduling is delayed. The loop returns as soon as the count is reached, so a
        // large bound never slows a passing run.
        for _ in 0 ..< 600 {
            if invocationCount >= expectedCount {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CatalogStoreFilesystemEventTestError.timedOut
    }

    func waitForRelease(_ invocation: Int) async {
        if releasedInvocations.contains(invocation) {
            return
        }
        await withCheckedContinuation { continuation in
            releaseWaiters[invocation] = continuation
        }
    }

    func release(_ invocation: Int) {
        releasedInvocations.insert(invocation)
        releaseWaiters.removeValue(forKey: invocation)?.resume()
    }
}

private enum CatalogStoreFilesystemEventTestError: Error {
    case timedOut
}

private func waitForFilesystemRescan(
    store: CatalogStore,
    recorder: ScanInvocationRecorder,
    baseline: Int,
    expectedAdditional: Int = 1,
    timeoutAttempts: Int = 200
) async throws {
    for _ in 0 ..< timeoutAttempts {
        let snapshot = try await catalogStoreTestState(store)
        let count = await recorder.invocations().count
        if !snapshot.isScanning, count == baseline + expectedAdditional {
            return
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw CatalogStoreFilesystemEventTestError.timedOut
}
