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
        #expect(result.grid.collapsed(shownBy: id("DSC1.JPG")) == pair)
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
        #expect(ids.allSatisfy { result.grid.expanded(shownBy: $0) == pair })
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
        let ids = [id("DSC1.ARW"), id("DSC1.JPG")]
        let collapsed = collapse(ids, [pair]).grid
        let shown = TileStackPresentation.of(pair.key, in: collapsed)
        #expect(shown.badgeLabel == "RAW+JPG" && !shown.onBand)
        let expanded = collapse(ids, [pair], expanded: [pair.id]).grid
        let raw = TileStackPresentation.of(id("DSC1.ARW"), in: expanded)
        let jpeg = TileStackPresentation.of(id("DSC1.JPG"), in: expanded)
        #expect(raw.badgeLabel == "RAW" && raw.onBand && !raw.isKey)
        #expect(jpeg.badgeLabel == "JPG" && jpeg.onBand && jpeg.isKey)
    }

    // MARK: Bursts

    private func frame(
        _ path: String, _ kind: MediaKind = .image, burst: String? = "B1", at capture: Double?,
        liked: Bool = false, chosenAt: Int64? = nil
    ) -> PhotoStackCandidate {
        var still = candidate(path, kind)
        still.burstIdentifier = burst
        still.captureLocal = capture
        still.isLiked = liked
        still.burstKeyChosenAtUnixMs = chosenAt
        return still
    }

    private func collapse(
        _ ids: [MediaAssetID], _ stacks: [PhotoStack], expanded: Set<PhotoStackID> = []
    ) -> PhotoStackCollapse.Result {
        PhotoStackCollapse.collapse(
            ids: ids, dayBuckets: [], coordinates: [], stacks: CatalogStacks(stacks), expanded: expanded
        )
    }

    private func burst(in stacks: [PhotoStack]) throws -> PhotoStack {
        try #require(stacks.first { $0.id.kind == .burst })
    }

    /// Stills sharing a burst identifier are one burst, its frames in capture order, its key
    /// the first frame; one carrier alone, or carriers of different bursts, make none.
    @Test func stillsSharingABurstIdentifierAreOneBurst() throws {
        let found = try burst(in: stacks([
            frame("IMG_3.HEIC", at: 3), frame("IMG_1.HEIC", at: 1), frame("IMG_2.HEIC", at: 2),
            candidate("IMG_9.HEIC", .image),
        ]))
        #expect(found.photos == [id("IMG_1.HEIC"), id("IMG_2.HEIC"), id("IMG_3.HEIC")])
        #expect(found.key == id("IMG_1.HEIC"))
        #expect(found.label == "3")
        #expect(stacks([frame("IMG_1.HEIC", at: 1)]).isEmpty)
        #expect(stacks([frame("IMG_1.HEIC", burst: "B1", at: 1), frame("IMG_2.HEIC", burst: "B2", at: 2)]).isEmpty)
    }

    /// The default key is the first Liked frame; the user's latest choice wins over it.
    @Test func aBurstsKeyIsItsChosenThenItsFirstLikedFrame() throws {
        let liked = try burst(in: stacks([
            frame("IMG_1.HEIC", at: 1), frame("IMG_2.HEIC", at: 2, liked: true), frame("IMG_3.HEIC", at: 3, liked: true),
        ]))
        #expect(liked.key == id("IMG_2.HEIC"))
        let chosen = try burst(in: stacks([
            frame("IMG_1.HEIC", at: 1, chosenAt: 5), frame("IMG_2.HEIC", at: 2, liked: true),
            frame("IMG_3.HEIC", at: 3, chosenAt: 9),
        ]))
        #expect(chosen.key == id("IMG_3.HEIC"))
    }

    /// A pair whose file carries the identifier is one frame, shown as the pair's key, and
    /// both its files are the burst's.
    @Test func aPairIsOneFrameOfABurst() throws {
        let found = stacks([
            frame("IMG_1.DNG", .raw, burst: nil, at: 1), frame("IMG_1.JPG", at: 1), frame("IMG_2.JPG", at: 2),
        ])
        let pair = try #require(found.first { $0.id.kind == .pair })
        let burst = try burst(in: found)
        #expect(burst.photos == [pair.key, id("IMG_2.JPG")])
        #expect(Set(burst.members) == [id("IMG_1.DNG"), id("IMG_1.JPG"), id("IMG_2.JPG")])
        #expect(burst.isRaw(id("IMG_1.DNG")))
    }

    /// A collapsed burst is its key frame's one tile; Move to Trash on it reaches every file
    /// of every frame; a file it hides goes to that tile, through its pair.
    @Test func aCollapsedBurstIsOneTileReachingEveryFile() throws {
        let found = stacks([
            frame("IMG_1.DNG", .raw, burst: nil, at: 1), frame("IMG_1.JPG", at: 1), frame("IMG_2.JPG", at: 2),
            candidate("IMG_9.JPG", .image),
        ])
        let burst = try burst(in: found)
        let ids = [id("IMG_1.DNG"), id("IMG_1.JPG"), id("IMG_2.JPG"), id("IMG_9.JPG")]
        let result = collapse(ids, found)
        #expect(result.ids == [id("IMG_1.JPG"), id("IMG_9.JPG")])
        #expect(result.grid.collapsed(shownBy: id("IMG_1.JPG")) == burst)
        #expect(Set(result.grid.files(reachedThrough: id("IMG_1.JPG"))) == Set(burst.members))
        #expect(result.grid.shownForHiddenMember[id("IMG_1.DNG")] == id("IMG_1.JPG"))
        #expect(result.grid.shownForHiddenMember[id("IMG_2.JPG")] == id("IMG_1.JPG"))
        #expect(TileStackPresentation.of(id("IMG_1.JPG"), in: result.grid).badgeLabel == "2")
    }

    /// An expanded burst shows every frame on its band, a pair frame still collapsed with its
    /// own badge; expanding that pair too shows both its files, and each is its own photo.
    @Test func anExpandedBurstShowsItsFramesAndTheirPairs() throws {
        let found = stacks([
            frame("IMG_1.DNG", .raw, burst: nil, at: 1), frame("IMG_1.JPG", at: 1), frame("IMG_2.JPG", at: 2),
        ])
        let pair = try #require(found.first { $0.id.kind == .pair })
        let burst = try burst(in: found)
        let ids = [id("IMG_1.DNG"), id("IMG_1.JPG"), id("IMG_2.JPG")]

        let framesShown = collapse(ids, found, expanded: [burst.id])
        #expect(framesShown.ids == [id("IMG_1.JPG"), id("IMG_2.JPG")])
        let pairFrame = TileStackPresentation.of(id("IMG_1.JPG"), in: framesShown.grid)
        #expect(pairFrame.badgeLabel == "RAW+JPG" && pairFrame.onBand)
        #expect(framesShown.grid.collapsed(shownBy: id("IMG_1.JPG")) == pair)
        #expect(framesShown.grid.expanded(shownBy: id("IMG_2.JPG")) == burst)
        #expect(framesShown.grid.files(reachedThrough: id("IMG_2.JPG")) == [id("IMG_2.JPG")])

        let filesShown = collapse(ids, found, expanded: [burst.id, pair.id])
        #expect(filesShown.ids == ids)
        #expect(filesShown.grid.expanded(shownBy: id("IMG_1.DNG")) == pair)
        #expect(filesShown.grid.pair(shownBy: id("IMG_1.DNG")) == pair)
    }

    // MARK: Camera bursts

    private func shot(
        _ path: String, _ kind: MediaKind = .image, frame: Int, at capture: Double, camera: String = "SONY|ILCE-6700|"
    ) -> PhotoStackCandidate {
        var still = candidate(path, kind)
        still.continuousFrame = frame
        still.camera = camera
        still.captureLocal = capture
        return still
    }

    private func cameraBursts(_ candidates: [PhotoStackCandidate]) -> [PhotoStack] {
        stacks(candidates).filter { $0.id.kind == .burst }
            .sorted { $0.photos[0].relativePath.rawValue < $1.photos[0].relativePath.rawValue }
    }

    /// A camera's continuous frames are one burst while their numbers rise in capture order;
    /// a sequence starting again at 1 is another burst, and a frame deleted from the middle
    /// splits nothing.
    @Test func aCamerasContinuousFramesAreOneBurstWhileTheirNumbersRise() {
        let found = cameraBursts([
            shot("A1.JPG", frame: 1, at: 1), shot("A2.JPG", frame: 2, at: 1.1), shot("A4.JPG", frame: 4, at: 1.3),
            shot("B1.JPG", frame: 1, at: 9), shot("B2.JPG", frame: 2, at: 9.1),
            shot("C1.JPG", frame: 1, at: 20),
        ])
        #expect(found.map(\.photos) == [
            [id("A1.JPG"), id("A2.JPG"), id("A4.JPG")],
            [id("B1.JPG"), id("B2.JPG")],
        ])
        #expect(found[0].key == id("A1.JPG"))
    }

    /// Two cameras' frames never make one burst, and a RAW+JPEG pair is one frame.
    @Test func cameraBurstsKeepToOneCameraAndAPairIsOneFrame() throws {
        let found = cameraBursts([
            shot("X1.ARW", .raw, frame: 1, at: 1), shot("X1.JPG", frame: 1, at: 1),
            shot("X2.ARW", .raw, frame: 2, at: 1.1), shot("X2.JPG", frame: 2, at: 1.1),
            shot("Y2.JPG", frame: 2, at: 1.05, camera: "NIKON|Z 8|1"),
        ])
        let burst = try #require(found.first)
        #expect(found.count == 1)
        #expect(burst.photos == [id("X1.JPG"), id("X2.JPG")])
        #expect(Set(burst.members) == [id("X1.ARW"), id("X1.JPG"), id("X2.ARW"), id("X2.JPG")])
    }
}
