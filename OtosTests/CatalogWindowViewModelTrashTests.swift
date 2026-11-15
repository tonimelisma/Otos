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
            // Moved: no longer waiting for the queue. Its row is kept, hidden, while the file
            // is in the Trash (ADR 0022).
            try await waitUntil { try await fixture.store.pendingTrashItems().isEmpty }
            // The queue can move the file before the main actor registers the undo, and
            // undo with nothing registered does nothing; wait for the registration itself.
            try await waitUntil { model.undoMenuState.canUndo }

            model.undoLastChange()
            try await waitUntil { FileManager.default.fileExists(atPath: path) }
            try await waitUntil {
                try await catalogStoreTestState(fixture.store).testAssets.map(\.id) == fixture.ids
            }
            #expect(model.undoMenuState.redoTitle == "Redo Move to Trash")
            #expect(model.trashAlertMessage == nil)

            model.redoLastChange()
            try await waitUntil { !FileManager.default.fileExists(atPath: path) }
            #expect(model.undoMenuState.undoTitle == "Undo Move to Trash")
        }
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
}

/// Move to Trash shows its result before the Store's mark returns (DES-119, APP-085): each
/// test holds the mark at its suspension (`trashMarkHook`) and delivers the competing event
/// there — the mark landing, failing, an undo, a second Move to Trash, a scope change.
@MainActor
@Suite(.testDirectory)
struct CatalogWindowViewModelTrashInterleavingTests {
    @Test func theItemsLeaveThePublishedGridBeforeTheMarkReturns() async throws {
        try await withCatalogedLibrary(fileCount: 3, fileNamePrefix: "trash") { fixture in
            let gate = ArrivalGate()
            let model = try makeTrashModel(store: fixture.store, trash: makeTestDirectory()) { await gate.arrive() }
            let order = try await startShowing(model, fixture)
            model.selectAssets([order[1]])
            // Without the large-download question there is no read before the hide: the act is
            // applied in this step.
            model.setAsksBeforeLargeTrashDownload(false)

            model.moveTargetedMediaToTrash()
            // In the step of the intent: the selection has moved on and ⌘Z is there.
            #expect(model.gridSelection.selection == [order[2]])
            #expect(model.undoMenuState.undoTitle == "Undo Move to Trash")

            await gate.waitForArrivals(1)
            _ = try await waitForWindowState(model) { $0.mediaGrid.orderedAssetIDs == [order[0], order[2]] }
            #expect(try await fixture.store.pendingTrashItems().isEmpty, "the mark is still held")

            await gate.open()
            let path = fixture.path(order[1])
            try await waitUntil { !FileManager.default.fileExists(atPath: path) }
            try await waitForProjectionQuiescence(model.catalogProjection)
            #expect(model.state.mediaGrid.orderedAssetIDs == [order[0], order[2]])
        }
    }

    @Test func aFailedMarkBringsTheItemsBackAndSaysSo() async throws {
        try await withCatalogedLibrary(fileCount: 2, fileNamePrefix: "trash") { fixture in
            let gate = ArrivalGate()
            let model = try makeTrashModel(store: fixture.store, trash: makeTestDirectory()) {
                await gate.arrive()
                throw InjectedMarkFailure()
            }
            let order = try await startShowing(model, fixture)
            model.selectAssets([order[0]])

            model.moveTargetedMediaToTrash()
            await gate.waitForArrivals(1)
            _ = try await waitForWindowState(model) { $0.mediaGrid.orderedAssetIDs == [order[1]] }

            await gate.open()
            _ = try await waitForWindowState(model) { $0.mediaGrid.orderedAssetIDs == order }
            try await waitUntil { model.trashAlertMessage != nil }
            #expect(model.trashAlertMessage == TrashAlertCopy.moveFailedOne)
            #expect(model.gridSelection.selection == [order[0]])
            #expect(!model.undoMenuState.canUndo, "no undo for a move that did not happen")
            #expect(FileManager.default.fileExists(atPath: fixture.path(order[0])))
        }
    }

    @Test func anUndoBeforeTheMarkLandsPutsBackExactlyWhatItHid() async throws {
        try await withCatalogedLibrary(fileCount: 2, fileNamePrefix: "trash") { fixture in
            let gate = ArrivalGate()
            let model = try makeTrashModel(store: fixture.store, trash: makeTestDirectory()) { await gate.arrive() }
            let order = try await startShowing(model, fixture)
            model.selectAssets([order[0]])

            model.moveTargetedMediaToTrash()
            await gate.waitForArrivals(1)
            model.undoLastChange()
            #expect(model.undoMenuState.redoTitle == "Redo Move to Trash")

            await gate.open()
            _ = try await waitForWindowState(model) { $0.mediaGrid.orderedAssetIDs == order }
            try await waitUntil { try await fixture.store.pendingTrashItems().isEmpty }
            try await waitForProjectionQuiescence(model.catalogProjection)
            #expect(model.state.mediaGrid.orderedAssetIDs == order)
            #expect(FileManager.default.fileExists(atPath: fixture.path(order[0])))
            #expect(model.trashAlertMessage == nil)
        }
    }

    @Test func aSecondMoveBeforeTheFirstLandsHidesBothAndUndoesEachAlone() async throws {
        try await withCatalogedLibrary(fileCount: 3, fileNamePrefix: "trash") { fixture in
            let gate = ArrivalGate()
            let model = try makeTrashModel(store: fixture.store, trash: makeTestDirectory()) { await gate.arrive() }
            let order = try await startShowing(model, fixture)
            model.selectAssets([order[0]])
            model.setAsksBeforeLargeTrashDownload(false)

            model.moveTargetedMediaToTrash()
            #expect(model.gridSelection.selection == [order[1]])
            await gate.waitForArrivals(1)
            // The second command acts on the survivor the first moved to, at once.
            #expect(model.canMoveTargetedMediaToTrash)
            model.moveTargetedMediaToTrash()
            _ = try await waitForWindowState(model) { $0.mediaGrid.orderedAssetIDs == [order[2]] }

            await gate.open()
            try await waitUntil {
                !FileManager.default.fileExists(atPath: fixture.path(order[0]))
                    && !FileManager.default.fileExists(atPath: fixture.path(order[1]))
            }
            // Undo takes back the last command alone.
            model.undoLastChange()
            try await waitUntil { FileManager.default.fileExists(atPath: fixture.path(order[1])) }
            _ = try await waitForWindowState(model) { $0.mediaGrid.orderedAssetIDs == [order[1], order[2]] }
            #expect(!FileManager.default.fileExists(atPath: fixture.path(order[0])))
        }
    }

    @Test func aScopeChangedMidMarkStillShowsTheItemsGone() async throws {
        try await withCatalogedLibrary(fileCount: 2, fileNamePrefix: "trash") { fixture in
            let gate = ArrivalGate()
            let model = try makeTrashModel(store: fixture.store, trash: makeTestDirectory()) { await gate.arrive() }
            let order = try await startShowing(model, fixture)
            model.selectAssets([order[0]])

            model.moveTargetedMediaToTrash()
            await gate.waitForArrivals(1)
            // Away and back while the mark is held: the return answers from the order held
            // from before the mark, and the item stays off it.
            model.selectSidebar(.people)
            _ = try await waitForWindowState(model) { $0.resolvedSidebarSelection == .people }
            model.selectSidebar(.library(fixture.rootPath))
            let back = try await waitForWindowState(model) { $0.resolvedSidebarSelection == .library(fixture.rootPath) }
            #expect(back.mediaGrid.orderedAssetIDs == [order[1]], "a read from before the mark cannot bring it back")

            await gate.open()
            try await waitUntil { !FileManager.default.fileExists(atPath: fixture.path(order[0])) }
            try await waitForProjectionQuiescence(model.catalogProjection)
            #expect(model.state.mediaGrid.orderedAssetIDs == [order[1]])
        }
    }
}

private struct InjectedMarkFailure: Error {}

/// Starts `model` on the fixture's store and waits for the lone library's scope, the one the
/// window selects for it at launch; returns the order it shows.
@MainActor
private func startShowing(_ model: CatalogWindowViewModel, _ fixture: CatalogedLibrary) async throws -> [MediaAssetID] {
    model.start()
    let shown = try await waitForWindowState(model) { state in
        state.resolvedSidebarSelection == .library(fixture.rootPath) && state.mediaGrid.orderedAssetIDs.count == fixture.ids.count
    }
    return shown.mediaGrid.orderedAssetIDs
}

/// A model whose Trash is `trash`, a folder the test owns; `nil` refuses every move.
@MainActor
private func makeTrashModel(
    store: CatalogStore,
    trash: URL?,
    markHook: (@Sendable () async throws -> Void)? = nil
) -> CatalogWindowViewModel {
    CatalogWindowViewModel(
        catalogStore: store,
        startsStallMonitor: false,
        startsEnrichment: false,
        startsSourceMonitoring: false,
        preferencesDomain: .suite(UUID().uuidString),
        volumeCapacity: ampleVolumeCapacity,
        trashFiles: trash.map { .folder($0) } ?? .refusing,
        trashMarkHook: markHook
    )
}

/// The lone library's scope, the one the window selects for it at launch, so the state
/// answers the window's own selection and its items are the user's to act on.
@MainActor
private func trashWindowState(ids: [MediaAssetID], root: LibraryRootPath) -> CatalogWindowState {
    CatalogWindowState(
        title: "Trash",
        libraries: [
            CatalogLibraryState(root: LibraryRoot(path: root), availability: .available, activity: .idle),
        ],
        removableSources: [],
        mediaGrid: CatalogMediaGridState(scope: .library(root), orderedAssetIDs: ids),
        filterOptions: .empty,
        resolvedSidebarSelection: .library(root),
        mediaEmptyState: .noMedia,
        deviceConnectionBanner: nil
    )
}
