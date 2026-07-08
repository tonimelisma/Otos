import Foundation
@testable import Otos
import Testing

struct ViewModelDefaultSelectionTests {
    @MainActor
    @Test func startupSelectsSingleLibraryWhenAllMediaIsHidden() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("jpeg".utf8).write(to: root.appending(path: "one.jpg"))

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
                && state.resolvedSidebarSelection == .library(rootPath)
        }
        #expect(model.sidebarSelection == .library(rootPath))
        #expect(state.title == "Pictures")
    }
}
