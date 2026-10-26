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
    /// ARC-043: a fresh catalog is the baseline schema plus the additive migrations after it.
    @Test func aNewCatalogIsTheBaselineSchemaPlusItsMigrations() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let store = CatalogStore(location: .databaseFile(databaseURL))
        try await store.start(scansSavedLibraries: false)
        await store.shutdown()

        let (applied, tables) = try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).read { db in
            let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            let tables = try String.fetchSet(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
            )
            return (applied, tables)
        }
        #expect(applied == [
            CatalogSchema.baselineMigrationIdentifier, CatalogSchema.fileIdentifierMigrationIdentifier,
            CatalogSchema.previewPathMigrationIdentifier, CatalogSchema.editRecipeMigrationIdentifier,
            CatalogSchema.heifOrientationMigrationIdentifier,
        ])
        #expect(tables == [
            "grdb_migrations", "library_root", "media_asset", "asset_metadata", "media_companion",
            "active_file_operation", "active_file_operation_companion_staging", "active_source_erase",
            "active_reorganization_component", "active_reorganization_member",
            "active_reorganization_step", "active_reorganization_directory",
            "pending_identity_remap_batch", "pending_identity_remap",
        ])
    }

    /// ARC-043: a catalog whose migration history this build does not know — one a newer
    /// Otos wrote, or one from before the schema baseline — is refused unopened, and
    /// nothing in it or beside it is erased.
    @Test(arguments: ["v999_future_history", "v21_enrichment_claim_is_a_process_fact"])
    func aCatalogWithUnknownHistoryIsRefusedWithoutErase(identifier: String) async throws {
        let fixture = try await Self.makeUnknownHistoryFixture(identifier: identifier)
        let store = CatalogStore(location: .databaseFile(fixture.databaseURL))

        do {
            try await store.start(scansSavedLibraries: false)
            Issue.record("Expected unsupportedCatalogSchema")
        } catch let CatalogStoreError.unsupportedCatalogSchema(problem) {
            #expect(problem == .writtenByOtherOtos)
        }

        let reader = try DatabaseQueue(path: fixture.databaseURL.path(percentEncoded: false))
        let (rootCount, applied) = try await reader.read { db in
            let rootCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM library_root") ?? 0
            let applied = try String.fetchSet(db, sql: "SELECT identifier FROM grdb_migrations")
            return (rootCount, applied)
        }
        #expect(rootCount == 1)
        #expect(applied.contains(identifier))
        #expect(FileManager.default.fileExists(atPath: fixture.thumbnail.path(percentEncoded: false)))
    }

    /// A refused catalog cannot say whether a persisted root is registered, so a
    /// namespace lease for that root reports the catalog, never the root, as missing.
    /// ARC-043: a catalog written at the baseline opens through the additive
    /// `file_identifier` migration and keeps its rows.
    @Test func aBaselineCatalogGainsTheFileIdentifierColumnAndKeepsItsRows() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).write { db in
            for statement in CatalogSchema.baselineStatements {
                try db.execute(sql: statement)
            }
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            try db.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                arguments: [CatalogSchema.baselineMigrationIdentifier]
            )
            try db.execute(sql: "INSERT INTO library_root (path, kind) VALUES ('/Pictures', 'library')")
            try db.execute(sql: """
            INSERT INTO media_asset (library_root_id, relative_path, relative_path_key, sort_key, name_sort_key)
            VALUES (1, 'a.jpg', 'a.jpg', 'a.jpg', 'a.jpg')
            """)
        }

        let store = CatalogStore(location: .databaseFile(databaseURL))
        try await store.start(scansSavedLibraries: false)
        await store.shutdown()

        let (applied, columns, rows) = try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).read { db in
            try (
                String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"),
                Set(String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('media_asset')")),
                Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_asset") ?? 0
            )
        }
        #expect(applied == [
            CatalogSchema.baselineMigrationIdentifier, CatalogSchema.fileIdentifierMigrationIdentifier,
            CatalogSchema.previewPathMigrationIdentifier, CatalogSchema.editRecipeMigrationIdentifier,
            CatalogSchema.heifOrientationMigrationIdentifier,
        ])
        #expect(columns.contains("file_identifier"))
        #expect(rows == 1)
    }

    /// ADR 0035 backfill: the preview migration clears the enrichment stamps of library
    /// stills — so they re-enrich and gain a rendered thumbnail and preview — and leaves
    /// videos and card rows stamped.
    @Test func thePreviewMigrationReEnrichesLibraryStillsOnly() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).write { db in
            for statement in CatalogSchema.baselineStatements + CatalogSchema.fileIdentifierStatements {
                try db.execute(sql: statement)
            }
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            for identifier in [CatalogSchema.baselineMigrationIdentifier, CatalogSchema.fileIdentifierMigrationIdentifier] {
                try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [identifier])
            }
            try db.execute(sql: "INSERT INTO library_root (id, path, kind) VALUES (1, '/Pictures', 'library')")
            try db.execute(sql: "INSERT INTO library_root (id, path, kind) VALUES (2, '/Volumes/Card', 'removableVolume')")
            for (root, path, kind) in [(1, "still.jpg", "image"), (1, "clip.mov", "video"), (2, "card.jpg", "image")] {
                try db.execute(
                    sql: """
                    INSERT INTO media_asset (library_root_id, relative_path, relative_path_key, sort_key,
                        name_sort_key, kind, enriched_source_size, enriched_source_mtime)
                    VALUES (?, ?, ?, ?, ?, ?, 10, 20)
                    """,
                    arguments: [root, path, path, path, path, kind]
                )
            }
        }

        let store = CatalogStore(location: .databaseFile(databaseURL))
        try await store.start(scansSavedLibraries: false)
        await store.shutdown()

        let stamped = try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).read { db in
            try Set(String.fetchAll(
                db, sql: "SELECT relative_path FROM media_asset WHERE enriched_source_size IS NOT NULL"
            ))
        }
        #expect(stamped == ["clip.mov", "card.jpg"])
    }

    /// A HEIF rotated by its `irot` property was cataloged with no orientation before
    /// MediaMetadata 0.6.1. The migration clears the enrichment stamps of library HEIF
    /// rows with no orientation, so they re-enrich and read it anew, and leaves HEIFs
    /// that have one, other formats and card rows stamped.
    @Test func theHeifOrientationMigrationReReadsLibraryHeifsWithoutOrientationOnly() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let earlier = [
            CatalogSchema.baselineMigrationIdentifier, CatalogSchema.fileIdentifierMigrationIdentifier,
            CatalogSchema.previewPathMigrationIdentifier, CatalogSchema.editRecipeMigrationIdentifier,
        ]
        try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).write { db in
            let statements = CatalogSchema.baselineStatements + CatalogSchema.fileIdentifierStatements
                + CatalogSchema.previewPathStatements + CatalogSchema.editRecipeStatements
            for statement in statements {
                try db.execute(sql: statement)
            }
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            for identifier in earlier {
                try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [identifier])
            }
            try db.execute(sql: "INSERT INTO library_root (id, path, kind) VALUES (1, '/Pictures', 'library')")
            try db.execute(sql: "INSERT INTO library_root (id, path, kind) VALUES (2, '/Volumes/Card', 'removableVolume')")
            struct Row {
                let root: Int
                let path: String
                let family: String
                let orientation: Int?
            }
            let rows = [
                Row(root: 1, path: "turned.heif", family: "heif", orientation: nil),
                Row(root: 1, path: "tagged.heic", family: "heif", orientation: 6),
                Row(root: 1, path: "plain.jpg", family: "jpeg", orientation: nil),
                Row(root: 2, path: "card.heif", family: "heif", orientation: nil),
            ]
            for row in rows {
                try db.execute(
                    sql: """
                    INSERT INTO media_asset (library_root_id, relative_path, relative_path_key, sort_key,
                        name_sort_key, kind, enriched_source_size, enriched_source_mtime)
                    VALUES (?, ?, ?, ?, ?, 'image', 10, 20)
                    """,
                    arguments: [row.root, row.path, row.path, row.path, row.path]
                )
                try db.execute(
                    sql: """
                    INSERT INTO asset_metadata (library_root_id, relative_path, family, orientation)
                    VALUES (?, ?, ?, ?)
                    """,
                    arguments: [row.root, row.path, row.family, row.orientation]
                )
            }
        }

        let store = CatalogStore(location: .databaseFile(databaseURL))
        try await store.start(scansSavedLibraries: false)
        await store.shutdown()

        let stamped = try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).read { db in
            try Set(String.fetchAll(
                db, sql: "SELECT relative_path FROM media_asset WHERE enriched_source_size IS NOT NULL"
            ))
        }
        #expect(stamped == ["tagged.heic", "plain.jpg", "card.heif"])
    }

    @Test func refusedCatalogDeniesNamespaceLeaseAsCatalogUnavailable() async throws {
        let fixture = try await Self.makeUnknownHistoryFixture(identifier: "v999_future_history")
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
}

private extension CatalogStoreSchemaMigrationTests {
    struct UnknownHistoryFixture {
        let databaseURL: URL
        let thumbnail: URL
    }

    /// A baseline catalog with one library and one asset whose migration record also
    /// names `identifier`, which this build does not register, beside a thumbnail.
    static func makeUnknownHistoryFixture(identifier: String) async throws -> UnknownHistoryFixture {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let thumbnailDirectory = databaseURL.deletingLastPathComponent()
            .appending(path: "Thumbnails", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
        let thumbnail = thumbnailDirectory.appending(path: "kept.jpg", directoryHint: .notDirectory)
        try Data("kept".utf8).write(to: thumbnail)

        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        try await dbQueue.write { db in
            try db.execute(sql: "INSERT INTO library_root (path) VALUES (?)", arguments: ["/tmp/unknown-history"])
            try db.execute(
                sql: """
                INSERT INTO media_asset (
                    library_root_id, relative_path, sort_key, name_sort_key, name
                ) VALUES (?, 'kept.jpg', 'k', 'kept.jpg', 'kept.jpg')
                """,
                arguments: [db.lastInsertedRowID]
            )
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [identifier])
        }
        return UnknownHistoryFixture(databaseURL: databaseURL, thumbnail: thumbnail)
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
