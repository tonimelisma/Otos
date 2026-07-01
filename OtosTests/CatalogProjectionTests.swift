import Foundation
@testable import Otos
import Testing

// swiftlint:disable file_length

struct CatalogProjectionTests {
    @Test func windowStateSortsLibrariesAndAssets() async {
        let pictures = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures"))
        let archive = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Archive"))
        let projection = CatalogProjection(diagnostics: nil)
        let snapshot = makeSnapshot(
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
            snapshot: snapshot,
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
        let snapshot = makeSnapshot(
            libraries: [makeLibrary(root: pictures), makeLibrary(root: archive)],
            assets: [
                makeAsset(root: pictures, relativePath: "one.jpg"),
                makeAsset(root: archive, relativePath: "two.jpg"),
            ]
        )

        let state = await projection.windowState(
            snapshot: snapshot,
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
            snapshot: makeSnapshot(
                libraries: [makeLibrary(root: pictures)],
                assets: [
                    makeAsset(root: pictures, relativePath: "one.jpg"),
                    makeAsset(root: archive, relativePath: "hidden.jpg"),
                ]
            ),
            sidebarSelection: .library(archive.path)
        )

        #expect(state.title == "All Media")
        #expect(state.resolvedSidebarSelection == .allMedia)
        #expect(state.mediaGrid.orderedAssetIDs.map(\.relativePath.rawValue) == ["one.jpg"])
    }

    @Test func windowStateHidesUnavailableLibraryAssets() async {
        let projection = CatalogProjection(diagnostics: nil)
        let pictures = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures"))
        let archive = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Archive"))
        let snapshot = makeSnapshot(
            libraries: [
                makeLibrary(root: pictures, availability: .unavailable),
                makeLibrary(root: archive),
            ],
            assets: [
                makeAsset(root: pictures, relativePath: "hidden.jpg"),
                makeAsset(root: archive, relativePath: "shown.jpg"),
            ]
        )

        let allMedia = await projection.windowState(snapshot: snapshot, sidebarSelection: .allMedia)
        let selectedUnavailable = await projection.windowState(
            snapshot: snapshot,
            sidebarSelection: .library(pictures.path)
        )

        #expect(allMedia.mediaGrid.orderedAssetIDs.map(\.relativePath.rawValue) == ["shown.jpg"])
        #expect(selectedUnavailable.mediaGrid.orderedAssetIDs.isEmpty)
        #expect(selectedUnavailable.mediaEmptyState == .libraryUnavailable)
    }

    @Test func windowStateHidesUnknownAssetsAndReportsCheckingStates() async {
        let projection = CatalogProjection(diagnostics: nil)
        let pictures = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures"))
        let snapshot = makeSnapshot(
            libraries: [makeLibrary(root: pictures, availability: .unknown)],
            assets: [makeAsset(root: pictures, relativePath: "cached.jpg")]
        )

        let allMedia = await projection.windowState(snapshot: snapshot, sidebarSelection: .allMedia)
        let selected = await projection.windowState(
            snapshot: snapshot,
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
        let snapshot = makeSnapshot(
            libraries: [
                makeLibrary(root: pictures),
                makeLibrary(root: archive, availability: .unknown),
            ],
            assets: [
                makeAsset(root: pictures, relativePath: "shown.jpg"),
                makeAsset(root: archive, relativePath: "hidden.jpg"),
            ]
        )

        let state = await projection.windowState(snapshot: snapshot, sidebarSelection: .allMedia)

        #expect(state.mediaGrid.orderedAssetIDs.map(\.relativePath.rawValue) == ["shown.jpg"])
        #expect(state.mediaEmptyState == .noMedia)
    }

    @Test func allMediaEmptyStateDistinguishesUnavailableCatalogedMedia() async {
        let projection = CatalogProjection(diagnostics: nil)
        let pictures = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures"))
        let snapshot = makeSnapshot(
            libraries: [makeLibrary(root: pictures, availability: .unavailable)],
            assets: [makeAsset(root: pictures, relativePath: "hidden.jpg")]
        )

        let state = await projection.windowState(snapshot: snapshot, sidebarSelection: .allMedia)

        #expect(state.mediaGrid.orderedAssetIDs.isEmpty)
        #expect(state.mediaEmptyState == .noAvailableMedia)
    }

    @Test func publicationLoopCoalescesStoreAndSidebarChanges() async throws {
        let temp = try makeTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10), diagnostics: nil)
        let projection = CatalogProjection(cadence: .milliseconds(10), diagnostics: nil)
        let recorder = StateRecorder()
        let stream = await projection.states(store: store, initialSidebarSelection: .allMedia)
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
            stateBuilder: { libraries, orderedAssetIDs, sidebarSelection in
                await probe.build(
                    libraries: libraries,
                    orderedAssetIDs: orderedAssetIDs,
                    sidebarSelection: sidebarSelection
                )
            }
        )
        let recorder = StateRecorder()
        let stream = await projection.states(store: store, initialSidebarSelection: .allMedia)
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
        let stream = await projection.states(store: store, initialSidebarSelection: .allMedia)
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
                captureDate: Date(timeIntervalSince1970: 700),
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
        let stream = await projection.states(store: store, initialSidebarSelection: .allMedia)
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
        try await Task.sleep(for: .milliseconds(80))

        #expect(await recorder.count() == 1)
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

private actor StateRecorder {
    private var states: [CatalogWindowState] = []

    func append(_ state: CatalogWindowState) {
        states.append(state)
    }

    func count() -> Int {
        states.count
    }

    func waitForCount(
        _ count: Int,
        attempts: Int = 100,
        matching predicate: ([CatalogWindowState]) -> Bool = { _ in true }
    ) async throws -> [CatalogWindowState] {
        for _ in 0 ..< attempts {
            if states.count >= count, predicate(states) {
                return states
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CatalogProjectionTestError.timedOut
    }
}

private actor ProjectionProbe {
    private var currentInFlight = 0
    private var maximumInFlightValue = 0
    private var calls = 0

    func build(
        libraries: [CatalogLibraryState],
        orderedAssetIDs: [MediaAssetID],
        sidebarSelection: SidebarSelection
    ) async -> CatalogWindowState {
        calls += 1
        currentInFlight += 1
        maximumInFlightValue = max(maximumInFlightValue, currentInFlight)
        try? await Task.sleep(for: .milliseconds(60))
        currentInFlight -= 1

        return CatalogWindowState(
            title: "Call \(calls)",
            libraries: libraries,
            mediaGrid: CatalogMediaGridState(
                scope: sidebarSelection,
                orderedAssetIDs: orderedAssetIDs
            ),
            resolvedSidebarSelection: sidebarSelection,
            mediaEmptyState: .noMedia
        )
    }

    func maximumInFlight() -> Int {
        maximumInFlightValue
    }

    func callCount() -> Int {
        calls
    }

    func waitUntilInFlight() async throws {
        for _ in 0 ..< 100 {
            if currentInFlight > 0 {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CatalogProjectionTestError.timedOut
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
    let stream = await projection.states(store: store, initialSidebarSelection: .allMedia)
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

private func makeSnapshot(
    libraries: [CatalogLibraryState],
    assets: [MediaAsset]
) -> ProjectionTestState {
    ProjectionTestState(
        libraries: libraries,
        assetsByID: Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
    )
}

extension CatalogProjection {
    func windowState(
        snapshot: ProjectionTestState,
        sidebarSelection: SidebarSelection
    ) async -> CatalogWindowState {
        await windowState(
            libraries: snapshot.libraries,
            orderedAssetIDs: orderedAssetIDs(in: snapshot),
            sidebarSelection: sidebarSelection
        )
    }
}

private func orderedAssetIDs(in snapshot: ProjectionTestState) -> [MediaAssetID] {
    snapshot.assetsByID.values
        .sorted { left, right in
            if left.sortKey != right.sortKey {
                return left.sortKey < right.sortKey
            }
            if left.libraryRootPath.rawValue != right.libraryRootPath.rawValue {
                return left.libraryRootPath.rawValue < right.libraryRootPath.rawValue
            }
            return left.relativePath.rawValue < right.relativePath.rawValue
        }
        .map(\.id)
}

private enum CatalogProjectionTestError: Error {
    case timedOut
}

private func waitForDiagnostics(
    _ url: URL,
    matching predicate: (String) -> Bool
) async throws -> String {
    for _ in 0 ..< 100 {
        let contents = readableDiagnostics(at: url)
        if let contents, predicate(contents) {
            return contents
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw CatalogProjectionTestError.timedOut
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
