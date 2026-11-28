import AppKit
import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// ViewModel side of the media context menu (APP-037): the right-click selection rule
/// through the real grid controller, synchronous model freshness, and the command
/// mapping onto the menu-bar intents.
@Suite(.testScope)
@MainActor
struct CatalogWindowViewModelMediaItemMenuTests {
    // Validates: APP-037
    @Test func contextClickOutsideSelectionSelectsOnlyTheHit() async throws {
        let workspace = MenuRecordingWorkspace()
        let model = makeMenuModel(workspace: workspace)
        let ids = try makeIDs(count: 4)
        model.applyState(menuWindowState(ids: ids))
        let controller = MediaGridViewController()
        _ = controller.view
        controller.selectionHandlers = .from(model)
        controller.contextMenu = model.makeMediaItemContextMenu
        controller.receive(model.state.mediaGrid)
        try await awaitGridShows(controller, model.state.mediaGrid)
        _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids)
        _ = model.applyGridClick(hit: ids[1], modifiers: [.command], orderedIDs: ids)

        let menu = controller.collectionView.onContextMenu?(IndexPath(item: 3, section: 0))

        #expect(menu != nil)
        #expect(model.gridSelection.selection == [ids[3]])
        #expect(model.currentTargetFileURLs == [ids[3].fileURL])
    }

    // Validates: APP-037
    @Test func contextClickInsideSelectionKeepsIt() async throws {
        let workspace = MenuRecordingWorkspace()
        let model = makeMenuModel(workspace: workspace)
        let ids = try makeIDs(count: 4)
        model.applyState(menuWindowState(ids: ids))
        let controller = MediaGridViewController()
        _ = controller.view
        controller.selectionHandlers = .from(model)
        controller.contextMenu = model.makeMediaItemContextMenu
        controller.receive(model.state.mediaGrid)
        try await awaitGridShows(controller, model.state.mediaGrid)
        _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids)
        _ = model.applyGridClick(hit: ids[2], modifiers: [.shift], orderedIDs: ids)

        let menu = controller.collectionView.onContextMenu?(IndexPath(item: 1, section: 0))

        #expect(menu != nil)
        #expect(model.gridSelection.selection == Set(ids[0 ... 2]))
        #expect(model.currentTargetFileURLs == ids[0 ... 2].map(\.fileURL))
    }

    // Validates: APP-037
    @Test func modelIsBuiltSynchronouslyForFreshTargets() throws {
        let workspace = MenuRecordingWorkspace()
        let model = makeMenuModel(workspace: workspace)
        let ids = try makeIDs(count: 2)
        model.applyState(menuWindowState(ids: ids))
        _ = model.applyGridClick(hit: ids[1], modifiers: [], orderedIDs: ids)

        // No await between the click and the menu: the off-main build cannot have landed.
        let menuModel = model.mediaItemMenuModel()

        #expect(menuModel.openTitle == "Open in Preview")
        #expect(menuModel.shareItems == [ids[1].fileURL])
        #expect(menuModel.canReveal)
        #expect(model.openWithMenu.openTitle == "Open in Preview")
        #expect(model.openWithMenuTask == nil)
    }

    // Validates: APP-037
    /// Reveal acts on the same targets as Open, Share and Copy: in Loupe that is the
    /// focused item, never a grid multi-selection left behind it (APP-037).
    @Test func revealUsesTheCurrentTargetsInEveryMode() async throws {
        let workspace = MenuRecordingWorkspace()
        let model = makeMenuModel(workspace: workspace)
        let ids = try makeIDs(count: 3)
        model.applyState(menuWindowState(ids: ids))
        _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids)
        _ = model.applyGridClick(hit: ids[2], modifiers: [.command], orderedIDs: ids)

        model.revealCurrentTargetsInFinder()
        model.openLoupe(id: ids[1])
        #expect(model.mediaItemMenuModel().canReveal)
        model.revealCurrentTargetsInFinder()
        try await waitUntil { model.hasSettledHandOffs }

        #expect(workspace.revealed == [[ids[0].fileURL, ids[2].fileURL], [ids[1].fileURL]])
    }

    // Validates: APP-051
    /// Reveal shows where a photo lives, not what a hand-off gives: an edited photo is
    /// revealed as its original, and nothing is rendered for it (ADR 0037).
    @Test func revealShowsTheOriginalOfAnEditedPhoto() async throws {
        try await withEditableLibrary(fileCount: 2) { library in
            _ = try await library.store.setEditRecipe(EditRecipe(exposure: 1), for: library.ids[1])
            let workspace = MenuRecordingWorkspace()
            let model = makeMenuModel(workspace: workspace, store: library.store)
            defer { model.handOffTask?.cancel() }
            model.applyState(menuWindowState(ids: library.ids))
            model.selectAll()

            model.revealCurrentTargetsInFinder()
            try await waitUntil { model.hasSettledHandOffs }

            #expect(workspace.revealed == [library.ids.map(\.fileURL)])
            #expect(model.handOffAlertMessage == nil)
            #expect(!FileManager.default.fileExists(atPath: library.store.handOffDirectory.path(percentEncoded: false)))
        }
    }

    // Validates: APP-037
    @Test func performRoutesToTheMenuBarIntents() async throws {
        let workspace = MenuRecordingWorkspace()
        let model = makeMenuModel(workspace: workspace)
        let ids = try makeIDs(count: 2)
        model.applyState(menuWindowState(ids: ids))
        model.selectAll()
        _ = model.mediaItemMenuModel()

        model.performMediaItemCommand(.open)
        try await waitUntil { await workspace.opens.count == 1 }
        let photos = OpenWithApplication(url: .photos, displayName: "Photos")
        model.performMediaItemCommand(.openWith(photos))
        try await waitUntil { await workspace.opens.count == 2 }

        let opens = await workspace.opens
        #expect(opens[0].application == .preview)
        #expect(opens[0].targets == ids.map(\.fileURL))
        #expect(opens[1].application == .photos)
        #expect(opens[1].targets == ids.map(\.fileURL))
    }

    @Test func compareContextTargetsTheActivatedPane() throws {
        let model = makeMenuModel(workspace: MenuRecordingWorkspace())
        let ids = try makeIDs(count: 3)
        model.applyState(menuWindowState(ids: ids))
        _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids)
        _ = model.applyGridClick(hit: ids[2], modifiers: [.command], orderedIDs: ids)
        model.enterCompare()

        // What a left-pane context click does: activate, then build.
        model.activateComparePane(.left)
        let left = model.mediaItemMenuModel()
        #expect(left.shareItems == [ids[0].fileURL])
        model.activateComparePane(.right)
        let right = model.mediaItemMenuModel()
        #expect(right.shareItems == [ids[2].fileURL])
    }
}

@MainActor
private func makeMenuModel(
    workspace: MenuRecordingWorkspace,
    store: CatalogStore = makeTestStore(location: .inMemory)
) -> CatalogWindowViewModel {
    // Open, Open With, Share, Copy and Reveal are hand-offs, consumed by the hand-off lane.
    let model = CatalogWindowViewModel(
        catalogStore: store,
        startsStallMonitor: false,
        startsEnrichment: false,
        startsSourceMonitoring: false,
        preferencesDomain: .suite(UUID().uuidString),
        workspace: workspace,
        volumeCapacity: ampleVolumeCapacity,
        trashFiles: .refusing
    )
    model.startHandOff(store: model.catalogStore)
    return model
}

private func makeIDs(count: Int) throws -> [MediaAssetID] {
    try makeLocalMediaIDs((0 ..< count).map { "asset-\($0).jpg" })
}

private func menuWindowState(ids: [MediaAssetID]) -> CatalogWindowState {
    CatalogWindowState(
        title: "Menu",
        libraries: [],
        removableSources: [],
        mediaGrid: CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: ids),
        filterOptions: .empty,
        resolvedSidebarSelection: .allMedia,
        mediaEmptyState: .noMedia,
        deviceConnectionBanner: nil
    )
}

private extension URL {
    static let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
    static let photos = URL(fileURLWithPath: "/System/Applications/Photos.app")
}

private actor MenuOpenLog {
    var opens: [(application: URL, targets: [URL])] = []

    func record(application: URL, targets: [URL]) {
        opens.append((application, targets))
    }
}

/// Every JPEG opens in Preview; Preview and Photos can open it.
private struct MenuRecordingWorkspace: WorkspaceOpening {
    private let log = MenuOpenLog()
    private let reveals = RevealRecorder()

    var revealed: [[URL]] {
        reveals.snapshot()
    }

    var opens: [(application: URL, targets: [URL])] {
        get async { await log.opens }
    }

    func applicationURLs(toOpen _: URL) -> [URL] {
        [.preview, .photos]
    }

    func defaultApplicationURL(toOpen _: URL) -> URL? {
        .preview
    }

    func displayName(forApplicationAt url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    func open(_ urls: [URL], withApplicationAt applicationURL: URL) async throws {
        await log.record(application: applicationURL, targets: urls)
    }

    func revealInFinder(_ urls: [URL]) {
        reveals.record(urls)
    }
}

/// Reveals as the workspace received them. A class, so the value-type workspace shares it.
private final class RevealRecorder: Sendable {
    private let storage = Mutex<[[URL]]>([])

    func record(_ urls: [URL]) {
        storage.withLock { $0.append(urls) }
    }

    func snapshot() -> [[URL]] {
        storage.withLock { $0 }
    }
}
