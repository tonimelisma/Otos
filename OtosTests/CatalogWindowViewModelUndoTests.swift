import Foundation
@testable import OtosKit
import Testing

/// Curation undo (APP-039) against a real in-memory catalog: ⌘Z restores each asset's
/// prior choice, ⇧⌘Z reapplies, titles name the act, and Trash is not on the stack.
@MainActor
struct CatalogWindowViewModelUndoTests {
    @Test func likeThenUndoRestoresNotRatedAndRedoReappliesLike() async throws {
        let fixture = try await makeUndoFixture(count: 2)
        defer { fixture.removeRoot() }
        let model = makeUndoModel(store: fixture.store)
        model.applyState(undoWindowState(ids: fixture.ids))
        model.startMediaChoiceForwarding(store: fixture.store)
        defer { model.mediaChoiceForwardingTask?.cancel() }
        model.selectAll()
        #expect(!model.curationUndoState.canUndo)

        model.submitMediaChoice(.liked, origin: .keyboard)
        try await waitForChoices(fixture.store, fixture.ids, [.liked, .liked])
        try await waitUntil { model.curationUndoState.canUndo }
        #expect(model.curationUndoState.undoTitle == "Undo Like")
        #expect(!model.curationUndoState.canRedo)

        model.undoCuration()
        try await waitForChoices(fixture.store, fixture.ids, [.notRated, .notRated])
        #expect(!model.curationUndoState.canUndo)
        #expect(model.curationUndoState.canRedo)
        #expect(model.curationUndoState.redoTitle == "Redo Like")

        model.redoCuration()
        try await waitForChoices(fixture.store, fixture.ids, [.liked, .liked])
        #expect(model.curationUndoState.canUndo)
        #expect(!model.curationUndoState.canRedo)
    }

    @Test func undoOfABatchRestoresMixedPriorsPerAsset() async throws {
        let fixture = try await makeUndoFixture(count: 3)
        defer { fixture.removeRoot() }
        let model = makeUndoModel(store: fixture.store)
        model.applyState(undoWindowState(ids: fixture.ids))
        model.startMediaChoiceForwarding(store: fixture.store)
        defer { model.mediaChoiceForwardingTask?.cancel() }
        let ids = fixture.ids

        // Priors: a liked, b disliked, c not rated.
        _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids)
        model.submitMediaChoice(.liked, origin: .keyboard)
        try await waitForChoices(fixture.store, ids, [.liked, .notRated, .notRated])
        _ = model.applyGridClick(hit: ids[1], modifiers: [], orderedIDs: ids)
        model.submitMediaChoice(.disliked, origin: .keyboard)
        try await waitForChoices(fixture.store, ids, [.liked, .disliked, .notRated])

        model.selectAll()
        model.submitMediaChoice(.notRated, origin: .menu)
        try await waitForChoices(fixture.store, ids, [.notRated, .notRated, .notRated])
        try await waitUntil { model.curationUndoState.undoTitle == "Undo Mark as Not Rated" }

        model.undoCuration()
        try await waitForChoices(fixture.store, ids, [.liked, .disliked, .notRated])
    }

    @Test func aChoiceThatChangesNothingRegistersNoUndo() async throws {
        let fixture = try await makeUndoFixture(count: 1)
        defer { fixture.removeRoot() }
        let model = makeUndoModel(store: fixture.store)
        model.applyState(undoWindowState(ids: fixture.ids))
        model.startMediaChoiceForwarding(store: fixture.store)
        defer { model.mediaChoiceForwardingTask?.cancel() }
        model.selectAll()

        model.submitMediaChoice(.notRated, origin: .keyboard)
        try await waitUntil { model.hasSettledMediaChoices }

        #expect(!model.curationUndoState.canUndo)
    }

    @Test func undoNeverAdvancesTheSelection() async throws {
        let fixture = try await makeUndoFixture(count: 3)
        defer { fixture.removeRoot() }
        let model = makeUndoModel(store: fixture.store)
        model.applyState(undoWindowState(ids: fixture.ids))
        model.startMediaChoiceForwarding(store: fixture.store)
        defer { model.mediaChoiceForwardingTask?.cancel() }
        model.setAdvanceAfterMediaChoice(true)
        let ids = fixture.ids
        _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids)

        model.submitMediaChoice(.liked, origin: .keyboard)
        try await waitForChoices(fixture.store, ids, [.liked, .notRated, .notRated])
        try await waitUntil { model.gridSelection.selection == [ids[1]] }
        // The undo is registered after the Store write lands, so the write being
        // visible does not mean undo is available yet.
        try await waitUntil { model.curationUndoState.canUndo }

        model.undoCuration()
        try await waitForChoices(fixture.store, ids, [.notRated, .notRated, .notRated])
        try await waitUntil { model.hasSettledMediaChoices }
        #expect(model.gridSelection.selection == [ids[1]])
    }

    @Test func storeReportsPriorChoicesPerRow() async throws {
        let fixture = try await makeUndoFixture(count: 2)
        defer { fixture.removeRoot() }
        let ids = fixture.ids
        _ = try await fixture.store.setMediaChoice(.liked, for: [ids[0]])

        let result = try await fixture.store.setMediaChoices([ids[0]: .disliked, ids[1]: .disliked])

        #expect(result.accepted)
        #expect(result.previous == [ids[0]: .liked, ids[1]: .notRated])
        let missing = MediaAssetID(
            libraryRootPath: ids[0].libraryRootPath,
            relativePath: MediaRelativePath(rawValue: "gone.jpg")
        )
        let stale = try await fixture.store.setMediaChoices([missing: .liked])
        #expect(!stale.accepted)
        #expect(stale.previous.isEmpty)
    }
}

@MainActor
private func makeUndoModel(store: CatalogStore) -> CatalogWindowViewModel {
    CatalogWindowViewModel(
        catalogStore: store,
        startsStallMonitor: false,
        startsEnrichment: false,
        startsSourceMonitoring: false,
        preferencesDomain: .suite(UUID().uuidString)
    )
}

private struct UndoFixture {
    let store: CatalogStore
    let root: URL
    let ids: [MediaAssetID]

    func removeRoot() {
        try? FileManager.default.removeItem(at: root)
        Task { await store.shutdown() }
    }
}

private func makeUndoFixture(count: Int) async throws -> UndoFixture {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "Otos-undo-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for index in 0 ..< count {
        try Data([0]).write(to: root.appending(path: "choice-\(index).jpg"))
    }
    let rootPath = try CatalogPath.normalizedExistingDirectoryPath(for: root)
    let ids = (0 ..< count).map { index in
        MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: rootPath.rawValue),
            relativePath: MediaRelativePath(rawValue: "choice-\(index).jpg")
        )
    }
    let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(5))
    try await store.addLibrary(url: root)
    try await waitUntil {
        await (try? store.mediaAssets(for: ids).count) == ids.count
    }
    return UndoFixture(store: store, root: root, ids: ids)
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

private func waitForChoices(_ store: CatalogStore, _ ids: [MediaAssetID], _ expected: [MediaChoice]) async throws {
    try await waitUntil {
        guard let assets = try? await store.mediaAssets(for: ids) else { return false }
        return ids.map { assets[$0]?.mediaChoice } == expected
    }
}
