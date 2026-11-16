import CryptoKit
import Foundation
@testable import OtosKit
import Testing

/// ADR 0054: a scope that spans the libraries and accounts shows one copy of each set of
/// identical copies, a library's before an account's; one root's scope and Duplicates show
/// every file. An uploaded Immich asset's checksum is its digest, so its copy of a library
/// file is found with no download.
@Suite(.testDirectory)
struct OneCopyTests {
    private static let server = URL(string: "https://photos.example.com")!
    private static let date = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Fixture {
        let store: CatalogStore
        let library: LibraryRootPath
        let account: LibraryRootPath
    }

    /// A library holding `IMG_1.JPG` ("same") and `IMG_2.JPG` ("other"), and `twin` ("same")
    /// when one is named, digested from their bytes unless `digested` is false, and an Immich
    /// account.
    private func fixture(digested: Bool = true, twin: String? = nil) async throws -> Fixture {
        let temp = try makeTestDirectory()
        let folder = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeCatalogStoreFile(folder.appending(path: "IMG_1.JPG"), contents: "same")
        try writeCatalogStoreFile(folder.appending(path: "IMG_2.JPG"), contents: "other")
        if let twin {
            try writeCatalogStoreFile(folder.appending(path: twin), contents: "same")
        }
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10), stagingContainers: StagingContainers(base: temp))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: folder)
        let library = try CatalogPath.normalizedDirectoryPath(for: folder)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == (twin == nil ? 2 : 3) }
        let account = try await store.addImmichAccount(server: Self.server, userID: "user-1", displayName: "Family")
        let fixture = Fixture(store: store, library: library, account: account)
        if digested {
            try await digestLibrary(fixture)
        }
        return fixture
    }

    /// Reads each library file's digest from its bytes.
    private func digestLibrary(_ fixture: Fixture) async throws {
        for facts in try #require(await fixture.store.planningMedia(for: fixture.library)) {
            let bytes = try Data(contentsOf: URL(filePath: fixture.library.rawValue).appending(path: facts.id.relativePath.rawValue))
            _ = try await fixture.store.applyContentHash(ContentHashResult(
                id: facts.id,
                contentHash: Self.digest(bytes),
                sourceSize: facts.byteSize,
                sourceMTimeSeconds: facts.contentModifiedAt.map { Int($0.timeIntervalSince1970.rounded(.down)) }
            ))
        }
    }

    private static func digest(_ bytes: Data) -> ContentDigest {
        ContentDigest(bytes: Array(Insecure.SHA1.hash(data: bytes)))!
    }

    private static func digest(_ text: String) -> ContentDigest {
        digest(Data(text.utf8))
    }

    private static func item(
        _ asset: String,
        digest: ContentDigest?,
        size: Int64? = 4,
        hidden: Bool = false
    ) -> SourceListedItem {
        SourceListedItem(
            file: ScannedMediaFile(
                relativePath: MediaRelativePath(rawValue: "\(asset)/IMG_1.JPG"), name: "IMG_1.JPG",
                contentTypeIdentifier: "public.jpeg", byteSize: size, createdAt: date, contentModifiedAt: date
            ),
            sourceItemID: asset, isHiddenBySource: hidden, sourceHasProducts: false, sourceDigest: digest
        )
    }

    private func apply(_ changes: SourceListingChanges, to account: LibraryRootPath, store: CatalogStore) async throws {
        let scan = try await store.beginSourceListing(rootPath: account)
        try await store.applySourceListingChanges(changes, scan: scan)
        await store.endSourceListing(scan: scan)
    }

    private func ids(
        _ scope: SidebarSelection,
        _ store: CatalogStore,
        available: Set<LibraryRootPath>? = nil,
        filter: MediaFilter = .all
    ) async throws -> Set<MediaAssetID> {
        let paths: Set<LibraryRootPath> = if let available {
            available
        } else {
            await CatalogWindowPolicy.availablePaths(from: store.currentLibraries())
        }
        return try await Set(store.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: scope, filter: filter), availableLibraryPaths: paths
        ).ids)
    }

    private func id(_ path: String, in root: LibraryRootPath) -> MediaAssetID {
        MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: path))
    }

    /// A digest write wakes what is built from copies only when it makes a file a copy or no
    /// longer one: a digest no other file holds changes the row's own detail, the second
    /// file with it makes two copies, and writing it again changes nothing and names nothing.
    @Test func aDigestWriteNamesCopiesOnlyWhenItMakesOrEndsACopy() async throws {
        let fixture = try await fixture(digested: false, twin: "IMG_3.JPG")
        let store = fixture.store
        let assets = try #require(await store.planningMedia(for: fixture.library))
        func facts(of path: String) throws -> (result: ContentHashResult, id: MediaAssetID) {
            let asset = try #require(assets.first { $0.id.relativePath.rawValue == path })
            let bytes = try Data(contentsOf: URL(filePath: fixture.library.rawValue).appending(path: path))
            return (ContentHashResult(
                id: asset.id, contentHash: Self.digest(bytes), sourceSize: asset.byteSize,
                sourceMTimeSeconds: asset.contentModifiedAt.map { Int($0.timeIntervalSince1970.rounded(.down)) }
            ), asset.id)
        }
        let changes = AsyncValueRecorder<CatalogStoreChange>()
        let stream = await store.changeNotifications()
        let recording = Task {
            for await change in stream {
                await changes.append(change)
            }
        }
        defer { recording.cancel() }

        // "other": no file shares it.
        _ = try await store.applyContentHash(facts(of: "IMG_2.JPG").result)
        // "same": the first file with it, then the second, which makes both copies.
        _ = try await store.applyContentHash(facts(of: "IMG_1.JPG").result)
        _ = try await store.applyContentHash(facts(of: "IMG_3.JPG").result)
        let recorded = await changes.waitForValues { $0.count == 3 }
        #expect(recorded == [.changed(.detail), .changed(.detail), .changed([.detail, .copies])])

        // The same digest again moves nothing, so nothing is announced: a later change is the
        // next one recorded.
        _ = try await store.applyContentHash(facts(of: "IMG_3.JPG").result)
        await store.setDuplicatesReach(.acrossLibraries)
        let after = await changes.waitForValues { $0.count == 4 }
        #expect(after.last == .changed(.duplicateFacts))
    }

    /// All Media shows the library's copy and not the account's; the account's own row, and
    /// Duplicates, show the account's copy too.
    @Test func aCombinedScopeShowsTheLibrarysCopyAndOneRootShowsEveryFile() async throws {
        let fixture = try await fixture()
        let store = fixture.store
        try await apply(
            SourceListingChanges(listed: [Self.item("a1", digest: Self.digest("same"))]),
            to: fixture.account, store: store
        )
        let libraryCopy = id("IMG_1.JPG", in: fixture.library)
        let accountCopy = id("a1/IMG_1.JPG", in: fixture.account)
        let other = id("IMG_2.JPG", in: fixture.library)

        #expect(try await ids(.allMedia, store) == [libraryCopy, other])
        #expect(try await ids(.library(fixture.account), store) == [accountCopy])
        #expect(try await ids(.library(fixture.library), store) == [libraryCopy, other])
        // A library and an account are two libraries: Duplicates lists the pair only while
        // it compares across them (ADR 0042), and All Media shows one copy either way.
        #expect(try await ids(.duplicates, store).isEmpty)
        await store.setDuplicatesReach(.acrossLibraries)
        #expect(try await ids(.duplicates, store) == [libraryCopy, accountCopy])
        #expect(try await ids(.allMedia, store) == [libraryCopy, other])

        // While the library is not available, its copy is not in the scope, so the
        // account's stands in for it.
        #expect(try await ids(.allMedia, store, available: [fixture.account]) == [accountCopy])
        await store.shutdown()
    }

    /// An external library's checksum hashes its path, so it is no digest: its asset is shown
    /// beside the library file it names nothing about.
    @Test func anAssetWithoutADigestOfItsBytesIsShown() async throws {
        let fixture = try await fixture()
        let store = fixture.store
        try await apply(SourceListingChanges(listed: [Self.item("a1", digest: nil)]), to: fixture.account, store: store)
        #expect(try await ids(.allMedia, store).contains(id("a1/IMG_1.JPG", in: fixture.account)))
        #expect(ImmichAsset.contentDigest(checksum: "MDO/p/AKSxrbhRCQnjVUzGGH/i0=", libraryID: "lib-1", assetID: "x") == nil)
        #expect(ImmichAsset.contentDigest(checksum: "MDO/p/AKSxrbhRCQnjVUzGGH/i0=", libraryID: nil, assetID: "x") != nil)
        #expect(ImmichAsset.contentDigest(checksum: "not base64", libraryID: nil, assetID: "x") == nil)
        await store.shutdown()
    }

    /// Two copies inside one account: the first by path is shown, and when Immich puts it in
    /// its trash the other is shown in its place.
    @Test func theNextCopyIsShownWhenTheShownOneIsHidden() async throws {
        let fixture = try await fixture()
        let store = fixture.store
        let digest = Self.digest("account only")
        try await apply(
            SourceListingChanges(listed: [Self.item("a1", digest: digest), Self.item("a2", digest: digest)]),
            to: fixture.account, store: store
        )
        let first = id("a1/IMG_1.JPG", in: fixture.account)
        let second = id("a2/IMG_1.JPG", in: fixture.account)
        #expect(try await ids(.allMedia, store).intersection([first, second]) == [first])

        try await apply(
            SourceListingChanges(listed: [Self.item("a1", digest: digest, hidden: true)]),
            to: fixture.account, store: store
        )
        #expect(try await ids(.allMedia, store).intersection([first, second]) == [second])
        await store.shutdown()
    }

    /// A digest listed before the server reported the size stays the row's once the size
    /// arrives: the size is of the same bytes.
    @Test func aSizeReportedAfterTheDigestKeepsItCurrent() async throws {
        let fixture = try await fixture()
        let store = fixture.store
        try await apply(
            SourceListingChanges(listed: [Self.item("a1", digest: Self.digest("same"), size: nil)]),
            to: fixture.account, store: store
        )
        let accountCopy = id("a1/IMG_1.JPG", in: fixture.account)
        #expect(try await !ids(.allMedia, store).contains(accountCopy))

        try await apply(SourceListingChanges(sizesBySourceItem: ["a1": 4]), to: fixture.account, store: store)
        #expect(try await !ids(.allMedia, store).contains(accountCopy))
        #expect(try await store.photoInfoOverlay(for: accountCopy)?.otherCopyRoots == [fixture.library])
        await store.shutdown()
    }

    /// Three copies and the library's not available: the next best reachable copy, the
    /// account's first by path, stands in alone; when the library is back, it shows again
    /// (owner, 2026-11-15).
    @Test func onlyTheNextBestReachableCopyStandsIn() async throws {
        let fixture = try await fixture()
        let store = fixture.store
        try await apply(
            SourceListingChanges(listed: [Self.item("a1", digest: Self.digest("same")), Self.item("a2", digest: Self.digest("same"))]),
            to: fixture.account, store: store
        )
        let libraryCopy = id("IMG_1.JPG", in: fixture.library)
        let first = id("a1/IMG_1.JPG", in: fixture.account)
        let copies: Set = [libraryCopy, first, id("a2/IMG_1.JPG", in: fixture.account)]

        #expect(try await ids(.allMedia, store).intersection(copies) == [libraryCopy])
        let offline = try await ids(.allMedia, store, available: [fixture.account])
        #expect(offline == [first])
        #expect(try await store.visibleAssetCount(for: .allMedia, availableLibraryPaths: [fixture.account]) == 1)
        #expect(try await ids(.allMedia, store).intersection(copies) == [libraryCopy])
        await store.shutdown()
    }

    /// A choice made on any copy is the photo's: every copy holds it, so a Liked filter finds
    /// the photo whichever copy shows, and undoing the act puts every copy back.
    @Test func aChoiceOnAnyCopyIsThePhotos() async throws {
        let fixture = try await fixture()
        let store = fixture.store
        try await apply(SourceListingChanges(listed: [Self.item("a1", digest: Self.digest("same"))]), to: fixture.account, store: store)
        let libraryCopy = id("IMG_1.JPG", in: fixture.library)
        let accountCopy = id("a1/IMG_1.JPG", in: fixture.account)
        var liked = MediaFilter.all
        liked.choices = [.liked]

        let act = try await store.setMediaChoices([accountCopy: .liked])
        #expect(try await choices(of: [libraryCopy, accountCopy], store) == [.liked, .liked])
        #expect(try await ids(.allMedia, store, filter: liked) == [libraryCopy])
        #expect(try await ids(.library(fixture.library), store, filter: liked) == [libraryCopy])

        _ = try await store.setMediaChoices(act.previous)
        #expect(try await choices(of: [libraryCopy, accountCopy], store) == [.notRated, .notRated])
        #expect(try await ids(.allMedia, store, filter: liked).isEmpty)
        await store.shutdown()
    }

    /// A copy found after choices were made on it and on the photo: every copy takes the
    /// choice made last. Liking the account's copy before the library's digest is read
    /// leaves the photo Liked once it is, and a copy disliked later and then found makes the
    /// photo Disliked.
    @Test func aCopyThatJoinsAPhotoTakesTheChoiceMadeLast() async throws {
        let fixture = try await fixture(digested: false)
        let store = fixture.store
        try await apply(
            SourceListingChanges(listed: [Self.item("a1", digest: Self.digest("same")), Self.item("a2", digest: nil)]),
            to: fixture.account, store: store
        )
        let libraryCopy = id("IMG_1.JPG", in: fixture.library)
        let first = id("a1/IMG_1.JPG", in: fixture.account)
        let second = id("a2/IMG_1.JPG", in: fixture.account)
        var liked = MediaFilter.all
        liked.choices = [.liked]

        _ = try await store.setMediaChoices([first: .liked])
        #expect(try await choices(of: [libraryCopy], store) == [.notRated])
        try await digestLibrary(fixture)
        #expect(try await choices(of: [libraryCopy, first], store) == [.liked, .liked])
        #expect(try await ids(.allMedia, store, filter: liked) == [libraryCopy])

        _ = try await store.setMediaChoices([second: .disliked])
        try await apply(SourceListingChanges(listed: [Self.item("a2", digest: Self.digest("same"))]), to: fixture.account, store: store)
        #expect(try await choices(of: [libraryCopy, first, second], store) == [.disliked, .disliked, .disliked])

        // Deleting a copy leaves the photo's choice on the others.
        try await apply(SourceListingChanges(deletedSourceItems: ["a2"]), to: fixture.account, store: store)
        #expect(try await choices(of: [libraryCopy, first], store) == [.disliked, .disliked])
        await store.shutdown()
    }

    /// Two files with the same bytes in one library (ADR 0054; ADR 0042): All Media shows one
    /// of them, the first by path, as one photo; the library's own view shows both files;
    /// Duplicates lists them as one group to clean up, within their library; and a Like on
    /// either is the photo's, so both files hold it and the one All Media shows is Liked.
    @Test func twoIdenticalFilesInOneLibraryAreOnePhotoAndTwoFilesToCleanUp() async throws {
        let fixture = try await fixture(twin: "IMG_1 copy.JPG")
        let store = fixture.store
        let first = id("IMG_1 copy.JPG", in: fixture.library)
        let second = id("IMG_1.JPG", in: fixture.library)
        let other = id("IMG_2.JPG", in: fixture.library)
        var liked = MediaFilter.all
        liked.choices = [.liked]

        #expect(try await ids(.allMedia, store) == [first, other])
        #expect(try await ids(.library(fixture.library), store) == [first, second, other])
        #expect(try await ids(.duplicates, store) == [first, second])
        let copies = try await store.duplicateCopies(availableLibraryPaths: [fixture.library, fixture.account]).copies
        #expect(Set(copies.map(\.copy.id)) == [first, second])
        #expect(Set(copies.map(\.digest)).count == 1)

        _ = try await store.setMediaChoices([second: .liked])
        #expect(try await choices(of: [first, second, other], store) == [.liked, .liked, .notRated])
        #expect(try await ids(.allMedia, store, filter: liked) == [first])
        #expect(try await ids(.library(fixture.library), store, filter: liked) == [first, second])
        await store.shutdown()
    }

    private func choices(of ids: [MediaAssetID], _ store: CatalogStore) async throws -> [MediaChoice?] {
        let assets = try await store.mediaAssets(for: ids)
        return ids.map { assets[$0]?.mediaChoice }
    }

    /// Info's Copies row lists where the item's other copies are, says none when it has
    /// none, and says not checked while its digest is owed.
    @Test func infoNamesWhereTheOtherCopiesAre() async throws {
        let fixture = try await fixture()
        let store = fixture.store
        try await apply(
            SourceListingChanges(listed: [Self.item("a1", digest: Self.digest("same")), Self.item("a2", digest: nil)]),
            to: fixture.account, store: store
        )
        let libraryCopy = id("IMG_1.JPG", in: fixture.library)
        #expect(try await store.photoInfoOverlay(for: libraryCopy)?.otherCopyRoots == [fixture.account])
        #expect(try await store.photoInfoOverlay(for: id("IMG_2.JPG", in: fixture.library))?.otherCopyRoots == [])
        #expect(try await store.photoInfoOverlay(for: id("a2/IMG_1.JPG", in: fixture.account))?.otherCopyRoots == nil)

        let names = [fixture.account: "Family", fixture.library: "Pictures"]
        #expect(PhotoInfo.copiesText([fixture.account], names: names) == "Family")
        #expect(PhotoInfo.copiesText([fixture.account, fixture.account, fixture.library], names: names) == "Family (2 copies) and Pictures")
        #expect(PhotoInfo.copiesText([], names: names) == "None")
        #expect(PhotoInfo.copiesText(nil, names: names) == "Not Checked Yet")
        await store.shutdown()
    }
}
