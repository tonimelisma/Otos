import AppKit
import Foundation
@testable import Otos
import Testing

/// Pure-helper tests for the remnants of `MediaGridSelection` (`orderedSelection`,
/// `selectionDelta`) and `MediaGridClipboard`. The selection-model operations
/// (`plainClick`/`commandClick`/`shiftClick`/`commandShiftClick`/`pruned`/`clearedBySpace`)
/// moved to `GridSelection` and are covered by `GridSelectionTests` (spec 0046).
@MainActor
struct MediaGridSelectionTests {
    // MARK: - Identity → URL

    @Test func fileURLIsBuiltFromRootAndRelativePath() {
        #expect(id("/Pictures", "a.jpg").fileURL.path == "/Pictures/a.jpg")
        #expect(id("/Pictures", "Nested/b.mov").fileURL.path == "/Pictures/Nested/b.mov")
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
