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

    // Validates: APP-010, APP-011
    @Test func plainClickSelectsOnlyTheClickedItemAndSetsAnchorAndBase() {
        let sel = GridSelection.empty.plainClick(itemC)

        #expect(sel.selection == [itemC])
        #expect(sel.anchor == itemC)
        #expect(sel.base == [itemC])
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

    // Validates: APP-010, APP-011
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

    // MARK: - commandShiftClick

    @Test func commandShiftClickExtendsTheRangeKeepingExistingIslands() {
        // Row 14: {B,E} (anchor E, base {B,E}), ⌘⇧-click H → {B,E,F,G,H}.
        let sel = GridSelection(selection: [itemB, itemE], anchor: itemE, base: [itemB, itemE])
            .commandShiftClick(itemH, orderedIDs: ordered)

        #expect(sel.selection == Set([itemB, itemE, itemF, itemG, itemH]))
        #expect(sel.anchor == itemE)
        #expect(sel.base == [itemB, itemE])
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

    // Validates: APP-011
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

    // MARK: - orderedSelection

    @Test func orderedSelectionFollowsDisplayOrderAndFiltersUnselected() {
        let idA = id("/Pictures", "a.jpg")
        let idB = id("/Pictures", "b.jpg")
        let idC = id("/Pictures", "c.jpg")
        let ordered = GridSelection.orderedSelection([idA, idC], in: [idC, idB, idA])
        #expect(ordered == [idC, idA])
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

    // MARK: - clipboard

    // Validates: APP-012
    /// One item per file, in order, each carrying only `public.file-url`: no string a
    /// receiver could paste instead of the file (ADR 0012).
    @Test func writePutsOneFileURLItemPerFileInOrder() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let urls = [id("/Pictures", "a.jpg"), id("/Pictures", "Nested/b.mov")].map(\.fileURL)

        let claim = MediaGridClipboard.claim(pasteboard)
        let count = MediaGridClipboard.write(files: urls, to: pasteboard, claimed: claim)

        #expect(count == 2)
        let read = (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        #expect(read.map(\.path) == ["/Pictures/a.jpg", "/Pictures/Nested/b.mov"])
        let types = pasteboard.pasteboardItems?.map(\.types) ?? []
        #expect(types.count == 2)
        #expect(types.allSatisfy { $0.contains(.fileURL) && !$0.contains(.string) })
        #expect(pasteboard.string(forType: .string) == nil)
    }

    // Validates: APP-012
    /// A Copy writes only while the pasteboard is still its claim's: whatever wrote it
    /// since — another app, or a newer Copy — is left alone.
    @Test func aWriteAfterSomeoneElseWroteThePasteboardLeavesItAlone() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let claim = MediaGridClipboard.claim(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("copied later", forType: .string)

        let count = MediaGridClipboard.write(files: [id("/Pictures", "a.jpg").fileURL], to: pasteboard, claimed: claim)

        #expect(count == 0)
        #expect(pasteboard.string(forType: .string) == "copied later")
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
