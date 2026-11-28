import Foundation
@testable import OtosKit
import Testing

/// The acts whose result needs a read show their status in the step that handles them
/// (DES-120): a filter or sort change keeps the grid and says so in its controls and the
/// window subtitle, and Import is held from the click on.
@Suite(.testScope)
@MainActor
struct ImmediateStatusTests {
    // Validates: APP-088
    @Test func aFilterAndASortShowInTheirControlsBeforeTheirReadWhileTheGridKeepsItsItems() {
        let model = makeStatusModel()
        let ids = (0 ..< 3).map {
            MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/r"), relativePath: MediaRelativePath(rawValue: "\($0).jpg"))
        }
        model.applyState(statusWindowState(ids: ids))
        #expect(model.windowSubtitle.isEmpty)

        model.setMediaChoice(.liked, included: true)
        #expect(model.windowSubtitle == "Filtered")
        #expect(model.queryDescriptor.filter.choices == [.liked])
        #expect(model.state.mediaGrid.orderedAssetIDs == ids, "the grid keeps what it shows until the read")
        #expect(model.showsSelectedScope, "the scope stays the user's, so its items still act")

        model.setSortOrder(.filenameAscending)
        #expect(model.queryDescriptor.sort == .filenameAscending)
        #expect(model.state.mediaGrid.orderedAssetIDs == ids)
    }

    // Validates: APP-088
    /// The bar's Import is disabled in the click's step, as a held click draws it, and is the
    /// coordinator's to draw again once a presentation after the click arrives.
    @Test func anImportClickIsHeldFromTheClickOn() async throws {
        let model = makeStatusModel()
        let coordinator = MediaOperationCoordinator(
            store: model.catalogStore,
            preferencesDomain: .suite(UUID().uuidString),
            volumeCapacity: ampleVolumeCapacity
        )
        model.mediaOperationCoordinator = coordinator
        let source = LibraryRootPath(rawValue: "/Volumes/Card")

        model.queueImport(for: source)
        #expect(model.heldImportClicks == [source])

        model.startImportIntentConsumer(coordinator: coordinator)
        try await waitUntil { model.deliveredImportClicks[source] == 1 }
        model.applyImportPresentations([])
        #expect(model.heldImportClicks.isEmpty)
        await coordinator.shutdown()
    }
}

@MainActor
private func makeStatusModel() -> CatalogWindowViewModel {
    CatalogWindowViewModel(
        catalogStore: makeTestStore(location: .inMemory),
        startsStallMonitor: false,
        startsEnrichment: false,
        startsSourceMonitoring: false,
        preferencesDomain: .suite(UUID().uuidString),
        volumeCapacity: ampleVolumeCapacity,
        trashFiles: .refusing
    )
}

private func statusWindowState(ids: [MediaAssetID]) -> CatalogWindowState {
    CatalogWindowState(
        title: "Status",
        libraries: [],
        removableSources: [],
        mediaGrid: CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: ids),
        filterOptions: .empty,
        resolvedSidebarSelection: .allMedia,
        mediaEmptyState: .noMedia,
        deviceConnectionBanner: nil
    )
}
