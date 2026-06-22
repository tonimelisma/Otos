import Foundation
import GRDB

/// Persistence guide
///
/// This extension is the SQLite edge of CatalogStore. It translates between the
/// durable relational schema and the Store's typed in-memory records, but it does
/// not own catalog behavior or publish UI state. Keeping SQL here makes the actor
/// methods in CatalogStore read in terms of catalog operations while preserving a
/// single persistence owner.
///
/// SQLite row IDs are deliberately confined to StoredRoot/StoredAsset. The
/// product identity of a library is its normalized LibraryRootPath, and the
/// product identity of an asset is that root path plus MediaRelativePath. A row ID
/// is only the compact foreign key used by SQLite; allowing it across this boundary
/// would give the same library two competing identities.
extension CatalogStore {
    /// Places the rebuildable catalog beside the rest of Otos's Application
    /// Support data. The caller supplies the bundle identifier so tests can use
    /// isolated locations without changing the production path convention.
    static func applicationDatabaseURL(bundleIdentifier: String) throws -> URL {
        let fileManager = FileManager.default
        let appSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryURL = appSupportURL
            .appending(path: bundleIdentifier, directoryHint: .isDirectory)
            .appending(path: "Catalog", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL.appending(path: "catalog.sqlite")
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // Migrations are append-only descriptions of durable schema evolution.
        // Runtime models stay independent of schema version while an existing
        // on-disk catalog migrates deterministically to the one current schema.
        migrator.registerMigration("v1_library_roots_and_media_assets") { db in
            try db.create(table: "library_root") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("path", .text).notNull().unique()
            }

            try db.create(table: "media_asset") { table in
                table.column("library_root_id", .integer)
                    .notNull()
                    .references("library_root", onDelete: .cascade)
                table.column("relative_path", .text).notNull()
                table.column("content_type_identifier", .text)
                table.column("byte_size", .integer)
                table.column("content_modified_at_unix", .double)
                table.primaryKey(["library_root_id", "relative_path"])
            }
        }
        migrator.registerMigration("v2_media_asset_name_and_created_at") { db in
            try db.alter(table: "media_asset") { table in
                table.add(column: "name", .text)
                table.add(column: "created_at_unix", .double)
            }
        }
        return migrator
    }

    static func fetchCatalog(_ db: Database) throws -> (roots: [StoredRoot], assets: [StoredAsset]) {
        let roots = try Row.fetchAll(
            db,
            sql: "SELECT id, path FROM library_root ORDER BY path COLLATE NOCASE, path"
        ).map { row in
            StoredRoot(id: row["id"], path: LibraryRootPath(rawValue: row["path"]))
        }

        let assets = try Row.fetchAll(
            db,
            sql: """
            SELECT library_root_id, relative_path, name, content_type_identifier, byte_size, \
            created_at_unix, content_modified_at_unix
            FROM media_asset
            ORDER BY library_root_id, relative_path COLLATE NOCASE, relative_path
            """
        ).map { row in
            storedAsset(from: row)
        }

        return (roots, assets)
    }

    static func upsertScannedFile(_ file: ScannedMediaFile, libraryRootID: Int64, db: Database) throws {
        // The compound key makes a scan idempotent: observing the same relative
        // path refreshes its current filesystem facts instead of creating scan
        // history or a second asset identity.
        try db.execute(
            sql: """
            INSERT INTO media_asset (
                library_root_id,
                relative_path,
                name,
                content_type_identifier,
                byte_size,
                created_at_unix,
                content_modified_at_unix
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(library_root_id, relative_path) DO UPDATE SET
                name = excluded.name,
                content_type_identifier = excluded.content_type_identifier,
                byte_size = excluded.byte_size,
                created_at_unix = excluded.created_at_unix,
                content_modified_at_unix = excluded.content_modified_at_unix
            """,
            arguments: [
                libraryRootID,
                file.relativePath.rawValue,
                file.name,
                file.contentTypeIdentifier,
                file.byteSize,
                file.createdAt?.timeIntervalSince1970,
                file.contentModifiedAt?.timeIntervalSince1970,
            ]
        )
    }
}

/// Converts nullable SQLite timestamps at the persistence edge so the rest of
/// the Store works with `Date?` rather than storage-format doubles.
private nonisolated func storedAsset(from row: Row) -> CatalogStore.StoredAsset {
    let createdUnix: Double? = row["created_at_unix"]
    let modifiedUnix: Double? = row["content_modified_at_unix"]
    return CatalogStore.StoredAsset(
        libraryRootID: row["library_root_id"],
        relativePath: MediaRelativePath(rawValue: row["relative_path"]),
        name: row["name"],
        contentTypeIdentifier: row["content_type_identifier"],
        byteSize: row["byte_size"],
        createdAt: createdUnix.map(Date.init(timeIntervalSince1970:)),
        contentModifiedAt: modifiedUnix.map(Date.init(timeIntervalSince1970:))
    )
}
