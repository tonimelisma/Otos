import AppKit
import Foundation
import os
@testable import Otos
import Testing

/// Controller-level tests for grid zoom's apply-gate deferral (spec 0048): a zoom
/// requested while a diffable structural apply is in flight must never run concurrently
/// with that apply, and must apply exactly once after it completes.
@MainActor
struct MediaAssetCollectionZoomTests {
    @Test func setColumnCountSwapsImmediatelyWhenNoApplyIsInFlight() {
        let controller = makeController(itemCount: 4)
        #expect(controller.columnCount == GridColumnCount.defaultValue)

        controller.setColumnCount(3)

        #expect(controller.columnCount == 3)
        #expect(controller.pendingColumnCount == nil)
    }

    @Test func setColumnCountIsANoOpWhenTheRequestedValueAlreadyMatches() {
        let controller = makeController(itemCount: 4)
        controller.setColumnCount(GridColumnCount.defaultValue)

        #expect(controller.columnCount == GridColumnCount.defaultValue)
        #expect(controller.pendingColumnCount == nil)
    }

    @Test func setColumnCountDefersWhileApplyIsInFlightAndAppliesExactlyOnceAfterCompletion() {
        let controller = makeController(itemCount: 4)
        let ids = controller.applyGate.displayedOrderedIDs
        let newGrid = CatalogMediaGridState(
            scope: .allMedia,
            orderedAssetIDs: ids + [makeAssetID(path: "extra.jpg")]
        )
        guard case .apply = controller.applyGate.receive(newGrid) else {
            Issue.record("Expected the differing grid to start a structural apply")
            return
        }
        #expect(controller.applyGate.isApplyInFlight)

        controller.setColumnCount(3)

        #expect(controller.columnCount == GridColumnCount.defaultValue, "swap must not run while an apply is in flight")
        #expect(controller.pendingColumnCount == 3)

        let context = MediaAssetCollectionViewController.StructuralApplyCompletionContext(
            grid: newGrid,
            preservedSelection: [],
            resetSelection: false,
            resetScroll: false,
            applyStart: Date(),
            insertedCount: 1,
            removedCount: 0,
            reorderOnly: false,
            largeApply: false,
            animatingDifferences: true,
            usesReloadDataFallback: false,
            signpost: .beginState(id: .exclusive)
        )
        controller.completeStructuralApply(context, operation: nil, stallMonitor: nil, diagnostics: nil)

        #expect(controller.columnCount == 3)
        #expect(controller.pendingColumnCount == nil)
    }
}

@MainActor
private func makeController(itemCount: Int) -> MediaAssetCollectionViewController {
    let controller = MediaAssetCollectionViewController()
    _ = controller.view // forces loadView(), which installs the collection view and data source

    let assetIDs = (0 ..< itemCount).map { makeAssetID(path: "asset-\($0).jpg") }
    var snapshot = NSDiffableDataSourceSnapshot<MediaAssetCollectionViewController.Section, MediaAssetID>()
    snapshot.appendSections([.media])
    snapshot.appendItems(assetIDs, toSection: .media)
    controller.dataSource.apply(snapshot, animatingDifferences: false)

    let grid = CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: assetIDs)
    _ = controller.applyGate.receive(grid)
    _ = controller.applyGate.complete(applied: grid)

    return controller
}

@MainActor
private func makeAssetID(path: String) -> MediaAssetID {
    MediaAssetID(
        libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
        relativePath: MediaRelativePath(rawValue: path)
    )
}
