import AppKit
import Foundation
import os
@testable import Otos
import Testing

/// Controller-level tests for shift-click range selection (spec 0046). Setup applies a
/// snapshot directly to `dataSource` and drives `mutationGate` through its own pure
/// `receive`/`completeStructuralApply` calls. Selection is driven through
/// `mouseSelectionFinished(hit:modifiers:)` — the same entry point
/// `MediaGridCollectionView`'s mouseDown capture calls once the native tracking loop has
/// settled selection — with `selectItems`/`deselectItems` first to mimic that settled
/// native result. No `NSEvent` construction is needed.
@MainActor
struct MediaAssetCollectionSelectionTests {
    @Test func plainClickSetsAnchorAndBase() throws {
        let controller = makeController(itemCount: 4)
        let ids = controller.mutationGate.displayedOrderedIDs

        try selectNatively(controller, ids[2]) // plain click on the item at index 2
        try controller.mouseSelectionFinished(hit: indexPath(controller, ids[2]), modifiers: [])

        #expect(controller.selectionAnchorID == ids[2])
        #expect(controller.anchorBaseSelection == [ids[2]])
        #expect(controller.selectedIdentities() == [ids[2]])
    }

    @Test func shiftClickExtendsAContiguousRangeFromTheAnchor() throws {
        let controller = makeController(itemCount: 8)
        let ids = controller.mutationGate.displayedOrderedIDs
        try setAnchor(controller, to: ids[2]) // click item 2

        // Native shift-click on an unselected item only adds that item.
        try selectNatively(controller, ids[5]) // shift-click item 5
        try controller.mouseSelectionFinished(hit: indexPath(controller, ids[5]), modifiers: [.shift])

        #expect(controller.selectedIdentities() == Set(ids[2 ... 5]))
        #expect(controller.selectionAnchorID == ids[2])
        #expect(controller.anchorBaseSelection == [ids[2]])
    }

    @Test func secondShiftClickFromTheSameAnchorContractsTheRange() throws {
        let controller = makeController(itemCount: 8)
        let ids = controller.mutationGate.displayedOrderedIDs
        try setAnchor(controller, to: ids[2])
        try selectNatively(controller, ids[6])
        try controller.mouseSelectionFinished(hit: indexPath(controller, ids[6]), modifiers: [.shift])
        #expect(controller.selectedIdentities() == Set(ids[2 ... 6]))

        // Shift-clicking an already-selected item (ids[4]) natively toggles it OFF; the
        // handler still recomputes the contiguous range from the same anchor.
        try deselectNatively(controller, ids[4])
        try controller.mouseSelectionFinished(hit: indexPath(controller, ids[4]), modifiers: [.shift])

        #expect(controller.selectedIdentities() == Set(ids[2 ... 4]))
    }

    @Test func commandClickThenShiftClickUnionsTheBaseWithTheNewRange() throws {
        let controller = makeController(itemCount: 13)
        let ids = controller.mutationGate.displayedOrderedIDs
        try setAnchor(controller, to: ids[2]) // click item 2

        // ⌘-click item 10: native ⌘-click adds it alongside the existing selection.
        try selectNatively(controller, ids[10])
        try controller.mouseSelectionFinished(hit: indexPath(controller, ids[10]), modifiers: [.command])
        #expect(controller.selectionAnchorID == ids[10])
        #expect(controller.anchorBaseSelection == [ids[2], ids[10]])

        // ⇧-click item 12: range extends from the new anchor (item 10) to item 12,
        // unioned with the base recorded at the ⌘-click.
        try selectNatively(controller, ids[12])
        try controller.mouseSelectionFinished(hit: indexPath(controller, ids[12]), modifiers: [.shift])

        #expect(controller.selectedIdentities() == Set([ids[2]] + ids[10 ... 12]))
    }

    @Test func shiftClickWithNoAnchorBehavesAsAPlainClick() throws {
        let controller = makeController(itemCount: 6)
        let ids = controller.mutationGate.displayedOrderedIDs

        try selectNatively(controller, ids[3])
        try controller.mouseSelectionFinished(hit: indexPath(controller, ids[3]), modifiers: [.shift])

        #expect(controller.selectedIdentities() == [ids[3]])
        #expect(controller.selectionAnchorID == ids[3])
        #expect(controller.anchorBaseSelection == [ids[3]])
    }

    @Test func shiftCommandClickBehavesAsShift() throws {
        let controller = makeController(itemCount: 8)
        let ids = controller.mutationGate.displayedOrderedIDs
        try setAnchor(controller, to: ids[2])

        try selectNatively(controller, ids[5])
        try controller.mouseSelectionFinished(hit: indexPath(controller, ids[5]), modifiers: [.shift, .command])

        #expect(controller.selectedIdentities() == Set(ids[2 ... 5])) // range wins over toggle
        #expect(controller.selectionAnchorID == ids[2]) // anchor unchanged, as for a plain ⇧-click
    }

    /// F5 regression: a plain click that collapses a multi-selection onto an
    /// already-selected member fires no `didSelectItemsAt` for the clicked item, yet the
    /// anchor must move to it. A following ⇧-click then ranges from the clicked item, not
    /// the old anchor.
    @Test func plainClickCollapsingAMultiSelectionMovesTheAnchorToTheClickedItem() throws {
        let controller = makeController(itemCount: 8)
        let ids = controller.mutationGate.displayedOrderedIDs

        // Build {ids0, ids1, ids2}: plain ids0, ⌘ ids1, ⌘ ids2.
        try selectNatively(controller, ids[0])
        try controller.mouseSelectionFinished(hit: indexPath(controller, ids[0]), modifiers: [])
        try selectNatively(controller, ids[1])
        try controller.mouseSelectionFinished(hit: indexPath(controller, ids[1]), modifiers: [.command])
        try selectNatively(controller, ids[2])
        try controller.mouseSelectionFinished(hit: indexPath(controller, ids[2]), modifiers: [.command])
        #expect(controller.selectedIdentities() == Set(ids[0 ... 2]))

        // A plain click on already-selected ids1 natively collapses to {ids1} and fires no
        // didSelect for ids1. Mimic that settled native result, then run the handler.
        try controller.collectionView.selectItems(at: [indexPath(controller, ids[1])], scrollPosition: [])
        try controller.collectionView.deselectItems(
            at: [indexPath(controller, ids[0]), indexPath(controller, ids[2])]
        )
        try controller.mouseSelectionFinished(hit: indexPath(controller, ids[1]), modifiers: [])

        #expect(controller.selectionAnchorID == ids[1])
        #expect(controller.anchorBaseSelection == [ids[1]])
        #expect(controller.selectedIdentities() == [ids[1]])

        // A following ⇧-click on ids4 ranges ids1…ids4, not ids0…ids4.
        try selectNatively(controller, ids[4])
        try controller.mouseSelectionFinished(hit: indexPath(controller, ids[4]), modifiers: [.shift])
        #expect(controller.selectedIdentities() == Set(ids[1 ... 4]))
    }

    @Test func emptySpacePlainClickClearsTheAnchorAndBase() throws {
        let controller = makeController(itemCount: 4)
        let ids = controller.mutationGate.displayedOrderedIDs
        try setAnchor(controller, to: ids[1])

        // A plain empty-space click natively clears the selection.
        controller.collectionView.deselectItems(at: controller.collectionView.selectionIndexPaths)
        controller.mouseSelectionFinished(hit: nil, modifiers: [])

        #expect(controller.selectionAnchorID == nil)
        #expect(controller.anchorBaseSelection.isEmpty)
    }

    @Test func emptySpaceShiftClickLeavesTheAnchorIntact() throws {
        let controller = makeController(itemCount: 4)
        let ids = controller.mutationGate.displayedOrderedIDs
        try setAnchor(controller, to: ids[1])

        controller.mouseSelectionFinished(hit: nil, modifiers: [.shift])

        #expect(controller.selectionAnchorID == ids[1])
        #expect(controller.anchorBaseSelection == [ids[1]])
    }

    @Test func structuralApplyPrunesAnAnchorWhoseAssetWasRemoved() throws {
        let controller = makeController(itemCount: 4)
        let ids = controller.mutationGate.displayedOrderedIDs
        try setAnchor(controller, to: ids[1])

        controller.restoreSelection([], in: [ids[0], ids[2], ids[3]])

        #expect(controller.selectionAnchorID == nil)
        #expect(controller.anchorBaseSelection.isEmpty)
    }

    @Test func structuralApplyKeepsAnchorWhenItsAssetSurvives() throws {
        let controller = makeController(itemCount: 4)
        let ids = controller.mutationGate.displayedOrderedIDs
        try setAnchor(controller, to: ids[1])

        controller.restoreSelection([ids[1]], in: [ids[0], ids[1], ids[2], ids[3]])

        #expect(controller.selectionAnchorID == ids[1])
    }

    /// F6 regression: when the anchor survives a structural apply, dead identities are
    /// pruned from the anchor base too — otherwise the next shift-range target keeps a
    /// removed identity and never equals the live selection, misfiring the shift-range
    /// signpost on every shift-click after a removal.
    @Test func structuralApplyPrunesDeadIdentitiesFromTheAnchorBaseWhenAnchorSurvives() {
        let controller = makeController(itemCount: 4)
        let ids = controller.mutationGate.displayedOrderedIDs
        controller.selectionAnchorID = ids[0]
        controller.anchorBaseSelection = [ids[0], ids[2]] // ids[2] is about to be removed

        controller.restoreSelection([], in: [ids[0], ids[1], ids[3]])

        #expect(controller.selectionAnchorID == ids[0])
        #expect(controller.anchorBaseSelection == [ids[0]])
    }

    @Test func descriptorChangeClearsTheAnchor() throws {
        let controller = makeController(itemCount: 4)
        let ids = controller.mutationGate.displayedOrderedIDs
        try setAnchor(controller, to: ids[1])

        controller.clearSelection(reason: "descriptorChange")

        #expect(controller.selectionAnchorID == nil)
        #expect(controller.anchorBaseSelection.isEmpty)
    }

    /// A descriptor-changing structural apply must clear the anchor unconditionally, even
    /// when the previously anchored asset is still present in the new scope's results.
    @Test func descriptorChangingApplyClearsAnchorEvenWhenTheAnchoredAssetSurvives() throws {
        let controller = makeController(itemCount: 4)
        let ids = controller.mutationGate.displayedOrderedIDs
        try setAnchor(controller, to: ids[1])

        let grid = CatalogMediaGridState(
            scope: .library(LibraryRootPath(rawValue: "/Pictures")),
            orderedAssetIDs: ids // the anchored asset (ids[1]) is still present
        )
        let context = MediaAssetCollectionViewController.StructuralApplyCompletionContext(
            grid: grid,
            preservedSelection: [],
            resetSelection: true,
            resetScroll: true,
            applyStart: Date(),
            insertedCount: 0,
            removedCount: 0,
            reorderOnly: false,
            largeApply: false,
            animatingDifferences: true,
            usesReloadDataFallback: false,
            signpost: .beginState(id: .exclusive)
        )

        controller.completeStructuralApply(context, operation: nil, stallMonitor: nil, diagnostics: nil)

        #expect(controller.selectionAnchorID == nil)
        #expect(controller.anchorBaseSelection.isEmpty)
        #expect(controller.selectedIdentities().isEmpty)
    }
}

// MARK: - Test support

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
    _ = controller.mutationGate.receive(grid)
    _ = controller.mutationGate.completeStructuralApply(applied: grid)

    return controller
}

@MainActor
private func indexPath(_ controller: MediaAssetCollectionViewController, _ id: MediaAssetID) throws -> IndexPath {
    try #require(controller.dataSource.indexPath(for: id))
}

/// Sets the anchor the way a real plain click would: select the item natively, then run
/// it through the handler with no modifiers.
@MainActor
private func setAnchor(_ controller: MediaAssetCollectionViewController, to id: MediaAssetID) throws {
    try selectNatively(controller, id)
    try controller.mouseSelectionFinished(hit: indexPath(controller, id), modifiers: [])
}

/// Mimics what AppKit's native selection tracking loop already did before
/// `mouseSelectionFinished` runs: `selectionIndexPaths` reflects the native (uncorrected)
/// result by the time the handler is called.
@MainActor
private func selectNatively(_ controller: MediaAssetCollectionViewController, _ id: MediaAssetID) throws {
    try controller.collectionView.selectItems(at: [indexPath(controller, id)], scrollPosition: [])
}

@MainActor
private func deselectNatively(_ controller: MediaAssetCollectionViewController, _ id: MediaAssetID) throws {
    try controller.collectionView.deselectItems(at: [indexPath(controller, id)])
}

@MainActor
private func makeAssetID(path: String) -> MediaAssetID {
    MediaAssetID(
        libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
        relativePath: MediaRelativePath(rawValue: path)
    )
}
