import Foundation
@testable import OtosKit
import Testing

/// ADR 0042: the keeper rule, what a pick or a folder rule keeps, and the Store's read.
@Suite(.testScope)
struct DuplicatesTests {
    private static let photos = LibraryRootPath(rawValue: "/Users/me/Photos")
    private static let backup = LibraryRootPath(rawValue: "/Volumes/Backup/Photos")
    private static let family = LibraryRootPath(rawValue: "/RemoteStaging/family")
    private static let digest = ContentDigest(data: Data(repeating: 1, count: ContentDigest.byteCount))!

    private static func copy(
        _ path: String,
        in root: LibraryRootPath = photos,
        born: TimeInterval = 100,
        captured: TimeInterval? = 1_700_000_000,
        kind: MediaKind? = .image,
        choice: MediaChoice = .notRated,
        edited: Bool = false,
        companions: Bool = false
    ) -> DuplicateCopyFacts {
        DuplicateCopyFacts(
            copy: DuplicateCopy(
                id: MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: path)),
                libraryDisplayName: root == photos ? "Photos" : root == family ? "Family" : "Backup",
                libraryKind: root == family ? .immichAccount : .library,
                kind: kind,
                captureLocalTime: captured.map(CaptureLocalTime.init(seconds:)),
                byteSize: 1000,
                createdAt: Date(timeIntervalSince1970: born),
                pixelWidth: 4032,
                pixelHeight: 3024,
                mediaChoice: choice,
                isEdited: edited,
                hasCompanions: companions
            ),
            digest: digest
        )
    }

    /// The keeper rule's tests compare across libraries, so a group may span them.
    private static func onlyGroup(_ copies: [DuplicateCopyFacts], kept: Set<DuplicateKeptPair> = []) throws -> DuplicateGroup {
        let groups = DuplicateGroupPolicy.groups(copies: copies, keptPairs: kept, reach: .acrossLibraries)
        try #require(groups.count == 1)
        return groups[0]
    }

    @Test func aCopySuffixLosesToTheOriginalName() throws {
        let group = try Self.onlyGroup([Self.copy("a/IMG_1 copy.jpg", born: 50), Self.copy("b/IMG_1.jpg", born: 90)])
        #expect(group.defaultKeep == [Self.copy("b/IMG_1.jpg").copy.id])
        #expect(group.copies.first?.name == "IMG_1.jpg")
    }

    @Test func theEarliestBirthWinsBetweenPlainNames() throws {
        let group = try Self.onlyGroup([Self.copy("b/IMG_1.jpg", born: 90), Self.copy("a/IMG_1.jpg", born: 50)])
        #expect(group.defaultKeep == [Self.copy("a/IMG_1.jpg").copy.id])
    }

    @Test func theOneCopyWithAuthoredWorkIsKeptWhateverItsName() throws {
        let group = try Self.onlyGroup([
            Self.copy("IMG_1.jpg", born: 10),
            Self.copy("IMG_1 copy.jpg", born: 90, companions: true),
        ])
        #expect(group.defaultKeep == [Self.copy("IMG_1 copy.jpg").copy.id])
    }

    @Test func workOnTwoCopiesIsCarriedOntoTheCopyKept() throws {
        let liked = Self.copy("a.jpg", choice: .liked).copy.id
        let edited = Self.copy("b.jpg", edited: true).copy.id
        let group = try Self.onlyGroup([Self.copy("a.jpg", choice: .liked), Self.copy("b.jpg", edited: true)])
        #expect(group.defaultKeep == [edited])
        #expect(DuplicatesSession().resolution(of: group)?.carries == [DuplicateCarry(from: liked, to: edited, work: .choice)])
    }

    @Test func onlyWorkThatCannotBeCombinedWaits() throws {
        let twoEdits = try Self.onlyGroup([Self.copy("a.jpg", edited: true), Self.copy("b.jpg", edited: true)])
        #expect(twoEdits.defaultKeep == nil)
        let twoSidecars = try Self.onlyGroup([Self.copy("a.jpg", companions: true), Self.copy("b.jpg", companions: true)])
        #expect(twoSidecars.defaultKeep == nil)
        let twoChoices = try Self.onlyGroup([Self.copy("a.jpg", choice: .liked), Self.copy("b.jpg", choice: .disliked)])
        #expect(twoChoices.defaultKeep == nil)
        let oneChoice = try Self.onlyGroup([Self.copy("a.jpg", choice: .liked), Self.copy("b.jpg", choice: .liked)])
        #expect(oneChoice.defaultKeep == [Self.copy("a.jpg").copy.id])
    }

    @Test func eachLibraryKeepsItsOwnCopy() throws {
        let pair = try Self.onlyGroup([Self.copy("IMG_1.jpg"), Self.copy("IMG_1.jpg", in: Self.backup)])
        #expect(pair.defaultKeep == [Self.copy("IMG_1.jpg").copy.id, Self.copy("IMG_1.jpg", in: Self.backup).copy.id])

        // Each library keeps its copy, so nothing moves; a second copy inside one library
        // still goes.
        #expect(DuplicatesSession().resolution(of: pair)?.moving == [])
        let extra = try Self.onlyGroup([
            Self.copy("IMG_1.jpg"),
            Self.copy("IMG_1 copy.jpg"),
            Self.copy("IMG_1.jpg", in: Self.backup),
        ])
        #expect(DuplicatesSession().resolution(of: extra)?.moving == [Self.copy("IMG_1 copy.jpg").copy.id])
    }

    /// A click keeps that copy and nothing else, across libraries too; it outranks the
    /// folder's rule.
    @Test func aClickKeepsThatCopyAndOutranksTheFolderRule() throws {
        let group = try Self.onlyGroup([
            Self.copy("IMG_1.jpg"),
            Self.copy("IMG_1 copy.jpg"),
            Self.copy("IMG_1.jpg", in: Self.backup),
        ])
        let suffixed = Self.copy("IMG_1 copy.jpg").copy.id
        var session = DuplicatesSession()
        session.picks[group.id] = suffixed
        let picked = try #require(session.resolution(of: group))
        #expect(picked.keep == [suffixed])
        #expect(Set(picked.moving) == [Self.copy("IMG_1.jpg").copy.id, Self.copy("IMG_1.jpg", in: Self.backup).copy.id])
        #expect(picked.reason == .picked)

        session.rules[DuplicateFolderSet(group)] = .largest
        #expect(session.resolution(of: group)?.keep == [suffixed])
    }

    @Test func keptCopiesAreSetAsideAndALaterCopyIsTheOnlyOneOffered() throws {
        let print = Self.copy("Print/IMG_1.jpg").copy.id
        let dated = Self.copy("2024/IMG_1.jpg").copy.id
        let kept: Set = [DuplicateKeptPair(print, dated)]

        let setAside = try Self.onlyGroup([Self.copy("Print/IMG_1.jpg"), Self.copy("2024/IMG_1.jpg")], kept: kept)
        #expect(setAside.isKept)

        let withNewcomer = try Self.onlyGroup(
            [Self.copy("Print/IMG_1.jpg"), Self.copy("2024/IMG_1.jpg"), Self.copy("Downloads/IMG_1.jpg")],
            kept: kept
        )
        #expect(!withNewcomer.isKept)
        #expect(withNewcomer.defaultKeep == [print, dated])
    }

    /// ADR 0046 §8: an Immich account's copy is never moved to the Trash. Whatever a click,
    /// a rule or the default chooses, it stays, and only the library's copies go; two
    /// copies in one account move nothing, and the header says why.
    @Test func anAccountsCopyStaysWhateverIsChosen() throws {
        let library = Self.copy("2026/08/IMG_1.jpg").copy.id
        let account = Self.copy("a1/IMG_1.jpg", in: Self.family).copy.id
        let across = try Self.onlyGroup([Self.copy("2026/08/IMG_1.jpg"), Self.copy("a1/IMG_1.jpg", in: Self.family)])
        var session = DuplicatesSession()
        session.picks[across.id] = library
        let picked = try #require(session.resolution(of: across))
        #expect(picked.keep == [library, account])
        #expect(picked.moving.isEmpty)
        #expect(picked.stays == [account])
        let header = DuplicateGroupPresentation.map(across, session: session)
        #expect(header.reason == "Otos never removes copies in “Family”")
        #expect(header.tiles.map(\.fate) == [.keep, .keep])
        #expect(header.tiles.first { $0.id == account }?.canMoveToTrash == false)
        #expect(header.tiles.first { $0.id == account }?.canKeep == true)
        #expect(header.tiles.first { $0.id == account }?.help.hasPrefix("Family ▸ IMG_1.jpg") == true)
        // Choosing the account's copy moves the library's.
        session.picks[across.id] = account
        #expect(session.resolution(of: across)?.moving == [library])

        let inAccount = try Self.onlyGroup([
            Self.copy("a1/IMG_1.jpg", in: Self.family), Self.copy("a2/IMG_1.jpg", in: Self.family, born: 200),
        ])
        #expect(DuplicatesSession().resolution(of: inAccount)?.moving == [])
        #expect(DuplicateGroupPresentation.map(inAccount, session: DuplicatesSession()).reason
            == "Otos never removes copies in “Family”")
        // An account's copies are one folder, and a folder no rule can empty offers none.
        #expect(DuplicateFolderSet(inAccount).folders.count == 1)
        let bucket = try #require(CatalogDuplicatesState(groups: [inAccount]).layout.buckets.first)
        #expect(DuplicateFolderBucketPresentation.map(bucket, session: DuplicatesSession(), withLibrary: false).rule == nil)
    }

    /// A library folder that mirrors an account is one folder header; keeping the library's
    /// side would move the account's copies, so it is not offered, and the row says why.
    @Test func aRuleRowNeverOffersToRemoveAnAccountsCopies() throws {
        let groups = try ["IMG_1.jpg", "IMG_2.jpg"].enumerated().map { index, name in
            try Self.onlyGroup([Self.copy("2026/08/\(name)"), Self.copy("a\(index)/\(name)", in: Self.family)])
        }
        let buckets = CatalogDuplicatesState(groups: groups).layout.buckets
        let pair = try #require(buckets.first)
        #expect(buckets.count == 1)
        #expect(pair.groups.count == 2)
        let row = DuplicateFolderBucketPresentation.map(pair, session: DuplicatesSession(), withLibrary: true)
        #expect(row.rule?.options.map(\.title) == ["Family", "Both"])
        #expect(row.detail == "2 photos in both · Otos never removes copies in “Family”")
    }

    @Test func copySuffixesAreFindersAndBrowsers() {
        #expect(DuplicateGroupPolicy.hasCopySuffix("IMG_1 copy.jpg"))
        #expect(DuplicateGroupPolicy.hasCopySuffix("IMG_1 copy 2.jpg"))
        #expect(DuplicateGroupPolicy.hasCopySuffix("IMG_1 (1).jpg"))
        #expect(DuplicateGroupPolicy.hasCopySuffix("20261031_183009_001.heif"))
        #expect(!DuplicateGroupPolicy.hasCopySuffix("DSC_0001.ARW"))
        #expect(!DuplicateGroupPolicy.hasCopySuffix("Beach 2.jpg"))
        #expect(!DuplicateGroupPolicy.hasCopySuffix("IMG_1.jpg"))
        // A whole relative path: only its last component is read, and a leading dot is no
        // extension.
        #expect(DuplicateGroupPolicy.hasCopySuffix("2024/Holiday/IMG_1 copy.jpg"))
        #expect(!DuplicateGroupPolicy.hasCopySuffix("2024 copy/IMG_1.jpg"))
        #expect(DuplicateGroupPolicy.hasCopySuffix(".hidden copy"))
    }

    @Test func theTallyCountsEveryActiveGroupAndWhatTheActMoves() throws {
        let preselected = try Self.onlyGroup([Self.copy("a/IMG_1.jpg"), Self.copy("b/IMG_1 copy.jpg")])
        let waiting = try DuplicateGroupPolicy.group(
            id: .identical(#require(ContentDigest(data: Data(repeating: 2, count: ContentDigest.byteCount))), library: nil),
            copies: [Self.copy("x.jpg", edited: true).copy, Self.copy("y.jpg", edited: true).copy],
            keptPairs: []
        )
        var session = DuplicatesSession()
        let state = CatalogDuplicatesState(groups: [preselected, waiting])
        let tally = session.tally(in: state)
        #expect(tally.itemsWithDuplicates == 2)
        #expect(tally.noun == .photos)
        #expect(tally.itemsToMove == [Self.copy("b/IMG_1 copy.jpg").copy.id])
        #expect(tally.bytesToMove == PartialByteCount(knownBytes: 1000, unknownCount: 0))
        #expect(tally.needingChoice == 1)

        // No rule decides between two edits; a click does, and the group joins the act.
        session.rules[DuplicateFolderSet(waiting)] = .oldest
        #expect(session.resolution(of: waiting) == nil)
        session.picks[waiting.id] = Self.copy("y.jpg").copy.id
        let decided = session.tally(in: state)
        #expect(decided.needingChoice == 0)
        // The group only a click decides is listed first.
        #expect(decided.itemsToMove == [Self.copy("x.jpg").copy.id, Self.copy("b/IMG_1 copy.jpg").copy.id])

        // A pick is forgotten once its copy has left the group.
        session.forgetPicks(absentFrom: CatalogDuplicatesState(groups: [preselected]))
        #expect(session.picks.isEmpty)
    }

    /// One rule decides every group in a folder, or in a pair of folders.
    @Test func aFolderRuleDecidesEveryGroupInThatFolder() throws {
        let one = try Self.onlyGroup([Self.copy("2026/10/a_001.jpg", born: 10), Self.copy("2026/10/a.jpg", born: 90)])
        var session = DuplicatesSession()
        let oneFolder = DuplicateFolderSet(one)
        #expect(oneFolder.folders.map(\.folder) == ["2026/10"])
        #expect(session.resolution(of: one)?.keep == [Self.copy("2026/10/a.jpg").copy.id])
        session.rules[oneFolder] = .oldest
        #expect(session.resolution(of: one)?.keep == [Self.copy("2026/10/a_001.jpg").copy.id])
        #expect(session.resolution(of: one)?.reason == .rule(.oldest))
        session.rules[oneFolder] = .originalName
        #expect(session.resolution(of: one)?.keep == [Self.copy("2026/10/a.jpg").copy.id])

        let mirrored = try Self.onlyGroup([Self.copy("2026/08/b.jpg", born: 10), Self.copy("Imports/b.jpg", born: 90)])
        let pair = DuplicateFolderSet(mirrored)
        let imports = try #require(pair.folders.first { $0.folder == "Imports" })
        session.rules[pair] = .folder(imports)
        #expect(session.resolution(of: mirrored)?.keep == [Self.copy("Imports/b.jpg").copy.id])

        let buckets = CatalogDuplicatesState(groups: [one, mirrored]).layout.buckets
        #expect(Set(buckets.map(\.id)) == [.folders(oneFolder), .folders(pair)])
    }

    /// The bar's L1 is what will happen; the count of items with duplicates is its L3, and
    /// is L1 only while nothing would move.
    @Test func theBarNamesTheActAndKeepsItsTitleWhenDisabled() {
        let none = DuplicatesBarPresentation.map(DuplicatesTally(
            itemsWithDuplicates: 6, noun: .videos, itemsToMove: [], bytesToMove: .zero, needingChoice: 6
        ))
        #expect(none.primaryLine == "6 videos with duplicates")
        #expect(none.secondaryLine == nil)
        #expect(none.middle == .choices("6 videos need your choice"))
        #expect(none.actionTitle == "Move Copies to Trash")
        #expect(!none.actionEnabled)

        let two = DuplicatesBarPresentation.map(DuplicatesTally(
            itemsWithDuplicates: 110, noun: .photosAndVideos,
            itemsToMove: [Self.copy("a.jpg").copy.id, Self.copy("b.mp4").copy.id],
            bytesToMove: PartialByteCount(knownBytes: 14_900_000_000, unknownCount: 0), needingChoice: 0
        ))
        #expect(two.primaryLine == "2 copies go to the Trash · 14.9 GB")
        #expect(two.secondaryLine == "110 photos and videos with duplicates")
        #expect(two.middle == .legend(DuplicatesBarPresentation.legend))
        #expect(two.actionTitle == "Move 2 Copies to Trash")
        #expect(two.actionEnabled)

        let moved = DuplicatesBarPresentation.map(
            DuplicatesTally(itemsWithDuplicates: 0, noun: .items, itemsToMove: [], bytesToMove: .zero, needingChoice: 0),
            receipt: DuplicatesReceipt(
                batch: MediaTrashBatchID(), movedCount: 2, bytes: PartialByteCount(knownBytes: 14_900_000_000, unknownCount: 0)
            ),
            canUndoMove: true
        )
        #expect(moved.primaryLine == "No duplicates")
        #expect(moved.secondaryLine == nil)
        let one = DuplicatesBarPresentation.map(DuplicatesTally(
            itemsWithDuplicates: 1, noun: .photos, itemsToMove: [Self.copy("a.jpg").copy.id],
            bytesToMove: PartialByteCount(knownBytes: 4_100_000, unknownCount: 0), needingChoice: 0
        ))
        #expect(one.primaryLine == "1 copy goes to the Trash · 4 MB")
        #expect(one.secondaryLine == "1 photo with duplicates")
        #expect(moved.middle == .receipt(
            line: "2 copies moved to the Trash · 14.9 GB",
            detail: "Empty the Trash in Finder to free the space",
            canUndo: true
        ))
    }

    @Test func theNounFollowsWhatTheGroupsHold() {
        #expect(DuplicateItemNoun.covering([.video, .video]) == .videos)
        #expect(DuplicateItemNoun.covering([.image, .raw]) == .photos)
        #expect(DuplicateItemNoun.covering([.image, .video]) == .photosAndVideos)
        #expect(DuplicateItemNoun.covering([.image, nil]) == .items)
        #expect(DuplicateItemNoun.covering([]) == .items)
    }

    /// A group is its date and why it keeps what it keeps, over its photos tagged Keep or
    /// Trash, each with its size; where each copy is goes in its tooltip.
    @Test func aGroupSaysWhyAndTagsEachPhotoKeepOrTrash() throws {
        let twins = try Self.onlyGroup([Self.copy("2026/08/a.mp4", born: 10, kind: .video), Self.copy("2026/08/b.mp4", born: 90, kind: .video)])
        var session = DuplicatesSession()
        let header = DuplicateGroupPresentation.map(twins, session: session)
        // The copies' local capture time, written as their own clock read it.
        #expect(header.title == CaptureLocalTime(seconds: 1_700_000_000).formatted(Date.FormatStyle(date: .long, time: .omitted)))
        #expect(header.reason == "2026/08 · Keeping the older file")
        #expect(header.tiles.map(\.fate) == [.keep, .trash])
        #expect(header.tiles.map(\.size) == ["1 KB", "1 KB"])
        #expect(header.tiles.first?.help.hasPrefix("Photos ▸ 2026/08/a.mp4") == true)
        // One folder: no folder under the photos; two folders: each photo names its own.
        #expect(header.tiles.map(\.folder) == [nil, nil])
        let mirrored = try Self.onlyGroup([Self.copy("2026/08/b.jpg"), Self.copy("Imports/b.jpg")])
        #expect(Set(DuplicateGroupPresentation.map(mirrored, session: session).tiles.compactMap(\.folder)) == ["2026/08", "Imports"])

        session.picks[twins.id] = Self.copy("2026/08/b.mp4").copy.id
        let picked = DuplicateGroupPresentation.map(twins, session: session)
        #expect(picked.reason == "2026/08 · You chose this one")
        #expect(picked.tiles.map(\.fate) == [.trash, .keep])

        let undated = try Self.onlyGroup([Self.copy("a.jpg", captured: nil), Self.copy("a copy.jpg", captured: nil)])
        #expect(DuplicateGroupPresentation.map(undated, session: session).title == "No Date")
    }

    /// A group whose copies hold work that cannot be combined tags nothing and asks for a
    /// click. A kept group says so.
    @Test func aGroupThatWaitsAsksForAClick() throws {
        let waiting = try Self.onlyGroup([Self.copy("a.jpg", edited: true), Self.copy("b.jpg", edited: true)])
        let header = DuplicateGroupPresentation.map(waiting, session: DuplicatesSession())
        #expect(header.reason == "Photos · The copies have different edits: click the one to keep")
        #expect(header.tiles.map(\.fate) == [.undecided, .undecided])

        let a = Self.copy("Print/IMG_1.jpg").copy.id
        let b = Self.copy("2024/IMG_1.jpg").copy.id
        let kept = try Self.onlyGroup([Self.copy("Print/IMG_1.jpg"), Self.copy("2024/IMG_1.jpg")], kept: [DuplicateKeptPair(a, b)])
        let keptHeader = DuplicateGroupPresentation.map(kept, session: DuplicatesSession())
        #expect(keptHeader.isKept)
        #expect(keptHeader.reason == "Kept both copies")
        #expect(keptHeader.tiles.isEmpty)
    }

    @Test func versionTilesCarryTheSizeThatTellsThemApart() {
        let ids = ["IMG_1.HEIC", "IMG_1_001.HEIC"].map {
            MediaAssetID(libraryRootPath: Self.photos, relativePath: MediaRelativePath(rawValue: $0))
        }
        func version(_ id: MediaAssetID, width: Int, bytes: Int64) -> DuplicateCopy {
            DuplicateCopy(
                id: id, libraryDisplayName: "Photos", libraryKind: .library, kind: .image, captureLocalTime: nil, byteSize: bytes,
                createdAt: nil, pixelWidth: width, pixelHeight: width * 3 / 4, mediaChoice: .notRated,
                isEdited: false, hasCompanions: false
            )
        }
        // 11,200,000 and 11,400,000 bytes both show as 11 MB: the rule ranks the bytes, so
        // the tiles show the sizes at one decimal.
        let alike = DuplicateGroupPolicy.group(
            id: .samePhoto(ids), copies: [version(ids[0], width: 4000, bytes: 11_200_000), version(ids[1], width: 4000, bytes: 11_400_000)],
            keptPairs: [], originals: Set(ids)
        )
        let alikeHeader = DuplicateGroupPresentation.map(alike, session: DuplicatesSession())
        #expect(alikeHeader.tiles.map(\.size) == ["11.4 MB", "11.2 MB"])
        #expect(alikeHeader.reason == "Photos · Keeping the largest file")

        let resized = DuplicateGroupPolicy.group(
            id: .samePhoto(ids), copies: [version(ids[0], width: 4000, bytes: 11_200_000), version(ids[1], width: 1000, bytes: 400_000)],
            keptPairs: [], originals: [ids[0]]
        )
        let resizedHeader = DuplicateGroupPresentation.map(resized, session: DuplicatesSession())
        #expect(resizedHeader.tiles.map(\.size) == ["11 MB", "400 KB"])
        #expect(resizedHeader.tiles.map(\.help) == [
            "Photos ▸ IMG_1.HEIC\n4000 × 3000 · 11 MB · Camera original",
            "Photos ▸ IMG_1_001.HEIC\n1000 × 750 · 400 KB",
        ])
    }

    @Test func sizesThatTieAtTheShownPrecisionGetTheDecimalsThatTellThemApart() {
        let bytes: [Int64] = [39_133_184, 39_100_416, 38_821_888, 38_805_504, 38_801_408, 38_793_216]
        let copies = bytes.enumerated().map { index, size in
            DuplicateCopy(
                id: MediaAssetID(libraryRootPath: Self.photos, relativePath: MediaRelativePath(rawValue: "f\(index).arw")),
                libraryDisplayName: "Photos", libraryKind: .library, kind: .raw, captureLocalTime: nil, byteSize: size, createdAt: nil,
                pixelWidth: 6192, pixelHeight: 4128, mediaChoice: .notRated, isEdited: false, hasCompanions: false
            )
        }
        let sizes = DuplicateTileFacts.distinguishingSizes(of: copies)
        #expect(copies.map { sizes[$0.id] } == ["39.13 MB", "39.10 MB", "38.82 MB", "38.81 MB", "38.80 MB", "38.79 MB"])

        let twins = Array(copies.prefix(2)).map {
            DuplicateCopy(
                id: $0.id, libraryDisplayName: "Photos", libraryKind: .library, kind: .raw, captureLocalTime: nil, byteSize: 39_133_184,
                createdAt: nil, pixelWidth: 6192, pixelHeight: 4128, mediaChoice: .notRated, isEdited: false,
                hasCompanions: false
            )
        }
        #expect(Set(DuplicateTileFacts.distinguishingSizes(of: twins).values) == ["39 MB"])
    }

    /// ← and → walk every copy across groups; ↑ and ↓ keep the place in the next group, or
    /// take its last copy when it is shorter.
    @Test func theArrowKeysWalkTheTilesInReadingOrder() {
        let ids = (0 ..< 5).map {
            MediaAssetID(libraryRootPath: Self.photos, relativePath: MediaRelativePath(rawValue: "\($0).jpg"))
        }
        let order = DuplicatesTileOrder(groups: [[ids[0], ids[1], ids[2]], [ids[3], ids[4]]])
        #expect(order.target(from: nil, .right) == ids[0])
        #expect(order.target(from: ids[2], .right) == ids[3])
        #expect(order.target(from: ids[3], .left) == ids[2])
        #expect(order.target(from: ids[0], .left) == nil)
        #expect(order.target(from: ids[2], .down) == ids[4])
        #expect(order.target(from: ids[4], .up) == ids[1])
        #expect(order.target(from: ids[4], .down) == nil)

        // An exact-copy group's names sit under one another: ↑ and ↓ move a line, and
        // from photos they land on the nearest line.
        let mixed = DuplicatesTileOrder(groups: [
            .init(copies: [ids[0], ids[1]], stacked: false),
            .init(copies: [ids[2], ids[3]], stacked: true),
            .init(copies: [ids[4]], stacked: true),
        ])
        #expect(mixed.target(from: ids[1], .down) == ids[2])
        #expect(mixed.target(from: ids[2], .down) == ids[3])
        #expect(mixed.target(from: ids[3], .down) == ids[4])
        #expect(mixed.target(from: ids[2], .up) == ids[1])
        #expect(mixed.target(from: ids[3], .right) == ids[4])
    }

    /// A folder's header offers what fits its folders: two folders, either one or the
    /// default; one folder, how to choose within it. It says how many, how much and why.
    @Test func aFolderRowOffersWhatFitsItsFolders() throws {
        let mirrored = try Self.onlyGroup([Self.copy("2026/08/b.jpg"), Self.copy("Imports/b.jpg")])
        let pair = try #require(CatalogDuplicatesState(groups: [mirrored]).layout.buckets.first)
        let row = DuplicateFolderBucketPresentation.map(pair, session: DuplicatesSession(), withLibrary: false)
        #expect(row.title == "2026/08 and Imports")
        #expect(row.detail == "1 photo in both · 1 KB in extra copies")
        #expect(row.summary == "Alike in every way, so keeping the first by name")
        #expect(row.rule?.prompt == "Keep the copies in")
        #expect(row.rule?.options.map(\.title) == ["2026/08", "Imports", "Otos decides"])
        #expect(row.rule?.selected == .automatic)

        let twice = try Self.onlyGroup([Self.copy("2026/10/a.jpg"), Self.copy("2026/10/a_001.jpg")])
        let older = try DuplicateGroupPolicy.group(
            id: .identical(#require(ContentDigest(data: Data(repeating: 3, count: ContentDigest.byteCount))), library: nil),
            copies: [Self.copy("2026/10/b.jpg", born: 10).copy, Self.copy("2026/10/c.jpg", born: 90).copy],
            keptPairs: []
        )
        let one = try #require(CatalogDuplicatesState(groups: [twice, older]).layout.buckets.first)
        var session = DuplicatesSession()
        let automatic = DuplicateFolderBucketPresentation.map(one, session: session, withLibrary: false)
        #expect(automatic.detail == "2 photos saved twice in this folder · 2 KB in extra copies")
        // The folder is audited as a whole: its groups' reasons, counted.
        #expect(Set(automatic.summary?.components(separatedBy: " · ") ?? []) == ["1 keeping the original name", "1 keeping the older file"])
        session.rules[DuplicateFolderSet(twice)] = .oldest
        let oneRow = DuplicateFolderBucketPresentation.map(one, session: session, withLibrary: false)
        #expect(oneRow.summary == "Keeping the oldest, as the folder rule says")
        #expect(oneRow.rule?.options.map(\.title) == ["Best copy", "Original name", "Oldest", "Largest"])
        #expect(oneRow.rule?.selected == .oldest)
        session.picks[twice.id] = Self.copy("2026/10/a_001.jpg").copy.id
        #expect(DuplicateFolderBucketPresentation.map(one, session: session, withLibrary: false).summary
            == "1 chosen by you · 1 keeping the oldest, as the folder rule says")
    }

    private static func samePhoto(_ paths: [String], bytes: [Int64], edited: Bool = false) -> DuplicateGroup {
        let ids = paths.map { MediaAssetID(libraryRootPath: photos, relativePath: MediaRelativePath(rawValue: $0)) }
        return DuplicateGroupPolicy.group(
            id: .samePhoto(ids),
            copies: zip(ids, bytes).map { id, size in
                DuplicateCopy(
                    id: id, libraryDisplayName: "Photos", libraryKind: .library, kind: .image,
                    captureLocalTime: CaptureLocalTime(seconds: 1_600_000_000), byteSize: size, createdAt: nil,
                    pixelWidth: size > 1_000_000 ? 4000 : 1000, pixelHeight: size > 1_000_000 ? 3000 : 750,
                    mediaChoice: .notRated, isEdited: edited, hasCompanions: false
                )
            },
            keptPairs: [], originals: [ids[0]]
        )
    }

    /// The list is three sections by the attention a group needs: what only a click
    /// decides, files of one photo, then exact copies under their folders, the folder with
    /// the most groups first and three or more folders last.
    @Test func theListPutsWhatNeedsAttentionFirst() throws {
        func identical(_ seed: UInt8, _ copies: [DuplicateCopyFacts]) throws -> DuplicateGroup {
            try DuplicateGroupPolicy.group(
                id: .identical(#require(ContentDigest(data: Data(repeating: seed, count: ContentDigest.byteCount))), library: nil),
                copies: copies.map(\.copy), keptPairs: []
            )
        }
        let twins = try identical(1, [Self.copy("2026/10/a.jpg"), Self.copy("2026/10/a_001.jpg")])
        let moreTwins = try identical(2, [Self.copy("2026/10/b.jpg", captured: 1_800_000_000), Self.copy("2026/10/b_001.jpg")])
        let mirrored = try identical(3, [Self.copy("2026/08/c.jpg"), Self.copy("Imports/c.jpg")])
        let scattered = try identical(4, [Self.copy("x/d.jpg"), Self.copy("y/d.jpg"), Self.copy("z/d.jpg")])
        let conflict = try identical(5, [Self.copy("2026/10/e.jpg", edited: true), Self.copy("2026/10/e_001.jpg", edited: true)])
        let resized = Self.samePhoto(["2026/10/f.jpg", "2026/10/f small.jpg"], bytes: [11_000_000, 400_000])

        let state = CatalogDuplicatesState(groups: [scattered, mirrored, twins, resized, moreTwins, conflict])
        #expect(state.layout.choose.map(\.id) == [conflict.id])
        #expect(state.layout.different.map(\.id) == [resized.id])
        #expect(state.layout.buckets.map(\.id) == [
            .folders(DuplicateFolderSet(twins)), .folders(DuplicateFolderSet(mirrored)), .scattered,
        ])
        // Inside a folder: largest first, then newest.
        #expect(state.layout.buckets.first?.groups.map(\.id) == [moreTwins.id, twins.id])
        #expect(state.groups.map(\.id) == [conflict.id, resized.id, moreTwins.id, twins.id, mirrored.id, scattered.id])
        #expect(DuplicatesSectionPresentation.map(.exact, in: state.layout)?.count == "4 photos")
        // Each section's sentence says what its groups are; the bar's legend is the one
        // instruction.
        #expect(DuplicatesSection.allCases.compactMap { DuplicatesSectionPresentation.map($0, in: state.layout)?.detail } == [
            "Their edits, ratings or .xmp files conflict.",
            "Otos keeps the best file of each.",
            "The same file stored more than once.",
        ])
        #expect(DuplicatesSectionPresentation.map(.choose, in: CatalogDuplicatesState(groups: [twins]).layout) == nil)

        // No rule could decide a group in three or more folders.
        let last = try #require(state.layout.buckets.last)
        let lastRow = DuplicateFolderBucketPresentation.map(last, session: DuplicatesSession(), withLibrary: false)
        #expect(lastRow.title == "In three or more folders")
        #expect(lastRow.rule == nil)

        // A group keeps its section when its copies are kept whole or one is picked: a
        // click never moves the group out from under the pointer.
        let ids = conflict.copies.map(\.id)
        let keptConflict = try DuplicateGroupPolicy.group(
            id: .identical(#require(ContentDigest(data: Data(repeating: 5, count: ContentDigest.byteCount))), library: nil),
            copies: conflict.copies, keptPairs: [DuplicateKeptPair(ids[0], ids[1])]
        )
        #expect(keptConflict.isKept)
        #expect(keptConflict.section == .choose)
    }

    /// A folder's rule governs the exact copies under its header; files of one photo
    /// differ in their pixels and are decided by their own photos.
    @Test func aFolderRuleLeavesFilesOfOnePhotoToTheirPhotos() {
        let resized = Self.samePhoto(["2026/10/f.jpg", "2026/10/f small.jpg"], bytes: [11_000_000, 400_000])
        var session = DuplicatesSession()
        let original = resized.copies[0].id
        #expect(session.resolution(of: resized)?.keep == [original])
        session.rules[DuplicateFolderSet(resized)] = .oldest
        #expect(session.resolution(of: resized)?.reason == .automatic(.criterion(.cameraOriginal)))
        // What differs is under each photo, not in a tooltip.
        let tiles = DuplicateGroupPresentation.map(resized, session: session).tiles
        #expect(tiles.map(\.caption) == ["4000 × 3000 · Camera original", "1000 × 750"])
    }

    /// An exact-copy group is one picture beside its copies' names: what the copies share
    /// is said once, and each line carries what tells its copy apart and the work it holds.
    @Test func exactCopiesAreToldApartByNameOrFolder() throws {
        let twins = try Self.onlyGroup([Self.copy("2026/08/a.jpg", choice: .liked), Self.copy("2026/08/a copy.jpg")])
        let row = DuplicateGroupPresentation.map(twins, session: DuplicatesSession(), style: .names)
        #expect(row.reason == "1 KB each · Keeping the copy you liked")
        // Beside the names, at the trailing edge of the first: the date, the shared size, why.
        #expect(row.dateAndReason == "\(row.title) · 1 KB each · Keeping the copy you liked")
        #expect(row.picture == Self.copy("2026/08/a.jpg").copy.id)
        #expect(row.tiles.map(\.label) == ["a.jpg", "a copy.jpg"])
        #expect(row.tiles.map(\.caption) == ["Liked", nil])
        #expect(row.tiles.map(\.fate) == [.keep, .trash])

        let mirrored = try Self.onlyGroup([Self.copy("2026/08/b.jpg"), Self.copy("Imports/b.jpg")])
        #expect(Set(DuplicateGroupPresentation.map(mirrored, session: DuplicatesSession(), style: .names).tiles.map(\.label))
            == ["2026/08", "Imports"])
        let renamed = try Self.onlyGroup([Self.copy("2026/08/b.jpg"), Self.copy("Imports/b (1).jpg")])
        #expect(Set(DuplicateGroupPresentation.map(renamed, session: DuplicatesSession(), style: .names).tiles.map(\.label))
            == ["2026/08 ▸ b.jpg", "Imports ▸ b (1).jpg"])
    }

    /// A group's photos take its own aspect from the copies' upright pixel size, bounded by
    /// 180 pt each way, so a picture fills its cell; square when no size is known.
    @Test func aGroupsCellsTakeItsOwnAspect() throws {
        #expect(DuplicateGroupPresentation.cell(width: 4032, height: 3024) == CGSize(width: 180, height: 135))
        #expect(DuplicateGroupPresentation.cell(width: 3024, height: 4032) == CGSize(width: 135, height: 180))
        #expect(DuplicateGroupPresentation.cell(width: 6000, height: 1000) == CGSize(width: 180, height: 30))
        #expect(DuplicateGroupPresentation.cell(width: nil, height: 3024) == CGSize(width: 180, height: 180))
        #expect(DuplicateGroupPresentation.cell(width: 0, height: 0) == CGSize(width: 180, height: 180))
        let landscape = try Self.onlyGroup([Self.copy("a.jpg"), Self.copy("a copy.jpg")])
        #expect(DuplicateGroupPresentation.map(landscape, session: DuplicatesSession()).cell == CGSize(width: 180, height: 135))
    }

    /// A closed folder header shows the pictures of its first five groups, each group's
    /// kept copy.
    @Test func aFolderHeaderPreviewsItsFirstGroups() throws {
        let groups = try (0 ..< 7).map { index in
            try DuplicateGroupPolicy.group(
                id: .identical(#require(ContentDigest(data: Data(repeating: UInt8(10 + index), count: ContentDigest.byteCount))), library: nil),
                copies: [Self.copy("2026/10/p\(index).jpg").copy, Self.copy("2026/10/p\(index)_001.jpg").copy],
                keptPairs: []
            )
        }
        let bucket = try #require(CatalogDuplicatesState(groups: groups).layout.buckets.first)
        let header = DuplicateFolderBucketPresentation.map(bucket, session: DuplicatesSession(), withLibrary: false)
        #expect(header.previews.count == DuplicateFolderBucketPresentation.previewLimit)
        #expect(header.previews.map(\.id) == bucket.groups.prefix(5).compactMap { $0.copies.first?.id })
        #expect(header.previews.allSatisfy { !$0.id.relativePath.fileName.contains("_001") })
    }

    /// ADR 0042: while Duplicates compares within each library, a copy in another library is
    /// no duplicate of it, and the same digest in two libraries is two groups.
    @Test func copiesGroupWithinEachLibraryUnlessDuplicatesComparesAcrossThem() throws {
        let copies = [
            Self.copy("a/IMG_1.jpg"), Self.copy("b/IMG_1.jpg"),
            Self.copy("IMG_1.jpg", in: Self.backup),
            Self.copy("asset-1/IMG_1.jpg", in: Self.family),
        ]
        let within = DuplicateGroupPolicy.groups(copies: copies, keptPairs: [], reach: .withinEachLibrary)
        try #require(within.count == 1)
        #expect(within[0].id == .identical(Self.digest, library: Self.photos))
        #expect(Set(within[0].copies.map(\.id.relativePath.rawValue)) == ["a/IMG_1.jpg", "b/IMG_1.jpg"])

        // A mirror alone, one copy in each of two libraries, is no group at all.
        #expect(DuplicateGroupPolicy.groups(
            copies: [Self.copy("IMG_1.jpg", in: Self.backup), Self.copy("asset-1/IMG_1.jpg", in: Self.family)],
            keptPairs: [], reach: .withinEachLibrary
        ).isEmpty)

        let across = DuplicateGroupPolicy.groups(copies: copies, keptPairs: [], reach: .acrossLibraries)
        try #require(across.count == 1)
        #expect(across[0].id == .identical(Self.digest, library: nil))
        #expect(across[0].copies.count == 4)
    }

    /// The Store's read, the Duplicates scope and a group's scope agree on the reach, and a
    /// change of reach is a change of which files are copies.
    @Test func theStoreComparesWithinEachLibraryUntilToldToCompareAcross() async throws {
        let temp = try makeTestDirectory()
        let first = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let second = temp.appending(path: "Mirror", directoryHint: .isDirectory)
        for url in [first, second] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        for url in [first.appending(path: "a.jpg"), first.appending(path: "b.jpg"), second.appending(path: "a.jpg"), second.appending(path: "c.jpg")] {
            try writeCatalogStoreFile(url, contents: url.lastPathComponent == "c.jpg" ? "other" : "same")
        }
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: first)
        try await store.addLibrary(url: second)
        let libraries = try [first, second].map(CatalogPath.normalizedDirectoryPath(for:))
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 4 }
        let shared = try #require(ContentDigest(data: Data(repeating: 1, count: ContentDigest.byteCount)))
        for library in libraries {
            for facts in try #require(await store.windowReads.planningMedia(for: library)) {
                let byte: UInt8 = facts.relativePath.rawValue == "c.jpg" ? 2 : 1
                _ = try await store.applyContentHash(ContentHashResult(
                    id: facts.id,
                    contentHash: #require(ContentDigest(data: Data(repeating: byte, count: ContentDigest.byteCount))),
                    sourceSize: facts.byteSize,
                    sourceMTimeSeconds: facts.contentModifiedAt.map { Int($0.timeIntervalSince1970.rounded(.down)) }
                ))
            }
        }
        let available = Set(libraries)
        func names(_ ids: [MediaAssetID]) -> Set<String> {
            Set(ids.map { "\($0.libraryRootPath == libraries[0] ? "first" : "second")/\($0.relativePath.rawValue)" })
        }
        func scoped(_ scope: SidebarSelection) async throws -> Set<String> {
            try await names(store.windowReads.orderedAssetIDs(
                for: CatalogQueryDescriptor(scope: scope), availableLibraryPaths: available
            ).ids)
        }

        #expect(await store.duplicatesReach == .withinEachLibrary)
        #expect(try await names(store.backgroundReads.duplicateCopies(availableLibraryPaths: available).copies.map(\.copy.id))
            == ["first/a.jpg", "first/b.jpg"])
        #expect(try await scoped(.duplicates) == ["first/a.jpg", "first/b.jpg"])
        #expect(try await scoped(.duplicateGroup(.identical(shared, library: libraries[0])))
            == ["first/a.jpg", "first/b.jpg"])

        let changes = await store.changeNotifications()
        await store.setDuplicatesReach(.acrossLibraries)
        for await change in changes where change.facts.contains(.duplicateFacts) {
            break
        }
        #expect(try await store.backgroundReads.duplicateCopies(availableLibraryPaths: available).reach == .acrossLibraries)
        #expect(try await names(store.backgroundReads.duplicateCopies(availableLibraryPaths: available).copies.map(\.copy.id))
            == ["first/a.jpg", "first/b.jpg", "second/a.jpg"])
        #expect(try await scoped(.duplicates) == ["first/a.jpg", "first/b.jpg", "second/a.jpg"])
        #expect(try await scoped(.duplicateGroup(.identical(shared, library: nil)))
            == ["first/a.jpg", "first/b.jpg", "second/a.jpg"])
        await store.shutdown()
    }

    @Test func theStoreGroupsVisibleCopiesWithCurrentDigestsAndRemembersKeepAll() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "Print"), withIntermediateDirectories: true)
        for path in ["a.jpg", "Print/a.jpg", "b.jpg"] {
            try writeCatalogStoreFile(root.appending(path: path), contents: path == "b.jpg" ? "other" : "same")
        }
        // Two empty files share the digest of no bytes; neither is a duplicate.
        for path in ["empty.jpg", "Print/empty.avi"] {
            try writeCatalogStoreFile(root.appending(path: path), contents: "")
        }
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let library = try CatalogPath.normalizedDirectoryPath(for: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 5 }
        let media = try #require(await store.windowReads.planningMedia(for: library))
        for facts in media {
            let byte: UInt8 = switch facts.relativePath.rawValue {
            case "b.jpg": 2
            case "empty.jpg", "Print/empty.avi": 3
            default: 1
            }
            _ = try await store.applyContentHash(ContentHashResult(
                id: facts.id,
                contentHash: #require(ContentDigest(data: Data(repeating: byte, count: ContentDigest.byteCount))),
                sourceSize: facts.byteSize,
                sourceMTimeSeconds: facts.contentModifiedAt.map { Int($0.timeIntervalSince1970.rounded(.down)) }
            ))
        }

        let read = try await store.backgroundReads.duplicateCopies(availableLibraryPaths: [library])
        #expect(Set(read.copies.map(\.copy.id.relativePath.rawValue)) == ["a.jpg", "Print/a.jpg"])
        #expect(read.keptPairs.isEmpty)
        // The Duplicates scope holds the copies the groups list, and no empty file.
        let scoped = try await store.windowReads.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: .duplicates), availableLibraryPaths: [library]
        ).ids
        #expect(Set(scoped.map(\.relativePath.rawValue)) == ["a.jpg", "Print/a.jpg"])

        let ids = read.copies.map(\.copy.id)
        let added = try await store.keepCopiesTogether([ids])
        #expect(added.count == 1)
        #expect(try await store.backgroundReads.duplicateCopies(availableLibraryPaths: [library]).keptPairs == added)

        // A copy waiting for the Trash makes no one else a duplicate.
        _ = try await store.markPendingTrash([ids[0]], batch: MediaTrashBatchID())
        #expect(try await store.backgroundReads.duplicateCopies(availableLibraryPaths: [library]).copies.isEmpty)
        await store.shutdown()
    }

    /// The act carries a moved copy's choice and edit onto the kept copy in the hiding write,
    /// and undo — once the moved copy is back — takes them back off.
    @Test func movingACopyCarriesItsWorkOntoTheKeptCopyAndUndoTakesItBack() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "Print"), withIntermediateDirectories: true)
        for path in ["a.jpg", "Print/a.jpg"] {
            try writeCatalogStoreFile(root.appending(path: path), contents: "same")
        }
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let library = try CatalogPath.normalizedDirectoryPath(for: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 2 }
        let moved = MediaAssetID(libraryRootPath: library, relativePath: MediaRelativePath(rawValue: "a.jpg"))
        let kept = MediaAssetID(libraryRootPath: library, relativePath: MediaRelativePath(rawValue: "Print/a.jpg"))
        var recipe = EditRecipe.neutral
        recipe.exposure = 0.5
        _ = try await store.setMediaChoice(.liked, for: [moved])
        _ = try await store.setEditRecipe(recipe, for: moved)

        let batch = MediaTrashBatchID()
        let hidden = try await store.markPendingTrash([moved], batch: batch, carrying: [
            DuplicateCarry(from: moved, to: kept, work: .choice),
            DuplicateCarry(from: moved, to: kept, work: .edit),
        ])
        #expect(hidden == [moved])
        #expect(try await store.windowReads.mediaAssets(for: [kept])[kept]?.mediaChoice == .liked)
        #expect(try await store.windowReads.editRecipe(for: kept)?.recipe == recipe)

        // The moved copy came back: what was carried comes off the kept copy.
        _ = try await store.clearPendingTrash([moved])
        try await store.revertCarriedWork(batch: batch, restored: [moved])
        #expect(try await store.windowReads.mediaAssets(for: [kept])[kept]?.mediaChoice == .notRated)
        #expect(try await store.windowReads.editRecipe(for: kept) == nil)
        // The moved copy still holds its own.
        #expect(try await store.windowReads.mediaAssets(for: [moved])[moved]?.mediaChoice == .liked)
        #expect(try await store.windowReads.editRecipe(for: moved)?.recipe == recipe)
        await store.shutdown()
    }
}
