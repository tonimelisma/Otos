import Foundation
@testable import OtosKit
import Testing

struct BrowserModePolicyTests {
    @Test func loupeEntryPrefersExplicitID() {
        let ids = makeIDs(4)
        let selection = GridSelection.empty.plainClick(ids[2])
        let focus = BrowserModePolicy.loupeEntryFocus(
            preferredID: ids[1],
            selection: selection,
            orderedIDs: ids
        )
        #expect(focus == ids[1])
    }

    @Test func loupeEntryFallsBackToAnchorThenFirstSelectedThenFirst() {
        let ids = makeIDs(4)
        #expect(
            BrowserModePolicy.loupeEntryFocus(
                preferredID: nil,
                selection: GridSelection.empty.plainClick(ids[2]),
                orderedIDs: ids
            ) == ids[2]
        )
        #expect(
            BrowserModePolicy.loupeEntryFocus(
                preferredID: nil,
                selection: .empty,
                orderedIDs: ids
            ) == ids[0]
        )
        #expect(
            BrowserModePolicy.loupeEntryFocus(
                preferredID: nil,
                selection: .empty,
                orderedIDs: []
            ) == nil
        )
    }

    @Test func neighborStepsAndClamps() {
        let ids = makeIDs(3)
        #expect(BrowserModePolicy.neighbor(of: ids[1], in: ids, delta: 1) == ids[2])
        #expect(BrowserModePolicy.neighbor(of: ids[2], in: ids, delta: 1) == ids[2])
        #expect(BrowserModePolicy.neighbor(of: ids[0], in: ids, delta: -1) == ids[0])
        #expect(BrowserModePolicy.neighbor(of: nil, in: ids, delta: 1) == ids[0])
    }

    @Test func pruneFocusKeepsSurvivorOrNearestSlot() {
        let previous = makeIDs(5)
        let removedMiddle = [previous[0], previous[1], previous[3], previous[4]]
        #expect(
            BrowserModePolicy.pruneFocus(
                previous: previous[2],
                previousOrderedIDs: previous,
                survivingOrderedIDs: removedMiddle
            ) == previous[3]
        )
        #expect(
            BrowserModePolicy.pruneFocus(
                previous: previous[2],
                previousOrderedIDs: previous,
                survivingOrderedIDs: previous
            ) == previous[2]
        )
    }
}

private func makeIDs(_ count: Int) -> [MediaAssetID] {
    (0 ..< count).map { index in
        MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
            relativePath: MediaRelativePath(rawValue: "a-\(index).jpg")
        )
    }
}
