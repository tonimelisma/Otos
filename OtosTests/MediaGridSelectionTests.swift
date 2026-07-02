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
