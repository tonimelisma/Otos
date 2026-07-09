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

    @MainActor
    @Test func reinsertingRememberedCardAutoSelectsIt() {
        let model = makePolicyTestViewModel()
        let unavailable = removableSource(
            path: "/Volumes/CARD",
            identity: "volume:card",
            availability: .unavailable
        )
        let available = removableSource(
            path: "/Volumes/CARD",
            identity: "volume:card",
            availability: .available
        )
        let previous = windowState(removableSources: [unavailable])
        let next = windowState(removableSources: [available])

        model.applySidebarSelectionPolicy(previous: previous, next: next)

        #expect(model.sidebarSelection == .library(available.path))
    }

    @MainActor
    @Test func initialDefaultDoesNotLatchOnEmptyPreloadState() {
        let model = makePolicyTestViewModel()
        let empty = CatalogWindowState.empty
        let library = CatalogLibraryState(
            root: LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures")),
            availability: .available,
            activity: .idle
        )
        let loaded = windowState(libraries: [library])

        model.applySidebarSelectionPolicy(previous: empty, next: empty)
        #expect(model.hasAppliedInitialDefault == false)
        #expect(model.sidebarSelection == .allMedia)

        model.applySidebarSelectionPolicy(previous: empty, next: loaded)
        #expect(model.hasAppliedInitialDefault == true)
        #expect(model.sidebarSelection == .library(library.path))
    }

    @MainActor
    @Test func initialDefaultSelectsCardAfterEmptyPreload() {
        let model = makePolicyTestViewModel()
        let empty = CatalogWindowState.empty
        let card = removableSource(
            path: "/Volumes/CARD",
            identity: "volume:card",
            availability: .available
        )
        let loaded = windowState(removableSources: [card])

        model.applySidebarSelectionPolicy(previous: empty, next: empty)
        model.applySidebarSelectionPolicy(previous: empty, next: loaded)

        #expect(model.sidebarSelection == .library(card.path))
    }

    @MainActor
    private func makePolicyTestViewModel() -> CatalogWindowViewModel {
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10), diagnostics: nil)
        return CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10), diagnostics: nil),
            diagnostics: nil,
            startsStallMonitor: false,
            startsEnrichment: false
        )
    }

    private func windowState(
        libraries: [CatalogLibraryState] = [],
        removableSources: [CatalogLibraryState] = []
    ) -> CatalogWindowState {
        CatalogWindowState(
            title: "All Media",
            libraries: libraries,
            removableSources: removableSources,
            mediaGrid: .empty,
            filterOptions: .empty,
            resolvedSidebarSelection: .allMedia,
            mediaEmptyState: .noMedia,
            deviceConnectionBanner: nil
        )
    }

    private func removableSource(
        path: String,
        identity: String,
        availability: LibraryAvailability
    ) -> CatalogLibraryState {
        CatalogLibraryState(
            root: LibraryRoot(
                path: LibraryRootPath(rawValue: path),
                kind: .removableVolume,
                deviceIdentity: identity,
                displayName: URL(fileURLWithPath: path).lastPathComponent,
                lastSeenAt: Date()
            ),
            availability: availability,
            activity: .idle,
            isEjectable: true
        )
    }
}
