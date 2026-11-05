import Foundation
@testable import OtosKit
import Testing

/// ADR 0042: the keeper rule, what a pick or a folder rule keeps, and the Store's read.
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
            id: .identical(#require(XXH3Digest128(data: Data(repeating: 2, count: 16)))),
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
        #expect(decided.itemsToMove == [Self.copy("b/IMG_1 copy.jpg").copy.id, Self.copy("x.jpg").copy.id])

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

        let summaries = DuplicateFolderSetSummary.summaries(of: CatalogDuplicatesState(groups: [one, mirrored]))
        #expect(Set(summaries.map(\.folderSet)) == [oneFolder, pair])
    }

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
        #expect(two.primaryLine == "110 photos and videos with duplicates")
        #expect(two.secondaryLine == "2 copies go to the Trash · 14.9 GB")
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
        #expect(header.title == Date(timeIntervalSince1970: 1_700_000_000).formatted(date: .long, time: .omitted))
        #expect(header.reason == "2026/08 · Keeping the older file")
        #expect(header.tiles.map(\.fate) == [.keep, .trash])
        #expect(header.tiles.map(\.size) == ["1 KB", "1 KB"])
        #expect(header.tiles.first?.help.hasPrefix("Photos ▸ 2026/08/a.mp4") == true)

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
                id: id, libraryDisplayName: "Photos", kind: .image, captureDate: nil, byteSize: bytes,
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
                libraryDisplayName: "Photos", kind: .raw, captureDate: nil, byteSize: size, createdAt: nil,
                pixelWidth: 6192, pixelHeight: 4128, mediaChoice: .notRated, isEdited: false, hasCompanions: false
            )
        }
        let sizes = DuplicateTileFacts.distinguishingSizes(of: copies)
        #expect(copies.map { sizes[$0.id] } == ["39.13 MB", "39.10 MB", "38.82 MB", "38.81 MB", "38.80 MB", "38.79 MB"])

        let twins = Array(copies.prefix(2)).map {
            DuplicateCopy(
                id: $0.id, libraryDisplayName: "Photos", kind: .raw, captureDate: nil, byteSize: 39_133_184,
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
    }

    /// A folder rule row offers what fits its folders: two folders, either one or the
    /// default; one folder, how to choose within it.
    @Test func aFolderRowOffersWhatFitsItsFolders() throws {
        let mirrored = try Self.onlyGroup([Self.copy("2026/08/b.jpg"), Self.copy("Imports/b.jpg")])
        let pair = try #require(DuplicateFolderSetSummary.summaries(of: CatalogDuplicatesState(groups: [mirrored])).first)
        let row = DuplicateFolderRulePresentation.map(pair, rule: nil, noun: .photos, withLibrary: false)
        #expect(row.title == "2026/08 and Imports")
        #expect(row.detail == "1 photo in both")
        #expect(row.prompt == "Keep the copies in")
        #expect(row.options.map(\.title) == ["2026/08", "Imports", "Otos decides"])
        #expect(row.selected == .automatic)

        let twice = try Self.onlyGroup([Self.copy("2026/10/a.jpg"), Self.copy("2026/10/a_001.jpg")])
        let one = try #require(DuplicateFolderSetSummary.summaries(of: CatalogDuplicatesState(groups: [twice])).first)
        let oneRow = DuplicateFolderRulePresentation.map(one, rule: .oldest, noun: .photos, withLibrary: false)
        #expect(oneRow.detail == "1 photo saved twice in this folder")
        #expect(oneRow.options.map(\.title) == ["Best copy", "Original name", "Oldest", "Largest"])
        #expect(oneRow.selected == .oldest)
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
