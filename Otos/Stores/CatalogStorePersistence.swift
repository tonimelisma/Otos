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
    /// Where the thumbnails live. A path, computed without touching the disk: the
    /// thumbnail store creates the folder before it writes into it.
    static func applicationThumbnailDirectory(bundleIdentifier: String) -> URL {
        URL.applicationSupportDirectory
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

    /// One baseline migration creates the schema (`CatalogSchema`); later changes are
    /// additive migrations registered after it. Import history and other non-rebuildable
    /// overlay forbid destructive schema reset, and a catalog whose history this build
    /// does not know refuses to open (ADR 0010).
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(CatalogSchema.baselineMigrationIdentifier) { db in
            for statement in CatalogSchema.baselineStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.fileIdentifierMigrationIdentifier) { db in
            for statement in CatalogSchema.fileIdentifierStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.previewPathMigrationIdentifier) { db in
            for statement in CatalogSchema.previewPathStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration(CatalogSchema.editRecipeMigrationIdentifier) { db in
            for statement in CatalogSchema.editRecipeStatements {
                try db.execute(sql: statement)
            }
        }
        return migrator
    }

    /// Compatibility check run before any migrator write. A schema whose history this
    /// build does not know refuses without erase, so non-rebuildable overlay is never
    /// destroyed.
    static func catalogSchemaCompatibility(_ db: Database) throws -> CatalogSchemaCompatibility {
        if try migrator.hasBeenSuperseded(db) {
            return .writtenByOtherOtos
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
                do {
                    try db.execute(sql: "PRAGMA synchronous = NORMAL")
                } catch {
                    // The connection stays at FULL: slower, never less durable.
                    OtosLog.persistence.errorOperation("catalog.durability", phase: "restoreFailed", fields: [
                        "error": String(describing: error),
                    ])
                }
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
                capabilities: VolumeNamespaceCapabilities(storedCaseSensitiveColumn: row["case_sensitive_names"]),
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
        deviceIdentity: DeviceIdentity? = nil,
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
    /// caller (`CatalogStore.moveLibrary(_:_:)`) computes the reordered array;
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
            sql: "SELECT relative_path, thumbnail_path, preview_path FROM media_asset WHERE library_root_id = ?",
            arguments: [rootRowID]
        )
        var thumbnailMigrations: [ThumbnailPathMigration] = []
        for row in rows {
            let relativePath: String = row["relative_path"]
            let thumbnailPath: String? = row["thumbnail_path"]
            let previewPath: String? = row["preview_path"]
            let relativePathValue = MediaRelativePath(rawValue: relativePath)
            let newID = MediaAssetID(libraryRootPath: path, relativePath: relativePathValue)
            let newThumbnailPath = thumbnailPath.map { _ in ThumbnailStore.relativeName(for: newID) }
            let newPreviewPath = previewPath.map { _ in ThumbnailStore.previewRelativeName(for: newID) }
            try db.execute(
                sql: """
                UPDATE media_asset
                SET sort_key = ?, thumbnail_path = ?, preview_path = ?
                WHERE library_root_id = ? AND relative_path = ?
                """,
                arguments: [
                    MediaSortKey.make(libraryRootPath: path, relativePath: relativePathValue),
                    newThumbnailPath,
                    newPreviewPath,
                    rootRowID,
                    relativePath,
                ]
            )
            if let previewPath, let newPreviewPath, previewPath != newPreviewPath {
                thumbnailMigrations.append(ThumbnailPathMigration(
                    oldRelativeName: previewPath,
                    newRelativeName: newPreviewPath
                ))
            }
            if let thumbnailPath, let newThumbnailPath, thumbnailPath != newThumbnailPath {
                thumbnailMigrations.append(ThumbnailPathMigration(
                    oldRelativeName: thumbnailPath,
                    newRelativeName: newThumbnailPath
                ))
            }
        }
        return thumbnailMigrations
    }

    static func updateLibraryRootLastSeen(rootRowID: Int64, lastSeenAt: Date, db: Database) throws {
        try db.execute(
            sql: "UPDATE library_root SET last_seen_at = ? WHERE id = ?",
            arguments: [lastSeenAt.timeIntervalSince1970, rootRowID]
        )
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
        /// The thumbnail and preview files to delete with the row.
        let derivedImagePaths: [String]
    }

    static func catalogedFileDeletionTarget(
        relativePath: MediaRelativePath,
        rootRowID: Int64,
        db: Database
    ) throws -> CatalogedFileDeletionTarget? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT thumbnail_path, preview_path
            FROM media_asset
            WHERE library_root_id = ? AND relative_path = ?
            """,
            arguments: [rootRowID, relativePath.rawValue]
        ) else {
            return nil
        }
        let thumbnailPath: String? = row["thumbnail_path"]
        let previewPath: String? = row["preview_path"]
        return CatalogedFileDeletionTarget(derivedImagePaths: [thumbnailPath, previewPath].compactMap(\.self))
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
                AND edit_revision = ?
            """,
            arguments: [
                libraryRootID,
                result.id.relativePath.rawValue,
                result.sourceSize ?? -1,
                sourceMTimeSeconds,
                sourceMTimeSeconds,
                sourceMTimeSeconds + 1,
                result.editRevision,
            ]
        ) != nil
    }

    /// Hash columns use `COALESCE(?, column)` rather than a plain assignment: when
    /// `result.contentHash` is absent (a `.removableVolume` source, ADR 0018),
    /// the row's existing digest — if any was recorded before the source's
    /// root kind or facts changed — must survive, not be clobbered to NULL.
    static func writeEnrichmentOverlay(_ result: EnrichmentResult, libraryRootID: Int64, db: Database) throws {
        // Both date projections derive from the one stored truth, here at the write.
        //
        // A video with no local-authority embedded timestamp falls back to its
        // filesystem mtime — which for video is when recording *stopped*, so the name
        // is wrong by the clip's own length. Where the duration is known, derive the
        // capture instant instead and store it as the wall, marked with its own
        // precision so it stays self-identifying. Deriving here rather than at naming
        // time keeps `capture_wall_compact` the single stored truth.
        let embeddedWall = CaptureWallClock.select(from: result.metadata.timestamps)
        let captureWall = embeddedWall ?? (
            result.enrichedKind == .video
                ? CaptureWallClock.derivedFromDuration(
                    modifiedAt: result.sourceMTimeSeconds.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    durationSeconds: result.metadata.durationSeconds
                )
                : nil
        )
        let instants = BestCaptureInstants.from(result.metadata.timestamps)
        try db.execute(
            sql: """
            UPDATE media_asset SET
                thumbnail_path = ?,
                preview_path = ?,
                rendered_revision = ?,
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
                result.previewPath,
                result.editRevision,
                instants.original?.timeIntervalSince1970,
                instants.quickTimeCreation?.timeIntervalSince1970,
                instants.digitized?.timeIntervalSince1970,
                instants.gps?.timeIntervalSince1970,
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

    /// Writes a reused source overlay onto the row `landed` settled, with the destination's
    /// own file facts and the derived images copied for it.
    static func writeReusableEnrichmentOverlay(
        _ overlay: ReusableEnrichmentOverlay,
        for landed: LandedImport,
        contentHash: XXH3Digest128,
        db: Database
    ) throws {
        let destinationRootID = landed.destinationRootID
        let destinationRelativePath = landed.operation.destinationRelativePath
        let destinationByteSize = landed.byteSize
        let destinationMTimeSeconds = Int(landed.contentModifiedAt.timeIntervalSince1970.rounded(.down))
        let captureWall = CaptureWallClock.select(from: overlay.metadata.timestamps)
        let instants = BestCaptureInstants.from(overlay.metadata.timestamps)
        try db.execute(
            sql: """
            UPDATE media_asset SET
                thumbnail_path = ?,
                preview_path = ?,
                rendered_revision = COALESCE(
                    (SELECT rendered_revision FROM media_asset WHERE library_root_id = ? AND relative_path = ?),
                    rendered_revision
                ),
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
                landed.destinationThumbnailPath,
                landed.destinationPreviewPath,
                landed.sourceRootID,
                landed.operation.sourceRelativePath.rawValue,
                instants.original?.timeIntervalSince1970,
                instants.quickTimeCreation?.timeIntervalSince1970,
                instants.digitized?.timeIntervalSince1970,
                instants.gps?.timeIntervalSince1970,
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

    /// The stored form of an asset's metadata. Encoding failing is an error, never a
    /// silently missing record.
    static func encodeMetadataExtraJSON(_ metadata: AssetMetadata) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try String(decoding: encoder.encode(metadata), as: UTF8.self)
    }

    /// Reads a stored metadata record back. A record that does not decode is an error,
    /// not an asset without metadata: each caller decides what that means for it.
    static func decodeMetadataExtraJSON(_ json: String) throws -> AssetMetadata {
        try JSONDecoder().decode(AssetMetadata.self, from: Data(json.utf8))
    }

    static func fetchExistingAssetRows(
        libraryRootID: Int64,
        underSubtree: MediaRelativePath? = nil,
        db: Database
    ) throws -> [(relativePath: MediaRelativePath, derivedImagePaths: [String], hadEnrichment: Bool)] {
        let rows: [Row] = if let underSubtree {
            // Component-safe: `a/b` matches itself and `a/b/...`, never `a/b2`.
            try Row.fetchAll(
                db,
                sql: """
                SELECT relative_path, thumbnail_path, preview_path, enriched_source_size, enriched_source_mtime
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
                SELECT relative_path, thumbnail_path, preview_path, enriched_source_size, enriched_source_mtime
                FROM media_asset
                WHERE library_root_id = ?
                """,
                arguments: [libraryRootID]
            )
        }
        return rows.map { row in
            let thumbnailPath: String? = row["thumbnail_path"]
            let previewPath: String? = row["preview_path"]
            return (
                relativePath: MediaRelativePath(rawValue: row["relative_path"]),
                derivedImagePaths: [thumbnailPath, previewPath].compactMap(\.self),
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
            sql: """
            SELECT relative_path FROM media_companion
            WHERE library_root_id = ? AND relative_path_key = ? AND relative_path <> ? LIMIT 1
            """,
            arguments: [libraryRootID, pathKey, companion.relativePath.rawValue]
        ) {
            try db.execute(
                sql: """
                UPDATE media_companion SET relative_path = ?, relative_path_key = ?
                WHERE library_root_id = ? AND relative_path = ?
                """,
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
            changed = try upsertCompanion(companion, libraryRootID: libraryRootID, capabilities: capabilities, db: db)
                || changed
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
                let changed = try upsertCompanion(
                    companion,
                    libraryRootID: libraryRootID,
                    capabilities: capabilities,
                    db: db
                )
                changedCount += changed ? 1 : 0
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
            let removed = try deleteCompanionRow(rootRowID: libraryRootID, relativePath: path, db: db)
            deleted += removed ? 1 : 0
        }
        return deleted
    }

    /// The row a newly seen path moved from outside Otos, when the move witness says so
    /// (ADR 0008): no row exists at the new path; exactly one row on the same volume
    /// records this file's identifier, size and creation time (whole seconds); and that
    /// row's own path no longer exists on disk. The witness is evidence for this one
    /// write, never an identity — a path stays the asset. Modification time is left out
    /// on purpose: OneDrive rewrites it on remote renames and moves (research `2026-10-25-cloud-drives.md`, R2). A
    /// copy has a new identifier, and a file still present at its old path is not moved,
    /// so neither is paired; anything ambiguous pairs nothing and stays today's purge.
    static func movedRowWitnessed(
        for file: ScannedMediaFile,
        libraryRootPath: LibraryRootPath,
        libraryRootID: Int64,
        db: Database
    ) throws -> (libraryRootID: Int64, rootPath: String, relativePath: String)? {
        guard let identifier = file.fileIdentifier, let size = file.byteSize, let created = file.createdAt else {
            return nil
        }
        let rowAtPath = try Bool.fetchOne(
            db,
            sql: "SELECT 1 FROM media_asset WHERE library_root_id = ? AND relative_path = ?",
            arguments: [libraryRootID, file.relativePath.rawValue]
        ) ?? false
        guard !rowAtPath else {
            return nil
        }
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT a.library_root_id, a.relative_path, r.path AS root_path
            FROM media_asset a JOIN library_root r ON r.id = a.library_root_id
            WHERE a.file_identifier = ? AND a.byte_size = ?
              AND CAST(COALESCE(a.created_at_unix, -1) AS INTEGER) = ?
            """,
            arguments: [Int64(bitPattern: identifier), size, Int64(created.timeIntervalSince1970)]
        )
        guard !rows.isEmpty, let volume = volumeDevice(of: libraryRootPath.url.path(percentEncoded: false)) else {
            return nil
        }
        let candidates: [(libraryRootID: Int64, rootPath: String, relativePath: String)] = rows.compactMap { row in
            let rootPath: String = row["root_path"]
            let relativePath: String = row["relative_path"]
            guard volumeDevice(of: rootPath) == volume else {
                return nil
            }
            let oldPath = LibraryRootPath(rawValue: rootPath).url
                .appendingPathComponent(relativePath, isDirectory: false).path(percentEncoded: false)
            var info = stat()
            guard lstat(oldPath, &info) != 0, errno == ENOENT else {
                return nil
            }
            return (row["library_root_id"], rootPath, relativePath)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private static func volumeDevice(of path: String) -> dev_t? {
        var info = stat()
        return stat(path, &info) == 0 ? info.st_dev : nil
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
            sql: """
            SELECT relative_path FROM media_asset
            WHERE library_root_id = ? AND relative_path_key = ? AND relative_path <> ? LIMIT 1
            """,
            arguments: [libraryRootID, pathKey, file.relativePath.rawValue]
        ) {
            try db.execute(
                sql: """
                UPDATE media_asset SET relative_path = ?, relative_path_key = ?
                WHERE library_root_id = ? AND relative_path = ?
                """,
                arguments: [file.relativePath.rawValue, pathKey, libraryRootID, existingPath]
            )
            let message = "op=catalog.scan.reconcile phase=respell "
                + "rootPath=\(libraryRootPath.rawValue) "
                + "from=\(existingPath) "
                + "to=\(file.relativePath.rawValue)"
            OtosLog.catalog.notice("\(message, privacy: .public)")
            return true
        }
        if let moved = try movedRowWitnessed(for: file, libraryRootPath: libraryRootPath, libraryRootID: libraryRootID, db: db) {
            // The row keeps everything Otos holds for the file and takes the new path;
            // the upsert below then refreshes its filesystem facts. `asset_metadata` and
            // every other child row follow through `ON UPDATE CASCADE`.
            try db.execute(
                sql: """
                UPDATE media_asset SET library_root_id = ?, relative_path = ?, relative_path_key = ?
                WHERE library_root_id = ? AND relative_path = ?
                """,
                arguments: [libraryRootID, file.relativePath.rawValue, pathKey, moved.libraryRootID, moved.relativePath]
            )
            let message = "op=catalog.scan.reconcile phase=moveWitnessed "
                + "fromRoot=\(moved.rootPath) from=\(moved.relativePath) "
                + "rootPath=\(libraryRootPath.rawValue) to=\(file.relativePath.rawValue)"
            OtosLog.catalog.notice("\(message, privacy: .public)")
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
                content_modified_at_unix,
                file_identifier
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(library_root_id, relative_path) DO UPDATE SET
                sort_key = excluded.sort_key,
                name_sort_key = excluded.name_sort_key,
                name = excluded.name,
                content_type_identifier = excluded.content_type_identifier,
                kind = excluded.kind,
                format = excluded.format,
                byte_size = excluded.byte_size,
                created_at_unix = excluded.created_at_unix,
                content_modified_at_unix = excluded.content_modified_at_unix,
                file_identifier = excluded.file_identifier
            WHERE media_asset.sort_key IS NOT excluded.sort_key
               OR media_asset.file_identifier IS NOT excluded.file_identifier
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
        let arguments = try assetMetadataStatementArguments(
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
        MediaSortKey.naturalKey(file.name ?? file.relativePath.fileName),
        file.name,
        file.contentTypeIdentifier,
        file.kind?.rawValue,
        file.format?.rawValue,
        file.byteSize,
        file.createdAt?.timeIntervalSince1970,
        file.contentModifiedAt?.timeIntervalSince1970,
        file.fileIdentifier.map { Int64(bitPattern: $0) },
    ]
    return StatementArguments(values)
}

private nonisolated func assetMetadataStatementArguments(
    _ metadata: AssetMetadata,
    libraryRootID: Int64,
    relativePath: MediaRelativePath,
    primaryLocation: GeoRecord?
) throws -> StatementArguments {
    let values: [(any DatabaseValueConvertible)?] = try [
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

/// A device identity is stored as its text.
nonisolated extension DeviceIdentity: DatabaseValueConvertible {
    var databaseValue: DatabaseValue {
        rawValue.databaseValue
    }

    static func fromDatabaseValue(_ dbValue: DatabaseValue) -> DeviceIdentity? {
        String.fromDatabaseValue(dbValue).map(DeviceIdentity.init(rawValue:))
    }
}
