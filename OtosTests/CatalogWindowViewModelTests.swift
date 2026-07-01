import Foundation
@testable import Otos
import Testing

struct CatalogWindowViewModelTests {
    @MainActor
    @Test func activeStateSubscriptionDoesNotRetainViewModel() async throws {
        let store = CatalogStore(location: .inMemory, diagnostics: nil)
        let buildProbe = WindowStateBuildProbe()
        let projection = CatalogProjection(
            cadence: .milliseconds(10),
            diagnostics: nil,
            stateBuilder: { libraries, _, selection in
                await buildProbe.recordBuild()
                return CatalogWindowState(
                    title: "Test",
                    libraries: libraries,
                    mediaGrid: CatalogMediaGridState(
                        scope: selection,
                        orderedAssetIDs: []
                    ),
                    resolvedSidebarSelection: selection,
                    mediaEmptyState: .noMedia
                )
            }
        )
        var model: CatalogWindowViewModel? = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: projection,
            diagnostics: nil,
            startsStallMonitor: false,
            startsEnrichment: false
        )
        weak var weakModel = model

        model?.start()
        try await buildProbe.waitForBuildCount(1)
        model = nil

        try await waitForCondition { weakModel == nil }
        try await Task.sleep(for: .milliseconds(40))
        let buildCountAfterTermination = await buildProbe.buildCount

        await store.shutdown()
        try await Task.sleep(for: .milliseconds(40))
        #expect(await buildProbe.buildCount == buildCountAfterTermination)
    }

    @MainActor
    @Test func storeChangesUpdateWindowState() async throws {
        let temp = try makeTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeFile(root.appending(path: "one.jpg"), contents: "jpeg")

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10), diagnostics: nil)
        let model = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10), diagnostics: nil),
            diagnostics: nil,
            startsStallMonitor: false,
            startsEnrichment: false
        )

        model.start()
        model.addLibrary(url: root)

        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        let state = try await waitForWindowState(model) { state in
            state.libraries.map(\.path) == [rootPath]
                && state.mediaGrid.orderedAssetIDs.map(\.relativePath.rawValue) == ["one.jpg"]
        }

        #expect(state.libraries.first?.availability == .available)
    }

    @MainActor
    @Test func sidebarSelectionChangesRouteThroughProjection() async throws {
        let temp = try makeTemporaryDirectory()
        let picturesURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let archiveURL = temp.appending(path: "Archive", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: picturesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archiveURL, withIntermediateDirectories: true)
        try writeFile(picturesURL.appending(path: "one.jpg"), contents: "jpeg")
        try writeFile(archiveURL.appending(path: "two.jpg"), contents: "jpeg")

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10), diagnostics: nil)
        let model = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10), diagnostics: nil),
            diagnostics: nil,
            startsStallMonitor: false,
            startsEnrichment: false
        )

        model.start()
        model.addLibrary(url: picturesURL)
        model.addLibrary(url: archiveURL)
        _ = try await waitForWindowState(model) { state in
            state.mediaGrid.orderedAssetIDs.count == 2
        }

        let picturesPath = try CatalogPath.normalizedDirectoryPath(for: picturesURL)
        model.selectSidebar(.library(picturesPath))

        let state = try await waitForWindowState(model) { state in
            state.mediaGrid.orderedAssetIDs.map(\.relativePath.rawValue) == ["one.jpg"]
        }
        #expect(state.title == "Pictures")
        #expect(state.resolvedSidebarSelection == .library(picturesPath))
    }

    @MainActor
    @Test func removedSelectedLibraryResetsSidebarSelectionToAllMedia() async throws {
        let temp = try makeTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10), diagnostics: nil)
        let model = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10), diagnostics: nil),
            diagnostics: nil,
            startsStallMonitor: false,
            startsEnrichment: false
        )

        model.start()
        model.addLibrary(url: root)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        _ = try await waitForWindowState(model) { state in
            state.libraries.map(\.path) == [rootPath]
        }

        model.selectSidebar(.library(rootPath))
        try await store.removeLibrary(path: rootPath)

        let state = try await waitForWindowState(model) { state in
            state.libraries.isEmpty && state.resolvedSidebarSelection == .allMedia
        }
        #expect(model.sidebarSelection == .allMedia)
        #expect(state.title == "All Media")
    }

    @MainActor
    @Test func startIsIdempotentAndAddRemoveIntentsRouteToStore() async throws {
        let temp = try makeTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeFile(root.appending(path: "one.jpg"), contents: "jpeg")

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10), diagnostics: nil)
        let model = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10), diagnostics: nil),
            diagnostics: nil,
            startsStallMonitor: false,
            startsEnrichment: false
        )

        model.start()
        model.start()
        model.addLibrary(url: root)

        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        let added = try await waitForWindowState(model) { state in
            state.libraries.map(\.path) == [rootPath]
        }
        #expect(added.libraries.count == 1)

        model.removeLibrary(added.libraries[0].root)

        let removed = try await waitForWindowState(model) { state in
            state.libraries.isEmpty
        }
        #expect(removed.mediaGrid.orderedAssetIDs.isEmpty)
    }

    @MainActor
    @Test func addRemoveCommandsExecuteInSubmissionOrder() async throws {
        let temp = try makeTemporaryDirectory()
        let firstURL = temp.appending(path: "First", directoryHint: .isDirectory)
        let secondURL = temp.appending(path: "Second", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: firstURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: true)

        let scanner = CatalogScanner { _, _, _, _ in [] }
        let store = CatalogStore(location: .inMemory, scanner: scanner, diagnostics: nil)
        let model = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10), diagnostics: nil),
            diagnostics: nil,
            startsStallMonitor: false,
            startsEnrichment: false
        )
        let firstPath = try CatalogPath.normalizedDirectoryPath(for: firstURL)
        let secondPath = try CatalogPath.normalizedDirectoryPath(for: secondURL)

        model.start()
        model.addLibrary(url: firstURL)
        model.removeLibrary(LibraryRoot(path: firstPath))
        model.addLibrary(url: secondURL)

        let state = try await waitForWindowState(model) { state in
            state.libraries.map(\.path) == [secondPath]
        }
        #expect(state.libraries.map(\.path) == [secondPath])
        #expect(try await catalogStoreTestState(store).libraries.map(\.path) == [secondPath])
    }

    @MainActor
    @Test func failedMutationDoesNotTerminateOrderedConsumer() async throws {
        let temp = try makeTemporaryDirectory()
        let firstURL = temp.appending(path: "First", directoryHint: .isDirectory)
        let secondURL = temp.appending(path: "Second", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: firstURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: true)

        let scanner = CatalogScanner { _, _, _, _ in [] }
        let store = CatalogStore(location: .inMemory, scanner: scanner, diagnostics: nil)
        let model = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10), diagnostics: nil),
            diagnostics: nil,
            startsStallMonitor: false,
            startsEnrichment: false
        )
        let firstPath = try CatalogPath.normalizedDirectoryPath(for: firstURL)
        let secondPath = try CatalogPath.normalizedDirectoryPath(for: secondURL)

        model.start()
        model.addLibrary(url: firstURL)
        model.addLibrary(url: firstURL)
        model.removeLibrary(LibraryRoot(path: firstPath))
        model.addLibrary(url: secondURL)

        let state = try await waitForWindowState(model) { state in
            state.libraries.map(\.path) == [secondPath]
        }
        #expect(state.libraries.map(\.path) == [secondPath])
    }

    @MainActor
    @Test func endingViewModelDropsQueuedMutationAfterCurrentMutation() async throws {
        let temp = try makeTemporaryDirectory()
        let firstURL = temp.appending(path: "First", directoryHint: .isDirectory)
        let secondURL = temp.appending(path: "Second", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: firstURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: true)

        let loadGate = ViewModelInitialLoadGate()
        let scanner = CatalogScanner { _, _, _, _ in [] }
        let store = CatalogStore(
            location: .inMemory,
            scanner: scanner,
            diagnostics: nil,
            initialLoadDidRead: {
                await loadGate.pause()
            }
        )
        var model: CatalogWindowViewModel? = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10), diagnostics: nil),
            diagnostics: nil,
            startsStallMonitor: false,
            startsEnrichment: false
        )
        weak var weakModel = model
        let firstPath = try CatalogPath.normalizedDirectoryPath(for: firstURL)

        model?.start()
        model?.addLibrary(url: firstURL)
        model?.addLibrary(url: secondURL)
        try await loadGate.waitUntilPaused()
        model = nil
        try await waitForCondition { weakModel == nil }

        await loadGate.release()
        try await store.start(scansSavedLibraries: false)
        try await Task.sleep(for: .milliseconds(50))
        let paths = try await catalogStoreTestState(store).libraries.map(\.path)
        let secondPath = try CatalogPath.normalizedDirectoryPath(for: secondURL)
        #expect(!paths.contains(secondPath))
        #expect(paths.isEmpty || paths == [firstPath])
    }

    @MainActor
    @Test func rapidSidebarIntentsResolveToLatestSelection() async throws {
        let temp = try makeTemporaryDirectory()
        let picturesURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let archiveURL = temp.appending(path: "Archive", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: picturesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archiveURL, withIntermediateDirectories: true)

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10), diagnostics: nil)
        let model = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10), diagnostics: nil),
            diagnostics: nil,
            startsStallMonitor: false,
            startsEnrichment: false
        )

        model.start()
        model.addLibrary(url: picturesURL)
        model.addLibrary(url: archiveURL)
        _ = try await waitForWindowState(model) { $0.libraries.count == 2 }

        let picturesPath = try CatalogPath.normalizedDirectoryPath(for: picturesURL)
        let archivePath = try CatalogPath.normalizedDirectoryPath(for: archiveURL)
        model.selectSidebar(.library(picturesPath))
        model.selectSidebar(.allMedia)
        model.selectSidebar(.library(archivePath))

        let state = try await waitForWindowState(model) { state in
            state.resolvedSidebarSelection == .library(archivePath)
        }

        #expect(model.sidebarSelection == .library(archivePath))
        #expect(state.title == "Archive")
    }
}

@MainActor
private func waitForWindowState(
    _ model: CatalogWindowViewModel,
    predicate: (CatalogWindowState) -> Bool
) async throws -> CatalogWindowState {
    for _ in 0 ..< 150 {
        let state = model.state
        if predicate(state) {
            return state
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw CatalogWindowViewModelTestError.timedOut
}

@MainActor
private func waitForCondition(_ predicate: () -> Bool) async throws {
    for _ in 0 ..< 100 {
        if predicate() {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CatalogWindowViewModelTestError.timedOut
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "OtosTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeFile(_ url: URL, contents: String) throws {
    try Data(contents.utf8).write(to: url)
}

private enum CatalogWindowViewModelTestError: Error {
    case timedOut
}

private actor WindowStateBuildProbe {
    private(set) var buildCount = 0

    func recordBuild() {
        buildCount += 1
    }

    func waitForBuildCount(_ expectedCount: Int) async throws {
        for _ in 0 ..< 100 {
            if buildCount >= expectedCount {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CatalogWindowViewModelTestError.timedOut
    }
}

private actor ViewModelInitialLoadGate {
    private var isPaused = false
    private var continuation: CheckedContinuation<Void, Never>?

    func pause() async {
        isPaused = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilPaused() async throws {
        for _ in 0 ..< 100 {
            if isPaused {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CatalogWindowViewModelTestError.timedOut
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
