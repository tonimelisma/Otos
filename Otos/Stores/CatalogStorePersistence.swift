import Foundation
import GRDB

/// Persistence guide
///
/// This extension is the SQLite edge of CatalogStore. It translates between the
/// durable relational schema and the Store's typed records, but it does
/// not own catalog behavior or publish UI state. Keeping SQL here makes the actor
/// methods in CatalogStore read in terms of catalog operations while preserving a
/// single persistence owner.
///
/// SQLite row IDs are deliberately confined to stored root/asset records. The
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

    /// Known migration identifiers in registration order. Future-schema refusal
    /// compares applied identifiers against this set before any write.
    static var knownMigrationIdentifiers: [String] {
        migrator.migrations
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // Import history and other non-rebuildable overlay forbid destructive
        // schema reset. Unknown future migrations refuse to open; known schemas
        // migrate additively. See ADR 0010 / plan 0055 Stage A.

        migrator.registerMigration("v3_sort_key_separator") { db in
            try db.create(table: "library_root") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("path", .text).notNull().unique()
                table.column("kind", .text).notNull().defaults(to: LibraryRootKind.library.rawValue)
                table.column("device_identity", .text)
                table.column("display_name", .text)
                table.column("last_seen_at", .double)
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
        migrator.registerMigration("v5_removable_source_roots") { db in
            let columns = try Set(String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('library_root')"))
            if !columns.contains("kind") {
                try db.alter(table: "library_root") { table in
                    table.add(column: "kind", .text).notNull().defaults(to: LibraryRootKind.library.rawValue)
                }
            }
            if !columns.contains("device_identity") {
                try db.alter(table: "library_root") { table in
                    table.add(column: "device_identity", .text)
                }
            }
            if !columns.contains("display_name") {
                try db.alter(table: "library_root") { table in
                    table.add(column: "display_name", .text)
                }
            }
            if !columns.contains("last_seen_at") {
                try db.alter(table: "library_root") { table in
                    table.add(column: "last_seen_at", .double)
                }
            }
            try db.execute(
                sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_library_root_device_identity
                ON library_root(device_identity)
                WHERE device_identity IS NOT NULL
                """
            )
        }
        migrator.registerMigration("v6_import_history_and_capture_wall") { db in
            try addImportHistoryAndCaptureWallColumns(db)
            try backfillCaptureWallFromMetadataJSON(db)
        }
        migrator.registerMigration("v7_media_companion") { db in
            try createMediaCompanionTable(db)
        }
        migrator.registerMigration("v8_active_file_operation") { db in
            try createActiveFileOperationTable(db)
        }
        migrator.registerMigration("v9_active_reorganization") { db in
            try rebuildAssetMetadataWithUpdateCascade(db)
            try createActiveReorganizationTables(db)
        }
        migrator.registerMigration("v10_import_provenance") { db in
            try addImportProvenanceColumns(db)
        }
        // Destination provenance has its own migration because GRDB never re-runs
        // an identifier that is already present in grdb_migrations.
        migrator.registerMigration("v11_import_destination_provenance") { db in
            try addImportProvenanceColumns(db)
        }
        return migrator
    }

    /// Rebuilds `asset_metadata` so path remaps cascade with media_asset PK updates
    /// (plan 0055 §4.3). SQLite cannot ALTER an existing FK action in place.
    static func rebuildAssetMetadataWithUpdateCascade(_ db: Database) throws {
        try db.execute(sql: "PRAGMA foreign_keys = OFF")
        try db.execute(
            sql: """
            CREATE TABLE asset_metadata_new (
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
                    ON UPDATE CASCADE
            )
            """
        )
        try db.execute(
            sql: """
            INSERT INTO asset_metadata_new SELECT * FROM asset_metadata
            """
        )
        try db.execute(sql: "DROP TABLE asset_metadata")
        try db.execute(sql: "ALTER TABLE asset_metadata_new RENAME TO asset_metadata")
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
        try db.execute(sql: "PRAGMA foreign_keys = ON")
    }

    static func createActiveReorganizationTables(_ db: Database) throws {
        try db.execute(
            sql: """
            CREATE TABLE active_reorganization_component (
                component_key TEXT PRIMARY KEY NOT NULL,
                library_root_path TEXT NOT NULL,
                plan_generation INTEGER NOT NULL,
                planned_root_revision INTEGER NOT NULL,
                phase TEXT NOT NULL,
                next_step_index INTEGER NOT NULL,
                created_at DOUBLE NOT NULL,
                updated_at DOUBLE NOT NULL
            )
            """
        )
        try db.execute(
            sql: """
            CREATE TABLE active_reorganization_member (
                component_key TEXT NOT NULL,
                member_index INTEGER NOT NULL,
                member_kind TEXT NOT NULL,
                logical_source_relative_path TEXT NOT NULL,
                current_relative_path TEXT NOT NULL,
                final_relative_path TEXT NOT NULL,
                byte_size INTEGER NOT NULL,
                content_modified_at DOUBLE NOT NULL,
                PRIMARY KEY (component_key, member_index),
                FOREIGN KEY (component_key)
                    REFERENCES active_reorganization_component(component_key)
                    ON DELETE CASCADE
            )
            """
        )
        try db.execute(
            sql: """
            CREATE TABLE active_reorganization_step (
                component_key TEXT NOT NULL,
                step_index INTEGER NOT NULL,
                member_index INTEGER NOT NULL,
                source_relative_path TEXT NOT NULL,
                destination_relative_path TEXT NOT NULL,
                phase TEXT NOT NULL,
                PRIMARY KEY (component_key, step_index),
                FOREIGN KEY (component_key, member_index)
                    REFERENCES active_reorganization_member(component_key, member_index)
                    ON DELETE CASCADE
            )
            """
        )
        try db.execute(
            sql: """
            CREATE TABLE active_reorganization_directory (
                component_key TEXT NOT NULL,
                relative_path TEXT NOT NULL,
                phase TEXT NOT NULL,
                PRIMARY KEY (component_key, relative_path),
                FOREIGN KEY (component_key)
                    REFERENCES active_reorganization_component(component_key)
                    ON DELETE CASCADE
            )
            """
        )
    }

    static func createActiveFileOperationTable(_ db: Database) throws {
        try db.execute(
            sql: """
            CREATE TABLE active_file_operation (
                operation_key TEXT PRIMARY KEY NOT NULL,
                mode TEXT NOT NULL,
                source_kind TEXT NOT NULL,
                source_device_identity TEXT,
                source_root_path TEXT NOT NULL,
                source_relative_path TEXT NOT NULL,
                destination_root_path TEXT NOT NULL,
                destination_relative_path TEXT NOT NULL,
                staging_path TEXT,
                import_batch_unix_ms INTEGER,
                source_byte_size INTEGER NOT NULL,
                source_modified_at DOUBLE NOT NULL,
                destination_modified_at DOUBLE,
                phase TEXT NOT NULL,
                delete_source_requested INTEGER NOT NULL,
                updated_at DOUBLE NOT NULL
            )
            """
        )
    }

    static func createMediaCompanionTable(_ db: Database) throws {
        try db.execute(
            sql: """
            CREATE TABLE media_companion (
                library_root_id INTEGER NOT NULL,
                relative_path TEXT NOT NULL,
                primary_relative_path TEXT,
                kind TEXT NOT NULL,
                byte_size INTEGER,
                content_modified_at DOUBLE,
                PRIMARY KEY (library_root_id, relative_path),
                FOREIGN KEY (library_root_id) REFERENCES library_root(id) ON DELETE CASCADE
            )
            """
        )
        try db.create(
            index: "idx_media_companion_primary",
            on: "media_companion",
            columns: ["library_root_id", "primary_relative_path"]
        )
    }

    /// Compatibility check run before any migrator write. Future or unrecognized
    /// schemas refuse without erase so non-rebuildable overlay cannot be destroyed.
    static func catalogSchemaCompatibility(_ db: Database) throws -> CatalogSchemaCompatibility {
        if try migrator.hasBeenSuperseded(db) {
            return .writtenByNewerOtos
        }
        let userTables = try Set(String.fetchAll(
            db,
            sql: """
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
            """
        ))
        if userTables.isEmpty {
            return .readyToMigrate
        }
        let applied = try migrator.appliedIdentifiers(db)
        let known = Set(migrator.migrations)
        if applied.isDisjoint(with: known) {
            return .unrecognized
        }
        return .readyToMigrate
    }

    /// Escalates `synchronous = FULL` for the duration of one write transaction so
    /// journal and settlement commits survive power loss, not only app crashes.
    /// The pool's default remains `NORMAL`; restore after the body returns.
    ///
    /// SQLite forbids changing the safety level inside a transaction, so the
    /// pragma is set on the writer connection before `BEGIN` and restored after
    /// commit/rollback.
    static func writeWithJournalDurability<T>(
        _ dbWriter: any DatabaseWriter,
        _ body: (Database) throws -> T
    ) throws -> T {
        try dbWriter.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA synchronous = FULL")
            defer {
                try? db.execute(sql: "PRAGMA synchronous = NORMAL")
            }
            var result: T!
            try db.inTransaction {
                result = try body(db)
                return .commit
            }
            return result
        }
    }

    static func fetchCatalog(_ db: Database) throws -> (roots: [StoredRoot], assetCount: Int) {
        let roots = try Row.fetchAll(
            db,
            sql: """
            SELECT id, path, kind, device_identity, display_name, last_seen_at
            FROM library_root
            ORDER BY path COLLATE NOCASE, path
            """
        ).map { row in
            let kindRaw: String = row["kind"]
            let lastSeenUnix: Double? = row["last_seen_at"]
            return StoredRoot(
                id: row["id"],
                path: LibraryRootPath(rawValue: row["path"]),
                kind: LibraryRootKind(rawValue: kindRaw) ?? .library,
                deviceIdentity: row["device_identity"],
                displayName: row["display_name"],
                lastSeenAt: lastSeenUnix.map(Date.init(timeIntervalSince1970:))
            )
        }
        let assetCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_asset") ?? 0
        return (roots, assetCount)
    }

    static func insertLibraryRoot(
        path: LibraryRootPath,
        kind: LibraryRootKind = .library,
        deviceIdentity: String? = nil,
        displayName: String? = nil,
        lastSeenAt: Date? = nil,
        db: Database
    ) throws -> StoredRoot {
        try db.execute(
            sql: """
            INSERT INTO library_root (path, kind, device_identity, display_name, last_seen_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            arguments: [
                path.rawValue,
                kind.rawValue,
                deviceIdentity,
                displayName,
                lastSeenAt?.timeIntervalSince1970,
            ]
        )
        return StoredRoot(
            id: db.lastInsertedRowID,
            path: path,
            kind: kind,
            deviceIdentity: deviceIdentity,
            displayName: displayName,
            lastSeenAt: lastSeenAt
        )
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

    static func updateLibraryRootSourceFacts(
        rootRowID: Int64,
        path: LibraryRootPath,
        displayName: String?,
        lastSeenAt: Date?,
        db: Database
    ) throws {
        try db.execute(
            sql: """
            UPDATE library_root
            SET path = ?, display_name = ?, last_seen_at = ?
            WHERE id = ?
            """,
            arguments: [
                path.rawValue,
                displayName,
                lastSeenAt?.timeIntervalSince1970,
                rootRowID,
            ]
        )
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
        let captureWall = CaptureWallClock.select(from: result.metadata.timestamps)
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
                duration_seconds = ?,
                enriched_source_size = ?,
                enriched_source_mtime = ?,
                capture_wall_compact = ?,
                capture_wall_precision = ?
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
                result.metadata.durationSeconds,
                result.sourceSize,
                result.sourceMTimeSeconds,
                captureWall?.compact,
                captureWall?.precision,
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

    static func updateThumbnailPath(
        _ thumbnailPath: String,
        libraryRootID: Int64,
        relativePath: MediaRelativePath,
        onlyWhenMissing: Bool,
        db: Database
    ) throws {
        let missingPredicate = onlyWhenMissing ? "AND thumbnail_path IS NULL" : ""
        try db.execute(
            sql: """
            UPDATE media_asset
            SET thumbnail_path = ?
            WHERE library_root_id = ?
              AND relative_path = ?
              \(missingPredicate)
            """,
            arguments: [thumbnailPath, libraryRootID, relativePath.rawValue]
        )
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

    static func fetchExistingAssetRows(
        libraryRootID: Int64,
        underSubtree: MediaRelativePath? = nil,
        db: Database
    ) throws -> [(relativePath: MediaRelativePath, thumbnailPath: String?)] {
        let rows: [Row] = if let underSubtree {
            // Component-safe: `a/b` matches itself and `a/b/...`, never `a/b2`.
            try Row.fetchAll(
                db,
                sql: """
                SELECT relative_path, thumbnail_path
                FROM media_asset
                WHERE library_root_id = ?
                  AND (relative_path = ? OR relative_path LIKE ? ESCAPE '\\')
                """,
                arguments: [
                    libraryRootID,
                    underSubtree.rawValue,
                    Self.sqlSubtreePrefixPattern(underSubtree),
                ]
            )
        } else {
            try Row.fetchAll(
                db,
                sql: """
                SELECT relative_path, thumbnail_path
                FROM media_asset
                WHERE library_root_id = ?
                """,
                arguments: [libraryRootID]
            )
        }
        return rows.map { row in
            let thumbnailPath: String? = row["thumbnail_path"]
            return (
                relativePath: MediaRelativePath(rawValue: row["relative_path"]),
                thumbnailPath: thumbnailPath
            )
        }
    }

    static func fetchExistingCompanionPaths(
        libraryRootID: Int64,
        underSubtree: MediaRelativePath? = nil,
        db: Database
    ) throws -> Set<MediaRelativePath> {
        let paths: [String] = if let underSubtree {
            try String.fetchAll(
                db,
                sql: """
                SELECT relative_path
                FROM media_companion
                WHERE library_root_id = ?
                  AND (relative_path = ? OR relative_path LIKE ? ESCAPE '\\')
                """,
                arguments: [
                    libraryRootID,
                    underSubtree.rawValue,
                    Self.sqlSubtreePrefixPattern(underSubtree),
                ]
            )
        } else {
            try String.fetchAll(
                db,
                sql: """
                SELECT relative_path
                FROM media_companion
                WHERE library_root_id = ?
                """,
                arguments: [libraryRootID]
            )
        }
        return Set(paths.map(MediaRelativePath.init(rawValue:)))
    }

    /// LIKE pattern for paths strictly inside `subtree/` with LIKE metacharacters escaped.
    static func sqlSubtreePrefixPattern(_ subtree: MediaRelativePath) -> String {
        let escaped = subtree.rawValue
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return escaped + "/%"
    }

    static func fetchCompanions(
        libraryRootID: Int64,
        db: Database
    ) throws -> [MediaCompanion] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT relative_path, primary_relative_path, kind, byte_size, content_modified_at
            FROM media_companion
            WHERE library_root_id = ?
            ORDER BY relative_path COLLATE NOCASE, relative_path
            """,
            arguments: [libraryRootID]
        ).compactMap { row in
            guard let kind = MediaCompanionKind(rawValue: row["kind"]) else {
                return nil
            }
            let primary: String? = row["primary_relative_path"]
            let modified: Double? = row["content_modified_at"]
            return MediaCompanion(
                relativePath: MediaRelativePath(rawValue: row["relative_path"]),
                primaryRelativePath: primary.map(MediaRelativePath.init(rawValue:)),
                kind: kind,
                byteSize: row["byte_size"],
                contentModifiedAt: modified.map(Date.init(timeIntervalSince1970:))
            )
        }
    }

    static func fetchPrimariesInDirectory(
        libraryRootID: Int64,
        directoryKey: String,
        db: Database
    ) throws -> [ScannedMediaFile] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT relative_path, name, content_type_identifier, kind, format,
                   byte_size, created_at_unix, content_modified_at_unix
            FROM media_asset
            WHERE library_root_id = ?
            """,
            arguments: [libraryRootID]
        )
        return rows.compactMap { row in
            let relativePath = MediaRelativePath(rawValue: row["relative_path"])
            guard MediaCompanionPairing.directoryKey(of: relativePath) == directoryKey else {
                return nil
            }
            let created: Double? = row["created_at_unix"]
            let modified: Double? = row["content_modified_at_unix"]
            let kindRaw: String? = row["kind"]
            let formatRaw: String? = row["format"]
            return ScannedMediaFile(
                relativePath: relativePath,
                name: row["name"],
                contentTypeIdentifier: row["content_type_identifier"],
                byteSize: row["byte_size"],
                createdAt: created.map(Date.init(timeIntervalSince1970:)),
                contentModifiedAt: modified.map(Date.init(timeIntervalSince1970:)),
                kind: kindRaw.flatMap(MediaKind.init(rawValue:)),
                format: formatRaw.map(MediaFormatToken.init(rawValue:))
            )
        }
    }

    static func fetchCompanionsInDirectory(
        libraryRootID: Int64,
        directoryKey: String,
        db: Database
    ) throws -> [ScannedCompanionFile] {
        try fetchCompanions(libraryRootID: libraryRootID, db: db)
            .filter { MediaCompanionPairing.directoryKey(of: $0.relativePath) == directoryKey }
            .map {
                ScannedCompanionFile(
                    relativePath: $0.relativePath,
                    kind: $0.kind,
                    byteSize: $0.byteSize,
                    contentModifiedAt: $0.contentModifiedAt
                )
            }
    }

    @discardableResult
    static func upsertCompanion(
        _ companion: MediaCompanion,
        libraryRootID: Int64,
        db: Database
    ) throws -> Bool {
        try db.execute(
            sql: """
            INSERT INTO media_companion (
                library_root_id,
                relative_path,
                primary_relative_path,
                kind,
                byte_size,
                content_modified_at
            )
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(library_root_id, relative_path) DO UPDATE SET
                primary_relative_path = excluded.primary_relative_path,
                kind = excluded.kind,
                byte_size = excluded.byte_size,
                content_modified_at = excluded.content_modified_at
            WHERE media_companion.primary_relative_path IS NOT excluded.primary_relative_path
               OR media_companion.kind IS NOT excluded.kind
               OR media_companion.byte_size IS NOT excluded.byte_size
               OR CAST(COALESCE(media_companion.content_modified_at, -1) AS INTEGER)
                  IS NOT CAST(COALESCE(excluded.content_modified_at, -1) AS INTEGER)
            """,
            arguments: [
                libraryRootID,
                companion.relativePath.rawValue,
                companion.primaryRelativePath?.rawValue,
                companion.kind.rawValue,
                companion.byteSize,
                companion.contentModifiedAt?.timeIntervalSince1970,
            ]
        )
        return db.changesCount > 0
    }

    @discardableResult
    static func deleteCompanionRow(
        rootRowID: Int64,
        relativePath: MediaRelativePath,
        db: Database
    ) throws -> Bool {
        try db.execute(
            sql: """
            DELETE FROM media_companion
            WHERE library_root_id = ? AND relative_path = ?
            """,
            arguments: [rootRowID, relativePath.rawValue]
        )
        return db.changesCount > 0
    }

    /// Re-derives `primary_relative_path` for every companion in the directory
    /// that contains `relativePath` (targeted FSEvents / media upsert path).
    @discardableResult
    static func repairCompanionsInDirectory(
        of relativePath: MediaRelativePath,
        libraryRootID: Int64,
        db: Database
    ) throws -> Bool {
        let directoryKey = MediaCompanionPairing.directoryKey(of: relativePath)
        let primaries = try fetchPrimariesInDirectory(
            libraryRootID: libraryRootID,
            directoryKey: directoryKey,
            db: db
        )
        let companions = try fetchCompanionsInDirectory(
            libraryRootID: libraryRootID,
            directoryKey: directoryKey,
            db: db
        )
        guard !companions.isEmpty else {
            return false
        }
        let paired = MediaCompanionPairing.pair(companions: companions, primaries: primaries)
        var changed = false
        for companion in paired {
            if try upsertCompanion(companion, libraryRootID: libraryRootID, db: db) {
                changed = true
            }
        }
        return changed
    }

    static func applyScannedCompanions(
        _ companions: [ScannedCompanionFile],
        libraryRootID: Int64,
        db: Database
    ) throws -> Int {
        var changedCount = 0
        let byDirectory = Dictionary(grouping: companions) {
            MediaCompanionPairing.directoryKey(of: $0.relativePath)
        }
        for (directoryKey, directoryCompanions) in byDirectory {
            let primaries = try fetchPrimariesInDirectory(
                libraryRootID: libraryRootID,
                directoryKey: directoryKey,
                db: db
            )
            let paired = MediaCompanionPairing.pair(
                companions: directoryCompanions,
                primaries: primaries
            )
            for companion in paired {
                if try upsertCompanion(companion, libraryRootID: libraryRootID, db: db) {
                    changedCount += 1
                }
            }
        }
        return changedCount
    }

    static func reconcileMissingCompanions(
        libraryRootID: Int64,
        observedPaths: Set<MediaRelativePath>,
        underSubtree: MediaRelativePath? = nil,
        db: Database
    ) throws -> Int {
        let existing = try fetchExistingCompanionPaths(
            libraryRootID: libraryRootID,
            underSubtree: underSubtree,
            db: db
        )
        let missing = existing.subtracting(observedPaths)
        var deleted = 0
        for path in missing {
            if try deleteCompanionRow(rootRowID: libraryRootID, relativePath: path, db: db) {
                deleted += 1
            }
        }
        return deleted
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

private nonisolated func addImportProvenanceColumns(_ db: Database) throws {
    let columns = try Set(String.fetchAll(
        db,
        sql: "SELECT name FROM pragma_table_xinfo('media_asset')"
    ))
    if !columns.contains("import_source_root_path") {
        try db.execute(sql: "ALTER TABLE media_asset ADD COLUMN import_source_root_path TEXT")
    }
    if !columns.contains("import_source_relative_path") {
        try db.execute(sql: "ALTER TABLE media_asset ADD COLUMN import_source_relative_path TEXT")
    }
    if !columns.contains("import_source_byte_size") {
        try db.execute(sql: "ALTER TABLE media_asset ADD COLUMN import_source_byte_size INTEGER")
    }
    if !columns.contains("import_source_modified_at_epoch") {
        try db.execute(sql: "ALTER TABLE media_asset ADD COLUMN import_source_modified_at_epoch DOUBLE")
    }
    if !columns.contains("import_destination_byte_size") {
        try db.execute(sql: "ALTER TABLE media_asset ADD COLUMN import_destination_byte_size INTEGER")
    }
    if !columns.contains("import_destination_modified_at_epoch") {
        try db.execute(sql: "ALTER TABLE media_asset ADD COLUMN import_destination_modified_at_epoch DOUBLE")
    }
}

private nonisolated func addImportHistoryAndCaptureWallColumns(_ db: Database) throws {
    let columns = try Set(String.fetchAll(
        db,
        sql: "SELECT name FROM pragma_table_xinfo('media_asset')"
    ))
    if !columns.contains("import_batch_unix_ms") {
        try db.execute(sql: "ALTER TABLE media_asset ADD COLUMN import_batch_unix_ms INTEGER")
    }
    if !columns.contains("capture_wall_compact") {
        try db.execute(sql: "ALTER TABLE media_asset ADD COLUMN capture_wall_compact INTEGER")
    }
    if !columns.contains("capture_wall_precision") {
        try db.execute(sql: "ALTER TABLE media_asset ADD COLUMN capture_wall_precision TEXT")
    }
    try db.execute(
        sql: """
        CREATE INDEX IF NOT EXISTS idx_media_asset_import_batch
        ON media_asset(import_batch_unix_ms, library_root_id, relative_path)
        WHERE import_batch_unix_ms IS NOT NULL
        """
    )
}

/// Backfills `capture_wall_*` from already-persisted metadata JSON so enriched rows
/// do not wait for a size/mtime change to re-enrich. Rows without stored metadata
/// stay NULL until their next enrichment write.
private nonisolated func backfillCaptureWallFromMetadataJSON(_ db: Database) throws {
    let rows = try Row.fetchAll(
        db,
        sql: """
        SELECT m.library_root_id, m.relative_path, a.metadata_extra_json
        FROM media_asset m
        LEFT JOIN asset_metadata a
            ON a.library_root_id = m.library_root_id
           AND a.relative_path = m.relative_path
        WHERE m.capture_wall_compact IS NULL
          AND a.metadata_extra_json IS NOT NULL
        """
    )
    for row in rows {
        let libraryRootID: Int64 = row["library_root_id"]
        let relativePath: String = row["relative_path"]
        let json: String = row["metadata_extra_json"]
        guard let metadata = CatalogStore.decodeMetadataExtraJSON(json),
              let wall = CaptureWallClock.select(from: metadata.timestamps)
        else {
            continue
        }
        try db.execute(
            sql: """
            UPDATE media_asset
            SET capture_wall_compact = ?, capture_wall_precision = ?
            WHERE library_root_id = ? AND relative_path = ?
            """,
            arguments: [wall.compact, wall.precision, libraryRootID, relativePath]
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
        duration_seconds DOUBLE,
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
        WHERE \(EnrichmentLeaseGateway.stalenessSQLPredicate())
        """
    )
    try db.execute(
        sql: """
        CREATE INDEX idx_media_asset_needs_enrichment_root
        ON media_asset(library_root_id, best_capture_unix DESC, relative_path)
        WHERE \(EnrichmentLeaseGateway.stalenessSQLPredicate())
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
        "duration_seconds",
        "enrichment_claimed_until",
        "import_batch_unix_ms",
        "capture_wall_compact",
        "capture_wall_precision",
    ]
}

private nonisolated func requiredCurrentLibraryRootColumns() -> Set<String> {
    [
        "id",
        "path",
        "kind",
        "device_identity",
        "display_name",
        "last_seen_at",
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
