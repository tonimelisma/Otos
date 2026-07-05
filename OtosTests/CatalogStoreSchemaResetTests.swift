import Foundation
import GRDB
@testable import Otos
import Testing

struct CatalogStoreSchemaResetTests {
    @Test func missingDurationHotColumnTriggersCleanResetAndThumbnailPurge() async throws {
        let fixture = try Self.makeMissingDurationFixture()

        let store = CatalogStore(location: .databaseFile(fixture.databaseURL))
        try await store.start(scansSavedLibraries: false)
        let snapshot = try await catalogStoreTestState(store)

        #expect(snapshot.libraries.isEmpty)
        #expect(snapshot.testAssets.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.original.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: fixture.staleThumbnail.path(percentEncoded: false)))
        #expect(try await Self.currentMediaAssetColumns(fixture.databaseURL).contains("duration_seconds"))
    }
}

private extension CatalogStoreSchemaResetTests {
    struct MissingDurationFixture {
        let databaseURL: URL
        let original: URL
        let staleThumbnail: URL
    }

    static func makeMissingDurationFixture() throws -> MissingDurationFixture {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appending(path: "durationless.jpg", directoryHint: .notDirectory)
        try writeCatalogStoreFile(original, contents: "jpeg")

        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let staleThumbnail = try makeStaleThumbnail(beside: databaseURL)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try createSchemaMissingDurationColumn(dbQueue)
        try seedMissingDurationRow(rootPath: rootPath, dbQueue: dbQueue)

        return MissingDurationFixture(
            databaseURL: databaseURL,
            original: original,
            staleThumbnail: staleThumbnail
        )
    }

    static func makeStaleThumbnail(beside databaseURL: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let thumbnailDirectory = databaseURL.deletingLastPathComponent()
            .appending(path: "Thumbnails", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
        let staleThumbnail = thumbnailDirectory.appending(path: "old-duration.jpg", directoryHint: .notDirectory)
        try Data("stale".utf8).write(to: staleThumbnail)
        return staleThumbnail
    }

    static func seedMissingDurationRow(rootPath: LibraryRootPath, dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO library_root (path) VALUES (?)", arguments: [rootPath.rawValue])
            try insertMissingDurationAsset(rootID: db.lastInsertedRowID, rootPath: rootPath, db: db)
        }
    }

    static func insertMissingDurationAsset(rootID: Int64, rootPath: LibraryRootPath, db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO media_asset (
                library_root_id,
                relative_path,
                sort_key,
                name_sort_key,
                name,
                content_type_identifier,
                thumbnail_path
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                rootID,
                "durationless.jpg",
                MediaSortKey.make(
                    libraryRootPath: rootPath,
                    relativePath: MediaRelativePath(rawValue: "durationless.jpg")
                ),
                MediaSortKey.naturalKey("durationless.jpg"),
                "durationless.jpg",
                "public.jpeg",
                "old-duration.jpg",
            ]
        )
    }

    static func createSchemaMissingDurationColumn(_ dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try createLibraryRootTable(db)
            try createMediaAssetTableMissingDuration(db)
            try createAssetMetadataTable(db)
        }
    }

    static func createLibraryRootTable(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE library_root (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT NOT NULL UNIQUE
        )
        """)
    }

    static func createMediaAssetTableMissingDuration(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE media_asset (
            library_root_id INTEGER NOT NULL REFERENCES library_root(id) ON DELETE CASCADE,
            relative_path TEXT NOT NULL,
            sort_key TEXT NOT NULL,
            name_sort_key TEXT NOT NULL,
            name TEXT,
            content_type_identifier TEXT,
            kind TEXT,
            format TEXT,
            byte_size INTEGER,
            created_at_unix DOUBLE,
            content_modified_at_unix DOUBLE,
            ts_original_unix DOUBLE,
            ts_quicktime_creation_unix DOUBLE,
            ts_digitized_unix DOUBLE,
            ts_gps_unix DOUBLE,
            enriched_kind TEXT,
            enriched_format TEXT,
            best_capture_unix DOUBLE,
            best_kind TEXT,
            best_format TEXT,
            enriched_source_size INTEGER,
            enriched_source_mtime INTEGER,
            thumbnail_path TEXT,
            enrichment_claimed_until DOUBLE,
            PRIMARY KEY (library_root_id, relative_path)
        )
        """)
    }

    static func createAssetMetadataTable(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE asset_metadata (
            library_root_id INTEGER NOT NULL,
            relative_path TEXT NOT NULL,
            metadata_extra_json TEXT,
            PRIMARY KEY (library_root_id, relative_path)
        )
        """)
    }

    static func currentMediaAssetColumns(_ databaseURL: URL) async throws -> Set<String> {
        try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).read { db in
            try Set(String.fetchAll(db, sql: "SELECT name FROM pragma_table_xinfo('media_asset')"))
        }
    }
}
