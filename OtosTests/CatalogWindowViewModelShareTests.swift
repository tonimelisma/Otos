import AppKit
import Foundation
@testable import OtosKit
import Testing

/// Intent-level coverage for Share (APP-036): the shareable list is the current-item
/// resolver's answer per view mode, and nothing is presented without a target. The
/// picker itself is the system's; these tests stop at the URLs handed to it.
@MainActor
struct CatalogWindowViewModelShareTests {
    @Test func gridSharesOrderedSelection() {
        let model = makeShareModel()
        let ids = makeIDs(count: 4)
        model.applyState(shareWindowState(ids: ids))

        _ = model.applyGridClick(hit: ids[2], modifiers: [], orderedIDs: ids)
        _ = model.applyGridClick(hit: ids[0], modifiers: [.command], orderedIDs: ids)

        #expect(model.currentTargetFileURLs == [ids[0].fileURL, ids[2].fileURL])
    }

    @Test func loupeSharesFocusedAsset() {
        let model = makeShareModel()
        let ids = makeIDs(count: 3)
        model.applyState(shareWindowState(ids: ids))
        model.selectAll()
        #expect(model.currentTargetFileURLs.count == 3)

        model.openLoupe(id: ids[1])

        #expect(model.currentTargetFileURLs == [ids[1].fileURL])
    }

    @Test func compareSharesActivePane() {
        let model = makeShareModel()
        let ids = makeIDs(count: 3)
        model.applyState(shareWindowState(ids: ids))
        _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids)
        _ = model.applyGridClick(hit: ids[2], modifiers: [.command], orderedIDs: ids)
        model.enterCompare()

        #expect(model.currentTargetFileURLs == [ids[2].fileURL])
        model.activateComparePane(.left)
        #expect(model.currentTargetFileURLs == [ids[0].fileURL])
    }

    @Test func noTargetPresentsNothing() {
        let model = makeShareModel()
        model.applyState(shareWindowState(ids: makeIDs(count: 2)))

        model.shareCurrentTargets(origin: .menu)

        #expect(model.currentTargetFileURLs.isEmpty)
        #expect(model.sharePickerPresenter.activePicker == nil)
    }

    @Test func presenterIgnoresEmptyItems() {
        let presenter = SharePickerPresenter()
        presenter.present([], relativeTo: .zero, of: NSView(frame: .zero))
        #expect(presenter.activePicker == nil)
    }
}

@MainActor
private func makeShareModel() -> CatalogWindowViewModel {
    CatalogWindowViewModel(
        catalogStore: CatalogStore(location: .inMemory),
        startsStallMonitor: false,
        startsEnrichment: false,
        startsSourceMonitoring: false,
        preferencesDomain: .suite(UUID().uuidString),
        trashFiles: .refusing
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

private func shareWindowState(ids: [MediaAssetID]) -> CatalogWindowState {
    CatalogWindowState(
        title: "Share",
        libraries: [],
        removableSources: [],
        mediaGrid: CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: ids),
        filterOptions: .empty,
        resolvedSidebarSelection: .allMedia,
        mediaEmptyState: .noMedia,
        deviceConnectionBanner: nil
    )
}
