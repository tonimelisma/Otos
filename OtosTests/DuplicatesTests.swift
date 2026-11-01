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
        #expect(group.wait == nil)
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

    @Test func twoCopiesWithAuthoredWorkWait() throws {
        let group = try Self.onlyGroup([Self.copy("a.jpg", choice: .liked), Self.copy("b.jpg", edited: true)])
        #expect(group.defaultKeep == nil)
        #expect(group.wait == .differingAuthoredWork)
    }

    @Test func nothingAcrossLibrariesIsPreselected() throws {
        let group = try Self.onlyGroup([Self.copy("IMG_1.jpg"), Self.copy("IMG_1.jpg", in: Self.backup)])
        #expect(group.defaultKeep == nil)
        #expect(group.wait == .spansLibraries)
        #expect(group.libraryPair == DuplicateLibraryPair(Self.photos, Self.backup))
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
            copies: [Self.copy("x.jpg").copy, Self.copy("x.jpg", in: Self.backup).copy],
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

    /// Before the catalog loads the pane claims nothing, not even `No duplicates` (APP-044).
    @Test func thePaneDrawsNothingBeforeTheCatalogLoads() throws {
        let group = try Self.onlyGroup([Self.copy("a/IMG_1.jpg"), Self.copy("b/IMG_1 copy.jpg")])
        #expect(DuplicatesPaneContent.of(.empty, isCatalogLoaded: false) == .nothing)
        #expect(DuplicatesPaneContent.of(.empty, isCatalogLoaded: true) == .noDuplicates)
        #expect(DuplicatesPaneContent.of(CatalogDuplicatesState(groups: [group]), isCatalogLoaded: true) == .list)
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
}
