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
        choice: MediaChoice = .notRated,
        edited: Bool = false,
        companions: Bool = false
    ) -> DuplicateCopyFacts {
        DuplicateCopyFacts(
            copy: DuplicateCopy(
                id: MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: path)),
                libraryDisplayName: root == photos ? "Photos" : "Backup",
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
        #expect(tally.photosWithDuplicates == 2)
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
        #expect(grownTally.photosWithDuplicates == 3)
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
            photosWithDuplicates: 6, itemsToMove: [], bytesToMove: .zero, needingChoice: 6
        ))
        #expect(none.primaryLine == "6 photos with duplicates")
        #expect(none.secondary == .reveal("6 need your choice"))
        #expect(none.actionTitle == "Move Marked Items to Trash")
        #expect(!none.actionEnabled)
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
