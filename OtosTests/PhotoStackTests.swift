import Foundation
@testable import OtosKit
import Testing

/// The stack rule and the collapse pass (ADR 0052): pure values, no Store.
struct PhotoStackTests {
    private let root = LibraryRootPath(rawValue: "/Library")

    private func id(_ path: String) -> MediaAssetID {
        MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: path))
    }

    /// A candidate as the Store reads it from a case-insensitive volume's row.
    private func candidate(_ path: String, _ kind: MediaKind, chosenAt: Int64? = nil) -> PhotoStackCandidate {
        let relativePath = MediaRelativePath(rawValue: path)
        return PhotoStackCandidate(
            relativePath: relativePath,
            kind: kind,
            nameKey: FilesystemNamespaceSemantics.nameKey(relativePath: relativePath, capabilities: .caseInsensitive),
            sortKey: MediaSortKey.make(libraryRootPath: root, relativePath: relativePath),
            keyChosenAtUnixMs: chosenAt
        )
    }

    private func stacks(_ candidates: [PhotoStackCandidate]) -> [PhotoStack] {
        PhotoStackRule.stacks(candidates: candidates, libraryRootPath: root)
    }

    /// Cutting a stored name key gives the key of the cut path, so the rule reads stems from
    /// the keys the catalog stores: accents in either Unicode form, case on either kind of
    /// volume, a leading dot and a folder with a dot in it.
    @Test(arguments: [
        "a/Ca\u{301}fe\u{301}.JPG", "a/Café.ARW", "ΣΑΣ.JPG", "b.c/IMG_1", ".hidden", "x/.hidden", "IMG_1.tar.gz", "IMG_1.\u{301}JPG",
    ])
    func aStoredKeysStemIsTheStemsKey(path: String) {
        for capabilities in [VolumeNamespaceCapabilities.caseInsensitive, .caseSensitive] {
            let relativePath = MediaRelativePath(rawValue: path)
            let folder = relativePath.folder
            let stemPath = MediaRelativePath(rawValue: folder.isEmpty ? relativePath.stem : folder + "/" + relativePath.stem)
            let cut = FilesystemNamespaceSemantics.stemKey(
                of: FilesystemNamespaceSemantics.nameKey(relativePath: relativePath, capabilities: capabilities)
            )
            #expect(cut == FilesystemNamespaceSemantics.nameKey(relativePath: stemPath, capabilities: capabilities))
        }
    }

    @Test func aRawAndItsJPEGArePairedAndTheJPEGIsTheKey() throws {
        let pair = try #require(stacks([candidate("a/DSC1.ARW", .raw), candidate("a/dsc1.jpg", .image)]).first)
        #expect(pair.id.kind == .pair)
        #expect(Set(pair.members) == [id("a/DSC1.ARW"), id("a/dsc1.jpg")])
        #expect(pair.key == id("a/dsc1.jpg"))
        #expect(pair.rawMembers == [id("a/DSC1.ARW")])
        #expect(pair.label == "RAW+JPG")
        #expect(pair.label(of: id("a/dsc1.jpg")) == "JPG")
    }

    @Test func anyOtherCountPairsNothing() {
        #expect(stacks([candidate("DSC1.ARW", .raw)]).isEmpty)
        #expect(stacks([candidate("DSC1.JPG", .image), candidate("DSC1.HEIC", .image)]).isEmpty)
        let threeStills = [candidate("DSC1.ARW", .raw), candidate("DSC1.JPG", .image), candidate("DSC1.HEIC", .image)]
        #expect(stacks(threeStills).isEmpty)
        #expect(stacks([candidate("a/DSC1.ARW", .raw), candidate("b/DSC1.JPG", .image)]).isEmpty)
        // A Live Photo's movie never makes or breaks a pair.
        let withMovie = [candidate("DSC1.ARW", .raw), candidate("DSC1.JPG", .image), candidate("DSC1.MOV", .video)]
        #expect(stacks(withMovie).count == 1)
    }

    @Test func theLatestChoiceIsTheKey() throws {
        let pair = try #require(stacks([
            candidate("DSC1.ARW", .raw, chosenAt: 20),
            candidate("DSC1.JPG", .image, chosenAt: 10),
        ]).first)
        #expect(pair.key == id("DSC1.ARW"))
    }

    @Test func aCollapsedPairShowsItsKeyInItsKeysPlace() throws {
        let pair = try #require(stacks([candidate("DSC1.ARW", .raw), candidate("DSC1.JPG", .image)]).first)
        let all = CatalogStacks([pair])
        let ids = [id("DSC0.JPG"), id("DSC1.ARW"), id("DSC1.JPG"), id("DSC2.JPG")]
        let result = PhotoStackCollapse.collapse(
            ids: ids, dayBuckets: [nil, nil, nil, nil], coordinates: [], stacks: all, expanded: []
        )
        #expect(result.ids == [id("DSC0.JPG"), id("DSC1.JPG"), id("DSC2.JPG")])
        #expect(result.dayBuckets.count == 3)
        #expect(result.grid.collapsed[id("DSC1.JPG")] == pair)
        #expect(result.grid.files(reachedThrough: id("DSC1.JPG")) == pair.members)
        #expect(result.grid.shownForHiddenMember[id("DSC1.ARW")] == id("DSC1.JPG"))
    }

    @Test func anExpandedPairShowsEveryMemberAsItsOwnPhoto() throws {
        let pair = try #require(stacks([candidate("DSC1.ARW", .raw), candidate("DSC1.JPG", .image)]).first)
        let ids = [id("DSC1.ARW"), id("DSC1.JPG")]
        let result = PhotoStackCollapse.collapse(
            ids: ids, dayBuckets: [], coordinates: [], stacks: CatalogStacks([pair]), expanded: [pair.id]
        )
        #expect(result.ids == ids)
        #expect(result.grid.expanded.count == 2)
        #expect(result.grid.files(reachedThrough: id("DSC1.ARW")) == [id("DSC1.ARW")])
    }

    /// A filter that leaves one member shows it as an ordinary photo, and a filter that hides
    /// the key shows the other member.
    @Test func aStackWithOneMemberPresentIsNotOneHere() throws {
        let pair = try #require(stacks([candidate("DSC1.ARW", .raw), candidate("DSC1.JPG", .image)]).first)
        let result = PhotoStackCollapse.collapse(
            ids: [id("DSC1.ARW")], dayBuckets: [], coordinates: [], stacks: CatalogStacks([pair]), expanded: []
        )
        #expect(result.ids == [id("DSC1.ARW")])
        #expect(result.grid == .empty)
    }

    @Test func theTileShowsTheStacksBadge() throws {
        let pair = try #require(stacks([candidate("DSC1.ARW", .raw), candidate("DSC1.JPG", .image)]).first)
        let collapsed = CatalogGridStacks(collapsed: [pair.key: pair], expanded: [:])
        #expect(TileStackPresentation.of(pair.key, in: collapsed) == .collapsed(label: "RAW+JPG"))
        let members = Dictionary(uniqueKeysWithValues: pair.members.map { ($0, pair) })
        let expanded = CatalogGridStacks(collapsed: [:], expanded: members)
        #expect(TileStackPresentation.of(id("DSC1.ARW"), in: expanded) == .expanded(label: "RAW", isKey: false))
        #expect(TileStackPresentation.of(id("DSC1.JPG"), in: expanded) == .expanded(label: "JPG", isKey: true))
    }
}
