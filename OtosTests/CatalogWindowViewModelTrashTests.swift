import Foundation
@testable import OtosKit
import Testing

/// Move to Trash acts without asking (Plan 0104 D1) and is undoable from Edit ▸ Undo
/// (APP-039): undo puts the files back from the Trash, redo moves them again. Each test's
/// Trash is a folder it owns, so a run never touches the user's Trash (ADR 0020).
@MainActor
@Suite(.testDirectory)
struct CatalogWindowViewModelTrashTests {
    @Test func moveToTrashActsWithoutAskingAndRegistersUndo() async throws {
        try await withCatalogedLibrary(fileCount: 2, fileNamePrefix: "trash") { fixture in
            let trash = try makeTestDirectory()
            let model = makeTrashModel(store: fixture.store, trash: trash)
            model.applyState(trashWindowState(ids: fixture.ids, root: fixture.rootPath))
            model.selectAll()

            model.moveTargetedMediaToTrash()

            try await waitUntil {
                fixture.ids.allSatisfy { !FileManager.default.fileExists(atPath: fixture.path($0)) }
            }
            // The files are in the Trash the model was given, and nowhere else.
            #expect(try FileManager.default.contentsOfDirectory(atPath: trash.path).count == 2)
            // Undo is registered once the items are hidden, which is not ordered against
            // the queue moving the files; wait for the registration itself.
            try await waitUntil { model.undoMenuState.canUndo }
            #expect(model.undoMenuState.undoTitle == "Undo Move to Trash")
        }
    }

    @Test func undoPutsItemsBackAndRedoMovesThemAgain() async throws {
        try await withCatalogedLibrary(fileCount: 1, fileNamePrefix: "trash") { fixture in
            let model = try makeTrashModel(store: fixture.store, trash: makeTestDirectory())
            model.applyState(trashWindowState(ids: fixture.ids, root: fixture.rootPath))
            model.selectAll()
            model.moveTargetedMediaToTrash()
            let path = fixture.path(fixture.ids[0])
            try await waitUntil { !FileManager.default.fileExists(atPath: path) }
            try await waitUntil {
                try await fixture.store.mediaAssets(for: fixture.ids).isEmpty
            }
            // The queue can move the file before the main actor registers the undo, and
            // undo with nothing registered does nothing; wait for the registration itself.
            try await waitUntil { model.undoMenuState.canUndo }

            model.undoLastChange()
            try await waitUntil { FileManager.default.fileExists(atPath: path) }
            try await waitUntil {
                try await fixture.store.mediaAssets(for: fixture.ids).count == 1
            }
            #expect(model.undoMenuState.redoTitle == "Redo Move to Trash")
            #expect(model.trashAlertMessage == nil)

            model.redoLastChange()
            try await waitUntil { !FileManager.default.fileExists(atPath: path) }
            #expect(model.undoMenuState.undoTitle == "Undo Move to Trash")
        }
    }

    @Test func theLargeDownloadPreferenceDefaultsOnAndPersists() {
        let domain = PreferencesDomain.suite(UUID().uuidString)
        let model = CatalogWindowViewModel(
            catalogStore: CatalogStore(location: .inMemory),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: domain,
            trashFiles: .refusing
        )
        #expect(model.asksBeforeLargeTrashDownload)
        model.setAsksBeforeLargeTrashDownload(false)
        let reloaded = CatalogWindowViewModel(
            catalogStore: CatalogStore(location: .inMemory),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: domain,
            trashFiles: .refusing
        )
        #expect(!reloaded.asksBeforeLargeTrashDownload)
    }

    @Test func localItemsMoveWithoutTheLargeDownloadQuestion() async throws {
        try await withCatalogedLibrary(fileCount: 1, fileNamePrefix: "trash") { fixture in
            let model = try makeTrashModel(store: fixture.store, trash: makeTestDirectory())
            #expect(model.asksBeforeLargeTrashDownload)
            model.applyState(trashWindowState(ids: fixture.ids, root: fixture.rootPath))
            model.selectAll()

            model.moveTargetedMediaToTrash()

            let path = fixture.path(fixture.ids[0])
            try await waitUntil { !FileManager.default.fileExists(atPath: path) }
            #expect(model.largeTrashDownloadPrompt == nil)
        }
    }

    @Test func loupeTrashingTheLastItemFocusesThePreviousOne() async throws {
        try await withCatalogedLibrary(fileCount: 3, fileNamePrefix: "trash") { fixture in
            let model = try makeTrashModel(store: fixture.store, trash: makeTestDirectory())
            model.applyState(trashWindowState(ids: fixture.ids, root: fixture.rootPath))
            model.openLoupe(id: fixture.ids[2])

            model.moveTargetedMediaToTrash()

            try await waitUntil { model.focusedAssetID != fixture.ids[2] }
            #expect(model.focusedAssetID == fixture.ids[1])
            #expect(model.gridSelection.selection == [fixture.ids[1]])
        }
    }

    @Test func loupeTrashingAMiddleItemFocusesTheNextOne() async throws {
        try await withCatalogedLibrary(fileCount: 3, fileNamePrefix: "trash") { fixture in
            let model = try makeTrashModel(store: fixture.store, trash: makeTestDirectory())
            model.applyState(trashWindowState(ids: fixture.ids, root: fixture.rootPath))
            model.openLoupe(id: fixture.ids[1])

            model.moveTargetedMediaToTrash()

            try await waitUntil { model.focusedAssetID != fixture.ids[1] }
            #expect(model.focusedAssetID == fixture.ids[2])
        }
    }

    @Test func gridTrashingTheTrailingItemsSelectsTheOneBeforeThem() async throws {
        try await withCatalogedLibrary(fileCount: 3, fileNamePrefix: "trash") { fixture in
            let model = try makeTrashModel(store: fixture.store, trash: makeTestDirectory())
            model.applyState(trashWindowState(ids: fixture.ids, root: fixture.rootPath))
            model.selectAssets([fixture.ids[1], fixture.ids[2]])

            model.moveTargetedMediaToTrash()

            try await waitUntil { model.gridSelection.selection != [fixture.ids[1], fixture.ids[2]] }
            #expect(model.gridSelection.selection == [fixture.ids[0]])
        }
    }

    @Test func noTargetDoesNothing() {
        let model = makeTrashModel(store: CatalogStore(location: .inMemory), trash: nil)
        model.moveTargetedMediaToTrash()
        #expect(model.mediaTrashTask == nil)
        #expect(!model.undoMenuState.canUndo)
    }
}

/// A model whose Trash is `trash`, a folder the test owns; `nil` refuses every move.
@MainActor
private func makeTrashModel(store: CatalogStore, trash: URL?) -> CatalogWindowViewModel {
    CatalogWindowViewModel(
        catalogStore: store,
        startsStallMonitor: false,
        startsEnrichment: false,
        startsSourceMonitoring: false,
        preferencesDomain: .suite(UUID().uuidString),
        trashFiles: trash.map { .folder($0) } ?? .refusing
    )
}

@MainActor
private func trashWindowState(ids: [MediaAssetID], root: LibraryRootPath) -> CatalogWindowState {
    CatalogWindowState(
        title: "Trash",
        libraries: [
            CatalogLibraryState(root: LibraryRoot(path: root), availability: .available, activity: .idle),
        ],
        removableSources: [],
        mediaGrid: CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: ids),
        filterOptions: .empty,
        resolvedSidebarSelection: .allMedia,
        mediaEmptyState: .noMedia,
        deviceConnectionBanner: nil
    )
}
