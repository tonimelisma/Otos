import Foundation
import GRDB
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

    private func addAccount(_ store: CatalogStore) async throws -> LibraryRootPath {
        try await store.addImmichAccount(
            server: Self.server, userID: "user-1", displayName: "Family"
        )
    }

    /// Lists `names` as the server would, each under its own asset folder.
    private func list(
        _ names: [String],
        into rootPath: LibraryRootPath,
        store: CatalogStore,
        byteSize: Int64 = 42
    ) async throws {
        let scan = try await store.beginSourceListing(rootPath: rootPath)
        let files = names.map { name in
            ScannedMediaFile(
                relativePath: MediaRelativePath(rawValue: "asset-\(name)/\(name)"),
                name: name,
                contentTypeIdentifier: "public.jpeg",
                byteSize: byteSize,
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
        let store = try CatalogStore(
            location: .inMemory, scanCadence: .milliseconds(10), stagingContainers: StagingContainers(base: makeTestDirectory())
        )
        try await store.start(scansSavedLibraries: false)
        let rootPath = try await addAccount(store)
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
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10), stagingContainers: StagingContainers(base: temp))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: folder)
        let library = try CatalogPath.normalizedDirectoryPath(for: folder)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        let rootPath = try await addAccount(store)
        try await list(["IMG_1.JPG"], into: rootPath, store: store)

        let digest = try #require(XXH3Digest128(data: Data(repeating: 1, count: 16)))
        let libraryMedia = try #require(await store.planningMedia(for: library))
        let media = try libraryMedia + #require(await store.planningMedia(for: rootPath))
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
        // ADR 0046 §8: the account's copy is never moved to the Trash, and its asset folder
        // is no folder of the user's.
        let accountCopy = try #require(copies.first { $0.copy.id.libraryRootPath == rootPath }?.copy)
        #expect(!accountCopy.canMoveToTrash)
        #expect(accountCopy.folder.isEmpty)
        #expect(copies.first { $0.copy.id.libraryRootPath == library }?.copy.canMoveToTrash == true)
        await store.shutdown()
    }

    /// ADR 0042, ADR 0046 §7: a signature names the pipeline that drew its thumbnail. A
    /// changed file's new Immich images land at the same path and still make the old
    /// signature stale, and Otos's rendering moves the still to Otos's pipeline.
    @Test func aSignatureFollowsTheSourceImagesAndTheRenderingThatReplacesThem() async throws {
        let store = try CatalogStore(
            location: .inMemory, scanCadence: .milliseconds(10), stagingContainers: StagingContainers(base: makeTestDirectory())
        )
        try await store.start(scansSavedLibraries: false)
        let rootPath = try await addAccount(store)
        try await list(["IMG_1.JPG"], into: rootPath, store: store)
        let still = id("IMG_1.JPG", in: rootPath)
        let signature = try #require(RenderSignature(
            differenceHash: 7, gray: [UInt8](repeating: 90, count: RenderSignature.grayEdge * RenderSignature.grayEdge)
        ))

        func applySourceImages(size: Int64) async {
            _ = await store.applyEnrichmentBatch([EnrichmentResult(
                id: still,
                metadata: nil,
                rendering: EnrichedRendering(thumbnailPath: "thumb.jpg", previewPath: "preview.jpg", origin: .source),
                sourceSize: size,
                sourceMTimeSeconds: 1_700_000_000,
                contentHash: nil
            )])
        }
        func signRead() async throws -> Int {
            let candidates = try await store.renderSignatureCandidates(limit: 10)
            return try await store.applyRenderSignatures(candidates.map {
                RenderSignatureResult(id: $0.id, source: $0.source, signature: signature)
            })
        }
        func drawnBy() async throws -> [EnrichedRendering.Origin] {
            try await store.samePhotoCandidates(availableLibraryPaths: [rootPath]).map(\.drawnBy)
        }

        await applySourceImages(size: 42)
        #expect(try await signRead() == 1)
        #expect(try await drawnBy() == [.source])
        #expect(try await store.renderSignatureCandidates(limit: 10).isEmpty)

        try await list(["IMG_1.JPG"], into: rootPath, store: store, byteSize: 43)
        await applySourceImages(size: 43)
        #expect(try await store.renderSignatureCandidates(limit: 10).map(\.id) == [still])
        #expect(try await signRead() == 1)

        _ = await store.applyEnrichmentBatch([EnrichmentResult(
            id: still,
            metadata: nil,
            rendering: EnrichedRendering(thumbnailPath: "thumb.jpg", previewPath: "preview.jpg"),
            sourceSize: 43,
            sourceMTimeSeconds: 1_700_000_000,
            contentHash: nil
        )])
        #expect(try await store.renderSignatureCandidates(limit: 10).map(\.id) == [still])
        #expect(try await signRead() == 1)
        #expect(try await drawnBy() == [.otos])
        await store.shutdown()
    }

    /// ADR 0046 §6: a launch that reaches no server shows the account's rows from the
    /// catalog — nothing lists them again first.
    @Test func aRelaunchShowsTheAccountsRowsBeforeAnyServerAnswers() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "Catalog.sqlite")
        let containers = StagingContainers(base: temp)
        let first = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10), stagingContainers: containers)
        try await first.start(scansSavedLibraries: false)
        let rootPath = try await addAccount(first)
        try await list(["IMG_1.JPG"], into: rootPath, store: first)
        await first.shutdown()

        let relaunched = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10), stagingContainers: containers)
        try await relaunched.start(scansSavedLibraries: true)
        let account = try #require(await relaunched.currentLibraries().first { $0.path == rootPath })
        #expect(account.isAvailable)
        #expect(account.root.remoteBaseURL == Self.server)
        #expect(try await allMedia(relaunched) == [id("IMG_1.JPG", in: rootPath)])
        await relaunched.shutdown()
    }

    /// One server typed two ways is one account; another user on it is another.
    @Test func theSameAccountAddedAgainIsTheSameRoot() async throws {
        let store = try CatalogStore(
            location: .inMemory, scanCadence: .milliseconds(10), stagingContainers: StagingContainers(base: makeTestDirectory())
        )
        try await store.start(scansSavedLibraries: false)
        let rootPath = try await addAccount(store)
        let again = try await store.addImmichAccount(
            server: #require(URL(string: "HTTPS://Photos.Example.com:443/")),
            userID: "user-1", displayName: "Family"
        )
        let other = try await store.addImmichAccount(
            server: Self.server, userID: "user-2", displayName: "Partner"
        )
        #expect(again == rootPath)
        #expect(other != rootPath)
        await #expect(throws: CatalogStoreError.invalidRemoteServer) {
            try await store.addImmichAccount(
                server: #require(URL(string: "ftp://photos.example.com")),
                userID: "user-1", displayName: "Family"
            )
        }
        await store.shutdown()
    }

    /// Removing an account deletes its rows and its staging folder; nothing on the server
    /// is touched, because Otos never writes to it.
    @Test func removingAnAccountDeletesItsRowsAndStaging() async throws {
        let store = try CatalogStore(
            location: .inMemory, scanCadence: .milliseconds(10), stagingContainers: StagingContainers(base: makeTestDirectory())
        )
        try await store.start(scansSavedLibraries: false)
        let rootPath = try await addAccount(store)
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

extension ImmichAccountCatalogTests {
    /// ADR 0046 §2: an account's root is at the path this build's staging containers name for
    /// its identity, whatever path the catalog stored. A root stored elsewhere — by another
    /// build, or before the containers were named by bundle identifier — moves at launch into
    /// this build's own container, and keeps every overlay its assets hold: the user's choice,
    /// an edit, a face and its person, a search reading and text, derived images, and an
    /// erase journaled against the old path. Nothing on disk is touched: the old folder stays
    /// for its own build to sweep, and no row is deleted.
    @Test func anAccountStoredOutsideThisBuildsContainerMovesIntoItWithEveryOverlay() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/Catalog.sqlite")
        let elsewhere = StagingContainers(base: temp.appending(path: "Shared", directoryHint: .isDirectory))
        let own = StagingContainers(base: temp.appending(path: "Own", directoryHint: .isDirectory))
        let first = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10), stagingContainers: elsewhere)
        try await first.start(scansSavedLibraries: false)
        let oldPath = try await addAccount(first)
        try await list(["IMG_1.JPG"], into: oldPath, store: first)
        let identity = try #require(await first.currentLibraries().first { $0.path == oldPath }?.root.deviceIdentity)
        let oldID = id("IMG_1.JPG", in: oldPath)
        _ = try await first.setMediaChoice(.liked, for: [oldID])
        let thumbnails = try #require(first.thumbnailDirectory)
        await first.shutdown()

        // The overlay a used account holds, keyed by the root's row and the asset's path.
        let relativePath = oldID.relativePath.rawValue
        let thumbnailName = ThumbnailStore.relativeName(for: oldID)
        try FileManager.default.createDirectory(
            at: thumbnails.appending(path: thumbnailName).deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("thumb".utf8).write(to: thumbnails.appending(path: thumbnailName))
        let queue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        let rootID = try await queue.write { db -> Int64 in
            let rootID = try #require(try Int64.fetchOne(db, sql: "SELECT id FROM library_root WHERE path = ?", arguments: [oldPath.rawValue]))
            try db.execute(
                sql: "UPDATE media_asset SET edit_recipe_json = '{}', edit_revision = 1, thumbnail_path = ? WHERE library_root_id = ? AND relative_path = ?",
                arguments: [thumbnailName, rootID, relativePath]
            )
            try db.execute(sql: "INSERT INTO person (name) VALUES ('Sam')")
            let person = db.lastInsertedRowID
            try db.execute(
                sql: """
                INSERT INTO face (library_root_id, relative_path, face_index, box_x, box_y, box_width, box_height,
                                  landmarks, quality, analysis_revision, embedding, person_id)
                VALUES (?, ?, 0, 0.1, 0.1, 0.2, 0.2, x'00', 0.9, 1, x'00', ?)
                """,
                arguments: [rootID, relativePath, person]
            )
            try db.execute(
                sql: "INSERT INTO search_embedding (library_root_id, relative_path, source, embedding) VALUES (?, ?, 'preview', x'00')",
                arguments: [rootID, relativePath]
            )
            try db.execute(
                sql: "INSERT INTO search_text (library_root_id, relative_path, source, lines) VALUES (?, ?, 'preview', 'beach')",
                arguments: [rootID, relativePath]
            )
            try db.execute(
                sql: """
                INSERT INTO active_source_erase (operation_key, source_kind, source_device_identity, source_root_path,
                                                 source_relative_path, source_byte_size, updated_at)
                VALUES ('erase-1', 'immichAccount', ?, ?, ?, 42, 0)
                """,
                arguments: [identity.rawValue, oldPath.rawValue, relativePath]
            )
            return rootID
        }
        try queue.close()

        let relaunched = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10), stagingContainers: own)
        try await relaunched.start(scansSavedLibraries: false)
        let newPath = try CatalogPath.normalizedDirectoryPath(for: own.sessionRoot(in: .remote, identity: identity))
        let roots = await relaunched.currentLibraries().filter { $0.kind == .immichAccount }
        let newID = id("IMG_1.JPG", in: newPath)
        let asset = try await relaunched.mediaAssets(for: [newID])[newID]
        let shown = try await allMedia(relaunched)
        await relaunched.shutdown()

        #expect(newPath != oldPath)
        #expect(roots.map(\.path) == [newPath])
        #expect(shown == [newID])
        #expect(asset?.mediaChoice == .liked)
        let reader = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        let kept = try await reader.read { db in
            let asset: StatementArguments = [rootID, relativePath]
            func count(_ table: String, _ condition: String = "") throws -> Int? {
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM \(table) WHERE library_root_id = ? AND relative_path = ?\(condition)", arguments: asset
                )
            }
            return try (
                rootID: Int64.fetchOne(db, sql: "SELECT id FROM library_root WHERE path = ?", arguments: [newPath.rawValue]),
                edit: Int.fetchOne(
                    db, sql: "SELECT edit_revision FROM media_asset WHERE library_root_id = ? AND relative_path = ?", arguments: asset
                ),
                thumbnail: String.fetchOne(
                    db, sql: "SELECT thumbnail_path FROM media_asset WHERE library_root_id = ? AND relative_path = ?", arguments: asset
                ),
                faces: count("face", " AND person_id IS NOT NULL"),
                readings: count("search_embedding"),
                texts: count("search_text"),
                erase: String.fetchOne(db, sql: "SELECT source_root_path FROM active_source_erase WHERE operation_key = 'erase-1'")
            )
        }
        try reader.close()
        #expect(kept.rootID == rootID)
        #expect(kept.edit == 1)
        #expect(kept.faces == 1)
        #expect(kept.readings == 1)
        #expect(kept.texts == 1)
        #expect(kept.erase == newPath.rawValue)
        // The derived image follows the asset's new identity.
        #expect(kept.thumbnail == ThumbnailStore.relativeName(for: newID))
        #expect(FileManager.default.fileExists(atPath: thumbnails.appending(path: ThumbnailStore.relativeName(for: newID)).path(percentEncoded: false)))
        // Nothing on disk moved or was deleted: the old folder is its own build's.
        #expect(FileManager.default.fileExists(atPath: oldPath.url.path(percentEncoded: false)))
    }
}
