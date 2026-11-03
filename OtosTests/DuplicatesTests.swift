import Foundation
@testable import OtosKit
import Testing

/// ADR 0042: the keeper rule, the session's counts, and the Store's duplicates read.
@Suite(.testDirectory)
struct DuplicatesTests {
    private static let photos = LibraryRootPath(rawValue: "/Users/me/Photos")
    private static let backup = LibraryRootPath(rawValue: "/Volumes/Backup/Photos")
    private static let digest = XXH3Digest128(data: Data(repeating: 1, count: 16))!

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
                libraryDisplayName: root == photos ? "Photos" : "Backup",
                kind: kind,
                captureDate: captured.map(Date.init(timeIntervalSince1970:)),
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

    private static func onlyGroup(_ copies: [DuplicateCopyFacts], kept: Set<DuplicateKeptPair> = []) throws -> DuplicateGroup {
        let groups = DuplicateGroupPolicy.groups(copies: copies, keptPairs: kept)
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
        #expect(DuplicatesSession().carries(in: group) == [DuplicateCarry(from: liked, to: edited, work: .choice)])
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
        #expect(pair.libraryPair == DuplicateLibraryPair(Self.photos, Self.backup))

        // A second copy inside one library is still marked.
        let extra = try Self.onlyGroup([
            Self.copy("IMG_1.jpg"),
            Self.copy("IMG_1 copy.jpg"),
            Self.copy("IMG_1.jpg", in: Self.backup),
        ])
        #expect(DuplicatesSession().copiesToMove(in: extra) == [Self.copy("IMG_1 copy.jpg").copy.id])
    }

    @Test func keepOnlyMarksTheRestOfTheGroupOrTheOtherLibrary() throws {
        let group = try Self.onlyGroup([
            Self.copy("IMG_1.jpg"),
            Self.copy("IMG_1 copy.jpg"),
            Self.copy("IMG_1.jpg", in: Self.backup),
        ])
        let suffixed = Self.copy("IMG_1 copy.jpg").copy.id
        var session = DuplicatesSession()
        session.keepOnly(suffixed, in: group)
        #expect(Set(session.copiesToMove(in: group)) == [Self.copy("IMG_1.jpg").copy.id, Self.copy("IMG_1.jpg", in: Self.backup).copy.id])

        var byLibrary = DuplicatesSession()
        byLibrary.keepOnly(Self.photos, in: [group])
        #expect(Set(byLibrary.copiesToMove(in: group)) == [suffixed, Self.copy("IMG_1.jpg", in: Self.backup).copy.id])
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

    @Test func copySuffixesAreFindersAndBrowsers() {
        #expect(DuplicateGroupPolicy.hasCopySuffix("IMG_1 copy.jpg"))
        #expect(DuplicateGroupPolicy.hasCopySuffix("IMG_1 copy 2.jpg"))
        #expect(DuplicateGroupPolicy.hasCopySuffix("IMG_1 (1).jpg"))
        #expect(DuplicateGroupPolicy.hasCopySuffix("20261031_183009_001.heif"))
        #expect(!DuplicateGroupPolicy.hasCopySuffix("DSC_0001.ARW"))
        #expect(!DuplicateGroupPolicy.hasCopySuffix("Beach 2.jpg"))
        #expect(!DuplicateGroupPolicy.hasCopySuffix("IMG_1.jpg"))
    }

    @Test func theSessionNeverMovesEveryCopyAndCountsEveryActiveGroup() throws {
        let preselected = try Self.onlyGroup([Self.copy("a/IMG_1.jpg"), Self.copy("b/IMG_1 copy.jpg")])
        let waiting = try DuplicateGroupPolicy.group(
            id: .identical(#require(XXH3Digest128(data: Data(repeating: 2, count: 16)))),
            copies: [Self.copy("x.jpg", edited: true).copy, Self.copy("y.jpg", edited: true).copy],
            keptPairs: []
        )
        let state = CatalogDuplicatesState(groups: [preselected, waiting])
        var session = DuplicatesSession()

        let tally = session.tally(in: state)
        #expect(tally.itemsWithDuplicates == 2)
        #expect(tally.noun == .photos)
        #expect(tally.itemsToMove == [Self.copy("b/IMG_1 copy.jpg").copy.id])
        #expect(tally.needingChoice == 1)

        // The kept copy of a group cannot be the last to go.
        let keeper = Self.copy("a/IMG_1.jpg").copy.id
        #expect(!session.canMoveToTrash(keeper, in: preselected))
        // Even marked by hand, every copy of a group never moves: the group moves none.
        session.keepOverrides[keeper] = false
        #expect(session.copiesToMove(in: preselected).isEmpty)
        session.keepOverrides[keeper] = nil

        // A group found while the user looks joins the count and the act at once.
        let newcomer = try DuplicateGroupPolicy.group(
            id: .identical(#require(XXH3Digest128(data: Data(repeating: 3, count: 16)))),
            copies: [Self.copy("n/a.jpg").copy, Self.copy("n/a copy.jpg").copy],
            keptPairs: []
        )
        let grown = CatalogDuplicatesState(groups: [preselected, waiting, newcomer])
        let grownTally = session.tally(in: grown)
        #expect(grownTally.itemsWithDuplicates == 3)
        #expect(grownTally.itemsToMove == [Self.copy("b/IMG_1 copy.jpg").copy.id, Self.copy("n/a copy.jpg").copy.id])
    }

    @Test func aMarkIsForgottenOnceNoGroupHoldsItsCopy() throws {
        let group = try Self.onlyGroup([Self.copy("a/IMG_1.jpg"), Self.copy("b/IMG_1 copy.jpg")])
        let suffixed = Self.copy("b/IMG_1 copy.jpg").copy.id
        var session = DuplicatesSession()
        session.keepOverrides[suffixed] = true

        session.forgetMarks(absentFrom: CatalogDuplicatesState(groups: [group]))
        #expect(session.keepOverrides[suffixed] == true)

        // The copy left — moved, its library offline — so when it returns it starts over.
        session.forgetMarks(absentFrom: .empty)
        #expect(session.keepOverrides.isEmpty)
        #expect(!session.keeps(suffixed, in: group))
    }

    @Test func theBarNamesTheActAndKeepsItsTitleWhenDisabled() {
        let none = DuplicatesBarPresentation.map(DuplicatesTally(
            itemsWithDuplicates: 6, noun: .videos, itemsToMove: [], bytesToMove: .zero, needingChoice: 6
        ))
        #expect(none.primaryLine == "6 videos with duplicates")
        #expect(none.secondaryLine == nil)
        #expect(none.middle == .choices("6 videos need your choice"))
        #expect(none.actionTitle == "Move Extra Copies to Trash")
        #expect(!none.actionEnabled)

        let two = DuplicatesBarPresentation.map(DuplicatesTally(
            itemsWithDuplicates: 110, noun: .photosAndVideos,
            itemsToMove: [Self.copy("a.jpg").copy.id, Self.copy("b.mp4").copy.id],
            bytesToMove: PartialByteCount(knownBytes: 14_900_000_000, unknownCount: 0), needingChoice: 0
        ))
        #expect(two.primaryLine == "110 photos and videos with duplicates")
        // The count the button repeats, and the bytes it does not carry.
        #expect(two.secondaryLine == "2 extra copies to move · 14.9 GB")
        #expect(two.middle == .legend(DuplicatesBarPresentation.legend))
        #expect(two.actionTitle == "Move 2 Extra Copies to Trash")
        #expect(two.actionEnabled)

        // After the act, its receipt with Undo while the act is the window's last change.
        let moved = DuplicatesBarPresentation.map(
            DuplicatesTally(itemsWithDuplicates: 0, noun: .items, itemsToMove: [], bytesToMove: .zero, needingChoice: 0),
            receipt: DuplicatesReceipt(
                batch: MediaTrashBatchID(), movedCount: 2, bytes: PartialByteCount(knownBytes: 14_900_000_000, unknownCount: 0)
            ),
            canUndoMove: true
        )
        #expect(moved.primaryLine == "No duplicates")
        #expect(moved.middle == .receipt(
            line: "2 extra copies moved to the Trash · 14.9 GB",
            detail: "Empty the Trash in Finder to free the space",
            canUndo: true
        ))
    }

    /// The noun is the user's own word for what the groups hold, and `items` until the
    /// catalog has read every kind.
    @Test func theNounFollowsWhatTheGroupsHold() {
        #expect(DuplicateItemNoun.covering([.video, .video]) == .videos)
        #expect(DuplicateItemNoun.covering([.image, .raw]) == .photos)
        #expect(DuplicateItemNoun.covering([.image, .video]) == .photosAndVideos)
        #expect(DuplicateItemNoun.covering([.image, nil]) == .items)
        #expect(DuplicateItemNoun.covering([]) == .items)
    }

    /// The header says what the copies share, the rows say what differs: the deepest folder
    /// every copy is in or under goes in the header, and each row names the rest.
    @Test func theHeaderNamesWhatTheCopiesShareAndTheRowsWhatDiffers() throws {
        let twins = try Self.onlyGroup([Self.copy("2026/08/a.mp4", kind: .video), Self.copy("2026/08/b.mp4", kind: .video)])
        let card = DuplicateGroupPresentation.map(twins, session: DuplicatesSession())
        #expect(card.title == "2 identical videos")
        #expect(card.sharedFacts?.hasSuffix("1 KB each · MP4 · 4032 × 3024 · Photos ▸ 2026/08") == true)
        #expect(card.rows.map(\.primary) == ["a.mp4", "b.mp4"])
        #expect(card.headerThumbnail == twins.copies.first?.id)
        #expect(!card.showsCompare)
        #expect(card.keepAllTitle == "Keep Both Copies")

        let nested = try Self.onlyGroup([
            Self.copy("2024/Holiday/Day 1/IMG_1.jpg"), Self.copy("2024/Holiday/Day 2/IMG_1.jpg"), Self.copy("2024/Holiday/IMG_1.jpg"),
        ])
        let nestedCard = DuplicateGroupPresentation.map(nested, session: DuplicatesSession())
        #expect(nestedCard.sharedFacts?.hasSuffix("Photos ▸ 2024/Holiday") == true)
        #expect(Set(nestedCard.rows.map(\.primary)) == ["Day 1/IMG_1.jpg", "Day 2/IMG_1.jpg", "IMG_1.jpg"])
        #expect(nestedCard.keepAllTitle == "Keep All Copies")

        let mirrored = try Self.onlyGroup([Self.copy("2024/IMG_1.jpg"), Self.copy("2024/IMG_1.jpg", in: Self.backup)])
        let mirroredCard = DuplicateGroupPresentation.map(mirrored, session: DuplicatesSession())
        #expect(mirroredCard.sharedFacts?.contains("▸") == false)
        #expect(Set(mirroredCard.rows.map(\.primary)) == ["Photos ▸ 2024/IMG_1.jpg", "Backup ▸ 2024/IMG_1.jpg"])
        #expect(mirroredCard.decision == "Keeping one copy in each library")
    }

    /// The decision line names the rule that was needed, the conflict that waits, or the
    /// user's own choice — and a mark changed back is no choice.
    @Test func theDecisionLineSaysWhyOrWhatToChoose() throws {
        var session = DuplicatesSession()
        let suffixed = try Self.onlyGroup([Self.copy("a/IMG_1 copy.jpg", born: 50), Self.copy("b/IMG_1.jpg", born: 90)])
        #expect(DuplicateGroupPresentation.map(suffixed, session: session).decision == "Keeping the original file name")

        let older = try Self.onlyGroup([Self.copy("b/IMG_1.jpg", born: 90), Self.copy("a/IMG_1.jpg", born: 50)])
        #expect(DuplicateGroupPresentation.map(older, session: session).decision == "Keeping the older file")
        // Birth times are compared at whole seconds, as the rows show them.
        let sameSecond = try Self.onlyGroup([Self.copy("b.jpg", born: 50.9), Self.copy("a.jpg", born: 50.1)])
        #expect(DuplicateGroupPresentation.map(sameSecond, session: session).decision == "Alike in every way, so keeping the first by name")
        let acrossFolders = try Self.onlyGroup([Self.copy("2025/a.jpg", born: 50), Self.copy("2024/b.jpg", born: 50)])
        #expect(DuplicateGroupPresentation.map(acrossFolders, session: session).decision
            == "Alike in every way, so keeping the first by folder and name")

        // The deciding criterion is the one needed against the copy beaten last: the plain
        // name beats the suffixed copy by name, and the older plain name by birth.
        let three = try Self.onlyGroup([
            Self.copy("a/IMG_1.jpg", born: 50), Self.copy("b/IMG_1.jpg", born: 90), Self.copy("c/IMG_1 copy.jpg", born: 10),
        ])
        #expect(DuplicateGroupPresentation.map(three, session: session).decision == "Keeping the older file")

        let disliked = try Self.onlyGroup([Self.copy("a.jpg", choice: .disliked), Self.copy("b.jpg")])
        #expect(DuplicateGroupPresentation.map(disliked, session: session).decision == "Keeping the copy you disliked")

        let waiting = try Self.onlyGroup([Self.copy("a.jpg", edited: true), Self.copy("b.jpg", edited: true)])
        let waitingCard = DuplicateGroupPresentation.map(waiting, session: session)
        #expect(waitingCard.decision == "Choose which edited copy to keep")
        #expect(waitingCard.sharedFacts?.hasSuffix("1 KB each · JPG · 4032 × 3024 · Photos") == true)
        let everyRowOffersTheChoice = waitingCard.rows.allSatisfy { $0.fate == .choice }
        #expect(everyRowOffersTheChoice)
        #expect(waitingCard.rows.map(\.secondary) == ["Edited in Otos", "Edited in Otos"])
        session.keepOnly(Self.copy("b.jpg").copy.id, in: waiting)
        let chosen = DuplicateGroupPresentation.map(waiting, session: session)
        #expect(chosen.decision == "Keeping the copy you chose")
        #expect(chosen.rows.map(\.fate) == [.movesToTrash, .stays])
        // Two edits cannot combine: the leaving copy's edit goes with it, and the row says so.
        #expect(chosen.rows[0].secondary == "Edited in Otos. Its edits move to the Trash with it")
        #expect(chosen.rows[1].secondary == "Edited in Otos")

        // A choice taken back is the default again.
        session = DuplicatesSession()
        let kept = Self.copy("b/IMG_1.jpg").copy.id
        session.keepOverrides[kept] = true
        #expect(DuplicateGroupPresentation.map(suffixed, session: session).decision == "Keeping the original file name")
        session.keepOverrides[Self.copy("a/IMG_1 copy.jpg").copy.id] = true
        #expect(DuplicateGroupPresentation.map(suffixed, session: session).decision == "Keeping the copies you chose")
    }

    /// In a pair, unchecking the kept copy keeps the other: one click swaps the keeper. With
    /// three copies the last kept copy stays kept.
    @Test func uncheckingAPairsKeptCopyKeepsTheOther() throws {
        let pair = try Self.onlyGroup([Self.copy("a.jpg", born: 50), Self.copy("b.jpg", born: 90)])
        let a = Self.copy("a.jpg").copy.id
        let b = Self.copy("b.jpg").copy.id
        var session = DuplicatesSession()
        #expect(session.canUnkeep(a, in: pair))
        let swapped = session.unkeep(a, in: pair)
        #expect(swapped)
        #expect(!session.keeps(a, in: pair))
        #expect(session.keeps(b, in: pair))
        #expect(DuplicateGroupPresentation.map(pair, session: session).decision == "Keeping the copy you chose")

        let three = try Self.onlyGroup([Self.copy("a.jpg", born: 50), Self.copy("b.jpg", born: 90), Self.copy("c.jpg", born: 90)])
        var threeSession = DuplicatesSession()
        #expect(!threeSession.canUnkeep(a, in: three))
        let refused = !threeSession.unkeep(a, in: three)
        #expect(refused)
        #expect(threeSession.keeps(a, in: three))
    }

    /// Versions of one photo show their pictures on the rows only when the pixels or the
    /// format differ; otherwise one picture stands for the group and the shared facts go on
    /// the card, at the precision the list shows.
    @Test func versionRowsShowPicturesOnlyWhenThePicturesDiffer() {
        let ids = ["IMG_1.HEIC", "IMG_1_001.HEIC"].map {
            MediaAssetID(libraryRootPath: Self.photos, relativePath: MediaRelativePath(rawValue: $0))
        }
        func version(_ id: MediaAssetID, width: Int, bytes: Int64) -> DuplicateCopy {
            DuplicateCopy(
                id: id, libraryDisplayName: "Photos", kind: .image, captureDate: nil, byteSize: bytes,
                createdAt: nil, pixelWidth: width, pixelHeight: width * 3 / 4, mediaChoice: .notRated,
                isEdited: false, hasCompanions: false
            )
        }
        let alike = DuplicateGroupPolicy.group(
            id: .samePhoto(ids), copies: [version(ids[0], width: 4000, bytes: 11_200_000), version(ids[1], width: 4000, bytes: 11_400_000)],
            keptPairs: [], originals: Set(ids)
        )
        // 11,200,000 and 11,400,000 bytes both show as 11 MB: the rule ranks the bytes, so
        // the rows show the bytes and the pictures, and the card drops the size.
        let alikeCard = DuplicateGroupPresentation.map(alike, session: DuplicatesSession())
        #expect(alikeCard.title == "2 files of one photo")
        #expect(alikeCard.decision == "Keeping the largest file")
        #expect(alikeCard.headerThumbnail == nil)
        #expect(alikeCard.showsCompare)
        #expect(alikeCard.sharedFacts == "HEIC · 4000 × 3000 · Photos")
        #expect(alikeCard.rows.map(\.primary) == ["IMG_1_001.HEIC", "IMG_1.HEIC"])
        #expect(alikeCard.rows.map(\.secondary) == ["11,400,000 bytes", "11,200,000 bytes"])
        #expect(alikeCard.rows.map(\.thumbnailAspect) == [0.75, 0.75])

        // The same bytes under two names: one picture, the size on the card, nothing on the
        // rows but the names, and the name decides.
        let same = DuplicateGroupPolicy.group(
            id: .samePhoto(ids), copies: [version(ids[0], width: 4000, bytes: 11_200_000), version(ids[1], width: 4000, bytes: 11_200_000)],
            keptPairs: [], originals: Set(ids)
        )
        let sameCard = DuplicateGroupPresentation.map(same, session: DuplicatesSession())
        #expect(sameCard.decision == "Keeping the original file name")
        #expect(sameCard.headerThumbnail == ids[0])
        #expect(sameCard.sharedFacts == "11 MB each · HEIC · 4000 × 3000 · Photos")
        #expect(sameCard.rows.map(\.secondary) == [nil, nil])

        let resized = DuplicateGroupPolicy.group(
            id: .samePhoto(ids), copies: [version(ids[0], width: 4000, bytes: 11_200_000), version(ids[1], width: 1000, bytes: 400_000)],
            keptPairs: [], originals: [ids[0]]
        )
        let resizedCard = DuplicateGroupPresentation.map(resized, session: DuplicatesSession())
        #expect(resizedCard.decision == "Keeping the camera original")
        #expect(resizedCard.headerThumbnail == nil)
        #expect(resizedCard.sharedFacts == "HEIC · Photos")
        #expect(resizedCard.rows.map(\.secondary) == ["4000 × 3000 · 11 MB · Camera original", "1000 × 750 · 400 KB · Not the camera original"])

        // Two files that name no capture still rank by pixels and size: the rows show the
        // sizes that differ, and the line names the rule that used them.
        let screenshots = DuplicateGroupPolicy.group(
            id: .samePhoto(ids), copies: [version(ids[0], width: 1206, bytes: 108_000), version(ids[1], width: 1206, bytes: 116_000)],
            keptPairs: [], originals: []
        )
        let screenshotsCard = DuplicateGroupPresentation.map(screenshots, session: DuplicatesSession())
        #expect(screenshotsCard.decision == "Keeping the largest file")
        #expect(screenshotsCard.rows.map(\.primary) == ["IMG_1_001.HEIC", "IMG_1.HEIC"])
        #expect(screenshotsCard.rows.map(\.secondary) == ["116 KB", "108 KB"])
        #expect(resizedCard.rows.map(\.thumbnailAspect) == [0.75, 0.75])
    }

    /// A row says where its work goes, and every row of a group takes the group's shape.
    @Test func aLeavingRowSaysWhereItsWorkGoes() throws {
        let group = try Self.onlyGroup([Self.copy("a.jpg", born: 50), Self.copy("b.jpg", born: 90, choice: .liked)])
        let card = DuplicateGroupPresentation.map(group, session: DuplicatesSession())
        #expect(card.decision == "Keeping the copy you liked")
        var session = DuplicatesSession()
        session.keepOnly(Self.copy("a.jpg").copy.id, in: group)
        let moved = DuplicateGroupPresentation.map(group, session: session)
        let leaving = try #require(moved.rows.first { $0.id == Self.copy("b.jpg").copy.id })
        #expect(leaving.fate == .movesToTrash)
        #expect(leaving.secondary?.hasPrefix("File created ") == true)
        #expect(leaving.secondary?.hasSuffix(" · Liked. Its Like moves to the kept copy") == true)
        let everyRowHasTheLine = moved.rows.allSatisfy(\.showsSecondaryLine)
        #expect(everyRowHasTheLine)
        #expect(leaving.accessibilityLabel.hasPrefix("b.jpg, moves to Trash, "))
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
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let library = try CatalogPath.normalizedDirectoryPath(for: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 5 }
        let media = try #require(await store.planningMedia(for: library))
        for facts in media {
            let byte: UInt8 = switch facts.relativePath.rawValue {
            case "b.jpg": 2
            case "empty.jpg", "Print/empty.avi": 3
            default: 1
            }
            _ = try await store.applyContentHash(ContentHashResult(
                id: facts.id,
                contentHash: #require(XXH3Digest128(data: Data(repeating: byte, count: 16))),
                sourceSize: facts.byteSize,
                sourceMTimeSeconds: facts.contentModifiedAt.map { Int($0.timeIntervalSince1970.rounded(.down)) }
            ))
        }

        let read = try await store.duplicateCopies(availableLibraryPaths: [library])
        #expect(Set(read.copies.map(\.copy.id.relativePath.rawValue)) == ["a.jpg", "Print/a.jpg"])
        #expect(read.keptPairs.isEmpty)

        let ids = read.copies.map(\.copy.id)
        let added = try await store.keepCopiesTogether([ids])
        #expect(added.count == 1)
        #expect(try await store.duplicateCopies(availableLibraryPaths: [library]).keptPairs == added)

        // A copy waiting for the Trash makes no one else a duplicate.
        _ = try await store.markPendingTrash([ids[0]], batch: MediaTrashBatchID())
        #expect(try await store.duplicateCopies(availableLibraryPaths: [library]).copies.isEmpty)
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
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
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
        #expect(try await store.mediaAssets(for: [kept])[kept]?.mediaChoice == .liked)
        #expect(try await store.editRecipe(for: kept)?.recipe == recipe)

        // The moved copy came back: what was carried comes off the kept copy.
        _ = try await store.clearPendingTrash([moved])
        try await store.revertCarriedWork(batch: batch, restored: [moved])
        #expect(try await store.mediaAssets(for: [kept])[kept]?.mediaChoice == .notRated)
        #expect(try await store.editRecipe(for: kept) == nil)
        // The moved copy still holds its own.
        #expect(try await store.mediaAssets(for: [moved])[moved]?.mediaChoice == .liked)
        #expect(try await store.editRecipe(for: moved)?.recipe == recipe)
        await store.shutdown()
    }
}
