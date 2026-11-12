import Foundation
import GRDB
import OSLog

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

    /// The MediaMetadata extraction revision each metadata record was read with (ADR 0039).
    /// Records from before the column read `NULL`: unknown, so older than any revision.
    /// `MetadataRefresher` re-reads a library row whose revision is lower than the
    /// reader's when its original is already local, and nothing is downloaded for it.
    static let extractionRevisionMigrationIdentifier = "v6_asset_metadata_extraction_revision"

    static let extractionRevisionStatements: [String] = [
        "ALTER TABLE asset_metadata ADD COLUMN extraction_revision INTEGER",
    ]

    /// MediaMetadata 0.7.1 (ADR 0039):
    /// - Revisions are per format family. The numbers v6 stored were one global
    ///   revision, so they no longer mean anything and become `NULL`, which the library
    ///   defines as 0 (read before revisions). A family the library has not changed since
    ///   then is current at 0, so only the families it fixed are re-read, from local bytes
    ///   (`MetadataRefresher`).
    /// - Format tokens take the library's file-type names (`HEIC` and `HIF` become `HEIF`,
    ///   `JPG` and `JPE` become `JPEG`, `TIF` becomes `TIFF`).
    static let familyRevisionMigrationIdentifier = "v7_family_revisions_and_file_type_names"

    static func migrateToFamilyRevisionsAndFileTypeNames(_ db: Database) throws {
        try db.execute(sql: "UPDATE asset_metadata SET extraction_revision = NULL")
        for column in ["format", "enriched_format"] {
            let tokens = try String.fetchAll(db, sql: "SELECT DISTINCT \(column) FROM media_asset WHERE \(column) IS NOT NULL")
            for token in tokens {
                guard let named = MediaFormatToken.normalize(extension: token)?.rawValue, named != token else { continue }
                try db.execute(
                    sql: "UPDATE media_asset SET \(column) = ? WHERE \(column) = ?",
                    arguments: [named, token]
                )
            }
        }
    }

    /// MediaMetadata 0.8.0 (ADR 0039): the catalog sorts by the library's capture instant.
    /// The four `ts_*_unix` columns, which `best_capture_unix` coalesced in Otos's own
    /// order (original, QuickTime creation, digitized, GPS), become one
    /// `capture_instant_unix` chosen by `CaptureTimestamps.instantPrecedence` (original,
    /// digitized, QuickTime creation and content-create, GPS). `best_capture_unix` falls
    /// back from it to the file's creation and modification dates, as before, and becomes
    /// a virtual column: SQLite cannot add a stored one, and the indexes over it hold the
    /// value either way.
    ///
    /// The instant is filled first from the old columns in the library's order, then from
    /// each row's stored timestamp records, which also hold the roles the old columns
    /// never did. A record that cannot be decoded keeps the first value and is logged:
    /// the catalog still opens, and the row is as well ordered as before.
    static let captureInstantMigrationIdentifier = "v8_media_asset_capture_instant"

    static func migrateToCaptureInstant(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE media_asset ADD COLUMN capture_instant_unix DOUBLE")
        try db.execute(sql: """
        UPDATE media_asset SET capture_instant_unix = COALESCE(
            ts_original_unix, ts_digitized_unix, ts_quicktime_creation_unix, ts_gps_unix
        )
        """)
        let rows = try Row.fetchAll(db, sql: """
        SELECT library_root_id, relative_path, metadata_extra_json FROM asset_metadata
        WHERE metadata_extra_json IS NOT NULL
        """)
        var undecodable = 0
        for row in rows {
            let json: String = row["metadata_extra_json"]
            let metadata: AssetMetadata
            do {
                metadata = try CatalogStore.decodeMetadataExtraJSON(json)
            } catch {
                undecodable += 1
                continue
            }
            try db.execute(
                sql: "UPDATE media_asset SET capture_instant_unix = ? WHERE library_root_id = ? AND relative_path = ?",
                arguments: [
                    metadata.captureInstant?.timeIntervalSince1970,
                    row["library_root_id"] as Int64,
                    row["relative_path"] as String,
                ]
            )
        }
        if undecodable > 0 {
            OtosLog.persistence.errorOperation("catalog.migration.captureInstant", phase: "undecodable", fields: [
                "count": "\(undecodable)",
            ])
        }
        // Every index over the date column — the sort orders and enrichment's priority —
        // goes while the column is rebuilt and comes back from its own definition.
        let indexes = try Row.fetchAll(db, sql: """
        SELECT name, sql FROM sqlite_master
        WHERE type = 'index' AND tbl_name = 'media_asset' AND sql LIKE '%best_capture_unix%'
        """)
        for index in indexes {
            try db.execute(sql: "DROP INDEX \(index["name"] as String)")
        }
        try db.execute(sql: "ALTER TABLE media_asset DROP COLUMN best_capture_unix")
        for column in ["ts_original_unix", "ts_quicktime_creation_unix", "ts_digitized_unix", "ts_gps_unix"] {
            try db.execute(sql: "ALTER TABLE media_asset DROP COLUMN \(column)")
        }
        try db.execute(sql: """
        ALTER TABLE media_asset ADD COLUMN best_capture_unix DOUBLE GENERATED ALWAYS AS (
            COALESCE(capture_instant_unix, created_at_unix, content_modified_at_unix)
        ) VIRTUAL
        """)
        for index in indexes {
            try db.execute(sql: index["sql"] as String)
        }
    }

    /// MediaMetadata 0.8.2 (ADR 0041): Apple's content identifier, which a Live Photo's
    /// still and motion movie share, stored as the library reports it. `parent_path` is the
    /// folder part of `relative_path` (`a/b/` for `a/b/c.heic`, empty at the root), so the
    /// pair rule (`LivePhotoSQL`) can ask for one folder through one index.
    ///
    /// Records read before 0.8.2 lack the field, which raises no extraction revision. Their
    /// families' revisions are cleared, as v7 did, so `MetadataRefresher` re-reads them from
    /// local bytes; a cloud-only original is not downloaded for it (ADR 0039).
    static let contentIdentifierMigrationIdentifier = "v9_media_asset_content_identifier"

    static let contentIdentifierStatements: [String] = [
        "ALTER TABLE media_asset ADD COLUMN content_identifier TEXT",
        """
        ALTER TABLE media_asset ADD COLUMN parent_path TEXT GENERATED ALWAYS AS (
            rtrim(relative_path, replace(relative_path, '/', ''))
        ) VIRTUAL
        """,
        """
        CREATE INDEX idx_media_asset_content_identifier
        ON media_asset(library_root_id, content_identifier, parent_path)
        WHERE content_identifier IS NOT NULL
        """,
        "UPDATE asset_metadata SET extraction_revision = NULL WHERE family IN ('heif', 'jpeg', 'isoBMFF')",
    ]

    /// The file path where the system Trash put a moved item's file (ADR 0022). A row whose file the queue
    /// moved to the Trash stays in the catalog, hidden by its pending mark, until the file is
    /// proven gone from the Trash: an item in the Trash is not proven deleted (ADR 0008), so
    /// everything Otos holds for it is kept, and Finder's Put Back — or undo — returns the
    /// file to the row's own path, where the next scan of that path shows it again.
    static let trashPathMigrationIdentifier = "v10_media_asset_trash_path"

    static let trashPathStatements: [String] = [
        "ALTER TABLE media_asset ADD COLUMN trash_path TEXT",
    ]

    /// Duplicates (ADR 0042). "Keep All Copies" is remembered per pair of paths, as overlay
    /// on both copies: an Otos move carries it (`ON UPDATE CASCADE`), and a copy's proven
    /// deletion or its library's removal ends it (`ON DELETE CASCADE`). The digest index
    /// lets the duplicates read group by content without a full scan per pass.
    static let duplicatesMigrationIdentifier = "v11_duplicate_kept_pair"

    static let duplicatesStatements: [String] = [
        """
        CREATE TABLE duplicate_kept_pair (
            first_root_id INTEGER NOT NULL,
            first_path TEXT NOT NULL,
            second_root_id INTEGER NOT NULL,
            second_path TEXT NOT NULL,
            PRIMARY KEY (first_root_id, first_path, second_root_id, second_path),
            FOREIGN KEY (first_root_id, first_path)
                REFERENCES media_asset(library_root_id, relative_path)
                ON UPDATE CASCADE ON DELETE CASCADE,
            FOREIGN KEY (second_root_id, second_path)
                REFERENCES media_asset(library_root_id, relative_path)
                ON UPDATE CASCADE ON DELETE CASCADE
        )
        """,
        """
        CREATE INDEX idx_duplicate_kept_pair_second
        ON duplicate_kept_pair(second_root_id, second_path)
        """,
        """
        CREATE INDEX idx_media_asset_content_hash
        ON media_asset(content_hash_xxh3_128) WHERE content_hash_xxh3_128 IS NOT NULL
        """,
    ]

    /// Same photo (ADR 0042). A still's render signature — a 64-bit difference hash and a
    /// 32 × 32 grayscale render of its stored thumbnail — with the thumbnail it was read
    /// from (`render_signature_source`), so a re-rendered thumbnail makes it stale without
    /// any write site having to know. MediaMetadata 0.9 adds capture sub-seconds and Apple's
    /// burst identifier, new fields its families' revisions do not announce; the families
    /// that carry EXIF are cleared, as v9 did, so `MetadataRefresher` re-reads them from
    /// local bytes and a cloud-only original is not downloaded for it (ADR 0039).
    static let renderSignatureMigrationIdentifier = "v12_render_signature"

    static let renderSignatureStatements: [String] = [
        "ALTER TABLE media_asset ADD COLUMN render_dhash INTEGER",
        "ALTER TABLE media_asset ADD COLUMN render_gray BLOB",
        "ALTER TABLE media_asset ADD COLUMN render_signature_source TEXT",
        "UPDATE asset_metadata SET extraction_revision = NULL WHERE family IN ('heif', 'jpeg', 'tiff')",
    ]

    /// One freshness stamp per product (ADR 0009): metadata, the rendering (thumbnail and
    /// preview, made from one development, ADR 0035), and the digest each name the
    /// `(size, mtime)` they were made from, so each is stale on its own. The old
    /// enrichment stamp certified metadata and rendering together; it becomes the metadata
    /// stamp, and the rendering stamp starts as its copy. A card's or camera's still or RAW
    /// without a preview was given QuickLook's or the camera's embedded thumbnail, not a
    /// rendering, so it starts with none and is rendered again. The claim indexes are
    /// created again from the current predicates.
    static let productStampsMigrationIdentifier = "v13_product_stamps"

    static var productStampsStatements: [String] {
        [
            "DROP INDEX \(EnrichmentClaimGateway.broadGlobalIndexName)",
            "DROP INDEX \(EnrichmentClaimGateway.broadRootIndexName)",
            "DROP INDEX \(EnrichmentClaimGateway.metadataOnlyGlobalIndexName)",
            "DROP INDEX \(EnrichmentClaimGateway.metadataOnlyRootIndexName)",
            "ALTER TABLE media_asset RENAME COLUMN enriched_source_size TO metadata_source_size",
            "ALTER TABLE media_asset RENAME COLUMN enriched_source_mtime TO metadata_source_mtime",
            "ALTER TABLE media_asset ADD COLUMN rendered_source_size INTEGER",
            "ALTER TABLE media_asset ADD COLUMN rendered_source_mtime INTEGER",
            """
            UPDATE media_asset
            SET rendered_source_size = metadata_source_size, rendered_source_mtime = metadata_source_mtime
            WHERE NOT (
                library_root_id IN (SELECT id FROM library_root WHERE kind <> 'library')
                AND enriched_kind IN ('image', 'raw')
                AND preview_path IS NULL
            )
            """,
            claimIndex(EnrichmentClaimGateway.broadGlobalIndexName, global: true, claim: .cardProducts, orderColumn: "best_capture_unix"),
            claimIndex(EnrichmentClaimGateway.broadRootIndexName, global: false, claim: .cardProducts, orderColumn: "best_capture_unix"),
            claimIndex(EnrichmentClaimGateway.metadataOnlyGlobalIndexName, global: true, claim: .metadata, orderColumn: "best_capture_unix"),
            claimIndex(EnrichmentClaimGateway.metadataOnlyRootIndexName, global: false, claim: .metadata, orderColumn: "best_capture_unix"),
        ]
    }

    /// Whether a card's or camera's retained row has been seen by the source's current
    /// attachment (ADR 0013). Attach sets it on every row the source held; each scan
    /// upsert that observes the file clears it, so the grid fills as the card is read
    /// instead of showing what the card held last time; the completed scan deletes what
    /// it never saw. Detach and launch clear it: with no attachment, nothing is awaited,
    /// and an offline card shows the rows it last held. Every user-facing read, import
    /// planning and enrichment claims exclude a row while it is set.
    static let awaitingPresenceMigrationIdentifier = "v14_media_asset_awaiting_presence"

    static let awaitingPresenceStatements: [String] = [
        "ALTER TABLE media_asset ADD COLUMN awaiting_presence INTEGER NOT NULL DEFAULT 0",
        // Few rows are ever set, and every write that clears them in bulk — detach, launch
        // — reads only those through this index rather than the whole table.
        """
        CREATE INDEX idx_media_asset_awaiting_presence
        ON media_asset(library_root_id) WHERE awaiting_presence <> 0
        """,
    ]

    /// The server an Immich account's root reads from, as Settings shows it (ADR 0046 §2).
    /// Null for every other kind; the session token is never stored here.
    static let remoteBaseURLMigrationIdentifier = "v15_library_root_remote_base_url"

    static let remoteBaseURLStatements: [String] = [
        "ALTER TABLE library_root ADD COLUMN remote_base_url TEXT",
    ]

    /// An item its source holds but hides: an Immich asset in Immich's trash (ADR 0046 §5).
    /// The row and its overlay stay, as they do for Otos's own Trash (ADR 0022), and every
    /// user-facing read leaves it out; the source showing it again shows it again.
    static let hiddenBySourceMigrationIdentifier = "v16_media_asset_hidden_by_source"

    static let hiddenBySourceStatements: [String] = [
        "ALTER TABLE media_asset ADD COLUMN hidden_by_source INTEGER NOT NULL DEFAULT 0",
    ]

    /// The `(size, mtime)` a source's own thumbnail and preview were made for (ADR 0035's
    /// source-provisional products, ADR 0046 §7): a row whose file has changed since is
    /// owed newer ones. Separate from the rendering stamp, which only Otos's rendering
    /// writes.
    static let sourceProductsMigrationIdentifier = "v17_media_asset_source_products"

    static let sourceProductsStatements: [String] = [
        "ALTER TABLE media_asset ADD COLUMN source_products_size INTEGER",
        "ALTER TABLE media_asset ADD COLUMN source_products_mtime INTEGER",
    ]

    /// Faces (ADR 0047). `FaceAnalyzer` reads a fixed library's stills for faces: each face
    /// it reads is a row of `face`, overlay on its asset, so a move carries it
    /// (`ON UPDATE CASCADE`, the move witness of ADR 0034 included) and the asset's proven
    /// deletion or its library's removal ends it (`ON DELETE CASCADE`). The faces stamp names
    /// the `(size, mtime)` they were read from (ADR 0009); a new reading replaces every face
    /// of the asset. Only `EnrichmentClaim.library` owes faces, so it gets its own pair of
    /// claim indexes; the card-products and metadata pairs are unchanged.
    ///
    /// A face row holds the box and the five alignment points as fractions of the upright
    /// photo (top-left origin), Vision's capture quality, the analysis revision that read it
    /// (`FaceAnalyzer.revision`), and the embedding as 512 little-endian Float32 values.
    static let facesMigrationIdentifier = "v18_faces"

    static var facesStatements: [String] {
        [
            "ALTER TABLE media_asset ADD COLUMN faces_source_size INTEGER",
            "ALTER TABLE media_asset ADD COLUMN faces_source_mtime INTEGER",
            """
            CREATE TABLE face (
                library_root_id INTEGER NOT NULL,
                relative_path TEXT NOT NULL,
                face_index INTEGER NOT NULL,
                box_x REAL NOT NULL,
                box_y REAL NOT NULL,
                box_width REAL NOT NULL,
                box_height REAL NOT NULL,
                landmarks BLOB NOT NULL,
                quality REAL NOT NULL,
                analysis_revision INTEGER NOT NULL,
                embedding BLOB NOT NULL,
                PRIMARY KEY (library_root_id, relative_path, face_index),
                FOREIGN KEY (library_root_id, relative_path)
                    REFERENCES media_asset(library_root_id, relative_path)
                    ON UPDATE CASCADE ON DELETE CASCADE
            )
            """,
            claimIndex(EnrichmentClaimGateway.libraryGlobalIndexName, global: true, claim: .library, orderColumn: "best_capture_unix"),
            claimIndex(EnrichmentClaimGateway.libraryRootIndexName, global: false, claim: .library, orderColumn: "best_capture_unix"),
        ]
    }

    /// People (ADR 0047). What the user decides about faces is overlay, and it outlives a
    /// new reading of the same photo: `writeFaces` carries each act to the new face it
    /// overlaps.
    /// - `person`: a name (optional until the user gives one) and an optional birthday, as
    ///   `YYYY-MM-DD`.
    /// - `face.person_id`: the person the user confirmed the face as; removing the person
    ///   returns the face to unnamed (`ON DELETE SET NULL`).
    /// - `face.is_not_face`: the user said this detection is not a face. Not carried to a new
    ///   reading: a changed file is read afresh.
    /// - `face.is_ignored`: the face belongs to a group the user ignored.
    /// - `face_rejection`: "not this person", so the suggestion never returns; removing the
    ///   person forgets them.
    static let peopleMigrationIdentifier = "v19_people"

    static let peopleStatements: [String] = [
        """
        CREATE TABLE person (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT,
            birthday TEXT
        )
        """,
        "ALTER TABLE face ADD COLUMN person_id INTEGER REFERENCES person(id) ON DELETE SET NULL",
        "ALTER TABLE face ADD COLUMN is_not_face INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE face ADD COLUMN is_ignored INTEGER NOT NULL DEFAULT 0",
        "CREATE INDEX idx_face_person ON face(person_id) WHERE person_id IS NOT NULL",
        """
        CREATE TABLE face_rejection (
            library_root_id INTEGER NOT NULL,
            relative_path TEXT NOT NULL,
            face_index INTEGER NOT NULL,
            person_id INTEGER NOT NULL REFERENCES person(id) ON DELETE CASCADE,
            PRIMARY KEY (library_root_id, relative_path, face_index, person_id),
            FOREIGN KEY (library_root_id, relative_path, face_index)
                REFERENCES face(library_root_id, relative_path, face_index)
                ON UPDATE CASCADE ON DELETE CASCADE
        )
        """,
        "CREATE INDEX idx_face_rejection_person ON face_rejection(person_id)",
    ]

    /// The source's own ID for the item a row is: an Immich asset's ID (ADR 0046 §2). A Live
    /// Photo's motion part lives in its still's folder, so a folder names only its still;
    /// every request Otos makes for an item, and every size and deletion the source reports
    /// for one, finds its row by this. Null for every kind that reads its files in place
    /// or names them by path. Existing account rows are all stills, named by their folder.
    static let sourceItemIDMigrationIdentifier = "v20_media_asset_source_item_id"

    static let sourceItemIDStatements: [String] = [
        "ALTER TABLE media_asset ADD COLUMN source_item_id TEXT",
        """
        UPDATE media_asset SET source_item_id = substr(relative_path, 1, instr(relative_path, '/') - 1)
        WHERE instr(relative_path, '/') > 1
          AND library_root_id IN (
              SELECT id FROM library_root WHERE kind = '\(LibraryRootKind.immichAccount.rawValue)'
          )
        """,
        """
        CREATE INDEX idx_media_asset_source_item ON media_asset(library_root_id, source_item_id)
        WHERE source_item_id IS NOT NULL
        """,
    ]

    /// Search embeddings (ADR 0048): one per asset, read from its stored thumbnail by
    /// `PhotoSearchIndex`, overlay on the asset — a move carries it (`ON UPDATE CASCADE`, the
    /// move witness of ADR 0034 included) and the asset's proven deletion or its root's
    /// removal ends it (`ON DELETE CASCADE`). `source` names the thumbnail and model revision
    /// it was read from (`SearchEmbeddingStorage.currentSource`); `embedding` is 768
    /// little-endian Float32 values, or NULL for a thumbnail that did not decode.
    static let searchEmbeddingsMigrationIdentifier = "v21_search_embeddings"

    static let searchEmbeddingsStatements: [String] = [
        """
        CREATE TABLE search_embedding (
            library_root_id INTEGER NOT NULL,
            relative_path TEXT NOT NULL,
            source TEXT NOT NULL,
            embedding BLOB,
            PRIMARY KEY (library_root_id, relative_path),
            FOREIGN KEY (library_root_id, relative_path)
                REFERENCES media_asset(library_root_id, relative_path)
                ON UPDATE CASCADE ON DELETE CASCADE
        )
        """,
    ]

    /// Search reads more of each picture (ADR 0048):
    /// - `search_embedding.labels`: the thumbnail's scene labels, read with its embedding
    ///   (`SearchEmbeddingStorage`); `SearchEmbedding.revision` 2 makes every row owed again.
    /// - `search_text`: the text Vision recognised in the asset's stored preview, overlay on
    ///   the asset like an embedding (cascade on move and deletion). `source` names the preview
    ///   and the recognition revision it was read from (`SearchTextStorage.currentSource`);
    ///   `text` is the recognised lines, empty when the preview holds none.
    static let searchTextMigrationIdentifier = "v22_search_labels_and_text"

    static let searchTextStatements: [String] = [
        "ALTER TABLE search_embedding ADD COLUMN labels TEXT",
        """
        CREATE TABLE search_text (
            library_root_id INTEGER NOT NULL,
            relative_path TEXT NOT NULL,
            source TEXT NOT NULL,
            text TEXT NOT NULL,
            PRIMARY KEY (library_root_id, relative_path),
            FOREIGN KEY (library_root_id, relative_path)
                REFERENCES media_asset(library_root_id, relative_path)
                ON UPDATE CASCADE ON DELETE CASCADE
        )
        """,
    ]

    /// The timeline runs on local capture time (ADR 0039): `best_capture_local` replaces
    /// `best_capture_unix`. It is the library's capture wall clock read as if it were UTC
    /// (`CaptureLocalTime`), so an item is ordered by, and sits on, the day it was taken on
    /// the clock where it was taken, whatever zone the Mac is in. An item whose file records
    /// no wall clock is placed by its absolute time — capture instant, else creation, else
    /// modification date — read with `assumed_utc_offset_seconds`, the offset of the Mac's
    /// zone when Otos recorded that time (`CaptureLocalTime.assumedUTCOffset`). This
    /// migration makes that assumption for every existing row in the zone it runs in.
    ///
    /// Every index over the old column is rebuilt, under its own name, over the new one.
    static let captureLocalTimeMigrationIdentifier = "v23_media_asset_capture_local_time"

    /// Re-reads the faces of every RAW stamped as read with none. Before the renderer told
    /// Image I/O a still's type, a Sony ARW's bytes read as a TIFF with no image, the upright
    /// original was unreadable, and the row was stamped with no faces (ENR-022), so no ARW
    /// in a library was ever read for faces. Clearing the stamp of a RAW that has no face
    /// row makes it owe faces again; a RAW with faces was read and keeps them.
    static let rawFacesMigrationIdentifier = "v24_raw_faces_reread"

    static var rawFacesStatements: [String] {
        [
            """
            UPDATE media_asset SET faces_source_size = NULL, faces_source_mtime = NULL
            WHERE best_kind = 'raw'
              AND faces_source_size IS NOT NULL
              AND NOT EXISTS (
                  SELECT 1 FROM face
                  WHERE face.library_root_id = media_asset.library_root_id
                    AND face.relative_path = media_asset.relative_path
              )
            """,
        ]
    }

    /// The decoder a still could not be decoded by (ENR-029). When the renderer cannot
    /// decode a still, its rendering falls back to QuickLook's thumbnail and it is stamped
    /// with no faces; `undecodable_by` names the decoder that said so
    /// (`ImageRenderer.decoderIdentity`), and is NULL once a decoder read it. A row
    /// rendered before this column with a stamp and no preview is such a fallback, so it
    /// is marked as undecodable by Otos's first decoder and tried again once.
    static let decodeVerdictMigrationIdentifier = "v25_media_asset_undecodable_by"

    static var decodeVerdictStatements: [String] {
        [
            "ALTER TABLE media_asset ADD COLUMN undecodable_by TEXT",
            """
            UPDATE media_asset SET undecodable_by = 'otos1'
            WHERE best_kind IN ('image', 'raw')
              AND rendered_source_size IS NOT NULL
              AND preview_path IS NULL
            """,
        ]
    }

    /// Faces auto-tagged (ADR 0047): every face has a person Otos guessed or the user gave,
    /// and named and unnamed people are one kind.
    /// - `face.assignment`: whose word `person_id` is (`FaceAssignmentColumn`): none, Otos's
    ///   guess, a seed (a face a person was first found from), the user's, or held (the user
    ///   removed the name, so only the user gives it a person again). A confirmed face is the
    ///   user's; a face of an ignored group is held.
    /// - `face.likeness`: how like its person the face is, which the likeness sort orders by.
    /// - `face.is_feature`: the person's feature photo, at most one face per person; it moves
    ///   and goes with its face.
    /// - `person.is_hidden`, `person.is_favorite`: shown only in the People gallery, and first.
    static let autoTaggedPeopleMigrationIdentifier = "v26_people_auto_tagged"

    static var autoTaggedPeopleStatements: [String] {
        [
            "ALTER TABLE face ADD COLUMN assignment INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE face ADD COLUMN likeness REAL",
            "ALTER TABLE face ADD COLUMN is_feature INTEGER NOT NULL DEFAULT 0",
            "UPDATE face SET assignment = \(FaceAssignmentColumn.user.rawValue) WHERE person_id IS NOT NULL",
            "UPDATE face SET assignment = \(FaceAssignmentColumn.held.rawValue) WHERE person_id IS NULL AND is_ignored = 1",
            "ALTER TABLE face DROP COLUMN is_ignored",
            "CREATE UNIQUE INDEX idx_face_feature ON face(person_id) WHERE is_feature = 1",
            "ALTER TABLE person ADD COLUMN is_hidden INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE person ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0",
        ]
    }

    /// Place names (ADR 0040): the country and town Apple Maps names for each cell of the map
    /// a located photo falls in (`PlaceCell`), read once per cell by `PlaceNameReader` and
    /// shared by every photo in it. A cell Maps names nothing for (open sea) is stored with no
    /// names, so it is not asked again; `locale` is the language the names are in, and a cell
    /// named in another language than the Mac's is asked again.
    static let placeNamesMigrationIdentifier = "v27_place_names"

    static var placeNamesStatements: [String] {
        [
            """
            CREATE TABLE place_cell (
                cell_latitude INTEGER NOT NULL,
                cell_longitude INTEGER NOT NULL,
                country TEXT,
                town TEXT,
                locale TEXT NOT NULL,
                PRIMARY KEY (cell_latitude, cell_longitude)
            )
            """,
            "CREATE INDEX idx_place_cell_names ON place_cell(country, town)",
        ]
    }

    /// The face a person is shown by is their key photo, as Photos calls it (ADR 0047):
    /// v26's `face.is_feature` and its index take that name. Nothing else changes.
    static let keyPhotoMigrationIdentifier = "v28_face_key_photo"

    static var keyPhotoStatements: [String] {
        [
            "DROP INDEX idx_face_feature",
            "ALTER TABLE face RENAME COLUMN is_feature TO is_key_photo",
            "CREATE UNIQUE INDEX idx_face_key_photo ON face(person_id) WHERE is_key_photo = 1",
        ]
    }

    /// Faces analysis revision 2 (ADR 0047) admits a face only when Vision's classifier sees
    /// a person around it. It reads the same detections with the same model and only turns
    /// more of them away, so a photo stamped with no face has none under it either. A photo
    /// with faces read under an earlier revision owes faces again: its stamp is cleared, and
    /// its re-reading carries each kept face's person over by its box.
    static let personAdmissionMigrationIdentifier = "v29_faces_person_admission"

    static var personAdmissionStatements: [String] {
        [
            """
            UPDATE media_asset SET faces_source_size = NULL, faces_source_mtime = NULL
            WHERE faces_source_size IS NOT NULL
              AND EXISTS (
                  SELECT 1 FROM face
                  WHERE face.library_root_id = media_asset.library_root_id
                    AND face.relative_path = media_asset.relative_path
                    AND face.analysis_revision < 2
              )
            """,
        ]
    }

    /// The absolute time an item without a wall clock is placed by, as SQL over `media_asset`.
    static let absoluteCaptureSQL = "COALESCE(capture_instant_unix, created_at_unix, content_modified_at_unix)"

    /// `best_capture_local`'s definition: the stored wall clock (`YYYYMMDDHHMMSS`) as
    /// seconds of a UTC reading, else the absolute time plus the assumed offset. A wall that
    /// is not a real date-time is NULL to `unixepoch` and falls through to the absolute time.
    static let bestCaptureLocalSQL = """
    COALESCE(
        unixepoch(printf('%04d-%02d-%02d %02d:%02d:%02d',
            capture_wall_compact / 10000000000, (capture_wall_compact / 100000000) % 100,
            (capture_wall_compact / 1000000) % 100, (capture_wall_compact / 10000) % 100,
            (capture_wall_compact / 100) % 100, capture_wall_compact % 100)),
        \(absoluteCaptureSQL) + assumed_utc_offset_seconds
    )
    """

    static func migrateToCaptureLocalTime(_ db: Database, timeZone: TimeZone = .current) throws {
        try db.execute(sql: "ALTER TABLE media_asset ADD COLUMN assumed_utc_offset_seconds INTEGER")
        let rows = try Row.fetchAll(db, sql: """
        SELECT library_root_id, relative_path, \(absoluteCaptureSQL) AS absolute FROM media_asset
        WHERE \(absoluteCaptureSQL) IS NOT NULL
        """)
        let update = try db.makeStatement(sql: """
        UPDATE media_asset SET assumed_utc_offset_seconds = ? WHERE library_root_id = ? AND relative_path = ?
        """)
        for row in rows {
            let offset = CaptureLocalTime.assumedUTCOffset(
                for: row["absolute"],
                previousAbsolute: nil,
                previousOffset: nil,
                timeZone: timeZone
            )
            try update.execute(arguments: [offset, row["library_root_id"] as Int64, row["relative_path"] as String])
        }
        let indexes = try Row.fetchAll(db, sql: """
        SELECT name, sql FROM sqlite_master
        WHERE type = 'index' AND tbl_name = 'media_asset' AND sql LIKE '%best_capture_unix%'
        """)
        for index in indexes {
            try db.execute(sql: "DROP INDEX \(index["name"] as String)")
        }
        try db.execute(sql: "ALTER TABLE media_asset DROP COLUMN best_capture_unix")
        try db.execute(sql: """
        ALTER TABLE media_asset ADD COLUMN best_capture_local DOUBLE GENERATED ALWAYS AS (
            \(bestCaptureLocalSQL)
        ) VIRTUAL
        """)
        for index in indexes {
            try db.execute(sql: (index["sql"] as String).replacingOccurrences(of: "best_capture_unix", with: "best_capture_local"))
        }
        OtosLog.persistence.noticeOperation("catalog.migration.captureLocalTime", phase: "finish", fields: [
            "rows": "\(rows.count)",
            "indexes": "\(indexes.count)",
            "timeZone": timeZone.identifier,
        ])
    }

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
        // The claim indexes as v1 created them, over the one enrichment stamp v13 split.
        // Their text is frozen here because it names columns v13 renames; v13 drops them
        // and creates the current ones from the gateway's predicates.
        v1ClaimIndex(EnrichmentClaimGateway.broadGlobalIndexName, global: true, broad: true),
        v1ClaimIndex(EnrichmentClaimGateway.broadRootIndexName, global: false, broad: true),
        v1ClaimIndex(EnrichmentClaimGateway.metadataOnlyGlobalIndexName, global: true, broad: false),
        v1ClaimIndex(EnrichmentClaimGateway.metadataOnlyRootIndexName, global: false, broad: false),
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

    /// A claim index over rows owing a product, newest first: the claim queries walk these
    /// by name with `INDEXED BY`, so the `WHERE` text is the gateway's predicate verbatim.
    /// `orderColumn` is the capture-order column of the schema the migration runs against:
    /// `best_capture_unix` before v23, `best_capture_local` from it.
    static func claimIndex(_ name: String, global: Bool, claim: EnrichmentClaim, orderColumn: String) -> String {
        claimIndex(
            name,
            global: global,
            predicate: EnrichmentClaimGateway.stalenessSQLPredicate(claim),
            orderColumn: orderColumn
        )
    }

    private static func v1ClaimIndex(_ name: String, global: Bool, broad: Bool) -> String {
        let metadata = """
        enriched_source_size IS NULL
           OR enriched_source_mtime IS NULL
           OR COALESCE(byte_size, -1) <> COALESCE(enriched_source_size, -1)
           OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
              <> COALESCE(enriched_source_mtime, -1)
        """
        let hash = """
        content_hash_xxh3_128 IS NULL
           OR length(content_hash_xxh3_128) <> 16
           OR content_hash_source_size IS NULL
           OR content_hash_source_mtime IS NULL
           OR COALESCE(byte_size, -1) <> COALESCE(content_hash_source_size, -1)
           OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
              <> COALESCE(content_hash_source_mtime, -1)
        """
        let predicate = broad
            ? """
            \(metadata)
               OR \(hash)
            """
            : metadata
        return claimIndex(name, global: global, predicate: predicate, orderColumn: "best_capture_unix")
    }

    private static func claimIndex(_ name: String, global: Bool, predicate: String, orderColumn: String) -> String {
        let columns = global
            ? "\(orderColumn) DESC, library_root_id, relative_path"
            : "library_root_id, \(orderColumn) DESC, relative_path"
        return """
        CREATE INDEX \(name)
        ON media_asset(\(columns))
        WHERE \(predicate)
        """
    }
}
