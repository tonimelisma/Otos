import AppKit
import Foundation
@testable import OtosKit
import Testing

/// Pure-model tests for `GridSelection` — selection/anchor/base transitions plus the
/// `orderedSelection` / `selectionDelta` helpers — and `MediaGridClipboard`. Items
/// `A B C D E F G H` are in display order throughout.
@MainActor
struct GridSelectionTests {
    // MARK: - plainClick

    @Test func plainClickSelectsOnlyTheClickedItemAndSetsAnchorAndBase() {
        let sel = GridSelection.empty.plainClick(itemC)

        #expect(sel.selection == [itemC])
        #expect(sel.anchor == itemC)
        #expect(sel.base == [itemC])
    }

    @Test func plainClickReplacesAPriorSelection() {
        let sel = GridSelection(selection: [itemA, itemB, itemC], anchor: itemB, base: [itemA, itemB, itemC])
            .plainClick(itemD)

        #expect(sel.selection == [itemD])
        #expect(sel.anchor == itemD)
        #expect(sel.base == [itemD])
    }

    // MARK: - commandClick

    @Test func commandClickAddsAnUnselectedItemAndSetsAnchorToIt() {
        let sel = GridSelection(selection: [itemB], anchor: itemB, base: [itemB])
            .commandClick(itemE)

        #expect(sel.selection == [itemB, itemE])
        #expect(sel.anchor == itemE)
        #expect(sel.base == [itemB, itemE])
    }

    @Test func commandClickTogglesAnSelectedItemOutAndKeepsItAsThePivot() {
        // B3 setup: select B, ⌘-click B → empty; anchor stays B, base empty.
        let sel = GridSelection(selection: [itemB], anchor: itemB, base: [itemB])
            .commandClick(itemB)

        #expect(sel.selection.isEmpty)
        #expect(sel.anchor == itemB)
        #expect(sel.base.isEmpty)
    }

    @Test func commandClickInsideARangeRemovesOnlyThatItem() {
        // Row 7: {C,D,E,F} (anchor C), ⌘-click D → {C,E,F}, anchor D.
        let sel = GridSelection(selection: [itemC, itemD, itemE, itemF], anchor: itemC, base: [itemC])
            .commandClick(itemD)

        #expect(sel.selection == [itemC, itemE, itemF])
        #expect(sel.anchor == itemD)
        #expect(sel.base == [itemC, itemE, itemF])
    }

    // MARK: - shiftClick

    @Test func shiftClickExtendsAForwardRangeFromTheAnchor() {
        // Row 2: click C, ⇧-click F → C D E F.
        let sel = GridSelection(selection: [itemC], anchor: itemC, base: [itemC])
            .shiftClick(itemF, orderedIDs: ordered)

        #expect(sel.selection == Set([itemC, itemD, itemE, itemF]))
        #expect(sel.anchor == itemC)
        #expect(sel.base == [itemC])
    }

    @Test func shiftClickExtendsABackwardRangeFromTheAnchor() {
        // Row 4: click F, ⇧-click C → C D E F.
        let sel = GridSelection(selection: [itemF], anchor: itemF, base: [itemF])
            .shiftClick(itemC, orderedIDs: ordered)

        #expect(sel.selection == Set([itemC, itemD, itemE, itemF]))
        #expect(sel.anchor == itemF)
        #expect(sel.base == [itemF])
    }

    @Test func shiftClickContractingFromTheSameAnchorKeepsTheClickedTile() {
        // B1 / Row 3: from {C,D,E,F} (anchor C, base {C}), ⇧-click D → {C,D}.
        let sel = GridSelection(selection: [itemC, itemD, itemE, itemF], anchor: itemC, base: [itemC])
            .shiftClick(itemD, orderedIDs: ordered)

        #expect(sel.selection == Set([itemC, itemD]))
        #expect(sel.anchor == itemC)
        #expect(sel.base == [itemC])
    }

    @Test func shiftClickUnionsTheBaseOutsideTheRangeKeepingIslands() {
        // Row 6: {B,E} (anchor E, base {B,E}), ⇧-click G → {B,E,F,G}.
        let sel = GridSelection(selection: [itemB, itemE], anchor: itemE, base: [itemB, itemE])
            .shiftClick(itemG, orderedIDs: ordered)

        #expect(sel.selection == Set([itemB, itemE, itemF, itemG]))
        #expect(sel.anchor == itemE)
        #expect(sel.base == [itemB, itemE])
    }

    @Test func shiftClickWithNoAnchorFallsBackToAPlainClick() {
        // Row 13: empty selection, ⇧-click → {clicked}.
        let sel = GridSelection.empty
            .shiftClick(itemD, orderedIDs: ordered)

        #expect(sel.selection == [itemD])
        #expect(sel.anchor == itemD)
        #expect(sel.base == [itemD])
    }

    @Test func shiftClickWithAnAnchorMissingFromOrderFallsBackToPlainClick() {
        let goneAnchor = id("/Pictures", "gone.jpg")
        let sel = GridSelection(selection: [itemC], anchor: goneAnchor, base: [itemC])
            .shiftClick(itemD, orderedIDs: ordered)

        #expect(sel.selection == [itemD])
        #expect(sel.anchor == itemD)
        #expect(sel.base == [itemD])
    }

    @Test func shiftClickWithClickedMissingFromOrderFallsBackToPlainClick() {
        let goneClicked = id("/Pictures", "gone.jpg")
        let sel = GridSelection(selection: [itemC], anchor: itemC, base: [itemC])
            .shiftClick(goneClicked, orderedIDs: ordered)

        #expect(sel.selection == [goneClicked])
        #expect(sel.anchor == goneClicked)
        #expect(sel.base == [goneClicked])
    }

    @Test func shiftClickOnAnEmptyOrderFallsBackToPlainClick() {
        let sel = GridSelection(selection: [itemC], anchor: itemC, base: [itemC])
            .shiftClick(itemD, orderedIDs: [])

        #expect(sel.selection == [itemD])
        #expect(sel.anchor == itemD)
        #expect(sel.base == [itemD])
    }

    @Test func shiftClickAnchorEqualToClickedIsTheSingleItem() {
        let sel = GridSelection(selection: [itemC], anchor: itemC, base: [itemC])
            .shiftClick(itemC, orderedIDs: ordered)

        #expect(sel.selection == [itemC])
    }

    // MARK: - commandShiftClick

    @Test func commandShiftClickExtendsTheRangeKeepingExistingIslands() {
        // Row 14: {B,E} (anchor E, base {B,E}), ⌘⇧-click H → {B,E,F,G,H}.
        let sel = GridSelection(selection: [itemB, itemE], anchor: itemE, base: [itemB, itemE])
            .commandShiftClick(itemH, orderedIDs: ordered)

        #expect(sel.selection == Set([itemB, itemE, itemF, itemG, itemH]))
        #expect(sel.anchor == itemE)
        #expect(sel.base == [itemB, itemE])
    }

    @Test func commandShiftClickWithNoAnchorFallsBackToPlainClick() {
        let sel = GridSelection.empty
            .commandShiftClick(itemD, orderedIDs: ordered)

        #expect(sel.selection == [itemD])
        #expect(sel.anchor == itemD)
        #expect(sel.base == [itemD])
    }

    @Test func commandShiftClickWithMissingAnchorFallsBackToPlainClick() {
        let goneAnchor = id("/Pictures", "gone.jpg")
        let sel = GridSelection(selection: [itemC], anchor: goneAnchor, base: [itemC])
            .commandShiftClick(itemD, orderedIDs: ordered)

        #expect(sel.selection == [itemD])
        #expect(sel.anchor == itemD)
    }

    // MARK: - clearedBySpace

    @Test func clearedBySpaceEmptiesSelectionAnchorAndBase() {
        let sel = GridSelection(selection: [itemA, itemB, itemC], anchor: itemB, base: [itemA, itemB, itemC])
            .clearedBySpace()

        #expect(sel == .empty)
    }

    // MARK: - pruned

    @Test func prunedKeepsSurvivingSelectionAndBaseWhenAnchorSurvives() {
        // Row 15: {C,D} (anchor C, base {C,D}), apply removes D → {C}, base {C}.
        let sel = GridSelection(selection: [itemC, itemD], anchor: itemC, base: [itemC, itemD])
            .pruned(to: [itemA, itemB, itemC, itemE, itemF, itemG, itemH])

        #expect(sel.selection == [itemC])
        #expect(sel.anchor == itemC)
        #expect(sel.base == [itemC])
    }

    @Test func prunedClearsAnchorAndBaseWhenTheAnchorIsRemoved() {
        // Row 16: {C,D} (anchor C), apply removes C → selection {D}, anchor nil, base [].
        let sel = GridSelection(selection: [itemC, itemD], anchor: itemC, base: [itemC, itemD])
            .pruned(to: [itemA, itemB, itemD, itemE, itemF, itemG, itemH])

        #expect(sel.selection == [itemD])
        #expect(sel.anchor == nil)
        #expect(sel.base.isEmpty)
    }

    @Test func prunedOfEmptySelectionStaysEmpty() {
        let sel = GridSelection.empty.pruned(to: ordered)

        #expect(sel == .empty)
    }

    // MARK: - reconcilingSelection

    @Test func reconcilingSelectionAdoptsLiveSelectionAsBaseWhenItDiffers() {
        // After ⌘A the live AppKit selection is everything; the model still held a
        // stale pre-keyboard base. Reconcile adopts the live set as the new base so a
        // later ⇧-click unions against "everything" instead of contracting to the
        // stale base ∪ range.
        let before = GridSelection(selection: [itemC], anchor: itemC, base: [itemC])
        let live = Set(ordered)
        let after = before.reconcilingSelection(live)

        #expect(after.selection == live)
        #expect(after.anchor == itemC)
        #expect(after.base == live)
    }

    @Test func reconcilingSelectionMovesTheAnchorForASingleItemKeyboardMove() {
        // An unmodified arrow key lands here as a live selection of exactly one item.
        // The anchor is also the "active item" loupe entry focuses, so it must follow
        // the arrow — otherwise Return opens loupe on the previously clicked tile.
        let before = GridSelection(selection: [itemC], anchor: itemC, base: [itemC])
        let after = before.reconcilingSelection([itemD])

        #expect(after.selection == [itemD])
        #expect(after.anchor == itemD)
        #expect(after.base == [itemD])
    }

    @Test func reconcilingSelectionIsNoOpWhenLiveMatchesModel() {
        let before = GridSelection(selection: [itemC, itemD], anchor: itemC, base: [itemC])
        let after = before.reconcilingSelection([itemC, itemD])

        #expect(after.selection == before.selection)
        #expect(after.anchor == before.anchor)
        #expect(after.base == before.base)
    }

    // MARK: - orderedSelection

    @Test func orderedSelectionFollowsDisplayOrderAndFiltersUnselected() {
        let idA = id("/Pictures", "a.jpg")
        let idB = id("/Pictures", "b.jpg")
        let idC = id("/Pictures", "c.jpg")
        let ordered = GridSelection.orderedSelection([idA, idC], in: [idC, idB, idA])
        #expect(ordered == [idC, idA])
    }

    @Test func orderedSelectionOfEmptySelectionIsEmpty() {
        #expect(GridSelection.orderedSelection([], in: [id("/Pictures", "a.jpg")]).isEmpty)
    }

    // MARK: - selectionDelta

    @Test func selectionDeltaExcludesSurvivorsFromBothSides() {
        let idA = id("/Pictures", "a.jpg")
        let idB = id("/Pictures", "b.jpg")
        let idC = id("/Pictures", "c.jpg")
        let delta = GridSelection.selectionDelta(current: [idA, idB], target: [idB, idC])
        #expect(delta.toDeselect == [idA])
        #expect(delta.toSelect == [idC])
    }

    @Test func selectionDeltaOfIdenticalSetsIsEmpty() {
        let idA = id("/Pictures", "a.jpg")
        let idB = id("/Pictures", "b.jpg")
        let delta = GridSelection.selectionDelta(current: [idA, idB], target: [idA, idB])
        #expect(delta.toDeselect.isEmpty)
        #expect(delta.toSelect.isEmpty)
    }

    @Test func selectionDeltaFromEmptyToNonEmptySelectsEverything() {
        let idA = id("/Pictures", "a.jpg")
        let delta = GridSelection.selectionDelta(current: [], target: [idA])
        #expect(delta.toDeselect.isEmpty)
        #expect(delta.toSelect == [idA])
    }

    @Test func selectionDeltaToEmptyDeselectsEverything() {
        let idA = id("/Pictures", "a.jpg")
        let delta = GridSelection.selectionDelta(current: [idA], target: [])
        #expect(delta.toDeselect == [idA])
        #expect(delta.toSelect.isEmpty)
    }

    // MARK: - clipboard

    @Test func writePutsFileURLsInOrderAndReturnsCount() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("test-\(UUID().uuidString)"))
        let idA = id("/Pictures", "a.jpg")
        let idB = id("/Pictures", "Nested/b.mov")

        let count = MediaGridClipboard.write([idA, idB], to: pasteboard)

        #expect(count == 2)
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        #expect(urls.map(\.path) == ["/Pictures/a.jpg", "/Pictures/Nested/b.mov"])
    }

    @Test func writeClearsPriorContentsAndEmptySelectionWritesNothing() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("test-\(UUID().uuidString)"))
        _ = MediaGridClipboard.write([id("/Pictures", "a.jpg")], to: pasteboard)

        let count = MediaGridClipboard.write([], to: pasteboard)

        #expect(count == 0)
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        #expect(urls == nil || urls?.isEmpty == true)
    }
}

// MARK: - Fixtures

@MainActor
private let ordered: [MediaAssetID] = ["itemA", "itemB", "itemC", "itemD",
                                       "itemE", "itemF", "itemG", "itemH"]
    .map { id("/Pictures", "\($0).jpg") }
@MainActor
private let itemA = ordered[0]
@MainActor
private let itemB = ordered[1]
@MainActor
private let itemC = ordered[2]
@MainActor
private let itemD = ordered[3]
@MainActor
private let itemE = ordered[4]
@MainActor
private let itemF = ordered[5]
@MainActor
private let itemG = ordered[6]
@MainActor
private let itemH = ordered[7]

@MainActor
private func id(_ root: String, _ relative: String) -> MediaAssetID {
    MediaAssetID(
        libraryRootPath: LibraryRootPath(rawValue: root),
        relativePath: MediaRelativePath(rawValue: relative)
    )
}
