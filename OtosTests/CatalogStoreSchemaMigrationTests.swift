import Foundation
import GRDB
@testable import OtosKit
import Testing

struct CaptureWallClockTests {
    @Test func selectsLocalFloatingOriginalOverAbsoluteQuickTime() {
        let records = [
            CaptureTimestampRecord(
                role: "quickTimeCreation",
                instant: Date(timeIntervalSince1970: 1_700_000_000),
                utcOffsetSeconds: 0,
                precision: "absolute",
                year: 2023,
                month: 11,
                day: 14,
                hour: 22,
                minute: 13,
                second: 20
            ),
            CaptureTimestampRecord(
                role: "original",
                instant: nil,
                utcOffsetSeconds: nil,
                precision: "localFloating",
                year: 2026,
                month: 1,
                day: 1,
                hour: 12,
                minute: 0,
                second: 0
            ),
        ]

        let wall = CaptureWallClock.select(from: records)
        #expect(wall?.compact == 20_260_101_120_000)
        #expect(wall?.precision == "localFloating")
    }

    @Test func prefersOriginalOverDigitizedWhenBothLocal() {
        let records = [
            CaptureTimestampRecord(
                role: "digitized",
                instant: nil,
                utcOffsetSeconds: -25200,
                precision: "localWithOffset",
                year: 2025,
                month: 6,
                day: 1,
                hour: 8,
                minute: 0,
                second: 0
            ),
            CaptureTimestampRecord(
                role: "original",
                instant: nil,
                utcOffsetSeconds: nil,
                precision: "localFloating",
                year: 2024,
                month: 12,
                day: 25,
                hour: 15,
                minute: 30,
                second: 45
            ),
        ]

        let wall = CaptureWallClock.select(from: records)
        #expect(wall?.compact == 20_241_225_153_045)
    }

    @Test func rejectsAbsoluteOnlyCandidates() {
        let records = [
            CaptureTimestampRecord(
                role: "original",
                instant: Date(),
                utcOffsetSeconds: 0,
                precision: "absolute",
                year: 2026,
                month: 1,
                day: 1,
                hour: 0,
                minute: 0,
                second: 0
            ),
            CaptureTimestampRecord(
                role: "gps",
                instant: Date(),
                utcOffsetSeconds: 0,
                precision: "absolute",
                year: 2026,
                month: 1,
                day: 1,
                hour: 0,
                minute: 0,
                second: 0
            ),
        ]
        #expect(CaptureWallClock.select(from: records) == nil)
    }

    @Test func roundTripsCompactComponents() {
        let compact: Int64 = 20_260_101_120_000
        let components = CaptureWallClock.components(fromCompact: compact)
        #expect(components?.year == 2026)
        #expect(components?.month == 1)
        #expect(components?.day == 1)
        #expect(components?.hour == 12)
        #expect(components?.minute == 0)
        #expect(components?.second == 0)
    }
}

@Suite(.testDirectory)
struct CatalogStoreSchemaMigrationTests {
    @Test func v10FixtureWithoutDestinationProvenanceMigratesAdditively() async throws {
        let databaseURL = try await Self.makeV10FixtureWithoutDestinationProvenance()
        let store = CatalogStore(location: .databaseFile(databaseURL))
        try await store.start(scansSavedLibraries: false)

        let columns = try await Self.mediaAssetColumns(databaseURL)
        #expect(columns.contains("import_destination_byte_size"))
        #expect(columns.contains("import_destination_modified_at_epoch"))
        #expect(columns.contains("content_hash_xxh3_128"))
        #expect(columns.contains("content_hash_source_size"))
        #expect(columns.contains("content_hash_source_mtime"))
        #expect(columns.contains("media_choice"))
        #expect(try await Self.activeFileOperationColumns(databaseURL).contains("content_hash_xxh3_128"))

        let applied = try await Self.appliedMigrationIdentifiers(databaseURL)
        #expect(applied.contains("v11_import_destination_provenance"))
        #expect(applied.contains("v12_xxh3_content_hashes"))
        #expect(applied.contains("v14_media_choice"))
    }

    @Test func v5FixtureMigratesToImportHistoryAndCaptureWallWithoutErase() async throws {
        let fixture = try await Self.makeV5EnrichedFixture()
        let store = CatalogStore(location: .databaseFile(fixture.databaseURL))
        try await store.start(scansSavedLibraries: false)

        let columns = try await Self.mediaAssetColumns(fixture.databaseURL)
        #expect(columns.contains("import_batch_unix_ms"))
        #expect(columns.contains("capture_wall_compact"))
        #expect(columns.contains("capture_wall_precision"))
        #expect(columns.contains("import_source_root_path"))
        #expect(columns.contains("import_source_relative_path"))
        #expect(columns.contains("import_source_byte_size"))
        #expect(columns.contains("import_source_modified_at_epoch"))
        #expect(columns.contains("import_destination_byte_size"))
        #expect(columns.contains("import_destination_modified_at_epoch"))
        #expect(columns.contains("content_hash_xxh3_128"))
        #expect(columns.contains("content_hash_source_size"))
        #expect(columns.contains("content_hash_source_mtime"))
        #expect(columns.contains("media_choice"))

        let snapshot = try await catalogStoreTestState(store)
        #expect(snapshot.libraries.count == 1)
        #expect(snapshot.testAssets.count == 1)

        let id = try #require(snapshot.testAssets.first?.id)
        let wall = try await store.captureWall(for: id)
        #expect(wall?.compact == 20_260_426_145_735)
        #expect(wall?.precision == "localFloating")

        // Original media and any pre-existing thumbnail path stay put — no erase.
        #expect(FileManager.default.fileExists(atPath: fixture.original.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: fixture.thumbnail.path(percentEncoded: false)))
    }

    @Test func futureSchemaIsRefusedWithoutErase() async throws {
        let fixture = try await Self.makeFutureSchemaFixture()
        let store = CatalogStore(location: .databaseFile(fixture.databaseURL))

        do {
            try await store.start(scansSavedLibraries: false)
            Issue.record("Expected unsupportedCatalogSchema")
        } catch let CatalogStoreError.unsupportedCatalogSchema(problem) {
            #expect(problem == .writtenByNewerOtos)
        }

        let rootCount = try await DatabaseQueue(path: fixture.databaseURL.path(percentEncoded: false)).read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM library_root") ?? 0
        }
        #expect(rootCount == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.thumbnail.path(percentEncoded: false)))

        let applied = try await DatabaseQueue(path: fixture.databaseURL.path(percentEncoded: false)).read { db in
            try String.fetchSet(db, sql: "SELECT identifier FROM grdb_migrations")
        }
        #expect(applied.contains("v999_future_history"))
    }

    /// A refused catalog cannot say whether a persisted root is registered, so a
    /// namespace lease for that root reports the catalog, never the root, as missing.
    @Test func refusedCatalogDeniesNamespaceLeaseAsCatalogUnavailable() async throws {
        let fixture = try await Self.makeFutureSchemaFixture()
        let persistedRoot = try await DatabaseQueue(path: fixture.databaseURL.path(percentEncoded: false)).read { db in
            try String.fetchOne(db, sql: "SELECT path FROM library_root")
        }
        let store = CatalogStore(location: .databaseFile(fixture.databaseURL))

        let acquisition = try await store.acquireNamespaceMutationLease(
            for: LibraryRootPath(rawValue: #require(persistedRoot)),
            owner: .importPublication
        )

        #expect(acquisition == .catalogUnavailable)
    }

    @Test func unrecognizedLegacySchemaIsRefusedWithoutErase() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let thumbnailDirectory = databaseURL.deletingLastPathComponent()
            .appending(path: "Thumbnails", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
        let staleThumbnail = thumbnailDirectory.appending(path: "keep-me.jpg", directoryHint: .notDirectory)
        try Data("keep".utf8).write(to: staleThumbnail)

        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try await dbQueue.write { db in
            try db.execute(sql: """
            CREATE TABLE library_root (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                path TEXT NOT NULL UNIQUE
            )
            """)
            try db.execute(sql: """
            CREATE TABLE media_asset (
                library_root_id INTEGER NOT NULL,
                relative_path TEXT NOT NULL,
                PRIMARY KEY (library_root_id, relative_path)
            )
            """)
            try db.execute(sql: "INSERT INTO library_root (path) VALUES (?)", arguments: ["/tmp/legacy"])
        }

        let store = CatalogStore(location: .databaseFile(databaseURL))
        do {
            try await store.start(scansSavedLibraries: false)
            Issue.record("Expected unsupportedCatalogSchema")
        } catch let CatalogStoreError.unsupportedCatalogSchema(problem) {
            #expect(problem == .unrecognized)
        }
        #expect(FileManager.default.fileExists(atPath: staleThumbnail.path(percentEncoded: false)))
    }

    @Test func v13MigrationAddsMetadataOnlyEnrichmentClaimIndexesAndKeepsDigests() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)

        // Simulate a catalog that stopped at v12: a removable-root row carrying a valid
        // digest and current facts, no metadata-only pair, and no v13 marker.
        let removableRootID = try await dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "INSERT INTO library_root (path) VALUES (?)", arguments: ["/tmp/otos-removable"])
            let rootID = db.lastInsertedRowID
            try db.execute(
                sql: """
                INSERT INTO media_asset (
                    library_root_id, relative_path, sort_key, name_sort_key, name,
                    content_type_identifier, byte_size, content_modified_at_unix,
                    enriched_source_size, enriched_source_mtime,
                    content_hash_xxh3_128, content_hash_source_size, content_hash_source_mtime
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    rootID, "a.jpg", "a.jpg", "a.jpg", "a.jpg", "public.jpeg",
                    1, 1000, 1, 1000,
                    XXH3Digest128.empty.data, 1, 1000,
                ]
            )
            try db.drop(index: EnrichmentClaimGateway.metadataOnlyGlobalIndexName)
            try db.drop(index: EnrichmentClaimGateway.metadataOnlyRootIndexName)
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                arguments: ["v13_hash_gated_enrichment_claim_indexes"]
            )
            return rootID
        }

        try CatalogStore.migrator.migrate(dbQueue)

        let applied = try await Self.appliedMigrationIdentifiers(databaseURL)
        #expect(applied.contains("v13_hash_gated_enrichment_claim_indexes"))
        let indexNames = try await dbQueue.read { db in
            try String.fetchSet(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
        }
        #expect(indexNames.contains(EnrichmentClaimGateway.broadGlobalIndexName))
        #expect(indexNames.contains(EnrichmentClaimGateway.broadRootIndexName))
        #expect(indexNames.contains(EnrichmentClaimGateway.metadataOnlyGlobalIndexName))
        #expect(indexNames.contains(EnrichmentClaimGateway.metadataOnlyRootIndexName))

        // The pre-existing digest survives and its row is not re-claimable under the
        // metadata-only predicate the removable root now claims with.
        let persistedHash = try await dbQueue.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT content_hash_xxh3_128 FROM media_asset WHERE library_root_id = ?",
                arguments: [removableRootID]
            )
        }
        #expect(persistedHash == XXH3Digest128.empty.data)
        let metadataOnlyClaimed = try await dbQueue.write { db in
            try EnrichmentClaimGateway.fetchStoredAssetsNeedingEnrichment(
                rootIDs: [removableRootID],
                limit: 4,
                hashRequired: false,
                db: db
            )
        }
        #expect(metadataOnlyClaimed.isEmpty)
    }

    @Test func importBatchQueriesReturnNewestFirst() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "a.jpg"), contents: "a")
        try writeCatalogStoreFile(root.appending(path: "b.jpg"), contents: "b")
        try writeCatalogStoreFile(root.appending(path: "c.jpg"), contents: "c")

        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let store = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 3 }

        let older = ImportBatchID(unixMilliseconds: 1_700_000_000_000)
        let newer = ImportBatchID(unixMilliseconds: 1_800_000_000_000)
        try await Self.stampImportBatches(
            databaseURL: databaseURL,
            stamps: [
                "a.jpg": older.unixMilliseconds,
                "b.jpg": newer.unixMilliseconds,
                "c.jpg": newer.unixMilliseconds,
            ]
        )

        let batches = try await store.importBatches()
        #expect(batches.map(\.batchID) == [newer, older])
        #expect(batches.map(\.assetCount) == [2, 1])

        let newerIDs = try await store.assetIDs(inImportBatch: newer)
        #expect(Set(newerIDs.map(\.relativePath.rawValue)) == ["b.jpg", "c.jpg"])
    }

    @Test func enrichmentWritesCaptureWallCompact() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "shot.jpg"), contents: "jpeg")

        let store = CatalogStore(
            location: .databaseFile(temp.appending(path: "db/catalog.sqlite")),
            scanCadence: .milliseconds(10)
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        let id = try #require(scanned.testAssets.first?.id)

        let metadata = AssetMetadata(
            timestamps: [
                CaptureTimestampRecord(
                    role: "original",
                    instant: nil,
                    utcOffsetSeconds: -25200,
                    precision: "localWithOffset",
                    year: 2026,
                    month: 7,
                    day: 10,
                    hour: 15,
                    minute: 30,
                    second: 0
                ),
            ]
        )
        let outcome = await store.applyEnrichmentBatch([
            EnrichmentResult(
                id: id,
                metadata: metadata,
                thumbnailPath: nil,
                sourceSize: 4,
                sourceMTimeSeconds: Int(scanned.testAssets[0].contentModifiedAt?.timeIntervalSince1970 ?? 0),
                contentHash: .empty
            ),
        ])
        #expect(outcome == .applied(count: 1))

        let wall = try await store.captureWall(for: id)
        #expect(wall?.compact == 20_260_710_153_000)
        #expect(wall?.precision == "localWithOffset")
    }

    /// APP-017 disk-image backstop. A persisted removable-volume root whose path
    /// is *currently* a mounted disk image is removed; one whose path isn't
    /// currently mountable at all is left alone — the migration cannot prove
    /// it a disk image, and the overlay-lifecycle rule treats an unresolvable
    /// path as temporarily missing, not deleted (`docs/adr/0008-…`). Mounts a
    /// real disk image rather than mocking `DiskArbitration`, since the fact
    /// under test is what the system actually reports for one.
    /// A claim is a process fact: v21 renames the column for every catalog and clears the
    /// claims the last process left, whatever expiry it had written.
    @Test func v21RenamesTheClaimColumnAndClearsLeftoverClaims() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue, upTo: "v20_pending_trash")
        try await dbQueue.write { db in
            try db.execute(sql: "INSERT INTO library_root (path) VALUES (?)", arguments: ["/tmp/otos-v21"])
            try db.execute(
                sql: """
                INSERT INTO media_asset (
                    library_root_id, relative_path, sort_key, name_sort_key, name,
                    content_type_identifier, byte_size, enrichment_claimed_until
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [db.lastInsertedRowID, "a.jpg", "a.jpg", "a.jpg", "a.jpg", "public.jpeg", 1, 4_102_444_800]
            )
        }

        try CatalogStore.migrator.migrate(dbQueue)

        let (columns, claimed) = try await dbQueue.read { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(media_asset)").compactMap { $0["name"] as String? }
            let claimed = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM media_asset WHERE enrichment_claimed IS NOT NULL"
            ) ?? -1
            return (columns, claimed)
        }
        #expect(columns.contains("enrichment_claimed"))
        #expect(!columns.contains("enrichment_claimed_until"))
        #expect(claimed == 0)
    }

    @Test func v16RemovesDiskImageRemovableRootsButPreservesUnmountedOnes() async throws {
        let image = try MountedTestDiskImage.attach(named: "OtosV16MigrationTest")
        defer { image.detach() }

        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)

        let diskImagePath = try CatalogPath.normalizedDirectoryPath(for: image.mountURL).rawValue
        let unmountedPath = "/Volumes/OtosNeverMounted-\(UUID().uuidString)"
        try await dbQueue.writeWithoutTransaction { db in
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                arguments: ["v16_remove_disk_image_removable_roots"]
            )
            try db.execute(
                sql: """
                INSERT INTO library_root (path, kind, device_identity, display_name)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [
                    diskImagePath, LibraryRootKind.removableVolume.rawValue,
                    "volume:disk-image-test", "OtosV16MigrationTest",
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO library_root (path, kind, device_identity, display_name)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [
                    unmountedPath, LibraryRootKind.removableVolume.rawValue,
                    "volume:unmounted-test", "NeverMounted",
                ]
            )
        }

        let store = CatalogStore(location: .databaseFile(databaseURL))
        try await store.start(scansSavedLibraries: false)

        let remainingPaths = try await dbQueue.read { db in
            try Set(String.fetchAll(
                db,
                sql: "SELECT path FROM library_root WHERE kind = ?",
                arguments: [LibraryRootKind.removableVolume.rawValue]
            ))
        }
        #expect(!remainingPaths.contains(diskImagePath), "The disk image root must be removed")
        #expect(
            remainingPaths.contains(unmountedPath),
            "An unmounted root must be left alone — it cannot be proven a disk image"
        )
    }
}

private extension CatalogStoreSchemaMigrationTests {
    static func activeFileOperationColumns(_ databaseURL: URL) async throws -> Set<String> {
        try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).read { db in
            try String.fetchSet(db, sql: "SELECT name FROM pragma_table_xinfo('active_file_operation')")
        }
    }

    static func makeV10FixtureWithoutDestinationProvenance() async throws -> URL {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        try await dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "ALTER TABLE media_asset DROP COLUMN import_destination_byte_size")
            try db.execute(sql: "ALTER TABLE media_asset DROP COLUMN import_destination_modified_at_epoch")
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                arguments: ["v11_import_destination_provenance"]
            )
        }
        return databaseURL
    }

    struct V5Fixture {
        let databaseURL: URL
        let original: URL
        let thumbnail: URL
    }

    struct FutureFixture {
        let databaseURL: URL
        let thumbnail: URL
    }

    static func makeV5EnrichedFixture() async throws -> V5Fixture {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appending(path: "dated.jpg", directoryHint: .notDirectory)
        try writeCatalogStoreFile(original, contents: "jpeg")

        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let thumbnailDirectory = databaseURL.deletingLastPathComponent()
            .appending(path: "Thumbnails", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
        let thumbnail = thumbnailDirectory.appending(path: "dated.jpg", directoryHint: .notDirectory)
        try Data("thumb".utf8).write(to: thumbnail)

        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try migrateThroughV5(dbQueue)
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO library_root (path, kind, device_identity, display_name, last_seen_at)
                VALUES (?, ?, NULL, NULL, NULL)
                """,
                arguments: [rootPath.rawValue, LibraryRootKind.library.rawValue]
            )
            let rootID = db.lastInsertedRowID
            let relative = "dated.jpg"
            try db.execute(
                sql: """
                INSERT INTO media_asset (
                    library_root_id, relative_path, sort_key, name_sort_key, name,
                    content_type_identifier, kind, format, byte_size,
                    created_at_unix, content_modified_at_unix, thumbnail_path,
                    enriched_source_size, enriched_source_mtime
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    rootID,
                    relative,
                    MediaSortKey.make(
                        libraryRootPath: rootPath,
                        relativePath: MediaRelativePath(rawValue: relative)
                    ),
                    MediaSortKey.naturalKey(relative),
                    relative,
                    "public.jpeg",
                    "image",
                    "jpg",
                    4,
                    Date().timeIntervalSince1970,
                    Date().timeIntervalSince1970,
                    "dated.jpg",
                    4,
                    Int(Date().timeIntervalSince1970),
                ]
            )
            let metadata = AssetMetadata(
                timestamps: [
                    CaptureTimestampRecord(
                        role: "original",
                        instant: nil,
                        utcOffsetSeconds: nil,
                        precision: "localFloating",
                        year: 2026,
                        month: 4,
                        day: 26,
                        hour: 14,
                        minute: 57,
                        second: 35
                    ),
                ]
            )
            let json = try #require(CatalogStore.encodeMetadataExtraJSON(metadata))
            try db.execute(
                sql: """
                INSERT INTO asset_metadata (library_root_id, relative_path, metadata_extra_json)
                VALUES (?, ?, ?)
                """,
                arguments: [rootID, relative, json]
            )
        }
        return V5Fixture(databaseURL: databaseURL, original: original, thumbnail: thumbnail)
    }

    static func makeFutureSchemaFixture() async throws -> FutureFixture {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let thumbnailDirectory = databaseURL.deletingLastPathComponent()
            .appending(path: "Thumbnails", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
        let thumbnail = thumbnailDirectory.appending(path: "future.jpg", directoryHint: .notDirectory)
        try Data("future".utf8).write(to: thumbnail)

        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try migrateThroughV5(dbQueue)
        try await dbQueue.write { db in
            try db.execute(sql: "INSERT INTO library_root (path) VALUES (?)", arguments: ["/tmp/future"])
            try db.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                arguments: ["v999_future_history"]
            )
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS future_only_table (
                id INTEGER PRIMARY KEY
            )
            """)
            try db.execute(
                sql: """
                INSERT INTO media_asset (
                    library_root_id, relative_path, sort_key, name_sort_key, name
                ) VALUES (1, 'kept.jpg', 'k', 'kept.jpg', 'kept.jpg')
                """
            )
        }
        return FutureFixture(databaseURL: databaseURL, thumbnail: thumbnail)
    }

    static func migrateThroughV5(_ dbQueue: DatabaseQueue) throws {
        try createV5SchemaMatchingProduction(dbQueue)
    }

    static func createV5SchemaMatchingProduction(_ dbQueue: DatabaseQueue) throws {
        try CatalogStore.migrator.migrate(dbQueue)
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?", arguments: [
                "v7_media_companion",
            ])
            try db.execute(sql: "DROP TABLE IF EXISTS media_companion")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?", arguments: [
                "v6_import_history_and_capture_wall",
            ])
            try db.execute(sql: "DROP INDEX IF EXISTS idx_media_asset_import_batch")
            try db.execute(sql: "ALTER TABLE media_asset DROP COLUMN import_batch_unix_ms")
            try db.execute(sql: "ALTER TABLE media_asset DROP COLUMN capture_wall_compact")
            try db.execute(sql: "ALTER TABLE media_asset DROP COLUMN capture_wall_precision")
        }
    }

    static func mediaAssetColumns(_ databaseURL: URL) async throws -> Set<String> {
        try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).read { db in
            try Set(String.fetchAll(db, sql: "SELECT name FROM pragma_table_xinfo('media_asset')"))
        }
    }

    static func appliedMigrationIdentifiers(_ databaseURL: URL) async throws -> Set<String> {
        try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).read { db in
            try Set(String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"))
        }
    }

    static func stampImportBatches(databaseURL: URL, stamps: [String: Int64]) async throws {
        try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).write { db in
            for (relativePath, batch) in stamps {
                try db.execute(
                    sql: """
                    UPDATE media_asset
                    SET import_batch_unix_ms = ?
                    WHERE relative_path = ?
                    """,
                    arguments: [batch, relativePath]
                )
            }
        }
    }
}
