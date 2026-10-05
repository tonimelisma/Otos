import Foundation
@testable import OtosKit
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
            scanCadence: .milliseconds(10)
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
            scanCadence: .milliseconds(10)
        )
        let projection = CatalogProjection(cadence: .milliseconds(10))
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
        let states = await recorder.waitForState { states in
            states.contains { state in
                state.libraries.first?.availability == .unavailable
                    && state.mediaGrid.orderedAssetIDs.isEmpty
                    && state.mediaEmptyState == .libraryUnavailable
            }
        }
        #expect(states.contains { $0.mediaEmptyState == .libraryUnavailable })
        await secondStore.shutdown()
    }

    /// Before the catalog's first load nothing is known, so nothing is claimed: no
    /// "No Media", no title (APP-044). A catalog that really is empty says so once loaded.
    @Test func beforeTheCatalogLoadsNoEmptinessIsClaimed() async throws {
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        let projection = CatalogProjection(cadence: .milliseconds(10))
        let recorder = EmptyStateRecorder()
        let stream = await projection.states(store: store, initialDescriptor: .default)
        let recordingTask = Task {
            for await state in stream {
                await recorder.append(state)
            }
        }
        defer {
            recordingTask.cancel()
        }

        let beforeLoad = await recorder.waitForState { !$0.isEmpty }
        #expect(beforeLoad.first?.mediaEmptyState == .loadingCatalog)
        #expect(beforeLoad.first?.title == "")

        try await store.start(scansSavedLibraries: false)
        let states = await recorder.waitForState { states in
            states.contains { $0.mediaEmptyState == .noMedia }
        }
        let firstClaim = try #require(states.firstIndex { $0.mediaEmptyState != .loadingCatalog })
        #expect(states[firstClaim].mediaEmptyState == .noMedia)
        #expect(states[..<firstClaim].allSatisfy { $0.mediaEmptyState == .loadingCatalog })
        await store.shutdown()
    }

    /// The load is the moment the window becomes meaningful, so it publishes at once
    /// instead of waiting for the background cadence (APP-044). The cadence here is a
    /// minute; the wait is ten seconds, so only an immediate publication passes.
    @Test func theCatalogLoadPublishesWithoutWaitingForTheCadence() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let databaseURL = temp.appending(path: "catalog.sqlite")
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "jpeg".write(to: root.appending(path: "one.jpg"), atomically: true, encoding: .utf8)
        let firstStore = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await firstStore.start(scansSavedLibraries: false)
        try await firstStore.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(firstStore) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.count == 1
        }
        await firstStore.shutdown()

        let store = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        let projection = CatalogProjection(cadence: .seconds(60))
        let recorder = EmptyStateRecorder()
        let stream = await projection.states(store: store, initialDescriptor: .default)
        let recordingTask = Task {
            for await state in stream {
                await recorder.append(state)
            }
        }
        defer {
            recordingTask.cancel()
        }
        _ = await recorder.waitForState { states in
            states.contains { $0.mediaEmptyState == .loadingCatalog }
        }

        try await store.start(scansSavedLibraries: false)

        let states = await recorder.waitForState { states in
            states.contains { $0.libraries.count == 1 }
        }
        #expect(states.last?.mediaEmptyState != .loadingCatalog)
        await store.shutdown()
    }
}

private typealias EmptyStateRecorder = AsyncValueRecorder<CatalogWindowState>

private extension AsyncValueRecorder where Value == CatalogWindowState {
    func waitForState(
        matching predicate: @escaping @Sendable ([CatalogWindowState]) -> Bool
    ) async -> [CatalogWindowState] {
        await waitForValues(matching: predicate)
    }
}
