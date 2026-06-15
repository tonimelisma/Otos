import Foundation
import GRDB

extension CatalogStore {
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
