import Foundation
@testable import OtosKit
import Testing

/// ENR-017: an import run brackets its read of the source in the Store, so enrichment
/// leaves a card alone exactly while it is copied, however the run ends.
@Suite(.testScope)
struct MediaOperationCoordinatorSourceReadTests {
    @Test func aCardIsNotEnrichedWhileItsImportRunsAndIsAfterItFails() async throws {
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
            identity: .volume(uuid: "source-read"),
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardPath && !$0.isScanning }
        }

        let execControl = ControlledExecutionControl()
        await execControl.suspendNextExecution(for: cardPath)
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: PreferencesDomain.suite(UUID().uuidString),
            volumeCapacity: ampleVolumeCapacity,
            makeExecutor: { _ in ControlledImportExecutor(control: execControl) }
        )
        await coordinator.start()
        await markEnrichmentLookedAtEveryRow(store, root: cardPath)
        try await waitUntil { await coordinator.readyPlan(for: cardPath) != nil }
        #expect(await store.enrichableRootPaths().contains(cardPath))

        let queueTask = Task { await coordinator.queueImport(for: cardPath) }
        try await waitUntil { await execControl.pendingSources().contains(cardPath) }
        #expect(await !(store.enrichableRootPaths().contains(cardPath)))

        await execControl.resumePending(
            for: cardPath,
            with: .failed(.unexpected(detail: "test"), publishedCount: 0)
        )
        await queueTask.value
        // The run closes its bracket before it reports the result.
        try await waitUntil { await store.enrichableRootPaths().contains(cardPath) }
        try await waitForCoordinatorQuiescence(coordinator)
        await coordinator.shutdown()
    }
}
