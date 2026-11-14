import Foundation
@testable import OtosKit
import Testing

@Suite(.testDirectory)
struct CatalogProjectionTests {
    /// Library-kind roots preserve their incoming (`sort_index`) order rather
    /// than being re-sorted by name — the user's own Settings → Libraries order.
    /// Asset ordering within the grid is unaffected.
    @Test func windowStatePreservesLibraryOrderAndSortsAssets() async {
        let pictures = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures"))
        let archive = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Archive"))
        let projection = CatalogProjection()
        let fixture = makeProjectionFixture(
            libraries: [
                makeLibrary(root: pictures, activity: .scanning),
                makeLibrary(root: archive),
            ],
            assets: [
                makeAsset(root: pictures, relativePath: "z.jpg"),
                makeAsset(root: archive, relativePath: "b.jpg"),
                makeAsset(root: archive, relativePath: "a.jpg"),
            ]
        )

        let state = await projection.windowState(
            fixture: fixture,
            sidebarSelection: .allMedia
        )

        #expect(state.libraries.map(\.displayName) == ["Pictures", "Archive"])
        #expect(state.libraries.map(\.activity) == [.scanning, .idle])
        #expect(state.mediaGrid.orderedAssetIDs.map(\.relativePath.rawValue) == ["a.jpg", "b.jpg", "z.jpg"])
    }

    @Test func windowStateFallsBackWhenSelectedLibraryIsMissing() async {
        let projection = CatalogProjection()
        let pictures = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures"))
        let archive = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Archive"))

        let state = await projection.windowState(
            fixture: makeProjectionFixture(
                libraries: [makeLibrary(root: pictures)],
                assets: [
                    makeAsset(root: pictures, relativePath: "one.jpg"),
                    makeAsset(root: archive, relativePath: "hidden.jpg"),
                ]
            ),
            sidebarSelection: .library(archive.path)
        )

        #expect(state.title == "Pictures")
        #expect(state.resolvedSidebarSelection == .library(pictures.path))
        #expect(state.mediaGrid.orderedAssetIDs.map(\.relativePath.rawValue) == ["one.jpg"])
    }

    @Test func windowStateHidesUnavailableLibraryAssets() async {
        let projection = CatalogProjection()
        let pictures = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures"))
        let archive = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Archive"))
        let fixture = makeProjectionFixture(
            libraries: [
                makeLibrary(root: pictures, availability: .unavailable),
                makeLibrary(root: archive),
            ],
            assets: [
                makeAsset(root: pictures, relativePath: "hidden.jpg"),
                makeAsset(root: archive, relativePath: "shown.jpg"),
            ]
        )

        let allMedia = await projection.windowState(fixture: fixture, sidebarSelection: .allMedia)
        let selectedUnavailable = await projection.windowState(
            fixture: fixture,
            sidebarSelection: .library(pictures.path)
        )

        #expect(allMedia.mediaGrid.orderedAssetIDs.map(\.relativePath.rawValue) == ["shown.jpg"])
        #expect(selectedUnavailable.mediaGrid.orderedAssetIDs.isEmpty)
        #expect(selectedUnavailable.mediaEmptyState == .libraryUnavailable)
    }

    @Test func windowStateHidesUnknownAssetsAndReportsCheckingStates() async {
        let projection = CatalogProjection()
        let pictures = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures"))
        let archive = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Archive"))
        let fixture = makeProjectionFixture(
            libraries: [
                makeLibrary(root: pictures, availability: .unknown),
                makeLibrary(root: archive, availability: .available),
            ],
            assets: [makeAsset(root: pictures, relativePath: "cached.jpg")]
        )

        let allMedia = await projection.windowState(fixture: fixture, sidebarSelection: .allMedia)
        let selected = await projection.windowState(
            fixture: fixture,
            sidebarSelection: .library(pictures.path)
        )

        #expect(allMedia.mediaGrid.orderedAssetIDs.isEmpty)
        #expect(allMedia.mediaEmptyState == .checkingLibraries)
        #expect(selected.mediaGrid.orderedAssetIDs.isEmpty)
        #expect(selected.mediaEmptyState == .libraryChecking)
    }

    @Test func availableAssetsRemainVisibleWhileAnotherLibraryIsUnknown() async {
        let projection = CatalogProjection()
        let pictures = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures"))
        let archive = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Archive"))
        let fixture = makeProjectionFixture(
            libraries: [
                makeLibrary(root: pictures),
                makeLibrary(root: archive, availability: .unknown),
            ],
            assets: [
                makeAsset(root: pictures, relativePath: "shown.jpg"),
                makeAsset(root: archive, relativePath: "hidden.jpg"),
            ]
        )

        let state = await projection.windowState(fixture: fixture, sidebarSelection: .allMedia)

        #expect(state.mediaGrid.orderedAssetIDs.map(\.relativePath.rawValue) == ["shown.jpg"])
        // A scope with items has no empty state to say.
        #expect(state.mediaEmptyState == nil)
    }

    @Test func allMediaEmptyStateDistinguishesUnavailableCatalogedMedia() async {
        let projection = CatalogProjection()
        let pictures = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures"))
        let fixture = makeProjectionFixture(
            libraries: [makeLibrary(root: pictures, availability: .unavailable)],
            assets: [makeAsset(root: pictures, relativePath: "hidden.jpg")]
        )

        let state = await projection.windowState(fixture: fixture, sidebarSelection: .allMedia)

        #expect(state.mediaGrid.orderedAssetIDs.isEmpty)
        #expect(state.mediaEmptyState == .libraryUnavailable)
    }

    @Test func publicationLoopCoalescesStoreAndSidebarChanges() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        let projection = CatalogProjection(cadence: .milliseconds(10))
        let recorder = StateRecorder()
        let stream = await projection.states(store: store, initialDescriptor: .default)
        let recordingTask = Task {
            for await state in stream {
                await recorder.append(state)
            }
        }
        defer {
            recordingTask.cancel()
        }

        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        await projection.updateSidebarSelection(.library(rootPath))

        let states = await recorder.waitForCount(1) { states in
            states.contains { $0.resolvedSidebarSelection == .library(rootPath) }
        }

        #expect(states.contains { $0.libraries.map(\.path) == [rootPath] })
    }

    @Test func publicationLoopRunsOneProjectionAtATimeAndRerunsWhenDirtyDuringRun() async throws {
        let store = CatalogStore(location: .inMemory)
        // Projection builds only for a loaded catalog (APP-044).
        try await store.start(scansSavedLibraries: false)
        let probe = ProjectionProbe()
        let projection = CatalogProjection(
            cadence: .milliseconds(10),
            stateBuilder: { libraries, orderedAssetIDs, request in
                try await probe.build(
                    libraries: libraries,
                    orderedAssetIDs: orderedAssetIDs,
                    request: request
                )
            }
        )
        let recorder = StateRecorder()
        let stream = await projection.states(store: store, initialDescriptor: .default)
        let recordingTask = Task {
            for await state in stream {
                await recorder.append(state)
            }
        }
        defer {
            recordingTask.cancel()
        }

        await probe.waitUntilInFlight()
        await projection.updateSidebarSelection(.library(LibraryRootPath(rawValue: "/Users/example/Pictures")))
        await probe.releaseBuilds()

        _ = await recorder.waitForCount(2)
        #expect(await probe.maximumInFlight() == 1)
        #expect(await probe.callCount() >= 2)
    }

    @Test func newerIntentDuringPublicationNeverCancelsTheRunningBuild() async throws {
        let store = CatalogStore(location: .inMemory)
        try await store.start(scansSavedLibraries: false)
        let probe = ProjectionProbe()
        let projection = CatalogProjection(
            cadence: .seconds(3600),
            stateBuilder: { libraries, orderedAssetIDs, request in
                try await probe.build(
                    libraries: libraries,
                    orderedAssetIDs: orderedAssetIDs,
                    request: request
                )
            }
        )
        let recorder = StateRecorder()
        let stream = await projection.states(store: store, initialDescriptor: .default)
        let recordingTask = Task {
            for await state in stream {
                await recorder.append(state)
            }
        }
        defer {
            recordingTask.cancel()
        }
        let pictures = SidebarSelection.library(LibraryRootPath(rawValue: "/Users/example/Pictures"))

        // The initial publication's build is parked; a sidebar intent arrives under it.
        await probe.waitUntilInFlight()
        await projection.updateSidebarSelection(pictures)
        await probe.releaseBuilds()

        let states = await recorder.waitForCount(1) { states in
            states.contains { $0.resolvedSidebarSelection == pictures }
        }
        #expect(states.contains { $0.resolvedSidebarSelection == pictures })
        #expect(await probe.cancelledBuildCount() == 0)
    }

    @Test func aFailedBuildPublishesNothingAndTheNextIntentRetries() async throws {
        let store = CatalogStore(location: .inMemory)
        try await store.start(scansSavedLibraries: false)
        let probe = ProjectionProbe()
        await probe.failCall(1)
        await probe.releaseBuilds()
        // An hour-long cadence: only the intent can retry the failed pass.
        let projection = makeProbedProjection(probe, cadence: .seconds(3600))
        let recorder = StateRecorder()
        let stream = await projection.states(store: store, initialDescriptor: .default)
        let recordingTask = Task {
            for await state in stream {
                await recorder.append(state)
            }
        }
        defer {
            recordingTask.cancel()
        }
        let pictures = SidebarSelection.library(LibraryRootPath(rawValue: "/Users/example/Pictures"))

        // Call 1 is the initial publication and its read fails. Once it has started it
        // has taken up everything requested, so an intent now is a new request.
        try await waitUntil { await probe.callCount() >= 1 }
        await projection.updateSidebarSelection(pictures)

        let states = await recorder.waitForCount(1) { states in
            states.contains { $0.resolvedSidebarSelection == pictures }
        }
        try await waitForProjectionQuiescence(projection)

        #expect(await probe.callCount() >= 2)
        // Every published state came from a build that read successfully: the failed call
        // published nothing, not an empty catalog.
        #expect(states.allSatisfy { $0.title.hasPrefix("Call ") && $0.title != "Call 1" })
    }

    @Test func aStoreChangeDuringABuildIsPublishedAfterIt() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = CatalogStore(location: .inMemory)
        try await store.start(scansSavedLibraries: false)
        let probe = ProjectionProbe()
        // An hour-long cadence: only the finishing pass noticing the new request can
        // publish the change.
        let projection = makeProbedProjection(probe, cadence: .seconds(3600))
        let recorder = StateRecorder()
        let stream = await projection.states(store: store, initialDescriptor: .default)
        let recordingTask = Task {
            for await state in stream {
                await recorder.append(state)
            }
        }
        defer {
            recordingTask.cancel()
        }

        await probe.waitUntilInFlight()
        let changesBefore = await projection.detailRefreshGeneration
        try await store.addLibrary(url: root)
        // Release only once the projection has recorded the change, so it arrived
        // during the build rather than after it.
        try await waitUntil { await projection.detailRefreshGeneration > changesBefore }
        await probe.releaseBuilds()

        let states = await recorder.waitForCount(1) { states in
            states.contains { $0.libraries.count == 1 }
        }
        #expect(states.contains { $0.libraries.count == 1 })
    }

    @Test func teardownDuringABuildPublishesNothing() async throws {
        let store = CatalogStore(location: .inMemory)
        try await store.start(scansSavedLibraries: false)
        let probe = ProjectionProbe()
        let projection = makeProbedProjection(probe, cadence: .seconds(3600))
        let recorder = StateRecorder()
        let stream = await projection.states(store: store, initialDescriptor: .default)
        let recordingTask = Task {
            for await state in stream {
                await recorder.append(state)
            }
        }

        await probe.waitUntilInFlight()
        let publishedBefore = await projection.publicationCount
        recordingTask.cancel()
        try await waitUntil { await !projection.hasSubscribers }
        await probe.releaseBuilds()
        try await waitForProjectionQuiescence(projection)

        #expect(await projection.publicationCount == publishedBefore)
        #expect(await recorder.count() == 0)
    }

    @Test func detailOnlyStoreChangePublishesGridRefreshGeneration() async throws {
        let fixture = try await makeDetailRefreshFixture()
        defer {
            fixture.recordingTask.cancel()
        }

        let asset = try #require(try await fixture.store.mediaAssets(for: [fixture.id])[fixture.id])
        let sourceMTime = try #require(asset.contentModifiedAt.map { Int($0.timeIntervalSince1970) })
        let outcome = await fixture.store.applyEnrichmentBatch([
            EnrichmentResult(
                id: fixture.id,
                metadata: AssetMetadata(
                    timestamps: [.absolute(instant: Date(timeIntervalSince1970: 700))],
                    cameraModel: "Cam"
                ),
                thumbnailPath: "thumb.jpg",
                sourceSize: asset.byteSize,
                sourceMTimeSeconds: sourceMTime,
                contentHash: .empty
            ),
        ])
        #expect(outcome == .applied(count: 1))

        let refreshedStates = await fixture.recorder.waitForCount(fixture.startingCount + 1) { states in
            states.contains { state in
                state.mediaGrid.orderedAssetIDs == [fixture.id]
                    && state.mediaGrid.detailRefreshGeneration > fixture.startingGeneration
            }
        }
        let refreshedState = try #require(refreshedStates.last { state in
            state.mediaGrid.orderedAssetIDs == [fixture.id]
                && state.mediaGrid.detailRefreshGeneration > fixture.startingGeneration
        })

        #expect(refreshedState.mediaGrid.orderedAssetIDs == fixture.initialState.mediaGrid.orderedAssetIDs)
    }

    @Test func publicationLoopDoesNotYieldUnchangedWindowState() async throws {
        let store = CatalogStore(location: .inMemory)
        let projection = CatalogProjection(
            cadence: .milliseconds(10),
            stateBuilder: { _, _, _ in .empty }
        )
        let recorder = StateRecorder()
        let stream = await projection.states(store: store, initialDescriptor: .default)
        let recordingTask = Task {
            for await state in stream {
                await recorder.append(state)
            }
        }
        defer {
            recordingTask.cancel()
        }

        try await store.start(scansSavedLibraries: false)
        _ = await recorder.waitForCount(1)
        let published = await projection.publicationCount
        await projection.updateSidebarSelection(.library(LibraryRootPath(rawValue: "/Users/example/Pictures")))
        try await waitForProjectionQuiescence(projection)

        #expect(await projection.publicationCount == published)
    }
}

extension CatalogProjectionTests {
    @Test func removableSourcesAreSeparateAndExcludedFromAllMedia() async {
        let projection = CatalogProjection()
        let pictures = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures"))
        let archive = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Archive"))
        let card = LibraryRoot(
            path: LibraryRootPath(rawValue: "/Volumes/Card"),
            kind: .removableVolume,
            deviceIdentity: .volume(uuid: "card"),
            displayName: "Card"
        )
        let fixture = makeProjectionFixture(
            libraries: [
                makeLibrary(root: pictures),
                makeLibrary(root: archive),
                CatalogLibraryState(root: card, availability: .available, activity: .idle, isEjectable: true),
            ],
            assets: [
                makeAsset(root: pictures, relativePath: "fixed.jpg"),
                makeAsset(root: card, relativePath: "removable.jpg"),
            ]
        )

        let allMedia = await projection.windowState(fixture: fixture, sidebarSelection: .allMedia)
        let selectedCard = await projection.windowState(fixture: fixture, sidebarSelection: .library(card.path))

        #expect(Set(allMedia.libraries.map(\.path)) == [pictures.path, archive.path])
        #expect(allMedia.removableSources.map(\.path) == [card.path])
        #expect(allMedia.removableSources.first?.isEjectable == true)
        #expect(allMedia.mediaGrid.orderedAssetIDs.map(\.relativePath.rawValue) == ["fixed.jpg"])
        #expect(selectedCard.title == "Card")
        #expect(selectedCard.mediaGrid.orderedAssetIDs.map(\.relativePath.rawValue) == ["removable.jpg"])
    }

    @Test func mtpCameraSelectionShowsEnumeratingStateAndConnectionBanner() async {
        let projection = CatalogProjection()
        let camera = LibraryRoot(
            path: LibraryRootPath(rawValue: "/tmp/Otos/DeviceStaging/camera"),
            kind: .deviceMTP,
            deviceIdentity: .camera(id: "serial"),
            displayName: "Camera"
        )
        let fixture = makeProjectionFixture(
            libraries: [
                CatalogLibraryState(root: camera, availability: .available, activity: .enumerating),
            ],
            assets: []
        )

        let state = await projection.windowState(fixture: fixture, sidebarSelection: .library(camera.path))

        #expect(state.libraries.isEmpty)
        #expect(state.removableSources.map(\.path) == [camera.path])
        #expect(state.mediaEmptyState == .deviceEnumerating("Camera"))
        #expect(state.deviceConnectionBanner?.identity == .camera(id: "serial"))
        #expect(state.deviceConnectionBanner?.message.contains("Mass Storage") == true)
    }

    /// ADR 0013: while an attached card is scanned and nothing on it has been seen yet,
    /// the grid says it is reading the card — not that there is no media.
    @Test func aCardBeingScannedWithNothingSeenYetShowsReadingCard() async {
        let projection = CatalogProjection()
        let card = LibraryRoot(
            path: LibraryRootPath(rawValue: "/Volumes/CARD"),
            kind: .removableVolume,
            deviceIdentity: .volume(uuid: "card"),
            displayName: "CARD"
        )
        let fixture = makeProjectionFixture(
            libraries: [CatalogLibraryState(root: card, availability: .available, activity: .scanning)],
            assets: []
        )

        let state = await projection.windowState(fixture: fixture, sidebarSelection: .library(card.path))

        #expect(state.mediaEmptyState == .cardReading("CARD"))
    }
}

private func makeLibrary(
    root: LibraryRoot,
    availability: LibraryAvailability = .available,
    activity: CatalogLibraryActivity = .idle
) -> CatalogLibraryState {
    CatalogLibraryState(root: root, availability: availability, activity: activity)
}

private func makeAsset(root: LibraryRoot, relativePath: String) -> MediaAsset {
    MediaAsset(
        libraryRootPath: root.path,
        relativePath: MediaRelativePath(rawValue: relativePath),
        name: URL(fileURLWithPath: relativePath).lastPathComponent,
        contentTypeIdentifier: "public.jpeg",
        byteSize: 1,
        createdAt: Date(timeIntervalSince1970: 10),
        contentModifiedAt: Date(timeIntervalSince1970: 20)
    )
}

private typealias StateRecorder = AsyncValueRecorder<CatalogWindowState>

private extension AsyncValueRecorder where Value == CatalogWindowState {
    func waitForCount(
        _ count: Int,
        matching predicate: @escaping @Sendable ([CatalogWindowState]) -> Bool = { _ in true }
    ) async -> [CatalogWindowState] {
        await waitForValues { states in
            states.count >= count && predicate(states)
        }
    }
}

private func makeProbedProjection(
    _ probe: ProjectionProbe,
    cadence: Duration = .milliseconds(10)
) -> CatalogProjection {
    CatalogProjection(
        cadence: cadence,
        stateBuilder: { libraries, orderedAssetIDs, request in
            try await probe.build(
                libraries: libraries,
                orderedAssetIDs: orderedAssetIDs,
                request: request
            )
        }
    )
}

private actor ProjectionProbe {
    private var currentInFlight = 0
    private var maximumInFlightValue = 0
    private var calls = 0
    private var cancelledBuilds = 0
    private var inFlightWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false
    private var failingCall: Int?

    struct InjectedFailure: Error {}

    /// The build for call `number` (1-based) throws, as a failed Store read does.
    func failCall(_ number: Int) {
        failingCall = number
    }

    func build(
        libraries: [CatalogLibraryState],
        orderedAssetIDs: [MediaAssetID],
        request: CatalogQueryRequest
    ) async throws -> CatalogWindowState {
        calls += 1
        if calls == failingCall {
            throw InjectedFailure()
        }
        currentInFlight += 1
        maximumInFlightValue = max(maximumInFlightValue, currentInFlight)
        resumeInFlightWaiters()
        if calls == 1, !isReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        currentInFlight -= 1
        if Task.isCancelled {
            cancelledBuilds += 1
        }

        return CatalogWindowState(
            title: "Call \(calls)",
            libraries: libraries,
            removableSources: [],
            mediaGrid: CatalogMediaGridState(
                descriptor: request.descriptor,
                orderedAssetIDs: orderedAssetIDs
            ),
            filterOptions: .empty,
            resolvedSidebarSelection: request.descriptor.scope,
            mediaEmptyState: .noMedia,
            deviceConnectionBanner: nil,
            queryGeneration: request.generation
        )
    }

    func maximumInFlight() -> Int {
        maximumInFlightValue
    }

    func callCount() -> Int {
        calls
    }

    /// Builds that finished inside a cancelled task — whose Store reads would have
    /// thrown `CancellationError` and produced an empty catalog.
    func cancelledBuildCount() -> Int {
        cancelledBuilds
    }

    func waitUntilInFlight() async {
        if currentInFlight > 0 {
            return
        }
        await withCheckedContinuation { continuation in
            inFlightWaiters.append(continuation)
            resumeInFlightWaiters()
        }
    }

    func releaseBuilds() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func resumeInFlightWaiters() {
        guard currentInFlight > 0 else {
            return
        }
        let waiters = inFlightWaiters
        inFlightWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private struct DetailRefreshFixture {
    let store: CatalogStore
    let projection: CatalogProjection
    let recorder: StateRecorder
    let recordingTask: Task<Void, Never>
    let id: MediaAssetID
    let initialState: CatalogWindowState
    let startingCount: Int
    let startingGeneration: UInt64
}

private func makeDetailRefreshFixture() async throws -> DetailRefreshFixture {
    let temp = try makeTestDirectory()
    let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "jpeg".write(to: root.appending(path: "one.jpg"), atomically: true, encoding: .utf8)

    let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
    let projection = CatalogProjection(cadence: .milliseconds(10))
    let recorder = StateRecorder()
    let stream = await projection.states(store: store, initialDescriptor: .default)
    let recordingTask = Task {
        for await state in stream {
            await recorder.append(state)
        }
    }

    try await store.start(scansSavedLibraries: false)
    try await store.addLibrary(url: root)
    let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
    let id = MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: "one.jpg"))
    let initialStates = await recorder.waitForCount(1) { states in
        states.contains { state in
            state.libraries.first?.activity == .idle && state.mediaGrid.orderedAssetIDs == [id]
        }
    }
    let initialState = try #require(initialStates.last { state in
        state.libraries.first?.activity == .idle && state.mediaGrid.orderedAssetIDs == [id]
    })
    return DetailRefreshFixture(
        store: store,
        projection: projection,
        recorder: recorder,
        recordingTask: recordingTask,
        id: id,
        initialState: initialState,
        startingCount: initialStates.count,
        startingGeneration: initialState.mediaGrid.detailRefreshGeneration
    )
}

private func makeProjectionFixture(
    libraries: [CatalogLibraryState],
    assets: [MediaAsset]
) -> ProjectionFixture {
    ProjectionFixture(
        libraries: libraries,
        orderedAssetIDs: orderedAssetIDs(for: assets)
    )
}

extension CatalogProjection {
    func windowState(
        fixture: ProjectionFixture,
        sidebarSelection: SidebarSelection
    ) async -> CatalogWindowState {
        await windowState(
            libraries: fixture.libraries,
            orderedAssetIDs: fixture.orderedAssetIDs,
            sidebarSelection: sidebarSelection
        )
    }
}
