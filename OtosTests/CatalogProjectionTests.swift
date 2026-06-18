import Foundation
@testable import Otos
import Testing

struct CatalogProjectionTests {
    @Test func windowStateSortsLibrariesAndAssets() async {
        let pictures = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures"))
        let archive = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Archive"))
        let projection = CatalogProjection(diagnostics: nil)
        let snapshot = CatalogSnapshot(
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
        #expect(state.assetsInSelectedScope.map(\.relativePath.rawValue) == ["a.jpg", "b.jpg", "z.jpg"])
    }

    @Test func windowStateFiltersAssetsInSelectedScope() async {
        let pictures = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures"))
        let archive = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Archive"))
        let projection = CatalogProjection(diagnostics: nil)
        let snapshot = CatalogSnapshot(
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
        #expect(state.assetsInSelectedScope.map(\.relativePath.rawValue) == ["one.jpg"])
    }

    @Test func windowStateFallsBackWhenSelectedLibraryIsMissing() async {
        let projection = CatalogProjection(diagnostics: nil)
        let pictures = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures"))
        let archive = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Archive"))

        let state = await projection.windowState(
            snapshot: CatalogSnapshot(
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
        #expect(state.assetsInSelectedScope.map(\.relativePath.rawValue) == ["one.jpg"])
    }

    @Test func windowStateHidesUnavailableLibraryAssets() async {
        let projection = CatalogProjection(diagnostics: nil)
        let pictures = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures"))
        let archive = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Archive"))
        let snapshot = CatalogSnapshot(
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

        #expect(allMedia.assetsInSelectedScope.map(\.relativePath.rawValue) == ["shown.jpg"])
        #expect(selectedUnavailable.assetsInSelectedScope.isEmpty)
        #expect(selectedUnavailable.mediaEmptyState == .libraryUnavailable)
    }

    @Test func allMediaEmptyStateDistinguishesUnavailableCatalogedMedia() async {
        let projection = CatalogProjection(diagnostics: nil)
        let pictures = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures"))
        let snapshot = CatalogSnapshot(
            libraries: [makeLibrary(root: pictures, availability: .unavailable)],
            assets: [makeAsset(root: pictures, relativePath: "hidden.jpg")]
        )

        let state = await projection.windowState(snapshot: snapshot, sidebarSelection: .allMedia)

        #expect(state.assetsInSelectedScope.isEmpty)
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
        libraryDisplayName: root.displayName,
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
            assetsInSelectedScope: [],
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

private enum CatalogProjectionTestError: Error {
    case timedOut
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "OtosTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
