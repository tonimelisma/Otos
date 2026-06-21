import Foundation
@testable import Otos
import Testing

struct CatalogWindowViewModelTests {
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
            startsStallMonitor: false
        )

        model.start()
        model.addLibrary(url: root)

        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        let state = try await waitForWindowState(model) { state in
            state.libraries.map(\.path) == [rootPath]
                && orderedAssets(in: state).map(\.relativePath.rawValue) == ["one.jpg"]
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
            startsStallMonitor: false
        )

        model.start()
        model.addLibrary(url: picturesURL)
        model.addLibrary(url: archiveURL)
        _ = try await waitForWindowState(model) { state in
            state.mediaGrid.orderedAssetIDs.count == 2
        }

        let picturesPath = try CatalogPath.normalizedDirectoryPath(for: picturesURL)
        model.sidebarSelection = .library(picturesPath)

        let state = try await waitForWindowState(model) { state in
            orderedAssets(in: state).map(\.relativePath.rawValue) == ["one.jpg"]
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
            startsStallMonitor: false
        )

        model.start()
        model.addLibrary(url: root)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        _ = try await waitForWindowState(model) { state in
            state.libraries.map(\.path) == [rootPath]
        }

        model.sidebarSelection = .library(rootPath)
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
            startsStallMonitor: false
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
    @Test func stateApplyWritesGridHandoffDiagnostics() async throws {
        let temp = try makeTemporaryDirectory()
        let outputURL = temp.appending(path: "catalog-diagnostics.jsonl")
        let diagnostics = CatalogDiagnostics(outputURL: outputURL, isEnabled: true)
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeFile(root.appending(path: "one.jpg"), contents: "jpeg")

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10), diagnostics: nil)
        let model = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10), diagnostics: nil),
            diagnostics: diagnostics,
            startsStallMonitor: false
        )

        model.start()
        model.addLibrary(url: root)

        _ = try await waitForWindowState(model) { state in
            orderedAssets(in: state).map(\.relativePath.rawValue) == ["one.jpg"]
        }
        let contents = try await waitForDiagnostics(outputURL) { contents in
            contents.contains("\"operation\":\"catalog.window.state.apply\"")
                && contents.contains("\"itemCount\":\"1\"")
        }

        #expect(contents.contains("\"previousItemCount\""))
        #expect(contents.contains("\"itemDelta\""))
        #expect(contents.contains("\"applyMs\""))
    }
}

private func orderedAssets(in state: CatalogWindowState) -> [MediaAsset] {
    state.mediaGrid.orderedAssetIDs.compactMap { state.mediaGrid.assetsByID[$0] }
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

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "OtosTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeFile(_ url: URL, contents: String) throws {
    try Data(contents.utf8).write(to: url)
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
    throw CatalogWindowViewModelTestError.timedOut
}

private func readableDiagnostics(at url: URL) -> String? {
    guard let data = try? Data(contentsOf: url) else {
        return nil
    }
    return String(data: data, encoding: .utf8)
}

private enum CatalogWindowViewModelTestError: Error {
    case timedOut
}
