import AppKit
import Foundation
@testable import OtosKit
import Testing

/// ViewModel side of the media context menu (APP-037): the right-click selection rule
/// through the real grid controller, synchronous model freshness, and the command
/// mapping onto the menu-bar intents.
@MainActor
struct CatalogWindowViewModelMediaItemMenuTests {
    @Test func contextClickOutsideSelectionSelectsOnlyTheHit() {
        let workspace = MenuRecordingWorkspace()
        let model = makeMenuModel(workspace: workspace)
        let ids = makeIDs(count: 4)
        model.applyState(menuWindowState(ids: ids))
        let controller = MediaGridViewController()
        _ = controller.view
        controller.selectionHandlers = .from(model)
        controller.contextMenu = model.makeMediaItemContextMenu
        controller.receive(model.state.mediaGrid)
        awaitGridApply(controller, expectedIDs: ids)
        _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids)
        _ = model.applyGridClick(hit: ids[1], modifiers: [.command], orderedIDs: ids)

        let menu = controller.collectionView.onContextMenu?(IndexPath(item: 3, section: 0))

        #expect(menu != nil)
        #expect(model.gridSelection.selection == [ids[3]])
        #expect(model.currentTargetFileURLs == [ids[3].fileURL])
    }

    @Test func contextClickInsideSelectionKeepsIt() {
        let workspace = MenuRecordingWorkspace()
        let model = makeMenuModel(workspace: workspace)
        let ids = makeIDs(count: 4)
        model.applyState(menuWindowState(ids: ids))
        let controller = MediaGridViewController()
        _ = controller.view
        controller.selectionHandlers = .from(model)
        controller.contextMenu = model.makeMediaItemContextMenu
        controller.receive(model.state.mediaGrid)
        awaitGridApply(controller, expectedIDs: ids)
        _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids)
        _ = model.applyGridClick(hit: ids[2], modifiers: [.shift], orderedIDs: ids)

        let menu = controller.collectionView.onContextMenu?(IndexPath(item: 1, section: 0))

        #expect(menu != nil)
        #expect(model.gridSelection.selection == Set(ids[0 ... 2]))
        #expect(model.currentTargetFileURLs == ids[0 ... 2].map(\.fileURL))
    }

    @Test func modelIsBuiltSynchronouslyForFreshTargets() {
        let workspace = MenuRecordingWorkspace()
        let model = makeMenuModel(workspace: workspace)
        let ids = makeIDs(count: 2)
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

    @Test func noTargetsBuildNoMenu() {
        let model = makeMenuModel(workspace: MenuRecordingWorkspace())
        model.applyState(menuWindowState(ids: makeIDs(count: 2)))

        #expect(model.mediaItemMenuModel() == .empty)
        #expect(model.makeMediaItemContextMenu() == nil)
    }

    @Test func performRoutesToTheMenuBarIntents() async throws {
        let workspace = MenuRecordingWorkspace()
        let model = makeMenuModel(workspace: workspace)
        let ids = makeIDs(count: 2)
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

    @Test func compareContextTargetsTheActivatedPane() {
        let model = makeMenuModel(workspace: MenuRecordingWorkspace())
        let ids = makeIDs(count: 3)
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
private func makeMenuModel(workspace: MenuRecordingWorkspace) -> CatalogWindowViewModel {
    CatalogWindowViewModel(
        catalogStore: CatalogStore(location: .inMemory),
        startsStallMonitor: false,
        startsEnrichment: false,
        startsSourceMonitoring: false,
        preferencesDomain: .suite(UUID().uuidString),
        workspace: workspace
    )
}

private func makeIDs(count: Int) -> [MediaAssetID] {
    (0 ..< count).map { index in
        MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
            relativePath: MediaRelativePath(rawValue: "asset-\(index).jpg")
        )
    }
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
}
