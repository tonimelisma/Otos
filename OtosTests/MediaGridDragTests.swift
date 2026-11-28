import AppKit
import Foundation
@testable import OtosKit
import Testing

/// Drag-out rules (ADR 0028, APP-038): what a drag carries, what it writes, and how a
/// mouse-down decides between selecting now and waiting for a possible drag.
struct MediaGridDragTests {
    // Validates: APP-038
    @Test func dragFromSelectedTileCarriesWholeSelectionInDisplayOrder() {
        let ids = makeIDs(count: 5)
        let selection: Set<MediaAssetID> = [ids[4], ids[1], ids[2]]

        let dragged = MediaGridDragPolicy.draggedIDs(hit: ids[2], selection: selection, orderedIDs: ids)

        #expect(dragged == [ids[1], ids[2], ids[4]])
    }

    // Validates: APP-038
    @Test func dragFromUnselectedTileCarriesOnlyThatTile() {
        let ids = makeIDs(count: 3)

        let dragged = MediaGridDragPolicy.draggedIDs(hit: ids[0], selection: [ids[2]], orderedIDs: ids)

        #expect(dragged == [ids[0]])
    }

    // Validates: APP-038
    @Test func plainClickOnSelectedTileWaitsForMouseUp() {
        #expect(MediaGridDragPolicy.decision(hasHit: true, hitIsSelected: true, isPlainClick: true, clickCount: 1)
            == .deferUntilMouseUp)
        #expect(MediaGridDragPolicy.decision(hasHit: true, hitIsSelected: false, isPlainClick: true, clickCount: 1)
            == .select)
        #expect(MediaGridDragPolicy.decision(hasHit: true, hitIsSelected: true, isPlainClick: false, clickCount: 1)
            == .select)
        #expect(MediaGridDragPolicy.decision(hasHit: false, hitIsSelected: false, isPlainClick: true, clickCount: 1)
            == .select)
        #expect(MediaGridDragPolicy.decision(hasHit: true, hitIsSelected: true, isPlainClick: true, clickCount: 2)
            == .doubleClick)
        #expect(MediaGridDragPolicy.decision(hasHit: true, hitIsSelected: false, isPlainClick: true, clickCount: 2)
            == .doubleClick)
    }

    // Validates: APP-038
    @Test func sourceCopiesOutsideAndRefusesInside() {
        #expect(MediaGridDragSource.operationMask(for: .outsideApplication) == .copy)
        #expect(MediaGridDragSource.operationMask(for: .withinApplication) == [])
    }
}

private func makeIDs(count: Int) -> [MediaAssetID] {
    (0 ..< count).map { index in
        MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
            relativePath: MediaRelativePath(rawValue: "asset-\(index).jpg")
        )
    }
}
