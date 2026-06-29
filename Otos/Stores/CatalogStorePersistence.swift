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

    /// Thumbnail files live beside the catalog in Application Support. Created lazily by
    /// `ThumbnailStore.write`; computed here so the location convention has one owner.
    static func applicationThumbnailDirectory(bundleIdentifier: String) throws -> URL {
        let appSupportURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupportURL
            .appending(path: bundleIdentifier, directoryHint: .isDirectory)
            .appending(path: "Thumbnails", directoryHint: .isDirectory)
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
        // Enrichment overlay columns, written only by enrichment (the scan upsert keeps
        // listing only fact columns, so a re-scan never clears these). The stamps drive
        // derived staleness; the blob is the on-demand full metadata, never loaded at
        // launch. When the AssetMetadata blob shape changes, a future migration nulls
        // every `metadata_blob` and the stamps so each asset re-enriches into the new
        // shape — that is the DB-wide blob version, not a per-row tag.
        migrator.registerMigration("v3_media_asset_enrichment") { db in
            try db.alter(table: "media_asset") { table in
                table.add(column: "enriched_source_size", .integer)
                table.add(column: "enriched_source_mtime", .integer)
                table.add(column: "thumbnail_path", .text)
                table.add(column: "capture_date_unix", .double)
                table.add(column: "metadata_blob", .blob)
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

        // The cheap enrichment columns load into the resident asset; `metadata_blob` is
        // deliberately not selected here (no 1M-blob decode at launch) — it is read on
        // demand by `metadataBlob(...)`.
        let assets = try Row.fetchAll(
            db,
            sql: """
            SELECT library_root_id, relative_path, name, content_type_identifier, byte_size, \
            created_at_unix, content_modified_at_unix, \
            enriched_source_size, enriched_source_mtime, thumbnail_path, capture_date_unix
            FROM media_asset
            ORDER BY library_root_id, relative_path COLLATE NOCASE, relative_path
            """
        ).map { row in
            storedAsset(from: row)
        }

        return (roots, assets)
    }

    /// Writes one asset's enrichment overlay, touching only enrichment columns (disjoint
    /// from the scan's fact columns). The source signature in the `WHERE` clause keeps
    /// an in-flight stale result from overwriting a row after a scan has already refreshed
    /// the file facts in SQLite.
    static func updateEnrichment(_ result: EnrichmentResult, libraryRootID: Int64, db: Database) throws {
        let sourceMTimeSeconds = result.sourceMTimeSeconds ?? -1
        try db.execute(
            sql: """
            UPDATE media_asset SET
                thumbnail_path = ?,
                capture_date_unix = ?,
                enriched_source_size = ?,
                enriched_source_mtime = ?,
                metadata_blob = ?
            WHERE library_root_id = ?
                AND relative_path = ?
                AND COALESCE(byte_size, -1) = ?
                AND (
                    (content_modified_at_unix IS NULL AND ? = -1)
                    OR (content_modified_at_unix >= ? AND content_modified_at_unix < ?)
                )
            """,
            arguments: [
                result.thumbnailPath,
                result.captureDate?.timeIntervalSince1970,
                result.sourceSize,
                result.sourceMTimeSeconds,
                encodeMetadata(result.metadata),
                libraryRootID,
                result.id.relativePath.rawValue,
                result.sourceSize ?? -1,
                sourceMTimeSeconds,
                sourceMTimeSeconds,
                sourceMTimeSeconds + 1,
            ]
        )
    }

    /// Reads one asset's full metadata blob on demand (a future inspector), decoding it
    /// from the binary plist. `nil` if absent or undecodable.
    static func metadataBlob(
        libraryRootID: Int64,
        relativePath: MediaRelativePath,
        db: Database
    ) throws -> AssetMetadata? {
        let data: Data? = try Row.fetchOne(
            db,
            sql: "SELECT metadata_blob FROM media_asset WHERE library_root_id = ? AND relative_path = ?",
            arguments: [libraryRootID, relativePath.rawValue]
        )?["metadata_blob"]
        return data.flatMap(decodeMetadata)
    }

    /// Binary-plist (not JSON) encoding of the typed metadata. `nil` only if encoding
    /// fails, which the caller stores as a null blob.
    static func encodeMetadata(_ metadata: AssetMetadata) -> Data? {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try? encoder.encode(metadata)
    }

    static func decodeMetadata(_ data: Data) -> AssetMetadata? {
        try? PropertyListDecoder().decode(AssetMetadata.self, from: data)
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
    let captureUnix: Double? = row["capture_date_unix"]
    return CatalogStore.StoredAsset(
        libraryRootID: row["library_root_id"],
        relativePath: MediaRelativePath(rawValue: row["relative_path"]),
        name: row["name"],
        contentTypeIdentifier: row["content_type_identifier"],
        byteSize: row["byte_size"],
        createdAt: createdUnix.map(Date.init(timeIntervalSince1970:)),
        contentModifiedAt: modifiedUnix.map(Date.init(timeIntervalSince1970:)),
        thumbnailPath: row["thumbnail_path"],
        captureDate: captureUnix.map(Date.init(timeIntervalSince1970:)),
        enrichedSourceSize: row["enriched_source_size"],
        enrichedSourceMTimeSeconds: row["enriched_source_mtime"]
    )
}
