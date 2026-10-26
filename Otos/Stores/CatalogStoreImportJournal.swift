import Foundation
import GRDB
import OSLog
import UniformTypeIdentifiers

nonisolated enum ImportOverlayReuseMiss: String, Equatable, Sendable {
    case absentSourceRow
    case staleSourceOverlay
    case missingOrMismatchedHash
    case removableSourceNotHashed
    case missingThumbnail
    /// A still whose source row has no stored preview (a camera row, enriched from byte
    /// ranges): reusing it would stamp a library row that then never gets one, so the
    /// copy is enriched from its own bytes instead (ADR 0035).
    case missingPreview
    case thumbnailCopyFailed
    case detachedSource
}

/// What landed in a library for one journaled import entry, as settlement records it:
/// the published file's facts, the companions published beside it, and the source's
/// overlay when it is reused. Where it landed and for which batch are the operation's.
nonisolated struct LandedImport {
    let operation: ActiveFileOperation
    let destinationRootID: Int64
    let sourceRootID: Int64?
    let byteSize: Int64
    let contentModifiedAt: Date
    let companions: [MediaCompanion]
    let reusableOverlay: ReusableEnrichmentOverlay?
    let destinationThumbnailPath: String?
    let destinationPreviewPath: String?
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

nonisolated struct ImportOverlayReuseResult: Equatable, Sendable {
    let metadataCloned: Bool
    let thumbnailCopied: Bool
    let miss: ImportOverlayReuseMiss?

    static let notReused = ImportOverlayReuseResult(
        metadataCloned: false,
        thumbnailCopied: false,
        miss: .absentSourceRow
    )
}

extension CatalogStore {
    static func insertActiveFileOperation(_ operation: ActiveFileOperation, db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO active_file_operation (
                operation_key, source_kind, source_device_identity,
                source_root_path, source_relative_path,
                destination_root_path, destination_relative_path,
                staging_path, content_hash_xxh3_128, import_batch_unix_ms,
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
                content_hash_xxh3_128 = ?,
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
        _ = try upsertScannedFile(
            file,
            libraryRootPath: operation.destinationRootPath,
            libraryRootID: destinationRootID,
            db: db
        )
        try db.execute(
            sql: """
            UPDATE media_asset
            SET import_batch_unix_ms = ?,
                import_source_root_path = ?,
                import_source_relative_path = ?,
                import_source_byte_size = ?,
                import_source_modified_at_epoch = ?,
                import_destination_byte_size = ?,
                import_destination_modified_at_epoch = ?,
                content_hash_xxh3_128 = ?,
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
            """,
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
        if let reusableOverlay = landed.reusableOverlay, let contentHash = operation.contentHash {
            try writeReusableEnrichmentOverlay(reusableOverlay, for: landed, contentHash: contentHash, db: db)
            // Reused products were rendered from the source's last rendered edit; an edit
            // saved after them is enrichment's to render for the copy (ADR 0036).
            try releaseUnrenderedEdits(db: db, rootID: destinationRootID, relativePath: relativePath)
        }
        for companion in landed.companions {
            try upsertCompanion(companion, libraryRootID: destinationRootID, db: db)
        }
    }

    static func fetchReusableEnrichmentOverlay(
        sourceRootID: Int64,
        sourceRelativePath: MediaRelativePath,
        db: Database
    ) throws -> ReusableEnrichmentOverlay? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT m.byte_size, m.content_modified_at_unix,
                   m.enriched_kind, m.enriched_format,
                   m.enriched_source_size, m.enriched_source_mtime,
                   m.content_hash_xxh3_128, m.content_hash_source_size,
                   m.content_hash_source_mtime, m.thumbnail_path, m.preview_path,
                   a.metadata_extra_json
            FROM media_asset m
            LEFT JOIN asset_metadata a
              ON a.library_root_id = m.library_root_id
             AND a.relative_path = m.relative_path
            WHERE m.library_root_id = ? AND m.relative_path = ?
            """,
            arguments: [sourceRootID, sourceRelativePath.rawValue]
        ),
            let metadataJSON: String = row["metadata_extra_json"]
        else {
            return nil
        }
        let metadata: AssetMetadata
        do {
            metadata = try CatalogStore.decodeMetadataExtraJSON(metadataJSON)
        } catch {
            // Reuse is an optimization: a record this build cannot read is not reused,
            // and settlement falls back to enriching the destination, as for any miss.
            OtosLog.catalog.errorOperation("mediaOperation.settle", phase: "overlayUndecodable", fields: [
                "relativePath": sourceRelativePath.rawValue,
                "error": String(describing: error),
            ])
            return nil
        }
        let modified: Double? = row["content_modified_at_unix"]
        let enrichedKindRaw: String? = row["enriched_kind"]
        let enrichedFormatRaw: String? = row["enriched_format"]
        let contentHashData: Data? = row["content_hash_xxh3_128"]
        return ReusableEnrichmentOverlay(
            metadata: metadata,
            enrichedKind: enrichedKindRaw.flatMap(MediaKind.init(rawValue:)),
            enrichedFormat: enrichedFormatRaw.map(MediaFormatToken.init(rawValue:)),
            sourceByteSize: row["byte_size"],
            sourceMTimeSeconds: modified.map { Int($0.rounded(.down)) } ?? -1,
            contentHash: contentHashData.flatMap(XXH3Digest128.init(data:)),
            contentHashSourceSize: row["content_hash_source_size"],
            contentHashSourceMTimeSeconds: row["content_hash_source_mtime"],
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
            contentHash: (row["content_hash_xxh3_128"] as Data?).flatMap(XXH3Digest128.init(data:)),
            importBatch: ImportBatchID(unixMilliseconds: row["import_batch_unix_ms"]),
            sourceByteSize: row["source_byte_size"],
            sourceModifiedAt: Date(timeIntervalSince1970: sourceModified),
            destinationModifiedAt: destinationModified.map(Date.init(timeIntervalSince1970:)),
            phase: phase,
            updatedAt: Date(timeIntervalSince1970: updated)
        )
    }
}
