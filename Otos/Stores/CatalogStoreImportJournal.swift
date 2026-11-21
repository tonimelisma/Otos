import Foundation
import GRDB
import OSLog
import UniformTypeIdentifiers

/// Where one of an imported copy's products came from when it settled (ADR 0009).
nonisolated enum ImportProductOrigin: String, Equatable, Sendable {
    /// The source row's, current for the bytes the import copied.
    case reused
    /// The source's thumbnail without a rendering (QuickLook's on a card's first pass, a
    /// camera's embedded preview), shown until enrichment renders the copy.
    case provisional
    /// Neither: the copy owes it, and enrichment makes it, offering the copy first.
    case owed
}

/// What settlement gave an imported copy, product by product.
nonisolated struct ImportProductsResult: Equatable, Sendable {
    let metadata: ImportProductOrigin
    let rendering: ImportProductOrigin

    static let owed = ImportProductsResult(metadata: .owed, rendering: .owed)
}

/// The rendering a settled copy gets: the source's derived images copied for it, and
/// whether they are a rendering (stamped with the copy's facts, at `renderedRevision`) or
/// a provisional thumbnail (not stamped).
nonisolated struct LandedRendering {
    let thumbnailPath: String?
    let previewPath: String?
    let stamped: Bool
    let renderedRevision: Int64
}

/// A copy's rendering while settlement stages it, before its images are promoted.
nonisolated struct StagedRendering {
    let thumbnail: StagedDerivedImage?
    let preview: StagedDerivedImage?
    let stamped: Bool
    let renderedRevision: Int64
}

/// What landed in a library for one journaled import entry, as settlement records it:
/// the published file's facts, the companions published beside it, and each product it
/// gets. Where it landed and for which batch are the operation's.
nonisolated struct LandedImport {
    let operation: ActiveFileOperation
    let destinationRootID: Int64
    let sourceRootID: Int64?
    let byteSize: Int64
    let contentModifiedAt: Date
    let companions: [MediaCompanion]
    let metadata: EnrichedMetadata?
    let rendering: LandedRendering?
}

extension CatalogStore {
    nonisolated static func insertActiveSourceErase(_ operation: ActiveSourceEraseOperation, db: Database) throws {
        try db.execute(sql: """
        INSERT OR REPLACE INTO active_source_erase
            (operation_key, source_kind, source_device_identity, source_root_path,
             source_relative_path, source_byte_size, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """, arguments: [
            operation.key.rawValue,
            operation.sourceKind.rawValue,
            operation.sourceDeviceIdentity,
            operation.sourceRootPath.rawValue,
            operation.sourceRelativePath.rawValue,
            operation.sourceByteSize,
            operation.updatedAt.timeIntervalSince1970,
        ])
    }

    nonisolated static func deleteActiveSourceErase(key: ActiveSourceEraseKey, db: Database) throws {
        try db.execute(sql: "DELETE FROM active_source_erase WHERE operation_key = ?", arguments: [key.rawValue])
    }

    /// A row whose source kind this build does not know is kept and reported, never
    /// read as some other kind: an erase acts on the source it names.
    nonisolated static func fetchAllActiveSourceErases(db: Database) throws -> [ActiveSourceEraseOperation] {
        try Row.fetchAll(db, sql: "SELECT * FROM active_source_erase ORDER BY operation_key").compactMap { row in
            let key = ActiveSourceEraseKey(rawValue: row["operation_key"])
            guard let kind = LibraryRootKind(rawValue: row["source_kind"]) else {
                OtosLog.catalog.faultOperation("import.erase.journal", phase: "unknownSourceKind", fields: [
                    "key": key.rawValue,
                    "sourceKind": row["source_kind"] ?? "",
                ])
                return nil
            }
            return ActiveSourceEraseOperation(
                key: key,
                sourceKind: kind,
                sourceDeviceIdentity: row["source_device_identity"],
                sourceRootPath: LibraryRootPath(rawValue: row["source_root_path"]),
                sourceRelativePath: MediaRelativePath(rawValue: row["source_relative_path"]),
                sourceByteSize: row["source_byte_size"],
                updatedAt: Date(timeIntervalSince1970: row["updated_at"])
            )
        }
    }
}

extension CatalogStore {
    static func insertActiveFileOperation(_ operation: ActiveFileOperation, db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO active_file_operation (
                operation_key, source_kind, source_device_identity,
                source_root_path, source_relative_path,
                destination_root_path, destination_relative_path,
                staging_path, content_sha1, import_batch_unix_ms,
                source_byte_size, source_modified_at, destination_modified_at,
                phase, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                operation.operationKey.rawValue,
                operation.sourceKind.rawValue,
                operation.sourceDeviceIdentity,
                operation.sourceRootPath.rawValue,
                operation.sourceRelativePath.rawValue,
                operation.destinationRootPath.rawValue,
                operation.destinationRelativePath.rawValue,
                operation.stagingURL?.path(percentEncoded: false),
                operation.contentHash?.data,
                operation.importBatch.unixMilliseconds,
                operation.sourceByteSize,
                operation.sourceModifiedAt.timeIntervalSince1970,
                operation.destinationModifiedAt?.timeIntervalSince1970,
                operation.phase.rawValue,
                operation.updatedAt.timeIntervalSince1970,
            ]
        )
        try replaceCompanionStaging(operation, db: db)
    }

    static func updateActiveFileOperation(_ operation: ActiveFileOperation, db: Database) throws {
        try db.execute(
            sql: """
            UPDATE active_file_operation SET
                staging_path = ?,
                content_sha1 = ?,
                destination_modified_at = ?,
                phase = ?,
                updated_at = ?
            WHERE operation_key = ?
            """,
            arguments: [
                operation.stagingURL?.path(percentEncoded: false),
                operation.contentHash?.data,
                operation.destinationModifiedAt?.timeIntervalSince1970,
                operation.phase.rawValue,
                operation.updatedAt.timeIntervalSince1970,
                operation.operationKey.rawValue,
            ]
        )
        guard db.changesCount == 1 else {
            throw CatalogStoreError.importOperationMissing(operation.operationKey)
        }
        try replaceCompanionStaging(operation, db: db)
    }

    private static func replaceCompanionStaging(_ operation: ActiveFileOperation, db: Database) throws {
        try db.execute(
            sql: "DELETE FROM active_file_operation_companion_staging WHERE operation_key = ?",
            arguments: [operation.operationKey.rawValue]
        )
        for url in operation.companionStagingURLs {
            try db.execute(
                sql: "INSERT INTO active_file_operation_companion_staging (operation_key, staging_path) VALUES (?, ?)",
                arguments: [operation.operationKey.rawValue, url.path(percentEncoded: false)]
            )
        }
    }

    static func deleteActiveFileOperation(key: ActiveFileOperationKey, db: Database) throws {
        try db.execute(
            sql: "DELETE FROM active_file_operation WHERE operation_key = ?",
            arguments: [key.rawValue]
        )
        guard db.changesCount == 1 else {
            throw CatalogStoreError.importOperationMissing(key)
        }
    }

    /// A row whose phase or source kind this build does not know is kept and reported;
    /// recovery cannot act on it correctly, so it does not act at all.
    static func fetchAllActiveFileOperations(db: Database) throws -> [ActiveFileOperation] {
        let stagingRows = try Row.fetchAll(
            db,
            sql: "SELECT operation_key, staging_path FROM active_file_operation_companion_staging ORDER BY staging_path"
        )
        var companionStaging: [String: [URL]] = [:]
        for row in stagingRows {
            let key: String = row["operation_key"]
            let path: String = row["staging_path"]
            companionStaging[key, default: []].append(URL(fileURLWithPath: path, isDirectory: false))
        }
        return try Row.fetchAll(db, sql: "SELECT * FROM active_file_operation ORDER BY updated_at").compactMap { row in
            activeFileOperation(from: row, companionStaging: companionStaging)
        }
    }

    nonisolated static let settleImportedAssetSQL = """
    UPDATE media_asset
    SET import_batch_unix_ms = ?,
        import_source_root_path = ?,
        import_source_relative_path = ?,
        import_source_byte_size = ?,
        import_source_modified_at_epoch = ?,
        import_destination_byte_size = ?,
        import_destination_modified_at_epoch = ?,
        content_sha1 = ?,
        content_hash_source_size = ?,
        content_hash_source_mtime = ?,
        media_choice = COALESCE(
            (SELECT media_choice FROM media_asset
             WHERE library_root_id = ? AND relative_path = ?),
            media_choice
        ),
        edit_recipe_json = COALESCE(
            (SELECT edit_recipe_json FROM media_asset
             WHERE library_root_id = ? AND relative_path = ?),
            edit_recipe_json
        ),
        edit_revision = COALESCE(
            (SELECT edit_revision FROM media_asset
             WHERE library_root_id = ? AND relative_path = ?),
            edit_revision
        )
    WHERE library_root_id = ? AND relative_path = ?
    """

    static func settleImportedAsset(_ landed: LandedImport, db: Database) throws {
        let operation = landed.operation
        let relativePath = operation.destinationRelativePath
        let destinationRootID = landed.destinationRootID
        let byteSize = landed.byteSize
        let contentModifiedAt = landed.contentModifiedAt
        let file = ScannedMediaFile(
            relativePath: relativePath,
            name: relativePath.fileName,
            contentTypeIdentifier: UTType(filenameExtension: relativePath.fileExtension)?.identifier,
            byteSize: byteSize,
            createdAt: contentModifiedAt,
            contentModifiedAt: contentModifiedAt
        )
        // The copy and its companions are keyed by the destination volume's own name
        // equality (ARC-056): on a case-sensitive root `IMG_1.jpg` beside `img_1.jpg` is
        // another file, never a respelling of it.
        let capabilities = try storedCapabilities(rootRowID: destinationRootID, db: db)
        _ = try upsertScannedFile(
            file,
            libraryRootPath: operation.destinationRootPath,
            libraryRootID: destinationRootID,
            capabilities: capabilities,
            db: db
        )
        try db.execute(
            sql: Self.settleImportedAssetSQL,
            arguments: [
                operation.importBatch.unixMilliseconds,
                operation.sourceRootPath.rawValue,
                operation.sourceRelativePath.rawValue,
                operation.sourceByteSize,
                operation.sourceModifiedAt.timeIntervalSince1970,
                byteSize,
                contentModifiedAt.timeIntervalSince1970,
                operation.contentHash?.data,
                operation.contentHash == nil ? nil : byteSize,
                operation.contentHash == nil ? nil : Int(contentModifiedAt.timeIntervalSince1970.rounded(.down)),
                landed.sourceRootID,
                operation.sourceRelativePath.rawValue,
                landed.sourceRootID,
                operation.sourceRelativePath.rawValue,
                landed.sourceRootID,
                operation.sourceRelativePath.rawValue,
                destinationRootID,
                relativePath.rawValue,
            ]
        )
        try writeLandedProducts(landed, db: db)
        // A rendering was drawn with the source's last rendered edit; an edit saved after
        // it is enrichment's to render for the copy (ADR 0036).
        try releaseUnrenderedEdits(db: db, rootID: destinationRootID, relativePath: relativePath)
        for companion in landed.companions {
            try upsertCompanion(companion, libraryRootID: destinationRootID, capabilities: capabilities, db: db)
        }
    }

    nonisolated static let reusableEnrichmentOverlaySQL = """
    SELECT m.enriched_kind, m.enriched_format,
           m.metadata_source_size, m.metadata_source_mtime,
           m.rendered_source_size, m.rendered_source_mtime, m.rendered_revision,
           m.edit_recipe_json, m.edit_revision,
           m.thumbnail_path, m.preview_path,
           a.metadata_extra_json
    FROM media_asset m
    LEFT JOIN asset_metadata a
      ON a.library_root_id = m.library_root_id
     AND a.relative_path = m.relative_path
    WHERE m.library_root_id = ? AND m.relative_path = ?
    """

    /// The source row's products and their stamps, or nil when there is no row. Its
    /// metadata is nil when the row has no record, or one this build cannot read: reuse is
    /// per product, so that only makes the metadata owed. A recipe that cannot be decoded
    /// throws: an unreadable recipe is a failed read, never an unedited photo (ADR 0036).
    static func fetchReusableEnrichmentOverlay(
        sourceRootID: Int64,
        sourceRelativePath: MediaRelativePath,
        db: Database
    ) throws -> ReusableEnrichmentOverlay? {
        guard let row = try Row.fetchOne(
            db,
            sql: reusableEnrichmentOverlaySQL,
            arguments: [sourceRootID, sourceRelativePath.rawValue]
        ) else {
            return nil
        }
        var metadata: EnrichedMetadata?
        if let metadataJSON: String = row["metadata_extra_json"] {
            do {
                let enrichedKindRaw: String? = row["enriched_kind"]
                let enrichedFormatRaw: String? = row["enriched_format"]
                metadata = try EnrichedMetadata(
                    metadata: CatalogStore.decodeMetadataExtraJSON(metadataJSON),
                    kind: enrichedKindRaw.flatMap(MediaKind.init(rawValue:)),
                    format: enrichedFormatRaw.map(MediaFormatToken.init(rawValue:))
                )
            } catch {
                // A record this build cannot read is not reused; the import reads the
                // copy's metadata itself.
                OtosLog.catalog.errorOperation("mediaOperation.settle", phase: "overlayUndecodable", fields: [
                    "relativePath": sourceRelativePath.rawValue,
                    "error": String(describing: error),
                ])
            }
        }
        return try ReusableEnrichmentOverlay(
            metadata: metadata,
            metadataSourceSize: row["metadata_source_size"],
            metadataSourceMTimeSeconds: row["metadata_source_mtime"],
            renderedSourceSize: row["rendered_source_size"],
            renderedSourceMTimeSeconds: row["rendered_source_mtime"],
            renderedRevision: row["rendered_revision"] ?? 0,
            recipe: CatalogStore.storedEditRecipe(json: row["edit_recipe_json"], revision: row["edit_revision"] ?? 0),
            thumbnailPath: row["thumbnail_path"],
            previewPath: row["preview_path"]
        )
    }

    private static func activeFileOperation(
        from row: Row,
        companionStaging: [String: [URL]]
    ) -> ActiveFileOperation? {
        let key: String = row["operation_key"]
        guard let phase = ActiveFileOperationPhase(rawValue: row["phase"]),
              let kind = LibraryRootKind(rawValue: row["source_kind"])
        else {
            OtosLog.catalog.faultOperation("mediaOperation.journal", phase: "unknownRow", fields: [
                "key": key,
                "phase": row["phase"] ?? "",
                "sourceKind": row["source_kind"] ?? "",
            ])
            return nil
        }
        let sourceModified: Double = row["source_modified_at"]
        let destinationModified: Double? = row["destination_modified_at"]
        let updated: Double = row["updated_at"]
        let stagingPath: String? = row["staging_path"]
        return ActiveFileOperation(
            operationKey: ActiveFileOperationKey(rawValue: key),
            sourceKind: kind,
            sourceDeviceIdentity: row["source_device_identity"],
            sourceRootPath: LibraryRootPath(rawValue: row["source_root_path"]),
            sourceRelativePath: MediaRelativePath(rawValue: row["source_relative_path"]),
            destinationRootPath: LibraryRootPath(rawValue: row["destination_root_path"]),
            destinationRelativePath: MediaRelativePath(rawValue: row["destination_relative_path"]),
            stagingURL: stagingPath.map { URL(fileURLWithPath: $0, isDirectory: false) },
            companionStagingURLs: companionStaging[key] ?? [],
            contentHash: (row["content_sha1"] as Data?).flatMap(ContentDigest.init(data:)),
            importBatch: ImportBatchID(unixMilliseconds: row["import_batch_unix_ms"]),
            sourceByteSize: row["source_byte_size"],
            sourceModifiedAt: Date(timeIntervalSince1970: sourceModified),
            destinationModifiedAt: destinationModified.map(Date.init(timeIntervalSince1970:)),
            phase: phase,
            updatedAt: Date(timeIntervalSince1970: updated)
        )
    }
}
