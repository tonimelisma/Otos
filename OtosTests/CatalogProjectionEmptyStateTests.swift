import Foundation
@testable import OtosKit
import Testing

@Suite(.testScope)
struct CatalogProjectionEmptyStateTests {
    @Test func storeBackedAllMediaEmptyStateCountsUnavailableCatalogedMedia() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "catalog.sqlite")
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "jpeg".write(to: root.appending(path: "hidden.jpg"), atomically: true, encoding: .utf8)

        let firstStore = makeTestStore(
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

        let secondStore = makeTestStore(
            location: .databaseFile(databaseURL),
            scanCadence: .milliseconds(10)
        )
        let projection = CatalogProjection(volumeCapacity: ampleVolumeCapacity, cadence: .milliseconds(10))
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
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }

        let gate = ArrivalGate()
        let projection = CatalogProjection(volumeCapacity: ampleVolumeCapacity, cadence: .milliseconds(10), duplicatesBuilder: { _, _ in
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
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10), stagingContainers: StagingContainers(base: temp))
        try await store.start(scansSavedLibraries: false)
        let rootPath = try await store.addImmichAccount(
            server: #require(URL(string: "https://photos.example.com")), userID: "user-1", displayName: "Family"
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
        let projection = CatalogProjection(volumeCapacity: ampleVolumeCapacity, cadence: .milliseconds(10), duplicatesBuilder: { _, _ in
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

    /// Each derived owner is rebuilt only when a kind of fact its answer is built from moved
    /// (`DuplicatesProjection.inputs`, `PeopleGallery.inputs`): a new person is a faces
    /// fact, which People reads and the groups do not; copies kept together are a copies
    /// fact, which the groups read and People does not.
    @Test func eachDerivedOwnerIsRebuiltOnlyWhenAFactItIsBuiltFromMoved() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["a.jpg", "b.jpg"] {
            try "jpeg \(name)".write(to: root.appending(path: name), atomically: true, encoding: .utf8)
        }
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let state = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 2 }
        let ids = state.testAssets.map(\.id)

        let duplicatesGate = ArrivalGate()
        let peopleGate = ArrivalGate()
        await duplicatesGate.open()
        await peopleGate.open()
        let projection = CatalogProjection(
            volumeCapacity: ampleVolumeCapacity,
            cadence: .milliseconds(10),
            duplicatesBuilder: { _, _ in
                await duplicatesGate.arrive()
                return .empty
            },
            peopleBuilder: { _, _ in
                await peopleGate.arrive()
                return .empty
            }
        )
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
                let peopleSettled = await projection.peopleAreQuiescent
                return windowSettled && duplicatesSettled && peopleSettled
            }
        }
        await duplicatesGate.waitForArrivals(1)
        await peopleGate.waitForArrivals(1)
        try await settle()
        let groupsBefore = await duplicatesGate.arrivalCount
        let peopleBefore = await peopleGate.arrivalCount

        _ = try await store.perform(.moveToNewPerson([], name: "Sam"))
        await peopleGate.waitForArrivals(peopleBefore + 1)
        try await settle()
        #expect(await duplicatesGate.arrivalCount == groupsBefore)
        let peopleAfterFaces = await peopleGate.arrivalCount

        _ = try await store.keepCopiesTogether([ids])
        await duplicatesGate.waitForArrivals(groupsBefore + 1)
        try await settle()
        #expect(await peopleGate.arrivalCount == peopleAfterFaces)
        await store.shutdown()
    }

    /// A row only added is one more still not yet checked for faces, so People's unchecked
    /// tally counts it, though neither the groups nor the assignment are rebuilt for it.
    @Test func addedRowsAreCountedInPeoplesTallyWithoutRebuildingDuplicates() async throws {
        let temp = try makeTestDirectory()
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10), stagingContainers: StagingContainers(base: temp))
        try await store.start(scansSavedLibraries: false)
        let rootPath = try await store.addImmichAccount(
            server: #require(URL(string: "https://photos.example.com")), userID: "user-1", displayName: "Family"
        )
        func item(_ id: String) -> SourceListedItem {
            SourceListedItem(
                file: ScannedMediaFile(
                    relativePath: MediaRelativePath(rawValue: "\(id)/IMG.JPG"),
                    name: "IMG.JPG",
                    contentTypeIdentifier: "public.jpeg",
                    byteSize: 10,
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
        let projection = CatalogProjection(volumeCapacity: ampleVolumeCapacity, cadence: .milliseconds(10), duplicatesBuilder: { _, _ in
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
                let peopleSettled = await projection.peopleAreQuiescent
                return windowSettled && duplicatesSettled && peopleSettled
            }
        }
        let scan = try await store.beginSourceListing(rootPath: rootPath)
        _ = await recorder.waitForState { states in
            states.contains { state in
                state.people != nil && state.libraries.contains { $0.path == rootPath && $0.activity == .enumerating }
            }
        }
        try await settle()
        let built = await gate.arrivalCount

        try await store.applySourceListingChanges(SourceListingChanges(listed: [item("a")]), scan: scan)
        let counted = await recorder.waitForState { states in
            states.contains { $0.mediaGrid.orderedAssetIDs.count == 1 && $0.people?.unchecked.photos == 1 }
        }
        #expect(counted.contains { $0.people?.unchecked.photos == 1 })
        try await settle()
        #expect(await gate.arrivalCount == built)
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
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)

        let gate = ArrivalGate()
        let projection = CatalogProjection(volumeCapacity: ampleVolumeCapacity, cadence: .milliseconds(10), duplicatesBuilder: { _, _ in
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
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        let projection = CatalogProjection(volumeCapacity: ampleVolumeCapacity, cadence: .milliseconds(10))
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
        let firstStore = makeTestStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await firstStore.start(scansSavedLibraries: false)
        try await firstStore.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(firstStore) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.count == 1
        }
        await firstStore.shutdown()

        let store = makeTestStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        let projection = CatalogProjection(volumeCapacity: ampleVolumeCapacity, cadence: .seconds(60))
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

    /// A window that shows no item has no grid a background change could reorder, so a change
    /// of which rows exist publishes at once: a library added to an empty catalog is listed,
    /// and its first scan batch shown, without waiting for the cadence. The cadence is an
    /// hour, so only immediate publications pass.
    @Test func aNewLibrarysFirstRowsReachAnEmptyWindowWithoutTheCadence() async throws {
        let root = try makeTestDirectory().appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0 ..< 3 {
            try writeCatalogStoreFile(root.appending(path: "photo-\(index).jpg"), contents: "jpeg")
        }
        let store = makeTestStore(location: .inMemory, scanCadence: .seconds(3600))
        try await store.start(scansSavedLibraries: false)
        let projection = CatalogProjection(volumeCapacity: ampleVolumeCapacity, cadence: .seconds(3600))
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
            states.contains { $0.mediaEmptyState == .noMedia }
        }

        try await store.addLibrary(url: root)

        let states = await recorder.waitForState { states in
            states.contains { $0.mediaGrid.orderedAssetIDs.count == 3 }
        }
        #expect(states.contains { $0.libraries.count == 1 && $0.mediaGrid.orderedAssetIDs.isEmpty })
        await store.shutdown()
    }

    /// The cadence still paces a shown grid: once the window shows items, a library added
    /// beside them is owed a publication that no doorbell rings, and is published on the next
    /// tick (here an hour away).
    @Test func aShownGridStillTakesARowChangeOnTheCadence() async throws {
        let root = try makeTestDirectory().appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "photo.jpg"), contents: "jpeg")
        let store = makeTestStore(location: .inMemory, scanCadence: .seconds(3600))
        try await store.start(scansSavedLibraries: false)
        let projection = CatalogProjection(volumeCapacity: ampleVolumeCapacity, cadence: .seconds(3600))
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
        try await store.addLibrary(url: root)
        _ = await recorder.waitForState { states in
            states.contains { $0.mediaGrid.orderedAssetIDs.count == 1 }
        }
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }

        let heard = await projection.detailRefreshGeneration
        try await store.addLibrary(url: makeTestDirectory())
        try await waitUntil { await projection.detailRefreshGeneration > heard }

        #expect(await !projection.isQuiescent)
        #expect(await recorder.snapshot().allSatisfy { $0.libraries.count < 2 })
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
