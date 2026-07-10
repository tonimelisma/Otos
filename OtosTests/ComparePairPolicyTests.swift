import Foundation
@testable import Otos
import Testing

struct ComparePairPolicyTests {
    @Test func entryUsesFirstTwoSelected() {
        let ids = makeIDs(5)
        var selection = GridSelection.empty.plainClick(ids[1])
        selection = selection.commandClick(ids[3])
        let pair = ComparePairPolicy.entry(selection: selection, orderedIDs: ids)
        #expect(pair.members == [ids[1], ids[3]])
        #expect(pair.older == ids[1])
    }

    @Test func entryWithOneSelectedAddsNextNeighbor() {
        let ids = makeIDs(4)
        let selection = GridSelection.empty.plainClick(ids[1])
        let pair = ComparePairPolicy.entry(selection: selection, orderedIDs: ids)
        #expect(pair.members == [ids[1], ids[2]])
    }

    @Test func entryWithEmptySelectionTakesFirstTwo() {
        let ids = makeIDs(3)
        let pair = ComparePairPolicy.entry(selection: .empty, orderedIDs: ids)
        #expect(pair.members == [ids[0], ids[1]])
    }

    @Test func clickReplacesOlderMember() {
        let ids = makeIDs(5)
        var pair = ComparePair(members: [ids[0], ids[1]], older: ids[0])
        pair = ComparePairPolicy.click(ids[3], pair: pair, orderedIDs: ids)
        #expect(Set(pair.members) == [ids[1], ids[3]])
        #expect(pair.older == ids[1])
        pair = ComparePairPolicy.click(ids[4], pair: pair, orderedIDs: ids)
        #expect(Set(pair.members) == [ids[3], ids[4]])
        #expect(pair.older == ids[3])
    }

    @Test func slideRightAdvancesWindow() {
        let ids = makeIDs(5)
        let pair = ComparePair(members: [ids[0], ids[1]], older: ids[0])
        let next = ComparePairPolicy.slide(1, pair: pair, orderedIDs: ids)
        #expect(next.members == [ids[1], ids[2]])
        #expect(next.older == ids[1])
    }

    @Test func slideLeftRetreatsWindow() {
        let ids = makeIDs(5)
        let pair = ComparePair(members: [ids[2], ids[3]], older: ids[2])
        let prev = ComparePairPolicy.slide(-1, pair: pair, orderedIDs: ids)
        #expect(prev.members == [ids[1], ids[2]])
        #expect(prev.older == ids[2])
    }

    @Test func pruneFillsHoleWithNeighbor() {
        let ids = makeIDs(5)
        let pair = ComparePair(members: [ids[1], ids[2]], older: ids[1])
        let survivors = [ids[0], ids[2], ids[3], ids[4]]
        let pruned = ComparePairPolicy.prune(pair: pair, survivingOrderedIDs: survivors)
        #expect(pruned.members.contains(ids[2]))
        #expect(pruned.members.count == 2)
    }

    @Test func panesFollowDisplayOrder() {
        let ids = makeIDs(4)
        let pair = ComparePair(members: [ids[3], ids[1]], older: ids[3])
        let panes = pair.panes(in: ids)
        #expect(panes.left == ids[1])
        #expect(panes.right == ids[3])
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
