import Foundation
@testable import OtosKit
import Testing

/// Execution progress reaches the coordinator through one per-run stream, so a sample can
/// neither arrive after the run settled nor overtake a newer one.
@Suite(.testDirectory)
struct MediaOperationCoordinatorProgressTests {
    private static func progress(_ completed: Int, bytes: Int64) -> MediaOperationProgress {
        MediaOperationProgress(
            completedCount: completed,
            totalCount: 3,
            completedBytes: bytes,
            totalBytes: 3072,
            elapsedMs: completed * 10
        )
    }

    @Test func noProgressIsPresentedAfterTheRunSettles() async throws {
        let temp = try makeTestDirectory()
        let destURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardURL, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 1024).write(to: cardURL.appending(path: "f.jpg"))

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: .volume(uuid: "progress-order"),
            displayName: "Card",
            isEjectable: true
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardPath && !$0.isScanning }
        }

        let defaults = PreferencesDomain.suite(UUID().uuidString)
        let execControl = ControlledExecutionControl()
        await execControl.suspendNextExecution(for: cardPath)
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: defaults,
            volumeCapacity: ampleVolumeCapacity,
            makeExecutor: { _ in ControlledImportExecutor(control: execControl) }
        )
        await coordinator.start()
        await markEnrichmentLookedAtEveryRow(store, root: cardPath)
        let recorder = AsyncValueRecorder<MediaOperationSourceState>()
        let stream = await coordinator.presentationsStream()
        let recording = Task {
            for await presentations in stream {
                if let state = presentations.first(where: { $0.sourcePath == cardPath })?.state {
                    await recorder.append(state)
                }
            }
        }
        _ = await recorder.waitForValues { states in
            states.contains {
                if case .ready = $0 {
                    true
                } else {
                    false
                }
            }
        }

        let queueTask = Task { await coordinator.queueImport(for: cardPath) }
        try await waitUntil { await execControl.pendingSources().contains(cardPath) }
        let last = Self.progress(2, bytes: 2048)
        await execControl.sendProgress(Self.progress(1, bytes: 1024), for: cardPath)
        await execControl.sendProgress(last, for: cardPath)
        await execControl.resumePending(
            for: cardPath,
            with: .completed(.tally(published: 1), incompleteItems: [], erase: nil)
        )
        await queueTask.value
        try await waitForCoordinatorQuiescence(coordinator)
        recording.cancel()

        let states = await recorder.snapshot()
        let firstSettled = try #require(states.firstIndex { state in
            if case .completed = state {
                true
            } else {
                false
            }
        })
        // Every sample the run sent was delivered before it settled, and the newest wins.
        #expect(states[..<firstSettled].contains(.executing(progress: last)))
        // None can follow the settlement.
        #expect(!states[firstSettled...].contains {
            if case .executing = $0 {
                true
            } else {
                false
            }
        })
        await coordinator.shutdown()
    }
}
