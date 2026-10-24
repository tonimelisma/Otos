import Foundation
@testable import OtosKit
import Testing

/// Move to Trash acts without asking (Plan 0104 D1) and is undoable from Edit ▸ Undo
/// (APP-039): undo puts the files back from the system Trash, redo moves them again.
@MainActor
struct CatalogWindowViewModelTrashTests {
    @Test func moveToTrashActsWithoutAskingAndRegistersUndo() async throws {
        let fixture = try await makeTrashFixture(count: 2)
        defer { fixture.removeRoot() }
        let model = makeTrashModel(store: fixture.store)
        model.applyState(trashWindowState(ids: fixture.ids, root: fixture.rootPath))
        model.selectAll()

        model.moveTargetedMediaToTrash()

        try await waitUntil {
            fixture.ids.allSatisfy { !FileManager.default.fileExists(atPath: fixture.path($0)) }
        }
        // Undo is registered once the items are hidden, which is not ordered against
        // the queue moving the files; wait for the registration itself.
        try await waitUntil { model.curationUndoState.canUndo }
        #expect(model.curationUndoState.undoTitle == "Undo Move to Trash")
    }

    @Test func undoPutsItemsBackAndRedoMovesThemAgain() async throws {
        let fixture = try await makeTrashFixture(count: 1)
        defer { fixture.removeRoot() }
        let model = makeTrashModel(store: fixture.store)
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
        try await waitUntil { model.curationUndoState.canUndo }

        model.undoCuration()
        try await waitUntil { FileManager.default.fileExists(atPath: path) }
        try await waitUntil {
            try await fixture.store.mediaAssets(for: fixture.ids).count == 1
        }
        #expect(model.curationUndoState.redoTitle == "Redo Move to Trash")
        #expect(model.trashAlertMessage == nil)

        model.redoCuration()
        try await waitUntil { !FileManager.default.fileExists(atPath: path) }
        #expect(model.curationUndoState.undoTitle == "Undo Move to Trash")
    }

    @Test func theLargeDownloadPreferenceDefaultsOnAndPersists() {
        let domain = PreferencesDomain.suite(UUID().uuidString)
        let model = CatalogWindowViewModel(
            catalogStore: CatalogStore(location: .inMemory),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: domain
        )
        #expect(model.asksBeforeLargeTrashDownload)
        model.setAsksBeforeLargeTrashDownload(false)
        let reloaded = CatalogWindowViewModel(
            catalogStore: CatalogStore(location: .inMemory),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: domain
        )
        #expect(!reloaded.asksBeforeLargeTrashDownload)
    }

    @Test func localItemsMoveWithoutTheLargeDownloadQuestion() async throws {
        let fixture = try await makeTrashFixture(count: 1)
        defer { fixture.removeRoot() }
        let model = makeTrashModel(store: fixture.store)
        #expect(model.asksBeforeLargeTrashDownload)
        model.applyState(trashWindowState(ids: fixture.ids, root: fixture.rootPath))
        model.selectAll()

        model.moveTargetedMediaToTrash()

        let path = fixture.path(fixture.ids[0])
        try await waitUntil { !FileManager.default.fileExists(atPath: path) }
        #expect(model.largeTrashDownloadPrompt == nil)
    }

    @Test func loupeTrashingTheLastItemFocusesThePreviousOne() async throws {
        let fixture = try await makeTrashFixture(count: 3)
        defer { fixture.removeRoot() }
        let model = makeTrashModel(store: fixture.store)
        model.applyState(trashWindowState(ids: fixture.ids, root: fixture.rootPath))
        model.openLoupe(id: fixture.ids[2])

        model.moveTargetedMediaToTrash()

        try await waitUntil { model.focusedAssetID != fixture.ids[2] }
        #expect(model.focusedAssetID == fixture.ids[1])
        #expect(model.gridSelection.selection == [fixture.ids[1]])
    }

    @Test func loupeTrashingAMiddleItemFocusesTheNextOne() async throws {
        let fixture = try await makeTrashFixture(count: 3)
        defer { fixture.removeRoot() }
        let model = makeTrashModel(store: fixture.store)
        model.applyState(trashWindowState(ids: fixture.ids, root: fixture.rootPath))
        model.openLoupe(id: fixture.ids[1])

        model.moveTargetedMediaToTrash()

        try await waitUntil { model.focusedAssetID != fixture.ids[1] }
        #expect(model.focusedAssetID == fixture.ids[2])
    }

    @Test func gridTrashingTheTrailingItemsSelectsTheOneBeforeThem() async throws {
        let fixture = try await makeTrashFixture(count: 3)
        defer { fixture.removeRoot() }
        let model = makeTrashModel(store: fixture.store)
        model.applyState(trashWindowState(ids: fixture.ids, root: fixture.rootPath))
        model.selectAssets([fixture.ids[1], fixture.ids[2]])

        model.moveTargetedMediaToTrash()

        try await waitUntil { model.gridSelection.selection != [fixture.ids[1], fixture.ids[2]] }
        #expect(model.gridSelection.selection == [fixture.ids[0]])
    }

    @Test func noTargetDoesNothing() {
        let model = makeTrashModel(store: CatalogStore(location: .inMemory))
        model.moveTargetedMediaToTrash()
        #expect(model.mediaTrashTask == nil)
        #expect(!model.curationUndoState.canUndo)
    }
}

@MainActor
private func makeTrashModel(store: CatalogStore) -> CatalogWindowViewModel {
    CatalogWindowViewModel(
        catalogStore: store,
        startsStallMonitor: false,
        startsEnrichment: false,
        startsSourceMonitoring: false,
        preferencesDomain: .suite(UUID().uuidString)
    )
}

private struct TrashFixture {
    let store: CatalogStore
    let root: URL
    let rootPath: LibraryRootPath
    let ids: [MediaAssetID]

    func path(_ id: MediaAssetID) -> String {
        root.appending(path: id.relativePath.rawValue).path
    }

    func removeRoot() {
        try? FileManager.default.removeItem(at: root)
        Task { await store.shutdown() }
    }
}

private func makeTrashFixture(count: Int) async throws -> TrashFixture {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "Otos-trash-confirm-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for index in 0 ..< count {
        try Data([0]).write(to: root.appending(path: "trash-\(index).jpg"))
    }
    let rootPath = try CatalogPath.normalizedExistingDirectoryPath(for: root)
    let libraryRootPath = LibraryRootPath(rawValue: rootPath.rawValue)
    let ids = (0 ..< count).map { index in
        MediaAssetID(libraryRootPath: libraryRootPath, relativePath: MediaRelativePath(rawValue: "trash-\(index).jpg"))
    }
    let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(5))
    try await store.addLibrary(url: root)
    try await waitUntil {
        try await store.mediaAssets(for: ids).count == ids.count
    }
    return TrashFixture(store: store, root: root, rootPath: libraryRootPath, ids: ids)
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
