import AppKit
import Foundation
import os
@testable import Otos
import Testing

/// Controller-level tests for shift-click range selection (spec 0046). These are the
/// first tests in the repo to host a live `MediaAssetCollectionViewController`: setup
/// applies a snapshot directly to `dataSource` and drives `applyGate` through its own
/// pure `receive`/`complete` calls rather than the full async structural-apply pipeline,
/// so tests stay synchronous and do not depend on AppKit's diffable-apply animation
/// timing. Selection events are driven through `handleUserSelectionEvent` with a
/// synthesized `NSEvent`, matching what the real delegate callbacks forward.
@MainActor
struct MediaAssetCollectionSelectionTests {
    @Test func plainClickSetsAnchorAndBase() throws {
        let controller = makeController(itemCount: 4)
        let ids = controller.applyGate.displayedOrderedIDs

        try selectNatively(controller, ids[2]) // plain click on the item at index 2
        try controller.handleUserSelectionEvent(
            indexPaths: [indexPath(controller, ids[2])],
            kind: .select,
            event: clickEvent()
        )

        #expect(controller.selectionAnchorID == ids[2])
        #expect(controller.anchorBaseSelection == [ids[2]])
        #expect(controller.selectedIdentities() == [ids[2]])
    }

    @Test func shiftClickExtendsAContiguousRangeFromTheAnchor() throws {
        let controller = makeController(itemCount: 8)
        let ids = controller.applyGate.displayedOrderedIDs
        try setAnchor(controller, to: ids[2]) // click item 2

        // Native shift-click on an unselected item only adds that item.
        try selectNatively(controller, ids[5]) // shift-click item 5
        try controller.handleUserSelectionEvent(
            indexPaths: [indexPath(controller, ids[5])],
            kind: .select,
            event: shiftClickEvent()
        )

        #expect(controller.selectedIdentities() == Set(ids[2 ... 5]))
        #expect(controller.selectionAnchorID == ids[2])
        #expect(controller.anchorBaseSelection == [ids[2]])
    }

    @Test func secondShiftClickFromTheSameAnchorContractsTheRange() throws {
        let controller = makeController(itemCount: 8)
        let ids = controller.applyGate.displayedOrderedIDs
        try setAnchor(controller, to: ids[2])
        try selectNatively(controller, ids[6])
        try controller.handleUserSelectionEvent(
            indexPaths: [indexPath(controller, ids[6])],
            kind: .select,
            event: shiftClickEvent()
        )
        #expect(controller.selectedIdentities() == Set(ids[2 ... 6]))

        // Shift-clicking an already-selected item (ids[4]) natively toggles it OFF —
        // the classic miss this fix must handle via the didDeselect path.
        try deselectNatively(controller, ids[4])
        try controller.handleUserSelectionEvent(
            indexPaths: [indexPath(controller, ids[4])],
            kind: .deselect,
            event: shiftClickEvent()
        )

        #expect(controller.selectedIdentities() == Set(ids[2 ... 4]))
    }

    @Test func commandClickThenShiftClickUnionsTheBaseWithTheNewRange() throws {
        let controller = makeController(itemCount: 13)
        let ids = controller.applyGate.displayedOrderedIDs
        try setAnchor(controller, to: ids[2]) // click item 2

        // ⌘-click item 10: native ⌘-click adds it alongside the existing selection.
        try selectNatively(controller, ids[10])
        try controller.handleUserSelectionEvent(
            indexPaths: [indexPath(controller, ids[10])],
            kind: .select,
            event: commandClickEvent()
        )
        #expect(controller.selectionAnchorID == ids[10])
        #expect(controller.anchorBaseSelection == [ids[2], ids[10]])

        // ⇧-click item 12: range extends from the new anchor (item 10) to item 12,
        // unioned with the base recorded at the ⌘-click.
        try selectNatively(controller, ids[12])
        try controller.handleUserSelectionEvent(
            indexPaths: [indexPath(controller, ids[12])],
            kind: .select,
            event: shiftClickEvent()
        )

        #expect(controller.selectedIdentities() == Set([ids[2]] + ids[10 ... 12]))
    }

    @Test func shiftClickWithNoAnchorBehavesAsAPlainClick() throws {
        let controller = makeController(itemCount: 6)
        let ids = controller.applyGate.displayedOrderedIDs

        try selectNatively(controller, ids[3])
        try controller.handleUserSelectionEvent(
            indexPaths: [indexPath(controller, ids[3])],
            kind: .select,
            event: shiftClickEvent()
        )

        #expect(controller.selectedIdentities() == [ids[3]])
        #expect(controller.selectionAnchorID == ids[3])
        #expect(controller.anchorBaseSelection == [ids[3]])
    }

    @Test func structuralApplyPrunesAnAnchorWhoseAssetWasRemoved() throws {
        let controller = makeController(itemCount: 4)
        let ids = controller.applyGate.displayedOrderedIDs
        try setAnchor(controller, to: ids[1])

        controller.restoreSelection([], in: [ids[0], ids[2], ids[3]])

        #expect(controller.selectionAnchorID == nil)
        #expect(controller.anchorBaseSelection.isEmpty)
    }

    @Test func structuralApplyKeepsAnchorWhenItsAssetSurvives() throws {
        let controller = makeController(itemCount: 4)
        let ids = controller.applyGate.displayedOrderedIDs
        try setAnchor(controller, to: ids[1])

        controller.restoreSelection([ids[1]], in: [ids[0], ids[1], ids[2], ids[3]])

        #expect(controller.selectionAnchorID == ids[1])
    }

    @Test func descriptorChangeClearsTheAnchor() throws {
        let controller = makeController(itemCount: 4)
        let ids = controller.applyGate.displayedOrderedIDs
        try setAnchor(controller, to: ids[1])

        controller.clearSelection(reason: "descriptorChange")

        #expect(controller.selectionAnchorID == nil)
        #expect(controller.anchorBaseSelection.isEmpty)
    }

    /// Regression test for a PR #51 review finding: a descriptor-changing structural
    /// apply (new sidebar scope/sort/filter) must clear the anchor unconditionally, even
    /// when the previously anchored asset happens to still be present in the new scope's
    /// results. `restoreSelection`'s anchor prune alone is not enough for this case
    /// because it only clears an anchor whose *asset* left the new ordered IDs.
    @Test func descriptorChangingApplyClearsAnchorEvenWhenTheAnchoredAssetSurvives() throws {
        let controller = makeController(itemCount: 4)
        let ids = controller.applyGate.displayedOrderedIDs
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
    _ = controller.applyGate.receive(grid)
    _ = controller.applyGate.complete(applied: grid)

    return controller
}

@MainActor
private func indexPath(_ controller: MediaAssetCollectionViewController, _ id: MediaAssetID) throws -> IndexPath {
    try #require(controller.dataSource.indexPath(for: id))
}

/// Sets the anchor the way a real plain click would: select the item, then run it
/// through the handler with a modifier-free click event.
@MainActor
private func setAnchor(_ controller: MediaAssetCollectionViewController, to id: MediaAssetID) throws {
    try selectNatively(controller, id)
    try controller.handleUserSelectionEvent(
        indexPaths: [indexPath(controller, id)],
        kind: .select,
        event: clickEvent()
    )
}

/// Mimics what AppKit's native selection model already did before the delegate fires:
/// the real `handleUserSelectionEvent` runs only after `selectionIndexPaths` reflects
/// the native (uncorrected) result.
@MainActor
private func selectNatively(_ controller: MediaAssetCollectionViewController, _ id: MediaAssetID) throws {
    try controller.collectionView.selectItems(at: [indexPath(controller, id)], scrollPosition: [])
}

@MainActor
private func deselectNatively(_ controller: MediaAssetCollectionViewController, _ id: MediaAssetID) throws {
    try controller.collectionView.deselectItems(at: [indexPath(controller, id)])
}

private func clickEvent() -> NSEvent? {
    syntheticMouseEvent(modifierFlags: [])
}

private func shiftClickEvent() -> NSEvent? {
    syntheticMouseEvent(modifierFlags: [.shift])
}

private func commandClickEvent() -> NSEvent? {
    syntheticMouseEvent(modifierFlags: [.command])
}

private func syntheticMouseEvent(modifierFlags: NSEvent.ModifierFlags) -> NSEvent? {
    NSEvent.mouseEvent(
        with: .leftMouseUp,
        location: .zero,
        modifierFlags: modifierFlags,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
    )
}

@MainActor
private func makeAssetID(path: String) -> MediaAssetID {
    MediaAssetID(
        libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
        relativePath: MediaRelativePath(rawValue: path)
    )
}
