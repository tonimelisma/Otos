import Foundation
import Observation
@testable import OtosKit
import SwiftUI
import Synchronization
import Testing

/// Which of the window's surfaces a change re-renders (`CatalogWindowParts`). Each surface's
/// body is evaluated the way SwiftUI evaluates it, under observation tracking; a surface whose
/// tracked reads a change notifies is one SwiftUI renders again. A one-tile hide re-renders
/// the detail column alone, and a publication that changed nothing re-renders nothing: before,
/// every publication re-rendered the whole window, and each cost a 45–60 ms main-thread update
/// while acts ran in a row (`docs/research/2026-11-16-window-state-turns.md`).
@Suite(.testScope)
@MainActor
struct WindowRenderDependencyTests {
    @Test func aOneTileHideRendersTheDetailColumnAlone() {
        let (model, shown) = makeShowingModel()
        model.selectAssets([shown.mediaGrid.orderedAssetIDs[0]])
        let rendered = Surfaces(model)

        var hidden = shown.hidingItems([shown.mediaGrid.orderedAssetIDs[2]])
        hidden.mediaGrid.content.prepareIndex()
        model.applyState(hidden)

        #expect(rendered.again() == [.detail])
    }

    @Test func aPublicationThatChangedNothingRendersNothing() {
        let (model, shown) = makeShowingModel()
        model.selectAssets([shown.mediaGrid.orderedAssetIDs[0]])
        let rendered = Surfaces(model)

        model.applyState(windowState(ids: shown.mediaGrid.orderedAssetIDs).sharingUnchanged(with: shown))

        #expect(rendered.again().isEmpty)
    }

    /// The selection is shown by the grid, and the toolbar's acts follow the targets; the
    /// sidebar and the window's frame do not show it.
    @Test func aMovedSelectionRendersTheGridAndTheToolbarsActs() {
        let (model, shown) = makeShowingModel()
        model.selectAssets([shown.mediaGrid.orderedAssetIDs[0]])
        let rendered = Surfaces(model)

        model.selectAssets([shown.mediaGrid.orderedAssetIDs[1]])

        let again = rendered.again()
        #expect(again.contains(.detail))
        #expect(!again.contains(.window))
        #expect(!again.contains(.sidebar))
    }

    /// A choice is drawn on its tile, by the grid's reconfigure of the tiles the tile store
    /// changed (this model's store holds none); nothing else in the window shows it but the
    /// toolbar's choice control.
    @Test func aChoiceRendersTheToolbarsChoiceAlone() {
        let (model, shown) = makeShowingModel()
        model.selectAssets([shown.mediaGrid.orderedAssetIDs[0]])
        let rendered = Surfaces(model)

        model.submitMediaChoice(.liked, origin: .keyboard)

        #expect(rendered.again() == [.toolbar])
    }
}

/// The window's surfaces, each rendered once under observation tracking; `again()` names
/// those a change since has invalidated.
private nonisolated enum Surface: Hashable, Sendable {
    case window
    case sidebar
    case detail
    case inspector
    case toolbar
}

private final nonisolated class Invalidated: Sendable {
    let surfaces = Mutex<Set<Surface>>([])
}

@MainActor
private final class Surfaces {
    private let invalidated = Invalidated()

    init(_ model: CatalogWindowViewModel) {
        render(.window) { _ = ContentView(viewModel: model).body }
        render(.sidebar) { _ = SidebarColumn(viewModel: model).body }
        render(.detail) { _ = DetailColumn(viewModel: model).body }
        render(.inspector) { _ = InspectorColumn(viewModel: model, pane: .info).body }
        render(.toolbar) { _ = CatalogToolbar(viewModel: model).body }
    }

    func again() -> Set<Surface> {
        invalidated.surfaces.withLock { $0 }
    }

    private func render(_ surface: Surface, _ body: () -> Void) {
        withObservationTracking(body) { [invalidated] in
            invalidated.surfaces.withLock { _ = $0.insert(surface) }
        }
    }
}

private let pictures = LibraryRootPath(rawValue: "/Users/example/Pictures")

@MainActor
private func makeShowingModel() -> (CatalogWindowViewModel, CatalogWindowState) {
    let model = CatalogWindowViewModel(
        catalogStore: makeTestStore(location: .inMemory),
        enrichmentCoordinator: nil,
        startsStallMonitor: false,
        startsEnrichment: false,
        startsSourceMonitoring: false,
        preferencesDomain: .suite(UUID().uuidString),
        volumeCapacity: ampleVolumeCapacity,
        trashFiles: .refusing
    )
    let ids = (0 ..< 5).map {
        MediaAssetID(libraryRootPath: pictures, relativePath: MediaRelativePath(rawValue: "asset-\($0).jpg"))
    }
    let shown = windowState(ids: ids).sharingUnchanged(with: nil)
    model.applyState(shown)
    return (model, shown)
}

private func windowState(ids: [MediaAssetID]) -> CatalogWindowState {
    CatalogWindowState(
        title: "Pictures",
        libraries: [CatalogLibraryState(root: LibraryRoot(path: pictures), availability: .available, activity: .idle)],
        removableSources: [],
        mediaGrid: CatalogMediaGridState(scope: .library(pictures), orderedAssetIDs: ids),
        filterOptions: .empty,
        resolvedSidebarSelection: .library(pictures),
        mediaEmptyState: nil,
        deviceConnectionBanner: nil,
        queryGeneration: 0
    )
}
