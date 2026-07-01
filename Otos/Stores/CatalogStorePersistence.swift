import Foundation
import GRDB

// swiftlint:disable file_length

/// Persistence guide
///
/// This extension is the SQLite edge of CatalogStore. It translates between the
/// durable relational schema and the Store's typed records, but it does
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
    struct SQLQuery {
        let sql: String
        let arguments: StatementArguments
    }

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
    /// `ThumbnailStore.stage`/`promote`; computed here so the location convention has one owner.
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

    /// File-backed catalogs use a pool so Store-owned reads can eventually run
    /// concurrently with scan/enrichment writes. GRDB puts `DatabasePool` files in
    /// WAL mode by default; the explicit cache/mmap pragmas make the current
    /// architecture decision visible at the one storage-construction point.
    static func fileBackedDatabaseConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.maximumReaderCount = 4
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA cache_size = -32768")
            try db.execute(sql: "PRAGMA mmap_size = 268435456")
        }
        return configuration
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.eraseDatabaseOnSchemaChange = true

        // The catalog is a rebuildable filesystem projection. With no active users
        // and no authoritative user data in this schema, incompatible old local
        // databases are intentionally erased and rebuilt instead of migrated.
        migrator.registerMigration("v1_clean_queryable_catalog") { db in
            try db.create(table: "library_root") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("path", .text).notNull().unique()
            }

            try db.create(table: "media_asset") { table in
                table.column("library_root_id", .integer)
                    .notNull()
                    .references("library_root", onDelete: .cascade)
                table.column("relative_path", .text).notNull()
                table.column("sort_key", .text).notNull()
                table.column("name", .text)
                table.column("content_type_identifier", .text)
                table.column("byte_size", .integer)
                table.column("created_at_unix", .double)
                table.column("content_modified_at_unix", .double)
                table.column("enriched_source_size", .integer)
                table.column("enriched_source_mtime", .integer)
                table.column("thumbnail_path", .text)
                table.column("capture_date_unix", .double)
                table.column("enrichment_claimed_until", .double)
                table.primaryKey(["library_root_id", "relative_path"])
            }

            try db.create(
                index: "idx_media_asset_order_global",
                on: "media_asset",
                columns: ["sort_key", "library_root_id", "relative_path"]
            )
            try db.create(
                index: "idx_media_asset_order_root",
                on: "media_asset",
                columns: ["library_root_id", "sort_key", "relative_path"]
            )
            try db.create(index: "idx_media_asset_capture_date", on: "media_asset", columns: ["capture_date_unix"])
            try db.execute(
                sql: """
                CREATE INDEX idx_media_asset_needs_enrichment_global
                ON media_asset(sort_key, library_root_id, relative_path)
                WHERE \(enrichmentStalenessSQLPredicate())
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX idx_media_asset_needs_enrichment_root
                ON media_asset(library_root_id, sort_key, relative_path)
                WHERE \(enrichmentStalenessSQLPredicate())
                """
            )

            try db.execute(
                sql: """
                CREATE TABLE asset_metadata (
                    library_root_id INTEGER NOT NULL,
                    relative_path TEXT NOT NULL,
                    family TEXT,
                    file_extension TEXT,
                    brand TEXT,
                    camera_make TEXT,
                    camera_model TEXT,
                    lens_model TEXT,
                    serial_number TEXT,
                    orientation INTEGER,
                    pixel_width INTEGER,
                    pixel_height INTEGER,
                    duration_seconds DOUBLE,
                    frame_rate DOUBLE,
                    video_codec TEXT,
                    primary_latitude DOUBLE,
                    primary_longitude DOUBLE,
                    primary_altitude_meters DOUBLE,
                    metadata_extra_json TEXT,
                    PRIMARY KEY (library_root_id, relative_path),
                    FOREIGN KEY (library_root_id, relative_path)
                        REFERENCES media_asset(library_root_id, relative_path)
                        ON DELETE CASCADE
                )
                """
            )
            try db.create(
                index: "idx_asset_metadata_camera_model",
                on: "asset_metadata",
                columns: ["camera_model"]
            )
            try db.create(
                index: "idx_asset_metadata_dimensions",
                on: "asset_metadata",
                columns: ["pixel_width", "pixel_height"]
            )
        }
        return migrator
    }

    static func fetchCatalog(_ db: Database) throws -> (roots: [StoredRoot], assetCount: Int) {
        let roots = try Row.fetchAll(
            db,
            sql: "SELECT id, path FROM library_root ORDER BY path COLLATE NOCASE, path"
        ).map { row in
            StoredRoot(id: row["id"], path: LibraryRootPath(rawValue: row["path"]))
        }
        let assetCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_asset") ?? 0
        return (roots, assetCount)
    }

    static func insertLibraryRoot(path: LibraryRootPath, db: Database) throws -> StoredRoot {
        try db.execute(
            sql: "INSERT INTO library_root (path) VALUES (?)",
            arguments: [path.rawValue]
        )
        return StoredRoot(id: db.lastInsertedRowID, path: path)
    }

    static func deleteLibraryRoot(rootRowID: Int64, db: Database) throws {
        try db.execute(
            sql: "DELETE FROM library_root WHERE id = ?",
            arguments: [rootRowID]
        )
    }

    @discardableResult
    static func deleteAssetRow(
        rootRowID: Int64,
        relativePath: MediaRelativePath,
        db: Database
    ) throws -> Bool {
        try db.execute(
            sql: "DELETE FROM media_asset WHERE library_root_id = ? AND relative_path = ?",
            arguments: [rootRowID, relativePath.rawValue]
        )
        return db.changesCount > 0
    }

    struct CatalogedFileDeletionTarget {
        let thumbnailPath: String?
    }

    static func catalogedFileDeletionTarget(
        relativePath: MediaRelativePath,
        rootRowID: Int64,
        db: Database
    ) throws -> CatalogedFileDeletionTarget? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT thumbnail_path
            FROM media_asset
            WHERE library_root_id = ? AND relative_path = ?
            """,
            arguments: [rootRowID, relativePath.rawValue]
        ) else {
            return nil
        }
        return CatalogedFileDeletionTarget(thumbnailPath: row["thumbnail_path"])
    }

    /// Detects an incompatible pre-user catalog before GRDB erases and rebuilds it, so
    /// Store can purge thumbnail files whose SQLite references are about to disappear.
    static func databaseNeedsCleanSchemaReset(_ db: Database) throws -> Bool {
        let userTables = try Set(String.fetchAll(
            db,
            sql: """
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
            """
        ))
        guard !userTables.isEmpty else {
            return false
        }
        guard userTables.contains("media_asset") else {
            return true
        }

        let mediaAssetColumns = try Set(String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('media_asset')"))
        let requiredMediaAssetColumns: Set = [
            "library_root_id",
            "relative_path",
            "sort_key",
            "name",
            "content_type_identifier",
            "byte_size",
            "created_at_unix",
            "content_modified_at_unix",
            "enriched_source_size",
            "enriched_source_mtime",
            "thumbnail_path",
            "capture_date_unix",
            "enrichment_claimed_until",
        ]
        guard requiredMediaAssetColumns.isSubset(of: mediaAssetColumns),
              userTables.contains("asset_metadata")
        else {
            return true
        }

        let metadataColumns = try Set(String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('asset_metadata')"))
        let requiredMetadataColumns: Set = [
            "library_root_id",
            "relative_path",
            "metadata_extra_json",
        ]
        return !requiredMetadataColumns.isSubset(of: metadataColumns)
    }

    static func enrichmentResultMatchesCurrentRow(
        _ result: EnrichmentResult,
        libraryRootID: Int64,
        db: Database
    ) throws -> Bool {
        let sourceMTimeSeconds = result.sourceMTimeSeconds ?? -1
        return try Row.fetchOne(
            db,
            sql: """
            SELECT 1
            FROM media_asset
            WHERE library_root_id = ?
                AND relative_path = ?
                AND COALESCE(byte_size, -1) = ?
                AND (
                    (content_modified_at_unix IS NULL AND ? = -1)
                    OR (content_modified_at_unix >= ? AND content_modified_at_unix < ?)
                )
            """,
            arguments: [
                libraryRootID,
                result.id.relativePath.rawValue,
                result.sourceSize ?? -1,
                sourceMTimeSeconds,
                sourceMTimeSeconds,
                sourceMTimeSeconds + 1,
            ]
        ) != nil
    }

    static func writeEnrichmentOverlay(_ result: EnrichmentResult, libraryRootID: Int64, db: Database) throws {
        try db.execute(
            sql: """
            UPDATE media_asset SET
                thumbnail_path = ?,
                capture_date_unix = ?,
                enriched_source_size = ?,
                enriched_source_mtime = ?
            WHERE library_root_id = ?
                AND relative_path = ?
            """,
            arguments: [
                result.thumbnailPath,
                result.captureDate?.timeIntervalSince1970,
                result.sourceSize,
                result.sourceMTimeSeconds,
                libraryRootID,
                result.id.relativePath.rawValue,
            ]
        )
        try upsertAssetMetadata(
            result.metadata,
            libraryRootID: libraryRootID,
            relativePath: result.id.relativePath,
            db: db
        )
    }

    /// Reads one asset's full preserved metadata JSON on demand. The scalar
    /// columns stay queryable; this JSON preserves the long-tail extraction payload
    /// for future inspector/detail work without making the grid load it.
    static func metadataExtra(
        libraryRootID: Int64,
        relativePath: MediaRelativePath,
        db: Database
    ) throws -> AssetMetadata? {
        let json: String? = try Row.fetchOne(
            db,
            sql: "SELECT metadata_extra_json FROM asset_metadata WHERE library_root_id = ? AND relative_path = ?",
            arguments: [libraryRootID, relativePath.rawValue]
        )?["metadata_extra_json"]
        return json.flatMap(decodeMetadataExtraJSON)
    }

    static func encodeMetadataExtraJSON(_ metadata: AssetMetadata) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(metadata)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func decodeMetadataExtraJSON(_ json: String) -> AssetMetadata? {
        guard let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(AssetMetadata.self, from: data)
    }

    static func fetchOrderedAssetIDRows(rootIDs: [Int64], db: Database) throws -> [(Int64, MediaRelativePath)] {
        guard let query = orderedAssetIDQuery(rootIDs: rootIDs) else {
            return []
        }
        return try Row.fetchAll(
            db,
            sql: query.sql,
            arguments: query.arguments
        ).map { row in
            (row["library_root_id"], MediaRelativePath(rawValue: row["relative_path"]))
        }
    }

    static func orderedAssetIDQuery(rootIDs: [Int64]) -> SQLQuery? {
        guard !rootIDs.isEmpty else {
            return nil
        }
        if rootIDs.count == 1, let rootID = rootIDs.first {
            return SQLQuery(
                sql: """
                SELECT library_root_id, relative_path
                FROM media_asset INDEXED BY idx_media_asset_order_root
                WHERE library_root_id = ?
                ORDER BY sort_key, relative_path
                """,
                arguments: [rootID]
            )
        }

        let placeholders = sqlPlaceholders(count: rootIDs.count)
        return SQLQuery(
            sql: """
            SELECT library_root_id, relative_path
            FROM media_asset INDEXED BY idx_media_asset_order_global
            WHERE library_root_id IN (\(placeholders))
            ORDER BY sort_key, library_root_id, relative_path
            """,
            arguments: StatementArguments(rootIDs)
        )
    }

    static func countAssets(rootIDs: [Int64], db: Database) throws -> Int {
        guard !rootIDs.isEmpty else {
            return 0
        }
        if rootIDs.count == 1, let rootID = rootIDs.first {
            return try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM media_asset
                WHERE library_root_id = ?
                """,
                arguments: [rootID]
            ) ?? 0
        }

        let placeholders = sqlPlaceholders(count: rootIDs.count)
        return try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*)
            FROM media_asset
            WHERE library_root_id IN (\(placeholders))
            """,
            arguments: StatementArguments(rootIDs)
        ) ?? 0
    }

    static func fetchStoredAssets(
        ids: [MediaAssetID],
        rootIDsByPath: [LibraryRootPath: Int64],
        db: Database
    ) throws -> [StoredAsset] {
        guard !ids.isEmpty else {
            return []
        }
        let idsByRootPath = Dictionary(grouping: ids, by: \.libraryRootPath)
        var assets: [StoredAsset] = []
        assets.reserveCapacity(ids.count)

        for (rootPath, idsForRoot) in idsByRootPath {
            guard let rootID = rootIDsByPath[rootPath] else {
                continue
            }
            let relativePaths = idsForRoot.map(\.relativePath.rawValue)
            let placeholders = sqlPlaceholders(count: relativePaths.count)
            var argumentValues: [any DatabaseValueConvertible] = [rootID]
            argumentValues.append(contentsOf: relativePaths)
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT library_root_id, relative_path, name, content_type_identifier, byte_size,
                       created_at_unix, content_modified_at_unix,
                       enriched_source_size, enriched_source_mtime, thumbnail_path, capture_date_unix
                FROM media_asset
                WHERE library_root_id = ? AND relative_path IN (\(placeholders))
                """,
                arguments: StatementArguments(argumentValues)
            )
            assets.append(contentsOf: rows.map(storedAsset(from:)))
        }
        return assets
    }

    static func fetchExistingAssetRows(
        libraryRootID: Int64,
        db: Database
    ) throws -> [(relativePath: MediaRelativePath, thumbnailPath: String?)] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT relative_path, thumbnail_path
            FROM media_asset
            WHERE library_root_id = ?
            """,
            arguments: [libraryRootID]
        ).map { row in
            let thumbnailPath: String? = row["thumbnail_path"]
            return (
                relativePath: MediaRelativePath(rawValue: row["relative_path"]),
                thumbnailPath: thumbnailPath
            )
        }
    }

    static func fetchStoredAssetsNeedingEnrichment(
        rootIDs: [Int64],
        claimNotAfter: TimeInterval,
        limit: Int,
        db: Database
    ) throws -> [StoredAsset] {
        let now = Date().timeIntervalSince1970
        guard let query = enrichmentClaimQuery(
            rootIDs: rootIDs,
            now: now,
            claimNotAfter: claimNotAfter,
            limit: limit
        ) else {
            return []
        }
        return try Row.fetchAll(db, sql: query.sql, arguments: query.arguments).map(storedAsset(from:))
    }

    static func enrichmentClaimQuery(
        rootIDs: [Int64],
        now: TimeInterval,
        claimNotAfter: TimeInterval,
        limit: Int
    ) -> SQLQuery? {
        guard !rootIDs.isEmpty, limit > 0 else {
            return nil
        }
        if rootIDs.count == 1, let rootID = rootIDs.first {
            return rootEnrichmentClaimQuery(
                rootID: rootID,
                now: now,
                claimNotAfter: claimNotAfter,
                limit: limit
            )
        }

        return globalEnrichmentClaimQuery(
            rootIDs: rootIDs,
            now: now,
            claimNotAfter: claimNotAfter,
            limit: limit
        )
    }

    private static func rootEnrichmentClaimQuery(
        rootID: Int64,
        now: TimeInterval,
        claimNotAfter: TimeInterval,
        limit: Int
    ) -> SQLQuery {
        SQLQuery(
            sql: """
            WITH candidates AS (
                SELECT library_root_id, relative_path
                FROM media_asset INDEXED BY idx_media_asset_needs_enrichment_root
                WHERE library_root_id = ?
                  AND (\(enrichmentStalenessSQLPredicate()))
                  AND (
                    enrichment_claimed_until IS NULL
                    OR enrichment_claimed_until < ?
                  )
                ORDER BY sort_key, relative_path
                LIMIT ?
            )
            UPDATE media_asset
            SET enrichment_claimed_until = ?
            WHERE (library_root_id, relative_path) IN (
                SELECT library_root_id, relative_path FROM candidates
            )
            RETURNING library_root_id, relative_path, name, content_type_identifier, byte_size,
                      created_at_unix, content_modified_at_unix,
                      enriched_source_size, enriched_source_mtime, thumbnail_path, capture_date_unix
            """,
            arguments: sqlArguments(rootID, now, limit, claimNotAfter)
        )
    }

    private static func globalEnrichmentClaimQuery(
        rootIDs: [Int64],
        now: TimeInterval,
        claimNotAfter: TimeInterval,
        limit: Int
    ) -> SQLQuery {
        let placeholders = sqlPlaceholders(count: rootIDs.count)
        var arguments = rootIDs.map { $0 as any DatabaseValueConvertible }
        arguments.append(now)
        arguments.append(limit)
        arguments.append(claimNotAfter)
        return SQLQuery(
            sql: """
            WITH candidates AS (
                SELECT library_root_id, relative_path
                FROM media_asset INDEXED BY idx_media_asset_needs_enrichment_global
                WHERE library_root_id IN (\(placeholders))
                  AND (\(enrichmentStalenessSQLPredicate()))
                  AND (
                    enrichment_claimed_until IS NULL
                    OR enrichment_claimed_until < ?
                  )
                ORDER BY sort_key, library_root_id, relative_path
                LIMIT ?
            )
            UPDATE media_asset
            SET enrichment_claimed_until = ?
            WHERE (library_root_id, relative_path) IN (
                SELECT library_root_id, relative_path FROM candidates
            )
            RETURNING library_root_id, relative_path, name, content_type_identifier, byte_size,
                      created_at_unix, content_modified_at_unix,
                      enriched_source_size, enriched_source_mtime, thumbnail_path, capture_date_unix
            """,
            arguments: StatementArguments(arguments)
        )
    }

    static func claimEnrichmentAsset(
        libraryRootID: Int64,
        relativePath: MediaRelativePath,
        claimedUntil: TimeInterval,
        db: Database
    ) throws -> Bool {
        let now = Date().timeIntervalSince1970
        try db.execute(
            sql: """
            UPDATE media_asset
            SET enrichment_claimed_until = ?
            WHERE library_root_id = ?
              AND relative_path = ?
              AND (\(enrichmentStalenessSQLPredicate()))
              AND (
                enrichment_claimed_until IS NULL
                OR enrichment_claimed_until < ?
              )
            """,
            arguments: [claimedUntil, libraryRootID, relativePath.rawValue, now]
        )
        return db.changesCount > 0
    }

    static func releaseEnrichmentClaims(
        ids: [MediaAssetID],
        rootIDsByPath: [LibraryRootPath: Int64],
        db: Database
    ) throws {
        for id in ids {
            guard let rootID = rootIDsByPath[id.libraryRootPath] else {
                continue
            }
            try db.execute(
                sql: """
                UPDATE media_asset
                SET enrichment_claimed_until = NULL
                WHERE library_root_id = ? AND relative_path = ?
                """,
                arguments: [rootID, id.relativePath.rawValue]
            )
        }
    }

    static func refreshEnrichmentClaims(
        ids: [MediaAssetID],
        rootIDsByPath: [LibraryRootPath: Int64],
        claimedUntil: TimeInterval,
        db: Database
    ) throws {
        for id in ids {
            guard let rootID = rootIDsByPath[id.libraryRootPath] else {
                continue
            }
            try db.execute(
                sql: """
                UPDATE media_asset
                SET enrichment_claimed_until = ?
                WHERE library_root_id = ? AND relative_path = ?
                """,
                arguments: [claimedUntil, rootID, id.relativePath.rawValue]
            )
        }
    }

    static func upsertScannedFile(
        _ file: ScannedMediaFile,
        libraryRootPath: LibraryRootPath,
        libraryRootID: Int64,
        db: Database
    ) throws -> Bool {
        // The compound key makes a scan idempotent: observing the same relative
        // path refreshes its current filesystem facts instead of creating scan
        // history or a second asset identity.
        try db.execute(
            sql: """
            INSERT INTO media_asset (
                library_root_id,
                relative_path,
                sort_key,
                name,
                content_type_identifier,
                byte_size,
                created_at_unix,
                content_modified_at_unix
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(library_root_id, relative_path) DO UPDATE SET
                sort_key = excluded.sort_key,
                name = excluded.name,
                content_type_identifier = excluded.content_type_identifier,
                byte_size = excluded.byte_size,
                created_at_unix = excluded.created_at_unix,
                content_modified_at_unix = excluded.content_modified_at_unix
            WHERE media_asset.sort_key IS NOT excluded.sort_key
               OR media_asset.name IS NOT excluded.name
               OR media_asset.content_type_identifier IS NOT excluded.content_type_identifier
               OR media_asset.byte_size IS NOT excluded.byte_size
               OR CAST(COALESCE(media_asset.created_at_unix, -1) AS INTEGER)
                  IS NOT CAST(COALESCE(excluded.created_at_unix, -1) AS INTEGER)
               OR CAST(COALESCE(media_asset.content_modified_at_unix, -1) AS INTEGER)
                  IS NOT CAST(COALESCE(excluded.content_modified_at_unix, -1) AS INTEGER)
            """,
            arguments: [
                libraryRootID,
                file.relativePath.rawValue,
                MediaSortKey.make(libraryRootPath: libraryRootPath, relativePath: file.relativePath),
                file.name,
                file.contentTypeIdentifier,
                file.byteSize,
                file.createdAt?.timeIntervalSince1970,
                file.contentModifiedAt?.timeIntervalSince1970,
            ]
        )
        return db.changesCount > 0
    }

    private static func upsertAssetMetadata(
        _ metadata: AssetMetadata,
        libraryRootID: Int64,
        relativePath: MediaRelativePath,
        db: Database
    ) throws {
        let primaryLocation = metadata.locations.first
        let arguments = assetMetadataStatementArguments(
            metadata,
            libraryRootID: libraryRootID,
            relativePath: relativePath,
            primaryLocation: primaryLocation
        )
        try db.execute(
            sql: upsertAssetMetadataSQL(),
            arguments: arguments
        )
    }
}

private nonisolated func upsertAssetMetadataSQL() -> String {
    """
    INSERT INTO asset_metadata (
        library_root_id,
        relative_path,
        family,
        file_extension,
        brand,
        camera_make,
        camera_model,
        lens_model,
        serial_number,
        orientation,
        pixel_width,
        pixel_height,
        duration_seconds,
        frame_rate,
        video_codec,
        primary_latitude,
        primary_longitude,
        primary_altitude_meters,
        metadata_extra_json
    )
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(library_root_id, relative_path) DO UPDATE SET
        family = excluded.family,
        file_extension = excluded.file_extension,
        brand = excluded.brand,
        camera_make = excluded.camera_make,
        camera_model = excluded.camera_model,
        lens_model = excluded.lens_model,
        serial_number = excluded.serial_number,
        orientation = excluded.orientation,
        pixel_width = excluded.pixel_width,
        pixel_height = excluded.pixel_height,
        duration_seconds = excluded.duration_seconds,
        frame_rate = excluded.frame_rate,
        video_codec = excluded.video_codec,
        primary_latitude = excluded.primary_latitude,
        primary_longitude = excluded.primary_longitude,
        primary_altitude_meters = excluded.primary_altitude_meters,
        metadata_extra_json = excluded.metadata_extra_json
    """
}

private nonisolated func enrichmentStalenessSQLPredicate() -> String {
    """
    enriched_source_size IS NULL
       OR enriched_source_mtime IS NULL
       OR COALESCE(byte_size, -1) <> COALESCE(enriched_source_size, -1)
       OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
          <> COALESCE(enriched_source_mtime, -1)
    """
}

private nonisolated func sqlPlaceholders(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ",")
}

private nonisolated func sqlArguments(_ values: (any DatabaseValueConvertible)...) -> StatementArguments {
    StatementArguments(values)
}

private nonisolated func assetMetadataStatementArguments(
    _ metadata: AssetMetadata,
    libraryRootID: Int64,
    relativePath: MediaRelativePath,
    primaryLocation: GeoRecord?
) -> StatementArguments {
    let values: [(any DatabaseValueConvertible)?] = [
        libraryRootID,
        relativePath.rawValue,
        metadata.family,
        metadata.fileExtension,
        metadata.brand,
        metadata.cameraMake,
        metadata.cameraModel,
        metadata.lensModel,
        metadata.serialNumber,
        metadata.orientation,
        metadata.pixelWidth,
        metadata.pixelHeight,
        metadata.durationSeconds,
        metadata.frameRate,
        metadata.videoCodec,
        primaryLocation?.latitude,
        primaryLocation?.longitude,
        primaryLocation?.altitudeMeters,
        CatalogStore.encodeMetadataExtraJSON(metadata),
    ]
    return StatementArguments(values)
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
