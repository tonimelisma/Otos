import Foundation
@testable import OtosKit
import Testing

@Suite(.testDirectory)
struct ViewModelDefaultSelectionTests {
    @MainActor
    @Test func startupSelectsSingleLibraryWhenAllMediaIsHidden() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("jpeg".utf8).write(to: root.appending(path: "one.jpg"))

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        let tempDefaults = PreferencesDomain.suite(UUID().uuidString)
        let model = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10)),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: tempDefaults,
            trashFiles: .refusing
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
            identity: .volume(uuid: "card"),
            availability: .unavailable
        )
        let available = removableSource(
            path: "/Volumes/CARD",
            identity: .volume(uuid: "card"),
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
            identity: .volume(uuid: "card"),
            availability: .available
        )
        let loaded = windowState(removableSources: [card])

        model.applySidebarSelectionPolicy(previous: empty, next: empty)
        model.applySidebarSelectionPolicy(previous: empty, next: loaded)

        #expect(model.sidebarSelection == .library(card.path))
    }

    /// Inserting a card takes the user to it even after they chose another row
    /// (APP-002): the one-time startup default is not the only automatic jump.
    @MainActor
    @Test func insertingACardAfterTheUserChoseALibrarySelectsTheCard() {
        let model = makePolicyTestViewModel()
        let library = CatalogLibraryState(
            root: LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures")),
            availability: .available,
            activity: .idle
        )
        let loaded = windowState(libraries: [library])
        model.applySidebarSelectionPolicy(previous: .empty, next: loaded)
        model.selectSidebar(.library(library.path))

        let card = removableSource(
            path: "/Volumes/CARD", identity: .volume(uuid: "card"), availability: .available, attachmentGeneration: 1
        )
        let withCard = windowState(libraries: [library], removableSources: [card])
        model.applySidebarSelectionPolicy(previous: loaded, next: withCard)
        #expect(model.sidebarSelection == .library(card.path))

        // Navigating away and seeing the same attachment again is not a new insertion.
        model.selectSidebar(.library(library.path))
        model.applySidebarSelectionPolicy(previous: withCard, next: withCard)
        #expect(model.sidebarSelection == .library(library.path))
    }

    @MainActor
    private func makePolicyTestViewModel() -> CatalogWindowViewModel {
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        let temp = PreferencesDomain.suite(UUID().uuidString)
        return CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10)),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: temp,
            trashFiles: .refusing
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
        identity: DeviceIdentity,
        availability: LibraryAvailability,
        attachmentGeneration: UInt64 = 0
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
            isEjectable: true,
            attachmentGeneration: attachmentGeneration
        )
    }
}
