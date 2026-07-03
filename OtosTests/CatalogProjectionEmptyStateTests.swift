import Foundation
@testable import Otos
import Testing

struct CatalogProjectionEmptyStateTests {
    @Test func storeBackedAllMediaEmptyStateCountsUnavailableCatalogedMedia() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let databaseURL = temp.appending(path: "catalog.sqlite")
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "jpeg".write(to: root.appending(path: "hidden.jpg"), atomically: true, encoding: .utf8)

        let firstStore = CatalogStore(
            location: .databaseFile(databaseURL),
            scanCadence: .milliseconds(10),
            diagnostics: nil
        )
        try await firstStore.start(scansSavedLibraries: false)
        try await firstStore.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(firstStore) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.count == 1
        }
        await firstStore.shutdown()
        try FileManager.default.removeItem(at: root)

        let secondStore = CatalogStore(
            location: .databaseFile(databaseURL),
            scanCadence: .milliseconds(10),
            diagnostics: nil
        )
        let projection = CatalogProjection(cadence: .milliseconds(10), diagnostics: nil)
        let recorder = EmptyStateRecorder()
        let stream = await projection.states(store: secondStore, initialDescriptor: .default)
        let recordingTask = Task {
            for await state in stream {
                await recorder.append(state)
            }
        }
        defer {
            recordingTask.cancel()
        }

        try await secondStore.start()
        _ = try await waitForCatalogStoreState(secondStore) { snapshot in
            snapshot.libraries.first?.availability == .unavailable
        }
        let states = try await recorder.waitForState { states in
            states.contains { state in
                state.libraries.first?.availability == .unavailable
                    && state.mediaGrid.orderedAssetIDs.isEmpty
                    && state.mediaEmptyState == .noAvailableMedia
            }
        }
        #expect(states.contains { $0.mediaEmptyState == .noAvailableMedia })
        await secondStore.shutdown()
    }
}

private typealias EmptyStateRecorder = AsyncValueRecorder<CatalogWindowState>

private extension AsyncValueRecorder where Value == CatalogWindowState {
    func waitForState(
        matching predicate: @escaping @Sendable ([CatalogWindowState]) -> Bool
    ) async throws -> [CatalogWindowState] {
        do {
            return try await withTestTimeout("empty-state projection", timeout: .seconds(10)) {
                await self.waitForValues(matching: predicate)
            }
        } catch {
            throw CatalogProjectionEmptyStateTestError.timedOut
        }
    }
}

private enum CatalogProjectionEmptyStateTestError: Error {
    case timedOut
}
