import AppKit
import Foundation
@testable import OtosKit
import Testing

/// Every choice travels the view model's one media-choice lane, so
/// `hasSettledMediaChoices` is the fact that it has been written or refused; each test
/// waits for that and then asserts the exact outcome.
@Suite(.testScope)
@MainActor
struct CatalogWindowViewModelCurationTests {
    @Test func rapidChoicesRemainLosslessAndOrdered() async throws {
        try await withCatalogedLibrary(fileCount: 1) { library in
            let model = makeCurationModel()
            model.applyState(curationWindowState(ids: library.ids))
            _ = model.applyGridClick(hit: library.ids[0], modifiers: [], orderedIDs: library.ids)
            model.startMediaChoiceForwarding(writer: .store(library.store))
            defer { model.mediaChoiceForwardingTask?.cancel() }

            model.submitMediaChoice(.liked, origin: .keyboard)
            model.submitMediaChoice(.notRated, origin: .keyboard)
            model.submitMediaChoice(.disliked, origin: .keyboard)

            try await waitUntil { model.hasSettledMediaChoices }
            let choice = try await library.store.windowReads.mediaAssets(for: library.ids)[library.ids[0]]?.mediaChoice
            #expect(choice == .disliked)
            #expect(model.gridSelection.selection == [library.ids[0]])
        }
    }

    // Validates: APP-026
    @Test func acceptedSameValueChoiceAdvancesOnlyWhenEnabled() async throws {
        try await withCatalogedLibrary(fileCount: 2) { library in
            let model = makeCurationModel()
            model.applyState(curationWindowState(ids: library.ids))
            _ = model.applyGridClick(hit: library.ids[0], modifiers: [], orderedIDs: library.ids)
            model.setAdvanceAfterMediaChoice(true)
            model.startMediaChoiceForwarding(writer: .store(library.store))
            defer { model.mediaChoiceForwardingTask?.cancel() }

            model.submitMediaChoice(.notRated, origin: .keyboard)

            try await waitUntil { model.hasSettledMediaChoices }
            #expect(model.gridSelection.selection == [library.ids[1]])
            let choice = try await library.store.windowReads.mediaAssets(for: library.ids)[library.ids[0]]?.mediaChoice
            #expect(choice == .notRated)
        }
    }

    // Validates: APP-026
    @Test func acceptedChoiceAtEndDoesNotWrap() async throws {
        try await withCatalogedLibrary(fileCount: 2) { library in
            let model = makeCurationModel()
            model.applyState(curationWindowState(ids: library.ids))
            _ = model.applyGridClick(hit: library.ids[1], modifiers: [], orderedIDs: library.ids)
            model.setAdvanceAfterMediaChoice(true)
            model.startMediaChoiceForwarding(writer: .store(library.store))
            defer { model.mediaChoiceForwardingTask?.cancel() }

            model.submitMediaChoice(.liked, origin: .keyboard)

            try await waitUntil { model.hasSettledMediaChoices }
            let choice = try await library.store.windowReads.mediaAssets(for: library.ids)[library.ids[1]]?.mediaChoice
            #expect(choice == .liked)
            #expect(model.gridSelection.selection == [library.ids[1]])
        }
    }

    // Validates: APP-013
    @Test func toolbarChoiceReflectsTheTargetsSharedValue() async throws {
        try await withCatalogedLibrary(fileCount: 3) { library in
            let model = CatalogWindowViewModel(
                catalogStore: library.store,
                startsStallMonitor: false,
                startsEnrichment: false,
                startsSourceMonitoring: false,
                preferencesDomain: .suite(UUID().uuidString),
                volumeCapacity: ampleVolumeCapacity,
                trashFiles: .refusing
            )
            let ids = library.ids
            model.applyState(curationWindowState(ids: ids))
            model.startMediaChoiceForwarding(writer: .store(library.store))
            defer { model.mediaChoiceForwardingTask?.cancel() }

            _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids)
            try await waitUntil { model.currentTargetChoice == .notRated }
            #expect(model.currentTargetChoice == .notRated)

            model.submitMediaChoice(.liked, origin: .toolbar)
            try await waitUntil { model.currentTargetChoice == .liked }
            #expect(model.currentTargetChoice == .liked)

            // A mixed selection shares no value; a uniform one does.
            _ = model.applyGridClick(hit: ids[1], modifiers: [.command], orderedIDs: ids)
            try await waitUntil { model.currentTargetChoice == nil }
            #expect(model.currentTargetChoice == nil)
            model.submitMediaChoice(.liked, origin: .toolbar)
            try await waitUntil { model.currentTargetChoice == .liked }
            #expect(model.currentTargetChoice == .liked)

            model.deselectAll()
            try await waitUntil { model.currentTargetChoice == nil }
            #expect(model.currentTargetChoice == nil)
        }
    }

    // Validates: APP-086
    /// A choice on items the catalog no longer holds is shown and advances, then the Store
    /// finds no row: the choice is withdrawn and its undo taken off the stack, with no alert,
    /// since the items left the catalog and its next read shows it.
    @Test func aChoiceOnItemsTheCatalogNoLongerHoldsIsWithdrawnWithoutAnAlert() async throws {
        let model = makeCurationModel()
        let ids = ["choice-0.jpg", "choice-1.jpg"].map {
            MediaAssetID(
                libraryRootPath: LibraryRootPath(rawValue: "/missing"),
                relativePath: MediaRelativePath(rawValue: $0)
            )
        }
        model.applyState(curationWindowState(ids: ids))
        _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids)
        model.setAdvanceAfterMediaChoice(true)
        model.startMediaChoiceForwarding(writer: .store(model.catalogStore))
        defer { model.mediaChoiceForwardingTask?.cancel() }

        model.submitMediaChoice(.liked, origin: .keyboard)
        #expect(model.gridSelection.selection == [ids[1]])
        #expect(model.undoMenuState.canUndo)
        try await waitUntil { model.hasSettledMediaChoices }

        #expect(model.mediaChoiceOverlay.isEmpty)
        #expect(!model.undoMenuState.canUndo)
        #expect(model.mediaChoiceFailure == nil)
    }
}

@MainActor
private func makeCurationModel() -> CatalogWindowViewModel {
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

private func curationWindowState(ids: [MediaAssetID]) -> CatalogWindowState {
    CatalogWindowState(
        title: "Curation",
        libraries: [],
        removableSources: [],
        mediaGrid: CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: ids),
        filterOptions: .empty,
        resolvedSidebarSelection: .allMedia,
        mediaEmptyState: .noMedia,
        deviceConnectionBanner: nil
    )
}
