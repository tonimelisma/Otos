import Foundation
@testable import OtosKit
import Testing

@Suite(.testDirectory)
struct CatalogProjectionEmptyStateTests {
    @Test func storeBackedAllMediaEmptyStateCountsUnavailableCatalogedMedia() async throws {
        let temp = try makeTestDirectory()
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

    /// Duplicate detection never holds back the window: with the duplicates build parked
    /// at its suspension, the loaded window — sidebar and grid — is already published, with
    /// its groups unknown rather than empty; released, the groups follow.
    @Test func theWindowPublishesBeforeDuplicatesAreBuilt() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "jpeg".write(to: root.appending(path: "a.jpg"), atomically: true, encoding: .utf8)
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }

        let gate = ArrivalGate()
        let projection = CatalogProjection(cadence: .milliseconds(10), duplicatesBuilder: { _, _ in
            await gate.arrive()
            return .empty
        })
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

        await gate.waitForArrivals(1)
        let window = await recorder.waitForState { states in
            states.contains { !$0.libraries.isEmpty && $0.mediaGrid.orderedAssetIDs.count == 1 }
        }
        #expect(window.last?.duplicates == nil)

        await gate.open()
        let built = await recorder.waitForState { states in
            states.contains { $0.duplicates != nil }
        }
        #expect(built.last?.duplicates == .empty)
        #expect(built.last?.libraries.isEmpty == false)
        await store.shutdown()
    }

    /// Rows that were only added carry nothing a duplicate group is built from, so they are
    /// published in the window without a rebuild of the groups; a change to a row the
    /// catalog holds still rebuilds them.
    @Test func addedRowsArePublishedWithoutRebuildingDuplicates() async throws {
        let temp = try makeTestDirectory()
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        let rootPath = try await store.addImmichAccount(
            server: #require(URL(string: "https://photos.example.com")), userID: "user-1", displayName: "Family",
            stagingContainer: temp.appending(path: "RemoteStaging")
        )
        func item(_ id: String, size: Int64) -> SourceListedItem {
            SourceListedItem(
                file: ScannedMediaFile(
                    relativePath: MediaRelativePath(rawValue: "\(id)/IMG.JPG"),
                    name: "IMG.JPG",
                    contentTypeIdentifier: "public.jpeg",
                    byteSize: size,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    contentModifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
                ),
                sourceItemID: id,
                isHiddenBySource: false,
                sourceHasProducts: true
            )
        }
        let gate = ArrivalGate()
        await gate.open()
        let projection = CatalogProjection(cadence: .milliseconds(10), duplicatesBuilder: { _, _ in
            await gate.arrive()
            return .empty
        })
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
        func settle() async throws {
            try await waitUntil {
                let windowSettled = await projection.isQuiescent
                let duplicatesSettled = await projection.duplicatesAreQuiescent
                return windowSettled && duplicatesSettled
            }
        }
        // The lease's own change is a catalog change: its publication (the account listing)
        // and the build it asks for are settled before the count is read.
        let scan = try await store.beginSourceListing(rootPath: rootPath)
        _ = await recorder.waitForState { states in
            states.contains { state in
                state.duplicates != nil
                    && state.libraries.contains { $0.path == rootPath && $0.activity == .enumerating }
            }
        }
        try await settle()
        let built = await gate.arrivalCount

        try await store.applySourceListingChanges(SourceListingChanges(listed: [item("a", size: 10)]), scan: scan)
        _ = await recorder.waitForState { states in states.contains { $0.mediaGrid.orderedAssetIDs.count == 1 } }
        try await settle()
        #expect(await gate.arrivalCount == built)

        try await store.applySourceListingChanges(SourceListingChanges(listed: [item("a", size: 20)]), scan: scan)
        await gate.waitForArrivals(built + 1)
        await store.endSourceListing(scan: scan)
        await store.shutdown()
    }

    /// The groups are a fact about the whole catalog, so a change of scope neither waits for
    /// their build nor starts one: with the build parked at its suspension, choosing a
    /// library publishes it; released, the groups are built exactly once.
    @Test func aScopeChangeNeitherWaitsForNorRebuildsDuplicates() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "jpeg".write(to: root.appending(path: "a.jpg"), atomically: true, encoding: .utf8)
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)

        let gate = ArrivalGate()
        let projection = CatalogProjection(cadence: .milliseconds(10), duplicatesBuilder: { _, _ in
            await gate.arrive()
            return .empty
        })
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

        await gate.waitForArrivals(1)
        await projection.updateSidebarSelection(.library(rootPath))
        let chosen = await recorder.waitForState { states in
            states.contains { $0.resolvedSidebarSelection == .library(rootPath) }
        }
        #expect(chosen.last?.duplicates == nil)

        await gate.open()
        _ = await recorder.waitForState { states in
            states.contains { $0.duplicates != nil }
        }
        try await waitUntil {
            let windowSettled = await projection.isQuiescent
            let duplicatesSettled = await projection.duplicatesAreQuiescent
            return windowSettled && duplicatesSettled
        }
        #expect(await gate.arrivalCount == 1)
        await store.shutdown()
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
        let temp = try makeTestDirectory()
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
