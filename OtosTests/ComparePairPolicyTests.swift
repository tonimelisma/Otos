import Foundation
@testable import OtosKit
import Testing

struct ComparePairPolicyTests {
    @Test func entryUsesFirstTwoSelectedAsLeftRight() {
        let ids = makeIDs(5)
        var selection = GridSelection.empty.plainClick(ids[1])
        selection = selection.commandClick(ids[3])
        let pair = ComparePairPolicy.entry(selection: selection, orderedIDs: ids)
        #expect(pair.left == ids[1])
        #expect(pair.right == ids[3])
        #expect(pair.members == [ids[1], ids[3]])
    }

    @Test func entryWithOneSelectedAddsNextNeighborAsRight() {
        let ids = makeIDs(4)
        let selection = GridSelection.empty.plainClick(ids[1])
        let pair = ComparePairPolicy.entry(selection: selection, orderedIDs: ids)
        #expect(pair.left == ids[1])
        #expect(pair.right == ids[2])
    }

    @Test func entryWithEmptySelectionTakesFirstTwo() {
        let ids = makeIDs(3)
        let pair = ComparePairPolicy.entry(selection: .empty, orderedIDs: ids)
        #expect(pair.left == ids[0])
        #expect(pair.right == ids[1])
    }

    @Test func clickReplacesNamedPane() {
        let ids = makeIDs(5)
        var pair = ComparePair(left: ids[0], right: ids[1])
        pair = ComparePairPolicy.click(
            ids[3],
            replacing: .right,
            pair: pair,
            orderedIDs: ids
        )
        #expect(pair.left == ids[0])
        #expect(pair.right == ids[3])
        pair = ComparePairPolicy.click(
            ids[4],
            replacing: .left,
            pair: pair,
            orderedIDs: ids
        )
        #expect(pair.left == ids[4])
        #expect(pair.right == ids[3])
    }

    @Test func clickOnOtherSlotSwapsInsteadOfDuplicating() {
        let ids = makeIDs(4)
        let pair = ComparePair(left: ids[0], right: ids[1])
        let swapped = ComparePairPolicy.click(
            ids[0],
            replacing: .right,
            pair: pair,
            orderedIDs: ids
        )
        #expect(swapped.left == ids[1])
        #expect(swapped.right == ids[0])
    }

    @Test func slideRightAdvancesWindow() {
        let ids = makeIDs(5)
        let pair = ComparePair(left: ids[0], right: ids[1])
        let next = ComparePairPolicy.slide(1, pair: pair, orderedIDs: ids)
        #expect(next.left == ids[1])
        #expect(next.right == ids[2])
    }

    @Test func slideLeftRetreatsWindow() {
        let ids = makeIDs(5)
        let pair = ComparePair(left: ids[2], right: ids[3])
        let prev = ComparePairPolicy.slide(-1, pair: pair, orderedIDs: ids)
        #expect(prev.left == ids[1])
        #expect(prev.right == ids[2])
    }

    @Test func slideAtEndsIsNoOp() {
        let ids = makeIDs(3)
        let atStart = ComparePair(left: ids[0], right: ids[1])
        #expect(ComparePairPolicy.slide(-1, pair: atStart, orderedIDs: ids) == atStart)
        let atEnd = ComparePair(left: ids[1], right: ids[2])
        #expect(ComparePairPolicy.slide(1, pair: atEnd, orderedIDs: ids) == atEnd)
    }

    @Test func pruneRefillsOnlyRemovedSlot() throws {
        let ids = makeIDs(5)
        let pair = ComparePair(left: ids[1], right: ids[2])
        let survivors = [ids[0], ids[2], ids[3], ids[4]]
        let pruned = ComparePairPolicy.prune(
            pair: pair,
            previousOrderedIDs: ids,
            survivingOrderedIDs: survivors
        )
        #expect(pruned.right == ids[2])
        let refilledLeft = try #require(pruned.left)
        #expect(refilledLeft != ids[2])
        #expect(survivors.contains(refilledLeft))
    }
}

private func makeIDs(_ count: Int) -> [MediaAssetID] {
    (0 ..< count).map { index in
        MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
            relativePath: MediaRelativePath(rawValue: "c-\(index).jpg")
        )
    }
}
