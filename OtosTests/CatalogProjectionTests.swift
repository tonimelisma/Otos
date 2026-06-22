import Foundation
@testable import Otos
import Testing

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
        #expect(orderedAssets(in: state).map(\.relativePath.rawValue) == ["a.jpg", "b.jpg", "z.jpg"])
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
        #expect(orderedAssets(in: state).map(\.relativePath.rawValue) == ["one.jpg"])
        #expect(Set(state.mediaGrid.assetsByID.keys) == Set(state.mediaGrid.orderedAssetIDs))
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
        #expect(orderedAssets(in: state).map(\.relativePath.rawValue) == ["one.jpg"])
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

        #expect(orderedAssets(in: allMedia).map(\.relativePath.rawValue) == ["shown.jpg"])
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

        #expect(orderedAssets(in: state).map(\.relativePath.rawValue) == ["shown.jpg"])
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
            stateBuilder: { snapshot, sidebarSelection in
                await probe.build(snapshot: snapshot, sidebarSelection: sidebarSelection)
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
                && contents.contains("\"snapshotMs\"")
                && contents.contains("\"projectionMs\"")
                && contents.contains("\"totalMs\"")
                && contents.contains("\"assetOrderCacheHit\"")
                && contents.contains("\"assetOrderSorted\"")
                && contents.contains("\"assetMembershipChanged\"")
                && contents.contains("\"assetSortMs\"")
        }

        #expect(contents.contains("\"dirtyAfterPublication\""))
        #expect(contents.contains("\"stateChanged\""))
    }

    @Test func publicationLoopDoesNotYieldUnchangedWindowState() async throws {
        let store = CatalogStore(location: .inMemory, diagnostics: nil)
        let projection = CatalogProjection(
            cadence: .milliseconds(10),
            diagnostics: nil,
            stateBuilder: { _, _ in .empty }
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
        matching predicate: ([CatalogWindowState]) -> Bool = { _ in true }
    ) async throws -> [CatalogWindowState] {
        for _ in 0 ..< 100 {
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

    func build(snapshot: CatalogSnapshot, sidebarSelection: SidebarSelection) async -> CatalogWindowState {
        calls += 1
        currentInFlight += 1
        maximumInFlightValue = max(maximumInFlightValue, currentInFlight)
        try? await Task.sleep(for: .milliseconds(60))
        currentInFlight -= 1

        return CatalogWindowState(
            title: "Call \(calls)",
            libraries: snapshot.libraries,
            mediaGrid: CatalogMediaGridState(
                scope: sidebarSelection,
                orderedAssetIDs: [],
                assetsByID: [:]
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

private func makeSnapshot(
    libraries: [CatalogLibraryState],
    assets: [MediaAsset]
) -> CatalogSnapshot {
    CatalogSnapshot(
        libraries: libraries,
        assetsByID: Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
    )
}

private func orderedAssets(in state: CatalogWindowState) -> [MediaAsset] {
    state.mediaGrid.orderedAssetIDs.compactMap { state.mediaGrid.assetsByID[$0] }
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
