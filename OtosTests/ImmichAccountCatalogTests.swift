import Foundation
@testable import OtosKit
import Testing

/// ADR 0046 §2, §3, §6: an Immich account is a library whose rows come from its server's
/// listing. These tests drive that listing by hand, as the sync will: the account sits in
/// the Libraries section, its rows are in All Media, Places and Duplicates, and a launch
/// with no server shows them from the catalog alone.
@Suite(.testDirectory)
struct ImmichAccountCatalogTests {
    private static let server = URL(string: "https://photos.example.com")!
    private static let helsinki = PlaceCoordinate(latitude: 60.17, longitude: 24.94)

    private func addAccount(_ store: CatalogStore, staging: URL) async throws -> LibraryRootPath {
        try await store.addImmichAccount(
            server: Self.server, userID: "user-1", displayName: "Family", stagingContainer: staging
        )
    }

    /// Lists `names` as the server would, each under its own asset folder.
    private func list(_ names: [String], into rootPath: LibraryRootPath, store: CatalogStore) async throws {
        let scan = try await store.beginSourceListing(rootPath: rootPath)
        let files = names.map { name in
            ScannedMediaFile(
                relativePath: MediaRelativePath(rawValue: "asset-\(name)/\(name)"),
                name: name,
                contentTypeIdentifier: "public.jpeg",
                byteSize: 42,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                contentModifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }
        try await store.recordSourceListingBatch(files, scan: scan)
        try await store.completeSourceListing(scan: scan, observedPaths: Set(files.map(\.relativePath)))
    }

    private func id(_ name: String, in rootPath: LibraryRootPath) -> MediaAssetID {
        MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: "asset-\(name)/\(name)"))
    }

    private func allMedia(_ store: CatalogStore) async throws -> [MediaAssetID] {
        let available = await CatalogWindowPolicy.availablePaths(from: store.currentLibraries())
        return try await store.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: .allMedia), availableLibraryPaths: available
        ).ids
    }

    @Test func anAccountIsALibraryWhoseListedRowsAreInAllMediaAndPlaces() async throws {
        let staging = try makeTestDirectory().appending(path: "RemoteStaging", directoryHint: .isDirectory)
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        let rootPath = try await addAccount(store, staging: staging)
        try await list(["IMG_1.JPG", "IMG_2.JPG"], into: rootPath, store: store)

        let account = try #require(await store.currentLibraries().first { $0.path == rootPath })
        #expect(account.kind == .immichAccount)
        #expect(account.isAvailable)
        #expect(account.root.remoteBaseURL == Self.server)
        #expect(account.root.locationDescription == "https://photos.example.com")
        #expect(CatalogWindowPolicy.sourceRows(from: [account]).libraries.map(\.path) == [rootPath])
        #expect(try await Set(allMedia(store)) == [id("IMG_1.JPG", in: rootPath), id("IMG_2.JPG", in: rootPath)])

        let located = id("IMG_1.JPG", in: rootPath)
        var metadata = AssetMetadata.absoluteCapture(instant: Date(timeIntervalSince1970: 1_700_000_000))
        metadata.locations = [
            GeoRecord(
                source: "exifGPS",
                latitude: Self.helsinki.latitude,
                longitude: Self.helsinki.longitude,
                altitudeMeters: nil
            ),
        ]
        _ = await store.applyEnrichmentBatch([
            EnrichmentResult(
                id: located,
                metadata: metadata,
                thumbnailPath: nil,
                sourceSize: 42,
                sourceMTimeSeconds: 1_700_000_000,
                contentHash: .empty
            ),
        ])
        let places = try await store.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: .places, sort: .dateNewest), availableLibraryPaths: [rootPath]
        )
        #expect(places.ids == [located])
        await store.shutdown()
    }

    /// Duplicates spans accounts like libraries: an account's copy of a library photo with
    /// the same digest is one group.
    @Test func anAccountsCopyOfALibraryPhotoIsADuplicate() async throws {
        let temp = try makeTestDirectory()
        let folder = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeCatalogStoreFile(folder.appending(path: "IMG_1.JPG"), contents: "same")
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: folder)
        let library = try CatalogPath.normalizedDirectoryPath(for: folder)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        let rootPath = try await addAccount(store, staging: temp.appending(path: "RemoteStaging"))
        try await list(["IMG_1.JPG"], into: rootPath, store: store)

        let digest = try #require(XXH3Digest128(data: Data(repeating: 1, count: 16)))
        let media = try #require(await store.planningMedia(for: library)) + #require(await store.planningMedia(for: rootPath))
        for facts in media {
            _ = try await store.applyContentHash(ContentHashResult(
                id: facts.id,
                contentHash: digest,
                sourceSize: facts.byteSize,
                sourceMTimeSeconds: facts.contentModifiedAt.map { Int($0.timeIntervalSince1970.rounded(.down)) }
            ))
        }

        let available = await CatalogWindowPolicy.availablePaths(from: store.currentLibraries())
        let copies = try await store.duplicateCopies(availableLibraryPaths: available).copies
        #expect(Set(copies.map(\.copy.id.libraryRootPath)) == [library, rootPath])
        await store.shutdown()
    }

    /// ADR 0046 §6: a launch that reaches no server shows the account's rows from the
    /// catalog — nothing lists them again first.
    @Test func aRelaunchShowsTheAccountsRowsBeforeAnyServerAnswers() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "Catalog.sqlite")
        let staging = temp.appending(path: "RemoteStaging", directoryHint: .isDirectory)
        let first = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await first.start(scansSavedLibraries: false)
        let rootPath = try await addAccount(first, staging: staging)
        try await list(["IMG_1.JPG"], into: rootPath, store: first)
        await first.shutdown()

        let relaunched = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await relaunched.start(scansSavedLibraries: true)
        let account = try #require(await relaunched.currentLibraries().first { $0.path == rootPath })
        #expect(account.isAvailable)
        #expect(account.root.remoteBaseURL == Self.server)
        #expect(try await allMedia(relaunched) == [id("IMG_1.JPG", in: rootPath)])
        await relaunched.shutdown()
    }

    /// One server typed two ways is one account; another user on it is another.
    @Test func theSameAccountAddedAgainIsTheSameRoot() async throws {
        let staging = try makeTestDirectory().appending(path: "RemoteStaging", directoryHint: .isDirectory)
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        let rootPath = try await addAccount(store, staging: staging)
        let again = try await store.addImmichAccount(
            server: #require(URL(string: "HTTPS://Photos.Example.com:443/")),
            userID: "user-1", displayName: "Family", stagingContainer: staging
        )
        let other = try await store.addImmichAccount(
            server: Self.server, userID: "user-2", displayName: "Partner", stagingContainer: staging
        )
        #expect(again == rootPath)
        #expect(other != rootPath)
        await #expect(throws: CatalogStoreError.invalidRemoteServer) {
            try await store.addImmichAccount(
                server: #require(URL(string: "ftp://photos.example.com")),
                userID: "user-1", displayName: "Family", stagingContainer: staging
            )
        }
        await store.shutdown()
    }

    /// Removing an account deletes its rows and its staging folder; nothing on the server
    /// is touched, because Otos never writes to it.
    @Test func removingAnAccountDeletesItsRowsAndStaging() async throws {
        let staging = try makeTestDirectory().appending(path: "RemoteStaging", directoryHint: .isDirectory)
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        let rootPath = try await addAccount(store, staging: staging)
        try await list(["IMG_1.JPG"], into: rootPath, store: store)
        #expect(FileManager.default.fileExists(atPath: rootPath.url.path(percentEncoded: false)))

        #expect(try await store.removeLibrary(path: rootPath) == .removed)
        #expect(await store.currentLibraries().isEmpty)
        #expect(try await allMedia(store).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: rootPath.url.path(percentEncoded: false)))
        await store.shutdown()
    }

    @Test func aServerAddressIsNormalizedToOneName() throws {
        let cases: [(String, String?)] = [
            ("https://photos.example.com", "https://photos.example.com"),
            ("HTTPS://Photos.Example.com:443/", "https://photos.example.com"),
            ("http://nas.local:2283/", "http://nas.local:2283"),
            ("http://nas.local:80/immich/?x=1#y", "http://nas.local/immich"),
            ("ftp://nas.local", nil),
            ("nas.local", nil),
        ]
        for (input, expected) in cases {
            let url = try #require(URL(string: input))
            #expect(ImmichServerAddress.normalized(url)?.absoluteString == expected, "\(input)")
        }
    }
}
