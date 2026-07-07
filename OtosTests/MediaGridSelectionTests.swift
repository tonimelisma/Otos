import AppKit
import Foundation
@testable import Otos
import Testing

@MainActor
struct MediaGridSelectionTests {
    // MARK: - Identity → URL

    @Test func fileURLIsBuiltFromRootAndRelativePath() {
        #expect(id("/Pictures", "a.jpg").fileURL.path == "/Pictures/a.jpg")
        #expect(id("/Pictures", "Nested/b.mov").fileURL.path == "/Pictures/Nested/b.mov")
    }

    // MARK: - pruned

    @Test func prunedKeepsOnlySurvivingIdentities() {
        let idA = id("/Pictures", "a.jpg")
        let idB = id("/Pictures", "b.jpg")
        let gone = id("/Pictures", "gone.jpg")
        let survivors = MediaGridSelection.pruned([idA, idB, gone], to: [idB, idA])
        #expect(survivors == [idA, idB])
    }

    @Test func prunedOfEmptySelectionIsEmpty() {
        #expect(MediaGridSelection.pruned([], to: [id("/Pictures", "a.jpg")]).isEmpty)
    }

    // MARK: - orderedSelection

    @Test func orderedSelectionFollowsDisplayOrderAndFiltersUnselected() {
        let idA = id("/Pictures", "a.jpg")
        let idB = id("/Pictures", "b.jpg")
        let idC = id("/Pictures", "c.jpg")
        // Selection given in arbitrary set order must emit in display order (idC, idA).
        let ordered = MediaGridSelection.orderedSelection([idA, idC], in: [idC, idB, idA])
        #expect(ordered == [idC, idA])
    }

    @Test func orderedSelectionOfEmptySelectionIsEmpty() {
        #expect(MediaGridSelection.orderedSelection([], in: [id("/Pictures", "a.jpg")]).isEmpty)
    }

    // MARK: - shiftRangeSelection

    @Test func shiftRangeSelectionCoversForwardRange() {
        let ordered = (0 ..< 8).map { id("/Pictures", "\($0).jpg") }
        let target = MediaGridSelection.shiftRangeSelection(
            anchor: ordered[2],
            clicked: ordered[5],
            base: [ordered[2]],
            orderedIDs: ordered
        )
        #expect(target == Set(ordered[2 ... 5]))
    }

    @Test func shiftRangeSelectionCoversBackwardRange() {
        let ordered = (0 ..< 8).map { id("/Pictures", "\($0).jpg") }
        let target = MediaGridSelection.shiftRangeSelection(
            anchor: ordered[5],
            clicked: ordered[2],
            base: [ordered[5]],
            orderedIDs: ordered
        )
        #expect(target == Set(ordered[2 ... 5]))
    }

    @Test func shiftRangeSelectionOfAnchorEqualToClickedIsSingleItem() {
        let ordered = (0 ..< 4).map { id("/Pictures", "\($0).jpg") }
        let target = MediaGridSelection.shiftRangeSelection(
            anchor: ordered[1],
            clicked: ordered[1],
            base: [ordered[1]],
            orderedIDs: ordered
        )
        #expect(target == [ordered[1]])
    }

    @Test func shiftRangeSelectionUnionsBaseOutsideTheRange() {
        let ordered = (0 ..< 8).map { id("/Pictures", "\($0).jpg") }
        // Base carries an earlier ⌘-clicked item that the new range does not cover.
        let target = MediaGridSelection.shiftRangeSelection(
            anchor: ordered[5],
            clicked: ordered[7],
            base: [ordered[2], ordered[5]],
            orderedIDs: ordered
        )
        #expect(target == Set([ordered[2]] + ordered[5 ... 7]))
    }

    @Test func shiftRangeSelectionContractsOnASecondShiftClickFromTheSameAnchor() {
        let ordered = (0 ..< 8).map { id("/Pictures", "\($0).jpg") }
        let firstRange = MediaGridSelection.shiftRangeSelection(
            anchor: ordered[2],
            clicked: ordered[6],
            base: [ordered[2]],
            orderedIDs: ordered
        )
        #expect(firstRange == Set(ordered[2 ... 6]))

        // Same anchor/base as before, not the grown selection — the range contracts
        // instead of accumulating every intermediate shift-click.
        let contracted = MediaGridSelection.shiftRangeSelection(
            anchor: ordered[2],
            clicked: ordered[4],
            base: [ordered[2]],
            orderedIDs: ordered
        )
        #expect(contracted == Set(ordered[2 ... 4]))
    }

    @Test func shiftRangeSelectionFallsBackToClickedWhenAnchorIsMissing() {
        let ordered = (0 ..< 4).map { id("/Pictures", "\($0).jpg") }
        let goneAnchor = id("/Pictures", "gone.jpg")
        let target = MediaGridSelection.shiftRangeSelection(
            anchor: goneAnchor,
            clicked: ordered[2],
            base: [goneAnchor],
            orderedIDs: ordered
        )
        #expect(target == [ordered[2]])
    }

    @Test func shiftRangeSelectionFallsBackToClickedWhenClickedIsMissing() {
        let ordered = (0 ..< 4).map { id("/Pictures", "\($0).jpg") }
        let goneClicked = id("/Pictures", "gone.jpg")
        let target = MediaGridSelection.shiftRangeSelection(
            anchor: ordered[0],
            clicked: goneClicked,
            base: [ordered[0]],
            orderedIDs: ordered
        )
        #expect(target == [goneClicked])
    }

    @Test func shiftRangeSelectionOfEmptyOrderedListFallsBackToClicked() {
        let clicked = id("/Pictures", "a.jpg")
        let target = MediaGridSelection.shiftRangeSelection(
            anchor: id("/Pictures", "b.jpg"),
            clicked: clicked,
            base: [],
            orderedIDs: []
        )
        #expect(target == [clicked])
    }

    // MARK: - selectionDelta

    @Test func selectionDeltaExcludesSurvivorsFromBothSides() {
        let idA = id("/Pictures", "a.jpg")
        let idB = id("/Pictures", "b.jpg")
        let idC = id("/Pictures", "c.jpg")
        // B survives in both current and target; only A (dropped) and C (added) move.
        let delta = MediaGridSelection.selectionDelta(current: [idA, idB], target: [idB, idC])
        #expect(delta.toDeselect == [idA])
        #expect(delta.toSelect == [idC])
    }

    @Test func selectionDeltaOfIdenticalSetsIsEmpty() {
        let idA = id("/Pictures", "a.jpg")
        let idB = id("/Pictures", "b.jpg")
        let delta = MediaGridSelection.selectionDelta(current: [idA, idB], target: [idA, idB])
        #expect(delta.toDeselect.isEmpty)
        #expect(delta.toSelect.isEmpty)
    }

    @Test func selectionDeltaFromEmptyToNonEmptySelectsEverything() {
        let idA = id("/Pictures", "a.jpg")
        let delta = MediaGridSelection.selectionDelta(current: [], target: [idA])
        #expect(delta.toDeselect.isEmpty)
        #expect(delta.toSelect == [idA])
    }

    @Test func selectionDeltaToEmptyDeselectsEverything() {
        let idA = id("/Pictures", "a.jpg")
        let delta = MediaGridSelection.selectionDelta(current: [idA], target: [])
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

@MainActor
private func id(_ root: String, _ relative: String) -> MediaAssetID {
    MediaAssetID(
        libraryRootPath: LibraryRootPath(rawValue: root),
        relativePath: MediaRelativePath(rawValue: relative)
    )
}
