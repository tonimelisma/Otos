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
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
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
        migrator.registerMigration("v3_sort_key_separator") { db in
            try db.create(table: "library_root") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("path", .text).notNull().unique()
            }

            try db.execute(sql: mediaAssetTableSQL())

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
            try createOrderIndexes(db)
            try createEnrichmentClaimIndexes(db)

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
        migrator.registerMigration("v4_newest_first_enrichment_claims") { db in
            try db.drop(index: "idx_media_asset_needs_enrichment_global")
            try db.drop(index: "idx_media_asset_needs_enrichment_root")
            try createEnrichmentClaimIndexes(db)
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

    static func updateLibraryRootPath(
        rootRowID: Int64,
        path: LibraryRootPath,
        db: Database
    ) throws -> [ThumbnailPathMigration] {
        try db.execute(
            sql: "UPDATE library_root SET path = ? WHERE id = ?",
            arguments: [path.rawValue, rootRowID]
        )
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT relative_path, thumbnail_path FROM media_asset WHERE library_root_id = ?",
            arguments: [rootRowID]
        )
        var thumbnailMigrations: [ThumbnailPathMigration] = []
        for row in rows {
            let relativePath: String = row["relative_path"]
            let thumbnailPath: String? = row["thumbnail_path"]
            let relativePathValue = MediaRelativePath(rawValue: relativePath)
            let newThumbnailPath = thumbnailPath.map { _ in
                ThumbnailStore.relativeName(for: MediaAssetID(
                    libraryRootPath: path,
                    relativePath: relativePathValue
                ))
            }
            try db.execute(
                sql: """
                UPDATE media_asset
                SET sort_key = ?, thumbnail_path = ?
                WHERE library_root_id = ? AND relative_path = ?
                """,
                arguments: [
                    MediaSortKey.make(libraryRootPath: path, relativePath: relativePathValue),
                    newThumbnailPath,
                    rootRowID,
                    relativePath,
                ]
            )
            if let thumbnailPath, let newThumbnailPath, thumbnailPath != newThumbnailPath {
                thumbnailMigrations.append(ThumbnailPathMigration(
                    oldRelativeName: thumbnailPath,
                    newRelativeName: newThumbnailPath
                ))
            }
        }
        return thumbnailMigrations
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

        let mediaAssetColumns = try Set(String.fetchAll(
            db,
            sql: "SELECT name FROM pragma_table_xinfo('media_asset')"
        ))
        guard requiredCurrentMediaAssetColumns().isSubset(of: mediaAssetColumns),
              userTables.contains("asset_metadata")
        else {
            return true
        }

        let metadataColumns = try Set(String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('asset_metadata')"))
        return !requiredCurrentMetadataColumns().isSubset(of: metadataColumns)
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
                ts_original_unix = ?,
                ts_quicktime_creation_unix = ?,
                ts_digitized_unix = ?,
                ts_gps_unix = ?,
                enriched_kind = ?,
                enriched_format = ?,
                enriched_source_size = ?,
                enriched_source_mtime = ?
            WHERE library_root_id = ?
                AND relative_path = ?
            """,
            arguments: [
                result.thumbnailPath,
                result.timestampFacts.original?.timeIntervalSince1970,
                result.timestampFacts.quickTimeCreation?.timeIntervalSince1970,
                result.timestampFacts.digitized?.timeIntervalSince1970,
                result.timestampFacts.gps?.timeIntervalSince1970,
                result.enrichedKind?.rawValue,
                result.enrichedFormat?.rawValue,
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

    static func fetchOrderedAssetIDRows(
        descriptor: CatalogQueryDescriptor,
        rootIDs: [Int64],
        db: Database
    ) throws -> [(Int64, MediaRelativePath)] {
        guard let query = orderedAssetIDQuery(descriptor: descriptor, rootIDs: rootIDs) else {
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

    static func orderedAssetIDQuery(descriptor: CatalogQueryDescriptor, rootIDs: [Int64]) -> SQLQuery? {
        guard !rootIDs.isEmpty else {
            return nil
        }
        let order = orderPlan(for: descriptor.sort, rootLocal: rootIDs.count == 1)
        var arguments: [any DatabaseValueConvertible] = []
        let rootPredicate: String
        if rootIDs.count == 1, let rootID = rootIDs.first {
            rootPredicate = "library_root_id = ?"
            arguments.append(rootID)
        } else {
            let placeholders = sqlPlaceholders(count: rootIDs.count)
            rootPredicate = "library_root_id IN (\(placeholders))"
            arguments.append(contentsOf: rootIDs)
        }
        let filter = filterPredicate(for: descriptor.filter)
        arguments.append(contentsOf: filter.arguments)
        let filterSQL = filter.sql.map { "\n  AND \($0)" } ?? ""
        return SQLQuery(
            sql: """
            SELECT library_root_id, relative_path
            FROM media_asset INDEXED BY \(order.indexName)
            WHERE \(rootPredicate)\(filterSQL)
            ORDER BY \(order.orderBy)
            """,
            arguments: StatementArguments(arguments)
        )
    }

    static func filterOptions(rootIDs: [Int64], db: Database) throws -> CatalogFilterOptions {
        guard let query = distinctFilterableTypesQuery(rootIDs: rootIDs) else {
            return .empty
        }
        let rows = try Row.fetchAll(db, sql: query.sql, arguments: query.arguments)
        var formatsByKind: [MediaKind: Set<MediaFormatToken>] = [:]
        for row in rows {
            let kindValue: String? = row["best_kind"]
            let formatValue: String? = row["best_format"]
            guard let kindValue, let kind = MediaKind(rawValue: kindValue) else {
                continue
            }
            var formats = formatsByKind[kind, default: []]
            if let formatValue {
                formats.insert(MediaFormatToken(rawValue: formatValue))
            }
            formatsByKind[kind] = formats
        }
        return CatalogFilterOptions(
            formatsByKind: formatsByKind.mapValues { $0.sorted() }
        )
    }

    static func distinctFilterableTypesQuery(rootIDs: [Int64]) -> SQLQuery? {
        guard !rootIDs.isEmpty else {
            return nil
        }
        let placeholders = sqlPlaceholders(count: rootIDs.count)
        return SQLQuery(
            sql: """
            SELECT DISTINCT best_kind, best_format
            FROM media_asset
            WHERE library_root_id IN (\(placeholders))
              AND best_kind IS NOT NULL
            ORDER BY best_kind, best_format
            """,
            arguments: StatementArguments(rootIDs)
        )
    }

    static func countAssets(rootIDs: [Int64], db: Database) throws -> Int {
        guard !rootIDs.isEmpty else {
            return 0
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
                       enriched_source_size, enriched_source_mtime, thumbnail_path,
                       best_capture_unix, best_kind, best_format
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
        let keys = try Row.fetchAll(db, sql: query.sql, arguments: query.arguments).map(enrichmentCandidateKey(from:))
        guard !keys.isEmpty else {
            return []
        }
        try claimStoredAssetsNeedingEnrichment(
            keys,
            now: now,
            claimedUntil: claimNotAfter,
            db: db
        )
        let assets = try fetchStoredAssetsForEnrichmentCandidates(keys, db: db)
        let assetsByKey = Dictionary(uniqueKeysWithValues: assets.map { asset in
            (EnrichmentCandidateKey(libraryRootID: asset.libraryRootID, relativePath: asset.relativePath), asset)
        })
        return keys.compactMap { assetsByKey[$0] }
    }

    static func enrichmentClaimQuery(
        rootIDs: [Int64],
        now: TimeInterval,
        claimNotAfter _: TimeInterval,
        limit: Int
    ) -> SQLQuery? {
        guard !rootIDs.isEmpty, limit > 0 else {
            return nil
        }
        if rootIDs.count == 1, let rootID = rootIDs.first {
            return rootEnrichmentClaimQuery(
                rootID: rootID,
                now: now,
                limit: limit
            )
        }

        return globalEnrichmentClaimQuery(
            rootIDs: rootIDs,
            now: now,
            limit: limit
        )
    }

    private static func rootEnrichmentClaimQuery(
        rootID: Int64,
        now: TimeInterval,
        limit: Int
    ) -> SQLQuery {
        SQLQuery(
            sql: """
            SELECT library_root_id, relative_path
            FROM media_asset INDEXED BY idx_media_asset_needs_enrichment_root
            WHERE library_root_id = ?
              AND (\(enrichmentStalenessSQLPredicate()))
              AND (
                enrichment_claimed_until IS NULL
                OR enrichment_claimed_until < ?
              )
            ORDER BY best_capture_unix DESC, relative_path
            LIMIT ?
            """,
            arguments: sqlArguments(rootID, now, limit)
        )
    }

    private static func globalEnrichmentClaimQuery(
        rootIDs: [Int64],
        now: TimeInterval,
        limit: Int
    ) -> SQLQuery {
        let placeholders = sqlPlaceholders(count: rootIDs.count)
        var arguments = rootIDs.map { $0 as any DatabaseValueConvertible }
        arguments.append(now)
        arguments.append(limit)
        return SQLQuery(
            sql: """
            SELECT library_root_id, relative_path
            FROM media_asset INDEXED BY idx_media_asset_needs_enrichment_global
            WHERE library_root_id IN (\(placeholders))
              AND (\(enrichmentStalenessSQLPredicate()))
              AND (
                enrichment_claimed_until IS NULL
                OR enrichment_claimed_until < ?
              )
            ORDER BY best_capture_unix DESC, library_root_id, relative_path
            LIMIT ?
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

    @discardableResult
    static func clearEnrichmentClaims(db: Database) throws -> Int {
        try db.execute(
            sql: """
            UPDATE media_asset
            SET enrichment_claimed_until = NULL
            WHERE enrichment_claimed_until IS NOT NULL
            """
        )
        return db.changesCount
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
                name_sort_key,
                name,
                content_type_identifier,
                kind,
                format,
                byte_size,
                created_at_unix,
                content_modified_at_unix
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(library_root_id, relative_path) DO UPDATE SET
                sort_key = excluded.sort_key,
                name_sort_key = excluded.name_sort_key,
                name = excluded.name,
                content_type_identifier = excluded.content_type_identifier,
                kind = excluded.kind,
                format = excluded.format,
                byte_size = excluded.byte_size,
                created_at_unix = excluded.created_at_unix,
                content_modified_at_unix = excluded.content_modified_at_unix
            WHERE media_asset.sort_key IS NOT excluded.sort_key
               OR media_asset.name_sort_key IS NOT excluded.name_sort_key
               OR media_asset.name IS NOT excluded.name
               OR media_asset.content_type_identifier IS NOT excluded.content_type_identifier
               OR media_asset.kind IS NOT excluded.kind
               OR media_asset.format IS NOT excluded.format
               OR media_asset.byte_size IS NOT excluded.byte_size
               OR CAST(COALESCE(media_asset.created_at_unix, -1) AS INTEGER)
                  IS NOT CAST(COALESCE(excluded.created_at_unix, -1) AS INTEGER)
               OR CAST(COALESCE(media_asset.content_modified_at_unix, -1) AS INTEGER)
                  IS NOT CAST(COALESCE(excluded.content_modified_at_unix, -1) AS INTEGER)
            """,
            arguments: scannedFileUpsertArguments(
                file,
                libraryRootPath: libraryRootPath,
                libraryRootID: libraryRootID
            )
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

private nonisolated func mediaAssetTableSQL() -> String {
    """
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
        best_capture_unix DOUBLE GENERATED ALWAYS AS (
            COALESCE(
                ts_original_unix,
                ts_quicktime_creation_unix,
                ts_digitized_unix,
                ts_gps_unix,
                created_at_unix,
                content_modified_at_unix
            )
        ) STORED,
        best_kind TEXT GENERATED ALWAYS AS (COALESCE(enriched_kind, kind)) STORED,
        best_format TEXT GENERATED ALWAYS AS (COALESCE(enriched_format, format)) STORED,
        enriched_source_size INTEGER,
        enriched_source_mtime INTEGER,
        thumbnail_path TEXT,
        enrichment_claimed_until DOUBLE,
        PRIMARY KEY (library_root_id, relative_path)
    )
    """
}

private nonisolated func createOrderIndexes(_ db: Database) throws {
    for direction in ["ASC", "DESC"] {
        try db.execute(
            sql: """
            CREATE INDEX idx_media_asset_best_capture_global_\(direction.lowercased())
            ON media_asset(best_capture_unix \(direction), library_root_id, relative_path)
            """
        )
        try db.execute(
            sql: """
            CREATE INDEX idx_media_asset_best_capture_root_\(direction.lowercased())
            ON media_asset(library_root_id, best_capture_unix \(direction), relative_path)
            """
        )
        try db.execute(
            sql: """
            CREATE INDEX idx_media_asset_name_global_\(direction.lowercased())
            ON media_asset(name_sort_key \(direction), library_root_id, relative_path)
            """
        )
        try db.execute(
            sql: """
            CREATE INDEX idx_media_asset_name_root_\(direction.lowercased())
            ON media_asset(library_root_id, name_sort_key \(direction), relative_path)
            """
        )
        try db.execute(
            sql: """
            CREATE INDEX idx_media_asset_size_global_\(direction.lowercased())
            ON media_asset((byte_size IS NULL), byte_size \(direction), library_root_id, relative_path)
            """
        )
        try db.execute(
            sql: """
            CREATE INDEX idx_media_asset_size_root_\(direction.lowercased())
            ON media_asset(library_root_id, (byte_size IS NULL), byte_size \(direction), relative_path)
            """
        )
    }
}

private nonisolated func createEnrichmentClaimIndexes(_ db: Database) throws {
    try db.execute(
        sql: """
        CREATE INDEX idx_media_asset_needs_enrichment_global
        ON media_asset(best_capture_unix DESC, library_root_id, relative_path)
        WHERE \(enrichmentStalenessSQLPredicate())
        """
    )
    try db.execute(
        sql: """
        CREATE INDEX idx_media_asset_needs_enrichment_root
        ON media_asset(library_root_id, best_capture_unix DESC, relative_path)
        WHERE \(enrichmentStalenessSQLPredicate())
        """
    )
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

private nonisolated struct EnrichmentCandidateKey: Hashable {
    let libraryRootID: Int64
    let relativePath: MediaRelativePath
}

private nonisolated func enrichmentCandidateKey(from row: Row) -> EnrichmentCandidateKey {
    EnrichmentCandidateKey(
        libraryRootID: row["library_root_id"],
        relativePath: MediaRelativePath(rawValue: row["relative_path"])
    )
}

private nonisolated func claimStoredAssetsNeedingEnrichment(
    _ keys: [EnrichmentCandidateKey],
    now: TimeInterval,
    claimedUntil: TimeInterval,
    db: Database
) throws {
    guard !keys.isEmpty else {
        return
    }
    var arguments: [any DatabaseValueConvertible] = [claimedUntil]
    arguments.append(contentsOf: enrichmentCandidateKeyArguments(keys))
    arguments.append(now)
    try db.execute(
        sql: """
        UPDATE media_asset
        SET enrichment_claimed_until = ?
        WHERE (library_root_id, relative_path) IN (\(sqlTuplePlaceholders(rowCount: keys.count, columnCount: 2)))
          AND (\(enrichmentStalenessSQLPredicate()))
          AND (
            enrichment_claimed_until IS NULL
            OR enrichment_claimed_until < ?
          )
        """,
        arguments: StatementArguments(arguments)
    )
}

private nonisolated func fetchStoredAssetsForEnrichmentCandidates(
    _ keys: [EnrichmentCandidateKey],
    db: Database
) throws -> [CatalogStore.StoredAsset] {
    guard !keys.isEmpty else {
        return []
    }
    return try Row.fetchAll(
        db,
        sql: """
        SELECT library_root_id, relative_path, name, content_type_identifier, byte_size,
               created_at_unix, content_modified_at_unix,
               enriched_source_size, enriched_source_mtime, thumbnail_path,
               best_capture_unix, best_kind, best_format
        FROM media_asset
        WHERE (library_root_id, relative_path) IN (\(sqlTuplePlaceholders(rowCount: keys.count, columnCount: 2)))
        """,
        arguments: StatementArguments(enrichmentCandidateKeyArguments(keys))
    ).map(storedAsset(from:))
}

private nonisolated func orderPlan(
    for sort: MediaSortOrder,
    rootLocal: Bool
) -> (indexName: String, orderBy: String) {
    let direction = sort.direction.sqlKeyword
    let suffix = direction.lowercased()
    switch (sort.field, rootLocal) {
    case (.bestDate, true):
        return (
            "idx_media_asset_best_capture_root_\(suffix)",
            "best_capture_unix \(direction), relative_path"
        )
    case (.bestDate, false):
        return (
            "idx_media_asset_best_capture_global_\(suffix)",
            "best_capture_unix \(direction), library_root_id, relative_path"
        )
    case (.name, true):
        return (
            "idx_media_asset_name_root_\(suffix)",
            "name_sort_key \(direction), relative_path"
        )
    case (.name, false):
        return (
            "idx_media_asset_name_global_\(suffix)",
            "name_sort_key \(direction), library_root_id, relative_path"
        )
    case (.size, true):
        return (
            "idx_media_asset_size_root_\(suffix)",
            "(byte_size IS NULL), byte_size \(direction), relative_path"
        )
    case (.size, false):
        return (
            "idx_media_asset_size_global_\(suffix)",
            "(byte_size IS NULL), byte_size \(direction), library_root_id, relative_path"
        )
    }
}

private nonisolated func filterPredicate(
    for filter: MediaFilter
) -> (sql: String?, arguments: [any DatabaseValueConvertible]) {
    guard filter.isActive else {
        return (nil, [])
    }
    var clauses: [String] = []
    var arguments: [any DatabaseValueConvertible] = []
    let kinds = filter.kinds.sorted { $0.rawValue < $1.rawValue }
    if !kinds.isEmpty {
        clauses.append("best_kind IN (\(sqlPlaceholders(count: kinds.count)))")
        arguments.append(contentsOf: kinds.map(\.rawValue))
    }
    let formats = filter.formats.sorted()
    if !formats.isEmpty {
        clauses.append("best_format IN (\(sqlPlaceholders(count: formats.count)))")
        arguments.append(contentsOf: formats.map(\.rawValue))
    }
    return ("(\(clauses.joined(separator: " OR ")))", arguments)
}

private extension MediaSortDirection {
    nonisolated var sqlKeyword: String {
        switch self {
        case .ascending:
            "ASC"
        case .descending:
            "DESC"
        }
    }
}

private nonisolated func sqlPlaceholders(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ",")
}

private nonisolated func sqlTuplePlaceholders(rowCount: Int, columnCount: Int) -> String {
    let tuple = "(\(sqlPlaceholders(count: columnCount)))"
    return Array(repeating: tuple, count: rowCount).joined(separator: ",")
}

private nonisolated func sqlArguments(_ values: (any DatabaseValueConvertible)...) -> StatementArguments {
    StatementArguments(values)
}

private nonisolated func enrichmentCandidateKeyArguments(
    _ keys: [EnrichmentCandidateKey]
) -> [any DatabaseValueConvertible] {
    keys.flatMap { key in
        [key.libraryRootID, key.relativePath.rawValue] as [any DatabaseValueConvertible]
    }
}

private nonisolated func requiredCurrentMediaAssetColumns() -> Set<String> {
    [
        "library_root_id",
        "relative_path",
        "sort_key",
        "name_sort_key",
        "name",
        "content_type_identifier",
        "kind",
        "format",
        "byte_size",
        "created_at_unix",
        "content_modified_at_unix",
        "ts_original_unix",
        "ts_quicktime_creation_unix",
        "ts_digitized_unix",
        "ts_gps_unix",
        "enriched_kind",
        "enriched_format",
        "best_capture_unix",
        "best_kind",
        "best_format",
        "enriched_source_size",
        "enriched_source_mtime",
        "thumbnail_path",
        "enrichment_claimed_until",
    ]
}

private nonisolated func requiredCurrentMetadataColumns() -> Set<String> {
    [
        "library_root_id",
        "relative_path",
        "metadata_extra_json",
    ]
}

private nonisolated func scannedFileUpsertArguments(
    _ file: ScannedMediaFile,
    libraryRootPath: LibraryRootPath,
    libraryRootID: Int64
) -> StatementArguments {
    let values: [(any DatabaseValueConvertible)?] = [
        libraryRootID,
        file.relativePath.rawValue,
        MediaSortKey.make(libraryRootPath: libraryRootPath, relativePath: file.relativePath),
        MediaSortKey.naturalKey(file.name ?? URL(fileURLWithPath: file.relativePath.rawValue).lastPathComponent),
        file.name,
        file.contentTypeIdentifier,
        file.kind?.rawValue,
        file.format?.rawValue,
        file.byteSize,
        file.createdAt?.timeIntervalSince1970,
        file.contentModifiedAt?.timeIntervalSince1970,
    ]
    return StatementArguments(values)
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
    let bestCaptureUnix: Double? = row["best_capture_unix"]
    let bestKindRaw: String? = row["best_kind"]
    let bestFormatRaw: String? = row["best_format"]
    return CatalogStore.StoredAsset(
        libraryRootID: row["library_root_id"],
        relativePath: MediaRelativePath(rawValue: row["relative_path"]),
        name: row["name"],
        contentTypeIdentifier: row["content_type_identifier"],
        byteSize: row["byte_size"],
        createdAt: createdUnix.map(Date.init(timeIntervalSince1970:)),
        contentModifiedAt: modifiedUnix.map(Date.init(timeIntervalSince1970:)),
        thumbnailPath: row["thumbnail_path"],
        bestCaptureDate: bestCaptureUnix.map(Date.init(timeIntervalSince1970:)),
        bestKind: bestKindRaw.flatMap(MediaKind.init(rawValue:)),
        bestFormat: bestFormatRaw.map(MediaFormatToken.init(rawValue:)),
        enrichedSourceSize: row["enriched_source_size"],
        enrichedSourceMTimeSeconds: row["enriched_source_mtime"]
    )
}
