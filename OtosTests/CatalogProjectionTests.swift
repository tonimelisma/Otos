import Foundation
@testable import Otos
import Testing

struct CatalogProjectionTests {
    @Test func windowStateSortsLibrariesAndAssets() async {
        let pictures = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures"))
        let archive = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Archive"))
        let projection = CatalogProjection(diagnostics: nil)
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

        #expect(state.libraries.map(\.displayName) == ["Archive", "Pictures"])
        #expect(state.libraries.map(\.activity) == [.idle, .scanning])
        #expect(state.mediaGrid.orderedAssetIDs.map(\.relativePath.rawValue) == ["a.jpg", "b.jpg", "z.jpg"])
    }

    @Test func windowStateFiltersAssetsInSelectedScope() async {
        let pictures = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures"))
        let archive = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Archive"))
        let projection = CatalogProjection(diagnostics: nil)
        let fixture = makeProjectionFixture(
            libraries: [makeLibrary(root: pictures), makeLibrary(root: archive)],
            assets: [
                makeAsset(root: pictures, relativePath: "one.jpg"),
                makeAsset(root: archive, relativePath: "two.jpg"),
            ]
        )

        let state = await projection.windowState(
            fixture: fixture,
            sidebarSelection: .library(pictures.path)
        )

        #expect(state.title == "Pictures")
        #expect(state.resolvedSidebarSelection == .library(pictures.path))
        #expect(state.mediaGrid.orderedAssetIDs.map(\.relativePath.rawValue) == ["one.jpg"])
    }

    @Test func windowStateFallsBackWhenSelectedLibraryIsMissing() async {
        let projection = CatalogProjection(diagnostics: nil)
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
        let projection = CatalogProjection(diagnostics: nil)
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
        let projection = CatalogProjection(diagnostics: nil)
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
        let projection = CatalogProjection(diagnostics: nil)
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
        #expect(state.mediaEmptyState == .noMedia)
    }

    @Test func allMediaEmptyStateDistinguishesUnavailableCatalogedMedia() async {
        let projection = CatalogProjection(diagnostics: nil)
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
        let temp = try makeTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10), diagnostics: nil)
        let projection = CatalogProjection(cadence: .milliseconds(10), diagnostics: nil)
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

        let states = try await recorder.waitForCount(1) { states in
            states.contains { $0.resolvedSidebarSelection == .library(rootPath) }
        }

        #expect(states.contains { $0.libraries.map(\.path) == [rootPath] })
    }

    @Test func publicationLoopRunsOneProjectionAtATimeAndRerunsWhenDirtyDuringRun() async throws {
        let store = CatalogStore(location: .inMemory, diagnostics: nil)
        let probe = ProjectionProbe()
        let projection = CatalogProjection(
            cadence: .milliseconds(10),
            diagnostics: nil,
            stateBuilder: { libraries, orderedAssetIDs, request in
                await probe.build(
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

        try await probe.waitUntilInFlight()
        await projection.updateSidebarSelection(.library(LibraryRootPath(rawValue: "/Users/example/Pictures")))
        await probe.releaseBuilds()

        _ = try await recorder.waitForCount(2)
        #expect(await probe.maximumInFlight() == 1)
        #expect(await probe.callCount() >= 2)
    }

    @Test func publicationDiagnosticsIncludeTimingFields() async throws {
        let temp = try makeTemporaryDirectory()
        let outputURL = temp.appending(path: "catalog-diagnostics.jsonl")
        let diagnostics = CatalogDiagnostics(outputURL: outputURL, isEnabled: true)
        let store = CatalogStore(location: .inMemory, diagnostics: nil)
        let projection = CatalogProjection(cadence: .milliseconds(10), diagnostics: diagnostics)
        let stream = await projection.states(store: store, initialDescriptor: .default)
        let recordingTask = Task {
            for await _ in stream {}
        }
        defer {
            recordingTask.cancel()
        }

        try await store.start(scansSavedLibraries: false)
        let contents = try await waitForDiagnostics(outputURL) { contents in
            contents.contains("\"operation\":\"catalog.projection.window\"")
                && contents.contains("\"storeReadMs\"")
                && contents.contains("\"projectionMs\"")
                && contents.contains("\"totalMs\"")
                && contents.contains("\"assetOrderQueryMs\"")
                && contents.contains("\"equalityUs\"")
                && contents.contains("\"detailRefreshGeneration\"")
                && contents.contains("\"detailRefreshChanged\"")
        }

        #expect(contents.contains("\"dirtyAfterPublication\""))
        #expect(contents.contains("\"stateChanged\""))
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
                metadata: AssetMetadata(cameraModel: "Cam"),
                timestampFacts: EnrichmentTimestampFacts(original: Date(timeIntervalSince1970: 700)),
                thumbnailPath: "thumb.jpg",
                sourceSize: asset.byteSize,
                sourceMTimeSeconds: sourceMTime
            ),
        ])
        #expect(outcome == .applied(count: 1))

        let refreshedStates = try await fixture.recorder.waitForCount(
            fixture.startingCount + 1,
            attempts: 100
        ) { states in
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
        let store = CatalogStore(location: .inMemory, diagnostics: nil)
        let projection = CatalogProjection(
            cadence: .milliseconds(10),
            diagnostics: nil,
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
        _ = try await recorder.waitForCount(1)
        await projection.updateSidebarSelection(.library(LibraryRootPath(rawValue: "/Users/example/Pictures")))
        try await assertStateCountStays(recorder, expectedCount: 1, duration: .milliseconds(80))

        #expect(await recorder.count() == 1)
    }
}

extension CatalogProjectionTests {
    @Test func removableSourcesAreSeparateAndExcludedFromAllMedia() async {
        let projection = CatalogProjection(diagnostics: nil)
        let pictures = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures"))
        let archive = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Archive"))
        let card = LibraryRoot(
            path: LibraryRootPath(rawValue: "/Volumes/Card"),
            kind: .removableVolume,
            deviceIdentity: "volume:card",
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
        let projection = CatalogProjection(diagnostics: nil)
        let camera = LibraryRoot(
            path: LibraryRootPath(rawValue: "/tmp/Otos/DeviceStaging/camera"),
            kind: .deviceMTP,
            deviceIdentity: "camera:serial",
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
        #expect(state.deviceConnectionBanner?.identity == "camera:serial")
        #expect(state.deviceConnectionBanner?.message.contains("Mass Storage") == true)
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
        attempts: Int = 100,
        matching predicate: @escaping @Sendable ([CatalogWindowState]) -> Bool = { _ in true }
    ) async throws -> [CatalogWindowState] {
        let timeout = attempts > 100 ? Duration.seconds(20) : .seconds(10)
        return try await withTestTimeout("projection state count", timeout: timeout) {
            await self.waitForValues { states in
                states.count >= count && predicate(states)
            }
        }
    }
}

private actor ProjectionProbe {
    private var currentInFlight = 0
    private var maximumInFlightValue = 0
    private var calls = 0
    private var inFlightWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func build(
        libraries: [CatalogLibraryState],
        orderedAssetIDs: [MediaAssetID],
        request: CatalogQueryRequest
    ) async -> CatalogWindowState {
        calls += 1
        currentInFlight += 1
        maximumInFlightValue = max(maximumInFlightValue, currentInFlight)
        resumeInFlightWaiters()
        if calls == 1, !isReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        currentInFlight -= 1

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

    func waitUntilInFlight() async throws {
        try await withTestTimeout("projection in-flight build") {
            await self.waitUntilInFlightUnbounded()
        }
    }

    private func waitUntilInFlightUnbounded() async {
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
    let temp = try makeTemporaryDirectory()
    let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "jpeg".write(to: root.appending(path: "one.jpg"), atomically: true, encoding: .utf8)

    let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10), diagnostics: nil)
    let projection = CatalogProjection(cadence: .milliseconds(10), diagnostics: nil)
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
    let initialStates = try await recorder.waitForCount(1) { states in
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

private enum CatalogProjectionTestError: Error {
    case timedOut
}

private func waitForDiagnostics(
    _ url: URL,
    matching predicate: @escaping @Sendable (String) -> Bool
) async throws -> String {
    try await withTestTimeout("projection diagnostics") {
        while !Task.isCancelled {
            let contents = readableDiagnostics(at: url)
            if let contents, predicate(contents) {
                return contents
            }
            await Task.yield()
        }
        throw CancellationError()
    }
}

private func assertStateCountStays(
    _ recorder: StateRecorder,
    expectedCount: Int,
    duration: Duration
) async throws {
    try await Task.sleep(for: duration)
    #expect(await recorder.count() == expectedCount)
}

private func readableDiagnostics(at url: URL) -> String? {
    guard let data = try? Data(contentsOf: url) else {
        return nil
    }
    return String(data: data, encoding: .utf8)
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "OtosTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
