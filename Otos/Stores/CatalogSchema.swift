import Foundation

/// The catalog's schema, as the one baseline migration creates it.
///
/// Otos had no users when the incremental history (v3–v23) was replaced by this
/// baseline (ADR 0010), so there is no older catalog to upgrade: a catalog whose
/// migration history this build does not know is refused unopened, like any other.
/// Changes from here on are additive migrations registered after the baseline.
///
/// Statements run in order inside the baseline migration's transaction. Column order
/// within a table is the order a row reads in; nothing depends on it, but it is kept
/// stable so a schema dump stays comparable across builds.
nonisolated enum CatalogSchema {
    static let baselineMigrationIdentifier = "v1_catalog_baseline"

    /// The move witness's scan fact (ADR 0008): each file's identifier on its volume,
    /// written by every scan upsert. Rows from before the column read `NULL` until their
    /// next scan, and a `NULL` never witnesses a move.
    static let fileIdentifierMigrationIdentifier = "v2_media_asset_file_identifier"

    static let fileIdentifierStatements: [String] = [
        "ALTER TABLE media_asset ADD COLUMN file_identifier INTEGER",
        """
        CREATE INDEX idx_media_asset_file_identifier
        ON media_asset(file_identifier) WHERE file_identifier IS NOT NULL
        """,
    ]

    /// The stored loupe preview (ADR 0035): its relative path beside the thumbnail's.
    /// Library stills enriched before previews existed have neither a preview nor a
    /// rendered thumbnail, so their enrichment stamps are cleared here: the existing
    /// staleness predicate then claims them again, and re-enrichment renders both from
    /// the original — downloading it first when it is cloud-only, under the free-space
    /// floor (ENR-008). Card and camera rows are left alone; they re-enrich when next
    /// attached and changed, and are forgotten after 90 days unseen.
    static let previewPathMigrationIdentifier = "v3_media_asset_preview_path"

    static let previewPathStatements: [String] = [
        "ALTER TABLE media_asset ADD COLUMN preview_path TEXT",
        """
        UPDATE media_asset SET enriched_source_size = NULL, enriched_source_mtime = NULL
        WHERE kind = 'image'
          AND library_root_id IN (SELECT id FROM library_root WHERE kind = 'library')
        """,
    ]

    /// One current edit per photo (ADR 0036): the recipe's JSON, the revision it was saved
    /// as, and the revision the stored thumbnail and preview were rendered from. Columns
    /// on the asset row, as `media_choice` is, so every re-key, move and deletion carries
    /// the edit with the row; Move to Trash and import carry it explicitly.
    static let editRecipeMigrationIdentifier = "v4_media_asset_edit_recipe"

    static let editRecipeStatements: [String] = [
        "ALTER TABLE media_asset ADD COLUMN edit_recipe_json TEXT",
        "ALTER TABLE media_asset ADD COLUMN edit_revision INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE media_asset ADD COLUMN rendered_revision INTEGER NOT NULL DEFAULT 0",
    ]

    /// HEIF orientation from its transform properties (MediaMetadata 0.6.1). Earlier
    /// versions read orientation only from Exif, and a HEIF that records its rotation in an
    /// `irot` or `imir` property instead (Sony cameras, for one) was cataloged with no
    /// orientation, so its upright size read as its stored, unrotated one. Every library
    /// HEIF row with no orientation has its enrichment stamps cleared: the staleness
    /// predicate claims it again and re-enrichment reads its metadata anew, downloading a
    /// cloud-only original first under the free-space floor (ENR-008). An upright HEIF with
    /// no orientation tag is read again too; nothing short of its bytes tells them apart.
    /// Card and camera rows are left alone, as for v3.
    static let heifOrientationMigrationIdentifier = "v5_heif_orientation_reread"

    static let heifOrientationStatements: [String] = [
        """
        UPDATE media_asset SET enriched_source_size = NULL, enriched_source_mtime = NULL
        WHERE library_root_id IN (SELECT id FROM library_root WHERE kind = 'library')
          AND (library_root_id, relative_path) IN (
            SELECT library_root_id, relative_path FROM asset_metadata
            WHERE family = 'heif' AND orientation IS NULL
          )
        """,
    ]

    static let baselineStatements: [String] = [
        """
        CREATE TABLE library_root (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT NOT NULL UNIQUE,
            kind TEXT NOT NULL DEFAULT 'library',
            device_identity TEXT,
            display_name TEXT,
            last_seen_at DOUBLE,
            sort_index INTEGER NOT NULL DEFAULT 0,
            case_sensitive_names INTEGER,
            device_model TEXT
        )
        """,
        """
        CREATE UNIQUE INDEX idx_library_root_device_identity
        ON library_root(device_identity)
        WHERE device_identity IS NOT NULL
        """,
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
            enrichment_claimed DOUBLE,
            import_batch_unix_ms INTEGER,
            capture_wall_compact INTEGER,
            capture_wall_precision TEXT,
            import_source_root_path TEXT,
            import_source_relative_path TEXT,
            import_source_byte_size INTEGER,
            import_source_modified_at_epoch DOUBLE,
            import_destination_byte_size INTEGER,
            import_destination_modified_at_epoch DOUBLE,
            content_hash_xxh3_128 BLOB,
            content_hash_source_size INTEGER,
            content_hash_source_mtime INTEGER,
            media_choice TEXT NOT NULL DEFAULT 'notRated'
                CHECK (media_choice IN ('liked', 'notRated', 'disliked')),
            relative_path_key TEXT NOT NULL DEFAULT '',
            pending_trash_batch_unix_ms INTEGER,
            PRIMARY KEY (library_root_id, relative_path)
        )
        """,
        """
        CREATE INDEX idx_media_asset_order_global
        ON media_asset(sort_key, library_root_id, relative_path)
        """,
        """
        CREATE INDEX idx_media_asset_order_root
        ON media_asset(library_root_id, sort_key, relative_path)
        """,
        """
        CREATE INDEX idx_media_asset_best_capture_global_asc
        ON media_asset(best_capture_unix ASC, library_root_id, relative_path)
        """,
        """
        CREATE INDEX idx_media_asset_best_capture_root_asc
        ON media_asset(library_root_id, best_capture_unix ASC, relative_path)
        """,
        """
        CREATE INDEX idx_media_asset_name_global_asc
        ON media_asset(name_sort_key ASC, library_root_id, relative_path)
        """,
        """
        CREATE INDEX idx_media_asset_name_root_asc
        ON media_asset(library_root_id, name_sort_key ASC, relative_path)
        """,
        """
        CREATE INDEX idx_media_asset_size_global_asc
        ON media_asset((byte_size IS NULL), byte_size ASC, library_root_id, relative_path)
        """,
        """
        CREATE INDEX idx_media_asset_size_root_asc
        ON media_asset(library_root_id, (byte_size IS NULL), byte_size ASC, relative_path)
        """,
        """
        CREATE INDEX idx_media_asset_best_capture_global_desc
        ON media_asset(best_capture_unix DESC, library_root_id, relative_path)
        """,
        """
        CREATE INDEX idx_media_asset_best_capture_root_desc
        ON media_asset(library_root_id, best_capture_unix DESC, relative_path)
        """,
        """
        CREATE INDEX idx_media_asset_name_global_desc
        ON media_asset(name_sort_key DESC, library_root_id, relative_path)
        """,
        """
        CREATE INDEX idx_media_asset_name_root_desc
        ON media_asset(library_root_id, name_sort_key DESC, relative_path)
        """,
        """
        CREATE INDEX idx_media_asset_size_global_desc
        ON media_asset((byte_size IS NULL), byte_size DESC, library_root_id, relative_path)
        """,
        """
        CREATE INDEX idx_media_asset_size_root_desc
        ON media_asset(library_root_id, (byte_size IS NULL), byte_size DESC, relative_path)
        """,
        """
        CREATE INDEX idx_media_asset_import_batch
        ON media_asset(import_batch_unix_ms, library_root_id, relative_path)
        WHERE import_batch_unix_ms IS NOT NULL
        """,
        // Rows whose enrichment or content hash is missing or stale, newest first: the
        // claim query walks these, so their names and predicates are the gateway's. The
        // metadata-only pair serves roots that are not hashed.
        claimIndex(EnrichmentClaimGateway.broadGlobalIndexName, global: true, hashRequired: true),
        claimIndex(EnrichmentClaimGateway.broadRootIndexName, global: false, hashRequired: true),
        claimIndex(EnrichmentClaimGateway.metadataOnlyGlobalIndexName, global: true, hashRequired: false),
        claimIndex(EnrichmentClaimGateway.metadataOnlyRootIndexName, global: false, hashRequired: false),
        """
        CREATE INDEX idx_media_asset_relative_path_key
        ON media_asset(library_root_id, relative_path_key)
        """,
        """
        CREATE INDEX idx_media_asset_pending_trash
        ON media_asset(pending_trash_batch_unix_ms, library_root_id, relative_path)
        WHERE pending_trash_batch_unix_ms IS NOT NULL
        """,
        """
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
                ON UPDATE CASCADE
        )
        """,
        """
        CREATE INDEX idx_asset_metadata_camera_model
        ON asset_metadata(camera_model)
        """,
        """
        CREATE INDEX idx_asset_metadata_dimensions
        ON asset_metadata(pixel_width, pixel_height)
        """,
        """
        CREATE TABLE media_companion (
            library_root_id INTEGER NOT NULL,
            relative_path TEXT NOT NULL,
            primary_relative_path TEXT,
            kind TEXT NOT NULL,
            byte_size INTEGER,
            content_modified_at DOUBLE,
            relative_path_key TEXT NOT NULL DEFAULT '',
            PRIMARY KEY (library_root_id, relative_path),
            FOREIGN KEY (library_root_id) REFERENCES library_root(id) ON DELETE CASCADE
        )
        """,
        """
        CREATE INDEX idx_media_companion_primary
        ON media_companion(library_root_id, primary_relative_path)
        """,
        """
        CREATE INDEX idx_media_companion_relative_path_key
        ON media_companion(library_root_id, relative_path_key)
        """,
        // The import journal: one row per file an import is copying or publishing, naming
        // every staging file it creates (companions in the table after it).
        """
        CREATE TABLE active_file_operation (
            operation_key TEXT PRIMARY KEY NOT NULL,
            source_kind TEXT NOT NULL,
            source_device_identity TEXT,
            source_root_path TEXT NOT NULL,
            source_relative_path TEXT NOT NULL,
            destination_root_path TEXT NOT NULL,
            destination_relative_path TEXT NOT NULL,
            staging_path TEXT,
            content_hash_xxh3_128 BLOB,
            import_batch_unix_ms INTEGER NOT NULL,
            source_byte_size INTEGER NOT NULL,
            source_modified_at DOUBLE NOT NULL,
            destination_modified_at DOUBLE,
            phase TEXT NOT NULL,
            updated_at DOUBLE NOT NULL
        )
        """,
        """
        CREATE TABLE active_file_operation_companion_staging (
            operation_key TEXT NOT NULL
                REFERENCES active_file_operation(operation_key) ON DELETE CASCADE,
            staging_path TEXT NOT NULL,
            PRIMARY KEY (operation_key, staging_path)
        )
        """,
        """
        CREATE TABLE active_source_erase (
            operation_key TEXT PRIMARY KEY NOT NULL,
            source_kind TEXT NOT NULL,
            source_device_identity TEXT,
            source_root_path TEXT NOT NULL,
            source_relative_path TEXT NOT NULL,
            source_byte_size INTEGER,
            updated_at DOUBLE NOT NULL
        )
        """,
        """
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
        """,
        """
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
        """,
        """
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
        """,
        """
        CREATE TABLE active_reorganization_directory (
            component_key TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            phase TEXT NOT NULL,
            PRIMARY KEY (component_key, relative_path),
            FOREIGN KEY (component_key)
                REFERENCES active_reorganization_component(component_key)
                ON DELETE CASCADE
        )
        """,
        // Identity remaps a settled reorganization committed and the window has not yet
        // applied (ARC-052).
        """
        CREATE TABLE pending_identity_remap_batch (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            library_root_path TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE pending_identity_remap (
            batch_id INTEGER NOT NULL REFERENCES pending_identity_remap_batch(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL,
            old_relative_path TEXT NOT NULL,
            new_relative_path TEXT NOT NULL,
            PRIMARY KEY (batch_id, ordinal)
        )
        """,
    ]

    private static func claimIndex(_ name: String, global: Bool, hashRequired: Bool) -> String {
        let columns = global
            ? "best_capture_unix DESC, library_root_id, relative_path"
            : "library_root_id, best_capture_unix DESC, relative_path"
        return """
        CREATE INDEX \(name)
        ON media_asset(\(columns))
        WHERE \(EnrichmentClaimGateway.stalenessSQLPredicate(hashRequired: hashRequired))
        """
    }
}
