import Foundation
@testable import OtosKit
import Testing

/// A choice shows its result before the catalog records it (DES-120, APP-086): each test holds
/// the write at its suspension (`HeldChoiceWrites`) and asserts what the window shows in the
/// step that handled the intent, then lets the write answer, land or fail, and asserts what
/// the window shows after.
@Suite(.testDirectory)
@MainActor
struct CatalogWindowViewModelChoiceShownFirstTests {
    @Test func aChoiceShowsOnItsTileTheToolbarAndTheUndoMenuBeforeItsWriteReturns() async throws {
        try await withCatalogedLibrary(fileCount: 2) { library in
            let held = HeldChoiceWrites(store: library.store)
            let model = makeShownFirstModel(library, writer: held.writer)
            defer { model.mediaChoiceForwardingTask?.cancel() }
            let id = library.ids[0]
            _ = model.applyGridClick(hit: id, modifiers: [], orderedIDs: library.ids)
            let revision = model.tileChoiceChange.revision

            model.submitMediaChoice(.liked, origin: .keyboard)

            #expect(model.tileContentStore.content(for: id)?.detail.mediaChoice == .liked)
            #expect(model.tileChoiceChange.revision != revision)
            #expect(model.tileChoiceChange.ids == [id])
            #expect(model.currentTargetChoice == .liked)
            #expect(model.undoMenuState.undoTitle == "Undo Like")
            try await waitUntil { await held.arrived == 1 }
            #expect(try await library.store.mediaAssets(for: [id])[id]?.mediaChoice == .notRated, "the write is held")
            // A read that started before the write landed answers with the choice.
            #expect(try await model.tileDetailReader.detail(for: id)?.mediaChoice == .liked)

            await held.release()
            try await waitUntil { model.hasSettledMediaChoices }
            #expect(try await library.store.mediaAssets(for: [id])[id]?.mediaChoice == .liked)
            // The first read that started after the landing retires the held choice.
            #expect(try await model.tileDetailReader.detail(for: id)?.mediaChoice == .liked)
            #expect(model.mediaChoiceOverlay.isEmpty)
            #expect(model.mediaChoiceFailure == nil)
        }
    }

    @Test func aFailedWriteWithdrawsTheChoiceSelectsItsItemsAndSaysSo() async throws {
        try await withCatalogedLibrary(fileCount: 2) { library in
            let held = HeldChoiceWrites(store: library.store, failing: [1])
            let model = makeShownFirstModel(library, writer: held.writer)
            defer { model.mediaChoiceForwardingTask?.cancel() }
            model.setAdvanceAfterMediaChoice(true)
            let id = library.ids[0]
            _ = model.applyGridClick(hit: id, modifiers: [], orderedIDs: library.ids)

            model.submitMediaChoice(.disliked, origin: .keyboard)
            #expect(model.tileContentStore.content(for: id)?.detail.mediaChoice == .disliked)
            #expect(model.gridSelection.selection == [library.ids[1]], "the advance is shown with the choice")

            await held.release()
            try await waitUntil { model.hasSettledMediaChoices }
            #expect(model.tileContentStore.content(for: id)?.detail.mediaChoice == .notRated)
            #expect(model.gridSelection.selection == [id])
            #expect(model.mediaChoiceFailure == MediaChoiceFailure(count: 1))
            #expect(model.mediaChoiceFailure?.title == "This Choice Couldn't Be Saved")
            #expect(!model.undoMenuState.canUndo)
            #expect(model.mediaChoiceOverlay.isEmpty)
            #expect(try await model.tileDetailReader.detail(for: id)?.mediaChoice == .notRated)
            model.dismissMediaChoiceFailure()
            #expect(model.mediaChoiceFailure == nil)
        }
    }

    /// ⌘Z pressed while the act's write is held: the tile shows what it showed before at once,
    /// and the undo is written after the act, from the priors the act's write reported.
    @Test func anUndoBeforeTheWriteLandsShowsAtOnceAndWritesAfterIt() async throws {
        try await withCatalogedLibrary(fileCount: 1) { library in
            let held = HeldChoiceWrites(store: library.store)
            let model = makeShownFirstModel(library, writer: held.writer)
            defer { model.mediaChoiceForwardingTask?.cancel() }
            let id = library.ids[0]
            model.selectAll()

            model.submitMediaChoice(.liked, origin: .keyboard)
            try await waitUntil { await held.arrived == 1 }
            model.undoLastChange()
            #expect(model.tileContentStore.content(for: id)?.detail.mediaChoice == .notRated)
            #expect(model.undoMenuState.canRedo)
            #expect(!model.undoMenuState.canUndo)

            await held.release()
            try await waitUntil { await held.arrived == 2 }
            #expect(try await library.store.mediaAssets(for: [id])[id]?.mediaChoice == .liked, "the act landed first")
            #expect(model.tileContentStore.content(for: id)?.detail.mediaChoice == .notRated)
            #expect(try await model.tileDetailReader.detail(for: id)?.mediaChoice == .notRated, "the undo is held")
            await held.release()
            try await waitUntil { model.hasSettledMediaChoices }
            #expect(try await library.store.mediaAssets(for: [id])[id]?.mediaChoice == .notRated)
            #expect(model.undoMenuState.redoTitle == "Redo Like")
        }
    }

    /// A second choice on the same item before the first lands is the one shown, and the
    /// first one's failure leaves it shown.
    @Test func aSecondChoiceOnTheSameItemWinsWhateverTheFirstComesTo() async throws {
        try await withCatalogedLibrary(fileCount: 1) { library in
            let held = HeldChoiceWrites(store: library.store, failing: [1])
            let model = makeShownFirstModel(library, writer: held.writer)
            defer { model.mediaChoiceForwardingTask?.cancel() }
            let id = library.ids[0]
            model.selectAll()

            model.submitMediaChoice(.liked, origin: .keyboard)
            model.submitMediaChoice(.disliked, origin: .keyboard)
            #expect(model.tileContentStore.content(for: id)?.detail.mediaChoice == .disliked)

            await held.release()
            try await waitUntil { await held.arrived == 2 }
            #expect(model.tileContentStore.content(for: id)?.detail.mediaChoice == .disliked)
            #expect(model.mediaChoiceFailure == MediaChoiceFailure(count: 1))
            await held.release()
            try await waitUntil { model.hasSettledMediaChoices }
            #expect(try await library.store.mediaAssets(for: [id])[id]?.mediaChoice == .disliked)
            #expect(model.undoMenuState.undoTitle == "Undo Dislike")
        }
    }

    /// The user leaves the scope while the write is held: the failure still withdraws the
    /// choice, and selects nothing the new scope does not show.
    @Test func aScopeChangeMidWriteLeavesTheWithdrawalToTheTiles() async throws {
        try await withCatalogedLibrary(fileCount: 1) { library in
            let held = HeldChoiceWrites(store: library.store, failing: [1])
            let model = makeShownFirstModel(library, writer: held.writer)
            defer { model.mediaChoiceForwardingTask?.cancel() }
            let id = library.ids[0]
            model.selectAll()

            model.submitMediaChoice(.liked, origin: .keyboard)
            model.applyState(shownFirstWindowState(ids: [], scope: .places))
            await held.release()
            try await waitUntil { model.hasSettledMediaChoices }

            #expect(model.tileContentStore.content(for: id)?.detail.mediaChoice == .notRated)
            #expect(model.gridSelection.selection.isEmpty)
            #expect(model.mediaChoiceFailure == MediaChoiceFailure(count: 1))
        }
    }

    /// The overlay alone: a read that started before the landing never retires a choice; the
    /// first read that started after it does.
    @Test func onlyAReadStartedAfterTheLandingRetiresAChoice() {
        let overlay = MediaChoiceOverlay()
        let id = MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/r"), relativePath: MediaRelativePath(rawValue: "a.jpg"))
        let read = MediaTileDetail(libraryRootPath: id.libraryRootPath, relativePath: id.relativePath, mediaChoice: .notRated)
        let early = overlay.readStarted()
        let command = overlay.submit([id: .liked]) { _ in .notRated }
        overlay.landed(command, ids: [id])
        #expect(overlay.answer([id: read], asked: [id], startedAt: early)[id]?.mediaChoice == .liked)
        #expect(overlay.choice(for: id) == .liked)
        let late = overlay.readStarted()
        let landed = read.with(mediaChoice: .liked)
        #expect(overlay.answer([id: landed], asked: [id], startedAt: late)[id]?.mediaChoice == .liked)
        #expect(overlay.isEmpty)
    }
}

/// Holds every choice write at its suspension until `release()`, then writes it to the store,
/// or throws for the writes `failing` numbers (1 is the first).
actor HeldChoiceWrites {
    private let store: CatalogStore
    private let failing: Set<Int>
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = 0
    private(set) var arrived = 0

    init(store: CatalogStore, failing: Set<Int> = []) {
        self.store = store
        self.failing = failing
    }

    nonisolated var writer: MediaChoiceWriter {
        MediaChoiceWriter { assignments in try await self.write(assignments) }
    }

    func release() {
        released += 1
        if !waiting.isEmpty {
            waiting.removeFirst().resume()
        }
    }

    private func write(_ assignments: [MediaAssetID: MediaChoice]) async throws -> CatalogStore.MediaChoiceMutationResult {
        arrived += 1
        let number = arrived
        if released < number {
            await withCheckedContinuation { waiting.append($0) }
        }
        if failing.contains(number) {
            throw CocoaError(.fileWriteUnknown)
        }
        return try await store.setMediaChoices(assignments)
    }
}

@MainActor
private func makeShownFirstModel(_ library: CatalogedLibrary, writer: MediaChoiceWriter) -> CatalogWindowViewModel {
    let model = CatalogWindowViewModel(
        catalogStore: library.store,
        startsStallMonitor: false,
        startsEnrichment: false,
        startsSourceMonitoring: false,
        preferencesDomain: .suite(UUID().uuidString),
        volumeCapacity: ampleVolumeCapacity,
        trashFiles: .refusing
    )
    model.applyState(shownFirstWindowState(ids: library.ids, scope: .allMedia))
    for id in library.ids {
        model.tileContentStore.mergeDetail(
            MediaTileDetail(libraryRootPath: id.libraryRootPath, relativePath: id.relativePath, mediaChoice: .notRated)
        )
    }
    model.startMediaChoiceForwarding(writer: writer)
    return model
}

private func shownFirstWindowState(ids: [MediaAssetID], scope: SidebarSelection) -> CatalogWindowState {
    CatalogWindowState(
        title: "Choices",
        libraries: [],
        removableSources: [],
        mediaGrid: CatalogMediaGridState(scope: scope, orderedAssetIDs: ids),
        filterOptions: .empty,
        resolvedSidebarSelection: scope,
        mediaEmptyState: .noMedia,
        deviceConnectionBanner: nil
    )
}
