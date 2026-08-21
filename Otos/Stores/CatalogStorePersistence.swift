import DiskArbitration
import Foundation
import GRDB
import OSLog

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
        // migrate additively. See ADR 0010.

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
            try createEnrichmentClaimIndexes(db, includeContentHash: false)

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
            try createEnrichmentClaimIndexes(db, includeContentHash: false)
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
        // FROZEN 2026-08. This is the SQL that shipped; it is a historical record of
        // what existing catalogs contain, not a description of current behaviour.
        // Never regenerate it from EnrichmentLeaseGateway, and never "fix" it to match
        // a newer predicate — doing so rewrites history for fresh installs only and
        // silently diverges them from every catalog already migrated through v12 in
        // the field. A new predicate needs a NEW migration. Text extracted verbatim
        // from `SELECT sql FROM sqlite_master` on a live migrated catalog
        // — do not hand-edit whitespace or clause order.
        migrator.registerMigration("v12_xxh3_content_hashes") { db in
            try addContentHashColumns(db)
            try db.drop(index: "idx_media_asset_needs_enrichment_global")
            try db.drop(index: "idx_media_asset_needs_enrichment_root")
            try db.execute(sql: """
            CREATE INDEX idx_media_asset_needs_enrichment_global
            ON media_asset(best_capture_unix DESC, library_root_id, relative_path)
            WHERE enriched_source_size IS NULL
               OR enriched_source_mtime IS NULL
               OR COALESCE(byte_size, -1) <> COALESCE(enriched_source_size, -1)
               OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
                  <> COALESCE(enriched_source_mtime, -1)
               OR content_hash_xxh3_128 IS NULL
               OR length(content_hash_xxh3_128) <> 16
               OR content_hash_source_size IS NULL
               OR content_hash_source_mtime IS NULL
               OR COALESCE(byte_size, -1) <> COALESCE(content_hash_source_size, -1)
               OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
                  <> COALESCE(content_hash_source_mtime, -1)
            """)
            try db.execute(sql: """
            CREATE INDEX idx_media_asset_needs_enrichment_root
            ON media_asset(library_root_id, best_capture_unix DESC, relative_path)
            WHERE enriched_source_size IS NULL
               OR enriched_source_mtime IS NULL
               OR COALESCE(byte_size, -1) <> COALESCE(enriched_source_size, -1)
               OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
                  <> COALESCE(enriched_source_mtime, -1)
               OR content_hash_xxh3_128 IS NULL
               OR length(content_hash_xxh3_128) <> 16
               OR content_hash_source_size IS NULL
               OR content_hash_source_mtime IS NULL
               OR COALESCE(byte_size, -1) <> COALESCE(content_hash_source_size, -1)
               OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
                  <> COALESCE(content_hash_source_mtime, -1)
            """)
        }
        // ADR 0018: hash production is gated on root kind — a
        // `.removableVolume` asset with current metadata is fully enriched even with
        // no hash. The broad pair from v12 stays for library/deviceMTP roots; this
        // adds a metadata-only pair so a removable-root row can leave the index
        // instead of staying pinned forever on `content_hash_xxh3_128 IS NULL`.
        //
        // FROZEN 2026-08, same rule as v12 above: this is a historical record, never
        // regenerated from EnrichmentLeaseGateway. Text extracted verbatim from a live
        // migrated catalog.
        migrator.registerMigration("v13_hash_gated_enrichment_claim_indexes") { db in
            try db.execute(sql: """
            CREATE INDEX idx_media_asset_needs_enrichment_global_metadata_only
            ON media_asset(best_capture_unix DESC, library_root_id, relative_path)
            WHERE enriched_source_size IS NULL
               OR enriched_source_mtime IS NULL
               OR COALESCE(byte_size, -1) <> COALESCE(enriched_source_size, -1)
               OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
                  <> COALESCE(enriched_source_mtime, -1)
            """)
            try db.execute(sql: """
            CREATE INDEX idx_media_asset_needs_enrichment_root_metadata_only
            ON media_asset(library_root_id, best_capture_unix DESC, relative_path)
            WHERE enriched_source_size IS NULL
               OR enriched_source_mtime IS NULL
               OR COALESCE(byte_size, -1) <> COALESCE(enriched_source_size, -1)
               OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
                  <> COALESCE(enriched_source_mtime, -1)
            """)
        }
        migrator.registerMigration("v14_media_choice") { db in
            try db.execute(sql: """
            ALTER TABLE media_asset ADD COLUMN media_choice TEXT NOT NULL DEFAULT 'notRated'
                CHECK (media_choice IN ('liked', 'notRated', 'disliked'))
            """)
        }
        migrator.registerMigration("v15_library_root_sort_index") { db in
            try db.execute(sql: "ALTER TABLE library_root ADD COLUMN sort_index INTEGER NOT NULL DEFAULT 0")
            try backfillLibraryRootSortIndex(db)
        }
        migrator.registerMigration("v16_remove_disk_image_removable_roots") { db in
            try removeDiskImageRemovableRoots(db)
        }
        migrator.registerMigration("v17_namespace_capabilities_and_path_keys") { db in
            try addNamespaceCapabilityColumns(db)
            try removeRecordedDiskImageRemovableRoots(db)
            try addRelativePathKeyColumns(db)
            try backfillRelativePathKeys(db)
        }
        migrator.registerMigration("v18_source_erase_journal") { db in
            try createActiveSourceEraseTable(db)
        }
        // Unicode normalization was never a per-volume fact: every production
        // caller passed the same value, and modelling it per volume let one path
        // produce two comparison keys. See
        // `docs/research/2026-08-21-volume-normalization-is-not-a-capability.md`.
        migrator.registerMigration("v19_drop_unicode_normalization_capability") { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(library_root)")
                .compactMap { $0["name"] as String? }
            if columns.contains("prefers_decomposed_unicode") {
                try db.execute(sql: "ALTER TABLE library_root DROP COLUMN prefers_decomposed_unicode")
            }
        }
        return migrator
    }

    /// Plan 0095 D10 backstop. `RemovableVolumeMonitor.currentAttachments`
    /// used to accept any mounted volume with `volumeIsRemovable == true`
    /// alone, which a mounted disk image also satisfies — production
    /// evidence held `/Volumes/Raycast` and `/Volumes/BoltAI 2`, both
    /// app-installer DMGs, as permanent removable sources. The monitor now
    /// excludes disk images at the source (`RemovableVolumeMonitor.
    /// isPhysicalRemovableDevice`); this one-time pass removes rows that
    /// already slipped through, keyed on the identical live
    /// `DiskArbitration` predicate.
    ///
    /// Additive-safe by construction: a row is deleted only when its path is
    /// *currently* mountable and `DiskArbitration` positively reports
    /// `"Disk Image"` right now. A root whose volume is not currently
    /// attached is left untouched — `deviceModel(forVolumeAt:session:)`
    /// returns `nil` for both "not mounted" and "no answer," and this
    /// migration only acts on the positive `"Disk Image"` case, never on
    /// `nil` — matching the overlay-lifecycle rule that a temporarily-missing
    /// original is never treated as deleted (`docs/adr/0008-…`). Originals on
    /// disk are untouched either way; this removes only Otos's own catalog
    /// rows, and `library_root.id`'s `ON DELETE CASCADE` foreign keys take
    /// every row that referenced it (media assets, companions, choices) with it.
    private static func removeDiskImageRemovableRoots(_ db: Database) throws {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, path FROM library_root WHERE kind = ?",
            arguments: [LibraryRootKind.removableVolume.rawValue]
        )
        guard !rows.isEmpty else {
            return
        }
        let session = DASessionCreate(kCFAllocatorDefault)
        for row in rows {
            let id: Int64 = row["id"]
            let path: String = row["path"]
            let url = URL(fileURLWithPath: path, isDirectory: true)
            guard RemovableVolumeMonitor.deviceModel(forVolumeAt: url, session: session) == "Disk Image" else {
                continue
            }
            try db.execute(sql: "DELETE FROM library_root WHERE id = ?", arguments: [id])
        }
    }

    /// v17 closes the v16 gap for roots that were detached when the earlier
    /// migration ran. The persisted device model is authoritative when known;
    /// unknown legacy roots remain untouched.
    private static func removeRecordedDiskImageRemovableRoots(_ db: Database) throws {
        try db.execute(
            sql: """
            DELETE FROM library_root
            WHERE kind = ? AND device_model = ?
            """,
            arguments: [LibraryRootKind.removableVolume.rawValue, "Disk Image"]
        )
    }

    /// Backfills `sort_index` in **today's displayed order** so upgrading does not
    /// reshuffle the sidebar. That order is the display
    /// name (falling back to the path's last component), the same comparison
    /// `CatalogWindowPolicy.sortLibraries` used before this migration made the
    /// column authoritative — replicated here in Swift because SQLite has no
    /// locale-aware string comparison. Only library-kind roots get a meaningful
    /// order; removable sources are ordered by display name at query time
    /// regardless of this column, so insertion order is a harmless default for them.
    private static func backfillLibraryRootSortIndex(_ db: Database) throws {
        struct LegacyRoot { let id: Int64
            let path: String
            let displayName: String?
        }
        let rows = try Row.fetchAll(db, sql: "SELECT id, path, display_name, kind FROM library_root")
        let libraries = rows.filter { ($0["kind"] as String?) == LibraryRootKind.library.rawValue }
            .map { LegacyRoot(id: $0["id"], path: $0["path"], displayName: $0["display_name"]) }
        let others = rows.filter { ($0["kind"] as String?) != LibraryRootKind.library.rawValue }
            .map { LegacyRoot(id: $0["id"], path: $0["path"], displayName: $0["display_name"]) }

        func effectiveDisplayName(_ root: LegacyRoot) -> String {
            if let displayName = root.displayName, !displayName.isEmpty {
                return displayName
            }
            let name = (root.path as NSString).lastPathComponent
            return name.isEmpty ? root.path : name
        }
        let orderedLibraries = libraries.sorted { left, right in
            let comparison = effectiveDisplayName(left).localizedStandardCompare(effectiveDisplayName(right))
            if comparison == .orderedSame {
                return left.path.localizedStandardCompare(right.path) == .orderedAscending
            }
            return comparison == .orderedAscending
        }
        for (index, root) in orderedLibraries.enumerated() {
            try db.execute(sql: "UPDATE library_root SET sort_index = ? WHERE id = ?", arguments: [index, root.id])
        }
        for root in others.sorted(by: { $0.id < $1.id }) {
            try db.execute(sql: "UPDATE library_root SET sort_index = ? WHERE id = ?", arguments: [root.id, root.id])
        }
    }

    /// Rebuilds `asset_metadata` so path remaps cascade with media_asset PK updates
    /// (ARC-043). SQLite cannot ALTER an existing FK action in place.
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
                content_hash_xxh3_128 BLOB,
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

    static func createActiveSourceEraseTable(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE active_source_erase (
            operation_key TEXT PRIMARY KEY NOT NULL,
            source_kind TEXT NOT NULL,
            source_device_identity TEXT,
            source_root_path TEXT NOT NULL,
            source_relative_path TEXT NOT NULL,
            source_byte_size INTEGER,
            updated_at DOUBLE NOT NULL
        )
        """)
    }

    static func createMediaCompanionTable(_ db: Database) throws {
        try db.execute(
            sql: """
            CREATE TABLE media_companion (
                library_root_id INTEGER NOT NULL,
                relative_path TEXT NOT NULL,
                relative_path_key TEXT NOT NULL DEFAULT '',
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
            SELECT id, path, kind, device_identity, display_name, last_seen_at, sort_index,
                   case_sensitive_names, device_model
            FROM library_root
            ORDER BY sort_index, path COLLATE NOCASE, path
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
                lastSeenAt: lastSeenUnix.map(Date.init(timeIntervalSince1970:)),
                sortIndex: row["sort_index"],
                // NULL means never probed. `isKnown` and the stored value are one
                // fact, written and read together, so an unprobed root cannot
                // read back as a confidently case-insensitive one.
                capabilities: (row["case_sensitive_names"] as Int?).map {
                    VolumeNamespaceCapabilities(isCaseSensitive: $0 == 1, isKnown: true)
                } ?? .unknown,
                deviceModel: row["device_model"]
            )
        }
        let assetCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_asset") ?? 0
        return (roots, assetCount)
    }

    /// One past the highest `sort_index` currently in use, so a newly added root
    /// (library or removable) appends after everything else rather than colliding.
    /// Global rather than scoped to `kind` — the column is only *meaningful* for
    /// ordering library-kind roots (`import-bar.md`), but
    /// every row needs some value, and a single counter is simpler than two.
    static func nextLibraryRootSortIndex(db: Database) throws -> Int64 {
        try (Int64.fetchOne(db, sql: "SELECT MAX(sort_index) FROM library_root") ?? -1) + 1
    }

    static func insertLibraryRoot(
        path: LibraryRootPath,
        kind: LibraryRootKind = .library,
        deviceIdentity: String? = nil,
        displayName: String? = nil,
        lastSeenAt: Date? = nil,
        sortIndex: Int64? = nil,
        capabilities: VolumeNamespaceCapabilities = .unknown,
        deviceModel: String? = nil,
        db: Database
    ) throws -> StoredRoot {
        let resolvedSortIndex = try sortIndex ?? nextLibraryRootSortIndex(db: db)
        try db.execute(
            sql: """
            INSERT INTO library_root (
                path, kind, device_identity, display_name, last_seen_at, sort_index,
                case_sensitive_names, device_model
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                path.rawValue,
                kind.rawValue,
                deviceIdentity,
                displayName,
                lastSeenAt?.timeIntervalSince1970,
                resolvedSortIndex,
                capabilities.storedCaseSensitiveColumn,
                deviceModel,
            ]
        )
        return StoredRoot(
            id: db.lastInsertedRowID,
            path: path,
            kind: kind,
            deviceIdentity: deviceIdentity,
            displayName: displayName,
            lastSeenAt: lastSeenAt,
            sortIndex: resolvedSortIndex,
            capabilities: capabilities,
            deviceModel: deviceModel
        )
    }

    /// Writes new `sort_index` values for a reordered set of library roots. The
    /// caller (`CatalogStore.moveLibrary(from:to:)`) computes the reordered array;
    /// this only persists it. One statement per row rather than a single UPDATE
    /// with a CASE expression — the set is sidebar-sized (tens, not thousands) and
    /// this reads far more directly than a generated CASE list.
    static func writeLibraryRootSortIndexes(_ pathsInOrder: [LibraryRootPath], db: Database) throws {
        for (index, path) in pathsInOrder.enumerated() {
            try db.execute(
                sql: "UPDATE library_root SET sort_index = ? WHERE path = ?",
                arguments: [index, path.rawValue]
            )
        }
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
        capabilities: VolumeNamespaceCapabilities = .unknown,
        deviceModel: String? = nil,
        db: Database
    ) throws {
        try db.execute(
            sql: """
            UPDATE library_root
            SET path = ?, display_name = ?, last_seen_at = ?,
                case_sensitive_names = ?, device_model = ?
            WHERE id = ?
            """,
            arguments: [
                path.rawValue,
                displayName,
                lastSeenAt?.timeIntervalSince1970,
                capabilities.storedCaseSensitiveColumn,
                deviceModel,
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

    /// Hash columns use `COALESCE(?, column)` rather than a plain assignment: when
    /// `result.contentHash` is absent (a `.removableVolume` source, ADR 0018),
    /// the row's existing digest — if any was recorded before the source's
    /// root kind or facts changed — must survive, not be clobbered to NULL.
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
                content_hash_xxh3_128 = COALESCE(?, content_hash_xxh3_128),
                content_hash_source_size = COALESCE(?, content_hash_source_size),
                content_hash_source_mtime = COALESCE(?, content_hash_source_mtime),
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
                result.contentHash?.data,
                result.contentHash != nil ? result.sourceSize : nil,
                result.contentHash != nil ? result.sourceMTimeSeconds : nil,
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

    static func writeReusableEnrichmentOverlay(
        _ overlay: ReusableEnrichmentOverlay,
        destinationRootID: Int64,
        destinationRelativePath: MediaRelativePath,
        destinationByteSize: Int64,
        destinationMTimeSeconds: Int,
        contentHash: XXH3Digest128,
        thumbnailPath: String?,
        db: Database
    ) throws {
        let captureWall = CaptureWallClock.select(from: overlay.metadata.timestamps)
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
                content_hash_xxh3_128 = ?,
                content_hash_source_size = ?,
                content_hash_source_mtime = ?,
                capture_wall_compact = ?,
                capture_wall_precision = ?
            WHERE library_root_id = ? AND relative_path = ?
            """,
            arguments: [
                thumbnailPath,
                overlay.originalTimestamp?.timeIntervalSince1970,
                overlay.quickTimeCreationTimestamp?.timeIntervalSince1970,
                overlay.digitizedTimestamp?.timeIntervalSince1970,
                overlay.gpsTimestamp?.timeIntervalSince1970,
                overlay.enrichedKind?.rawValue,
                overlay.enrichedFormat?.rawValue,
                overlay.durationSeconds,
                destinationByteSize,
                destinationMTimeSeconds,
                contentHash.data,
                destinationByteSize,
                destinationMTimeSeconds,
                captureWall?.compact,
                captureWall?.precision,
                destinationRootID,
                destinationRelativePath.rawValue,
            ]
        )
        try upsertAssetMetadata(
            overlay.metadata,
            libraryRootID: destinationRootID,
            relativePath: destinationRelativePath,
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
    ) throws -> [(relativePath: MediaRelativePath, thumbnailPath: String?, hadEnrichment: Bool)] {
        let rows: [Row] = if let underSubtree {
            // Component-safe: `a/b` matches itself and `a/b/...`, never `a/b2`.
            try Row.fetchAll(
                db,
                sql: """
                SELECT relative_path, thumbnail_path, enriched_source_size, enriched_source_mtime
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
                SELECT relative_path, thumbnail_path, enriched_source_size, enriched_source_mtime
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
                thumbnailPath: thumbnailPath,
                hadEnrichment: (row["enriched_source_size"] as Int64?) != nil
                    || (row["enriched_source_mtime"] as Int64?) != nil
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
        capabilities: VolumeNamespaceCapabilities = .unknown,
        db: Database
    ) throws -> Bool {
        let pathKey = FilesystemNamespaceSemantics.nameKey(
            relativePath: companion.relativePath,
            capabilities: capabilities
        ).rawValue
        if let existingPath: String = try String.fetchOne(
            db,
            sql: "SELECT relative_path FROM media_companion WHERE library_root_id = ? AND relative_path_key = ? AND relative_path <> ? LIMIT 1",
            arguments: [libraryRootID, pathKey, companion.relativePath.rawValue]
        ) {
            try db.execute(
                sql: "UPDATE media_companion SET relative_path = ?, relative_path_key = ? WHERE library_root_id = ? AND relative_path = ?",
                arguments: [companion.relativePath.rawValue, pathKey, libraryRootID, existingPath]
            )
            let message = "op=catalog.scan.reconcile phase=respellCompanion "
                + "rootID=\(libraryRootID) "
                + "from=\(existingPath) "
                + "to=\(companion.relativePath.rawValue)"
            OtosLog.catalog.notice("\(message, privacy: .public)")
            return true
        }
        try db.execute(
            sql: """
            INSERT INTO media_companion (
                library_root_id,
                relative_path,
                relative_path_key,
                primary_relative_path,
                kind,
                byte_size,
                content_modified_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
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
                pathKey,
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
        capabilities: VolumeNamespaceCapabilities = .unknown,
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
            if try upsertCompanion(companion, libraryRootID: libraryRootID, capabilities: capabilities, db: db) {
                changed = true
            }
        }
        return changed
    }

    static func applyScannedCompanions(
        _ companions: [ScannedCompanionFile],
        libraryRootID: Int64,
        capabilities: VolumeNamespaceCapabilities = .unknown,
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
                if try upsertCompanion(companion, libraryRootID: libraryRootID, capabilities: capabilities, db: db) {
                    changedCount += 1
                }
            }
        }
        return changedCount
    }

    static func reconcileMissingCompanions(
        libraryRootID: Int64,
        observedPaths: Set<MediaRelativePath>,
        capabilities: VolumeNamespaceCapabilities = .unknown,
        underSubtree: MediaRelativePath? = nil,
        db: Database
    ) throws -> Int {
        let existing = try fetchExistingCompanionPaths(
            libraryRootID: libraryRootID,
            underSubtree: underSubtree,
            db: db
        )
        var existingKeys: [FilesystemNameKey: MediaRelativePath] = [:]
        var ambiguousKeys = Set<FilesystemNameKey>()
        for path in existing {
            let key = FilesystemNamespaceSemantics.nameKey(relativePath: path, capabilities: capabilities)
            if existingKeys[key] != nil {
                ambiguousKeys.insert(key)
            } else {
                existingKeys[key] = path
            }
        }
        let observedKeys = Set(observedPaths.map {
            FilesystemNamespaceSemantics.nameKey(relativePath: $0, capabilities: capabilities)
        })
        let missing = existingKeys
            .filter { !ambiguousKeys.contains($0.key) && !observedKeys.contains($0.key) }
            .map(\.value)
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
        capabilities: VolumeNamespaceCapabilities = .unknown,
        db: Database
    ) throws -> Bool {
        let pathKey = FilesystemNamespaceSemantics.nameKey(
            relativePath: file.relativePath,
            capabilities: capabilities
        ).rawValue
        if let existingPath: String = try String.fetchOne(
            db,
            sql: "SELECT relative_path FROM media_asset WHERE library_root_id = ? AND relative_path_key = ? AND relative_path <> ? LIMIT 1",
            arguments: [libraryRootID, pathKey, file.relativePath.rawValue]
        ) {
            try db.execute(
                sql: "UPDATE media_asset SET relative_path = ?, relative_path_key = ? WHERE library_root_id = ? AND relative_path = ?",
                arguments: [file.relativePath.rawValue, pathKey, libraryRootID, existingPath]
            )
            let message = "op=catalog.scan.reconcile phase=respell "
                + "rootPath=\(libraryRootPath.rawValue) "
                + "from=\(existingPath) "
                + "to=\(file.relativePath.rawValue)"
            OtosLog.catalog.notice("\(message, privacy: .public)")
            return true
        }
        // The compound key makes a scan idempotent: observing the same relative
        // path refreshes its current filesystem facts instead of creating scan
        // history or a second asset identity.
        try db.execute(
            sql: """
            INSERT INTO media_asset (
                library_root_id,
                relative_path,
                relative_path_key,
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
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                libraryRootID: libraryRootID,
                pathKey: pathKey
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

private nonisolated func addNamespaceCapabilityColumns(_ db: Database) throws {
    let columns = try Set(String.fetchAll(db, sql: "SELECT name FROM pragma_table_xinfo('library_root')"))
    if !columns.contains("case_sensitive_names") {
        try db.execute(sql: "ALTER TABLE library_root ADD COLUMN case_sensitive_names INTEGER")
    }
    if !columns.contains("prefers_decomposed_unicode") {
        try db.execute(sql: "ALTER TABLE library_root ADD COLUMN prefers_decomposed_unicode INTEGER")
    }
    if !columns.contains("device_model") {
        try db.execute(sql: "ALTER TABLE library_root ADD COLUMN device_model TEXT")
    }
}

private nonisolated func addRelativePathKeyColumns(_ db: Database) throws {
    let mediaColumns = try Set(String.fetchAll(db, sql: "SELECT name FROM pragma_table_xinfo('media_asset')"))
    if !mediaColumns.contains("relative_path_key") {
        try db.execute(sql: "ALTER TABLE media_asset ADD COLUMN relative_path_key TEXT NOT NULL DEFAULT ''")
    }
    let companionColumns = try Set(String.fetchAll(db, sql: "SELECT name FROM pragma_table_xinfo('media_companion')"))
    if !companionColumns.isEmpty, !companionColumns.contains("relative_path_key") {
        try db.execute(sql: "ALTER TABLE media_companion ADD COLUMN relative_path_key TEXT NOT NULL DEFAULT ''")
    }
    try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_media_asset_relative_path_key ON media_asset(library_root_id, relative_path_key)")
    if !companionColumns.isEmpty {
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_media_companion_relative_path_key ON media_companion(library_root_id, relative_path_key)")
    }
}

private nonisolated func backfillRelativePathKeys(_ db: Database) throws {
    let roots = try Row.fetchAll(
        db,
        sql: "SELECT id, case_sensitive_names FROM library_root"
    )
    for root in roots {
        let rootID: Int64 = root["id"]
        guard let caseSensitive = root["case_sensitive_names"] as Int? else { continue }
        let capabilities = VolumeNamespaceCapabilities(isCaseSensitive: caseSensitive == 1, isKnown: true)
        let assets = try Row.fetchAll(
            db,
            sql: """
            SELECT relative_path, relative_path_key, import_batch_unix_ms,
                   enriched_source_size, enriched_source_mtime, thumbnail_path
            FROM media_asset
            WHERE library_root_id = ?
            """,
            arguments: [rootID]
        )
        var owners: [String: Row] = [:]
        for row in assets {
            let path: String = row["relative_path"]
            let key = FilesystemNamespaceSemantics.nameKey(
                relativePath: MediaRelativePath(rawValue: path),
                capabilities: capabilities
            ).rawValue
            if let existing = owners[key] {
                let existingImported: Int64? = existing["import_batch_unix_ms"]
                let currentImported: Int64? = row["import_batch_unix_ms"]
                let existingEnriched: Bool = existing["enriched_source_size"] != nil && existing["enriched_source_mtime"] != nil
                let currentEnriched: Bool = row["enriched_source_size"] != nil && row["enriched_source_mtime"] != nil
                let keepCurrent = (currentImported != nil && existingImported == nil)
                    || (currentImported == existingImported && currentEnriched && !existingEnriched)
                    || (currentImported == existingImported && currentEnriched == existingEnriched && path < (existing["relative_path"] as String))
                let keeper = keepCurrent ? row : existing
                let loser = keepCurrent ? existing : row
                let keeperPath: String = keeper["relative_path"]
                let loserPath: String = loser["relative_path"]
                try db.execute(sql: "DELETE FROM media_asset WHERE library_root_id = ? AND relative_path = ?", arguments: [rootID, loserPath])
                owners[key] = keeper
                let message = "op=catalog.schema phase=mergePathCollision "
                    + "rootID=\(rootID) "
                    + "kept=\(keeperPath) "
                    + "deleted=\(loserPath)"
                OtosLog.persistence.notice("\(message, privacy: .public)")
            } else {
                owners[key] = row
            }
            try db.execute(
                sql: "UPDATE media_asset SET relative_path_key = ? WHERE library_root_id = ? AND relative_path = ?",
                arguments: [key, rootID, path]
            )
        }
        let companions = try Row.fetchAll(
            db,
            sql: "SELECT relative_path, relative_path_key FROM media_companion WHERE library_root_id = ?",
            arguments: [rootID]
        )
        var companionOwners: [String: String] = [:]
        for companion in companions {
            let path: String = companion["relative_path"]
            let key = FilesystemNamespaceSemantics.nameKey(
                relativePath: MediaRelativePath(rawValue: path),
                capabilities: capabilities
            ).rawValue
            if let existingPath = companionOwners[key], existingPath != path {
                let keep = min(existingPath, path)
                let drop = max(existingPath, path)
                try db.execute(
                    sql: "DELETE FROM media_companion WHERE library_root_id = ? AND relative_path = ?",
                    arguments: [rootID, drop]
                )
                companionOwners[key] = keep
                let message = "op=catalog.schema phase=mergeCompanionPathCollision "
                    + "rootID=\(rootID) "
                    + "kept=\(keep) "
                    + "deleted=\(drop)"
                OtosLog.persistence.notice("\(message, privacy: .public)")
                if path == drop {
                    continue
                }
            } else {
                companionOwners[key] = path
            }
            try db.execute(
                sql: "UPDATE media_companion SET relative_path_key = ? WHERE library_root_id = ? AND relative_path = ?",
                arguments: [key, rootID, path]
            )
        }
    }
}

private nonisolated func addContentHashColumns(_ db: Database) throws {
    let mediaColumns = try Set(String.fetchAll(
        db,
        sql: "SELECT name FROM pragma_table_xinfo('media_asset')"
    ))
    if !mediaColumns.contains("content_hash_xxh3_128") {
        try db.execute(sql: "ALTER TABLE media_asset ADD COLUMN content_hash_xxh3_128 BLOB")
    }
    if !mediaColumns.contains("content_hash_source_size") {
        try db.execute(sql: "ALTER TABLE media_asset ADD COLUMN content_hash_source_size INTEGER")
    }
    if !mediaColumns.contains("content_hash_source_mtime") {
        try db.execute(sql: "ALTER TABLE media_asset ADD COLUMN content_hash_source_mtime INTEGER")
    }
    let operationColumns = try Set(String.fetchAll(
        db,
        sql: "SELECT name FROM pragma_table_xinfo('active_file_operation')"
    ))
    if !operationColumns.contains("content_hash_xxh3_128") {
        try db.execute(sql: "ALTER TABLE active_file_operation ADD COLUMN content_hash_xxh3_128 BLOB")
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
        relative_path_key TEXT NOT NULL DEFAULT '',
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
        content_hash_xxh3_128 BLOB,
        content_hash_source_size INTEGER,
        content_hash_source_mtime INTEGER,
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

private nonisolated func createEnrichmentClaimIndexes(
    _ db: Database,
    includeContentHash: Bool,
    globalIndexName: String = EnrichmentLeaseGateway.broadGlobalIndexName,
    rootIndexName: String = EnrichmentLeaseGateway.broadRootIndexName
) throws {
    let predicate = EnrichmentLeaseGateway.stalenessSQLPredicate(hashRequired: includeContentHash)
    try db.execute(
        sql: """
        CREATE INDEX \(globalIndexName)
        ON media_asset(best_capture_unix DESC, library_root_id, relative_path)
        WHERE \(predicate)
        """
    )
    try db.execute(
        sql: """
        CREATE INDEX \(rootIndexName)
        ON media_asset(library_root_id, best_capture_unix DESC, relative_path)
        WHERE \(predicate)
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
        "relative_path_key",
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
        "media_choice",
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
        "case_sensitive_names",
        "device_model",
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
    libraryRootID: Int64,
    pathKey: String
) -> StatementArguments {
    let values: [(any DatabaseValueConvertible)?] = [
        libraryRootID,
        file.relativePath.rawValue,
        pathKey,
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
