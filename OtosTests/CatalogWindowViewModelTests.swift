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
            catalogProjection: CatalogProjection(cadence: .milliseconds(10), diagnostics: nil)
        )

        model.start()
        model.addLibrary(url: root)

        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        let state = try await waitForWindowState(model) { state in
            state.libraries.map(\.path) == [rootPath]
                && state.assetsInSelectedScope.map(\.relativePath.rawValue) == ["one.jpg"]
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
            catalogProjection: CatalogProjection(cadence: .milliseconds(10), diagnostics: nil)
        )

        model.start()
        model.addLibrary(url: picturesURL)
        model.addLibrary(url: archiveURL)
        _ = try await waitForWindowState(model) { state in
            state.assetsInSelectedScope.count == 2
        }

        let picturesPath = try CatalogPath.normalizedDirectoryPath(for: picturesURL)
        model.sidebarSelection = .library(picturesPath)

        let state = try await waitForWindowState(model) { state in
            state.assetsInSelectedScope.map(\.relativePath.rawValue) == ["one.jpg"]
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
            catalogProjection: CatalogProjection(cadence: .milliseconds(10), diagnostics: nil)
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
            catalogProjection: CatalogProjection(cadence: .milliseconds(10), diagnostics: nil)
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
        #expect(removed.assetsInSelectedScope.isEmpty)
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
