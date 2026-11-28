import Foundation
@testable import OtosKit
import Testing

/// Execution progress reaches the coordinator through one per-run stream, so a sample can
/// neither arrive after the run settled nor overtake a newer one.
@Suite(.testScope)
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

    // Validates: ARC-047
    @Test func noProgressIsPresentedAfterTheRunSettles() async throws {
        let temp = try makeTestDirectory()
        let destURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardURL, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 1024).write(to: cardURL.appending(path: "f.jpg"))

        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: .volume(uuid: "progress-order"),
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardPath && !$0.isScanning }
        }

        let defaults = PreferencesDomain.suite(UUID().uuidString)
        let execControl = ControlledExecutionControl()
        await execControl.suspendNextExecution(for: cardPath)
        let builder = ControlledImportPlanBuilder()
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: defaults,
            planBuilder: builder,
            volumeCapacity: ampleVolumeCapacity,
            makeExecutor: { _ in ControlledImportExecutor(control: execControl) }
        )
        await coordinator.start()
        await markEnrichmentLookedAtEveryRow(store, root: cardPath)
        try await waitUntil { await coordinator.readyPlan(for: cardPath) != nil }

        // Each state is read from the coordinator while the test holds the step that would
        // replace it: the run while its progress is read, the re-plan while its settlement
        // is. The presentation stream keeps only the newest frame, so a frame a reader had
        // not yet taken when the next one was published is never seen at all.
        let queueTask = Task { await coordinator.queueImport(for: cardPath) }
        try await waitUntil { await execControl.pendingSources().contains(cardPath) }
        let last = Self.progress(2, bytes: 2048)
        await execControl.sendProgress(Self.progress(1, bytes: 1024), for: cardPath)
        await execControl.sendProgress(last, for: cardPath)
        // The run's samples are delivered in order, so the newest is what it settles on.
        try await waitUntil { await presented(coordinator, cardPath) == .executing(progress: last) }

        await builder.suspendNextBuild(for: cardPath)
        await execControl.resumePending(
            for: cardPath,
            with: .completed(.tally(published: 1), incompleteItems: [], erase: nil)
        )
        await queueTask.value
        try await waitForPendingBuilder(builder, source: cardPath)
        // The run's samples were drained before it settled, so the settlement is what shows.
        let settled = await presented(coordinator, cardPath)
        await builder.resumePendingBuild(for: cardPath)
        try await waitForCoordinatorQuiescence(coordinator)
        let replanned = await presented(coordinator, cardPath)
        #expect(settled.map(Self.isCompleted) == true, "settled as \(String(describing: settled))")
        // None can follow the settlement.
        #expect(replanned.map(Self.isExecuting) == false, "re-planned as \(String(describing: replanned))")
        await coordinator.shutdown()
    }

    private func presented(
        _ coordinator: MediaOperationCoordinator,
        _ source: LibraryRootPath
    ) async -> MediaOperationSourceState? {
        await coordinator.currentPresentations().first { $0.sourcePath == source }?.state
    }

    private static func isCompleted(_ state: MediaOperationSourceState) -> Bool {
        if case .completed = state {
            true
        } else {
            false
        }
    }

    private static func isExecuting(_ state: MediaOperationSourceState) -> Bool {
        if case .executing = state {
            true
        } else {
            false
        }
    }
}
