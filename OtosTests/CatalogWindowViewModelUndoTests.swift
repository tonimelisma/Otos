import Foundation
@testable import OtosKit
import Testing

/// Curation undo (APP-039) against a real in-memory catalog: ⌘Z restores each asset's
/// prior choice, ⇧⌘Z reapplies, titles name the act, and Trash is not on the stack.
///
/// Every choice, undo and redo travels the view model's one media-choice lane, so
/// `hasSettledMediaChoices` is the fact that it has been written (or refused) and its
/// undo registered; each step waits for that and then asserts the exact outcome.
@Suite(.testScope)
@MainActor
struct CatalogWindowViewModelUndoTests {
    // Validates: APP-039
    @Test func likeThenUndoRestoresNotRatedAndRedoReappliesLike() async throws {
        try await withCatalogedLibrary(fileCount: 2) { library in
            let model = makeUndoModel(store: library.store)
            model.applyState(undoWindowState(ids: library.ids))
            model.startMediaChoiceForwarding(writer: .store(library.store))
            defer { model.mediaChoiceForwardingTask?.cancel() }
            model.selectAll()
            #expect(!model.undoMenuState.canUndo)

            model.submitMediaChoice(.liked, origin: .keyboard)
            try await expectSettledChoices([.liked, .liked], model, library)
            #expect(model.undoMenuState.canUndo)
            #expect(model.undoMenuState.undoTitle == "Undo Like")
            #expect(!model.undoMenuState.canRedo)

            model.undoLastChange()
            try await expectSettledChoices([.notRated, .notRated], model, library)
            #expect(!model.undoMenuState.canUndo)
            #expect(model.undoMenuState.canRedo)
            #expect(model.undoMenuState.redoTitle == "Redo Like")

            model.redoLastChange()
            try await expectSettledChoices([.liked, .liked], model, library)
            #expect(model.undoMenuState.canUndo)
            #expect(!model.undoMenuState.canRedo)
        }
    }

    // Validates: APP-039
    @Test func undoOfABatchRestoresMixedPriorsPerAsset() async throws {
        try await withCatalogedLibrary(fileCount: 3) { library in
            let model = makeUndoModel(store: library.store)
            model.applyState(undoWindowState(ids: library.ids))
            model.startMediaChoiceForwarding(writer: .store(library.store))
            defer { model.mediaChoiceForwardingTask?.cancel() }
            let ids = library.ids

            // Priors: a liked, b disliked, c not rated.
            _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids)
            model.submitMediaChoice(.liked, origin: .keyboard)
            try await expectSettledChoices([.liked, .notRated, .notRated], model, library)
            _ = model.applyGridClick(hit: ids[1], modifiers: [], orderedIDs: ids)
            model.submitMediaChoice(.disliked, origin: .keyboard)
            try await expectSettledChoices([.liked, .disliked, .notRated], model, library)

            model.selectAll()
            model.submitMediaChoice(.notRated, origin: .menu)
            try await expectSettledChoices([.notRated, .notRated, .notRated], model, library)
            #expect(model.undoMenuState.undoTitle == "Undo Mark as Not Rated")

            model.undoLastChange()
            try await expectSettledChoices([.liked, .disliked, .notRated], model, library)
        }
    }

    // Validates: APP-039
    @Test func aChoiceThatChangesNothingRegistersNoUndo() async throws {
        try await withCatalogedLibrary(fileCount: 1) { library in
            let model = makeUndoModel(store: library.store)
            model.applyState(undoWindowState(ids: library.ids))
            model.startMediaChoiceForwarding(writer: .store(library.store))
            defer { model.mediaChoiceForwardingTask?.cancel() }
            model.selectAll()

            model.submitMediaChoice(.notRated, origin: .keyboard)
            try await expectSettledChoices([.notRated], model, library)

            #expect(!model.undoMenuState.canUndo)
        }
    }

    // Validates: APP-039
    /// Undo never auto-advances, and it shows what it changed (F-18): after a like advanced
    /// to the next photo, undoing it selects the liked photo again rather than leaving the
    /// change out of sight.
    @Test func undoRevealsWhatItChangedAndNeverAdvances() async throws {
        try await withCatalogedLibrary(fileCount: 3) { library in
            let model = makeUndoModel(store: library.store)
            model.applyState(undoWindowState(ids: library.ids))
            model.startMediaChoiceForwarding(writer: .store(library.store))
            defer { model.mediaChoiceForwardingTask?.cancel() }
            model.setAdvanceAfterMediaChoice(true)
            let ids = library.ids
            _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids)

            model.submitMediaChoice(.liked, origin: .keyboard)
            try await expectSettledChoices([.liked, .notRated, .notRated], model, library)
            #expect(model.gridSelection.selection == [ids[1]])
            #expect(model.undoMenuState.canUndo)

            model.undoLastChange()
            try await expectSettledChoices([.notRated, .notRated, .notRated], model, library)
            #expect(model.gridSelection.selection == [ids[0]])
        }
    }

    // Validates: APP-039
    @Test func storeReportsPriorChoicesPerRow() async throws {
        try await withCatalogedLibrary(fileCount: 2) { library in
            let ids = library.ids
            _ = try await library.store.setMediaChoice(.liked, for: [ids[0]])

            let result = try await library.store.setMediaChoices([ids[0]: .disliked, ids[1]: .disliked])

            #expect(result.accepted)
            #expect(result.previous == [ids[0]: .liked, ids[1]: .notRated])
            let missing = MediaAssetID(
                libraryRootPath: ids[0].libraryRootPath,
                relativePath: MediaRelativePath(rawValue: "gone.jpg")
            )
            let stale = try await library.store.setMediaChoices([missing: .liked])
            #expect(!stale.accepted)
            #expect(stale.previous.isEmpty)
        }
    }
}

@MainActor
private func makeUndoModel(store: CatalogStore) -> CatalogWindowViewModel {
    CatalogWindowViewModel(
        catalogStore: store,
        startsStallMonitor: false,
        startsEnrichment: false,
        startsSourceMonitoring: false,
        preferencesDomain: .suite(UUID().uuidString),
        volumeCapacity: ampleVolumeCapacity,
        trashFiles: .refusing
    )
}

private func undoWindowState(ids: [MediaAssetID]) -> CatalogWindowState {
    CatalogWindowState(
        title: "Undo",
        libraries: [],
        removableSources: [],
        mediaGrid: CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: ids),
        filterOptions: .empty,
        resolvedSidebarSelection: .allMedia,
        mediaEmptyState: .noMedia,
        deviceConnectionBanner: nil
    )
}

/// Waits until every choice submitted to `model` (undo and redo included) has been
/// written or refused, then expects the catalog to hold exactly `expected` for the
/// library's assets, in order.
@MainActor
private func expectSettledChoices(
    _ expected: [MediaChoice?],
    _ model: CatalogWindowViewModel,
    _ library: CatalogedLibrary,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    try await waitUntil { model.hasSettledMediaChoices }
    let assets = try await library.store.windowReads.mediaAssets(for: library.ids)
    #expect(library.ids.map { assets[$0]?.mediaChoice } == expected, sourceLocation: sourceLocation)
}
