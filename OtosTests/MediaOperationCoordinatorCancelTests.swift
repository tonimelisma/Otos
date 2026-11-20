import Foundation
@testable import OtosKit
import Testing

/// A user's Cancel stops the run it was given for, wherever that run is (ARC-047): the
/// coordinator holds the run's executor from the step that starts it, before the run's
/// source-read bracket or its hop onto the executor, and an executor's cancel is never undone.
@Suite(.testScope)
struct MediaOperationCoordinatorCancelTests {
    /// The cancel is delivered while the run waits at its start, after its source-read bracket
    /// and before the real executor's `execute` begins: the run ends stopped by the user, and
    /// nothing is copied.
    @Test func aCancelBeforeTheRunsExecutorBeginsStopsItWithNothingCopied() async throws {
        let temp = try makeTestDirectory()
        let destURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardURL, withIntermediateDirectories: true)
        for name in ["a.jpg", "b.jpg"] {
            try Data(repeating: 3, count: 1024).write(to: cardURL.appending(path: name))
        }

        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: .volume(uuid: "cancel-before-start"),
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardPath && !$0.isScanning }
        }

        let defaults = PreferencesDomain.suite(UUID().uuidString)
        var prefs = ImportPreferences.default
        prefs.destinationFolderPolicy = .none
        prefs.destinationNamePolicy = .original
        ImportPreferencesStore.save(prefs, defaults: defaults.makeDefaults())

        let execControl = ControlledExecutionControl()
        await execControl.holdStartOfNextExecution(for: cardPath)
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: defaults,
            volumeCapacity: ampleVolumeCapacity,
            makeExecutor: { _ in
                ControlledImportExecutor(
                    control: execControl,
                    live: MediaImportExecutor(store: store, volumeCapacity: ampleVolumeCapacity)
                )
            }
        )
        await coordinator.start()
        let plan = try await waitForValue(every: .milliseconds(20)) { await coordinator.readyPlan(for: cardPath) }
        #expect(plan.totals.copyCount == 2)

        let queueTask = Task { await coordinator.queueImport(for: cardPath) }
        try await waitUntil(every: .milliseconds(10)) { await execControl.heldStartSources().contains(cardPath) }
        await coordinator.cancelImport(for: cardPath)
        await execControl.releaseStart(for: cardPath)
        await queueTask.value

        let copied = try FileManager.default.contentsOfDirectory(atPath: destURL.path(percentEncoded: false))
            .filter { !$0.hasPrefix(".") }
        #expect(copied.isEmpty, "a cancelled run copies nothing, got \(copied)")
        // The run's outcome, however it ended: `copiedJustNow` is set once a run settles.
        let settled = try await waitForValue(every: .milliseconds(20)) {
            await coordinator.currentPresentations().first { $0.sourcePath == cardPath && $0.copiedJustNow != nil }
        }
        #expect(settled.stopReason == .user)
        #expect(settled.copiedJustNow == 0)
        await coordinator.shutdown()
        await store.shutdown()
    }
}
