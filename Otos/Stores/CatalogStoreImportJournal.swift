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
    case thumbnailCopyFailed
    case detachedSource
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
                operation_key, mode, source_kind, source_device_identity,
                source_root_path, source_relative_path,
                destination_root_path, destination_relative_path,
                staging_path, content_hash_xxh3_128, import_batch_unix_ms,
                source_byte_size, source_modified_at, destination_modified_at,
                phase, delete_source_requested, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: activeFileOperationArguments(operation)
        )
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
                operation.stagingPath,
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

    static func fetchAllActiveFileOperations(db: Database) throws -> [ActiveFileOperation] {
        try Row.fetchAll(db, sql: "SELECT * FROM active_file_operation ORDER BY updated_at").compactMap {
            activeFileOperation(from: $0)
        }
    }

    // swiftlint:disable:next function_parameter_count
    static func settleImportedAsset(
        operation: ActiveFileOperation,
        destinationRootID: Int64,
        destinationRootPath: LibraryRootPath,
        relativePath: MediaRelativePath,
        byteSize: Int64,
        contentModifiedAt: Date,
        batch: ImportBatchID,
        companions: [MediaCompanion],
        reusableOverlay: ReusableEnrichmentOverlay? = nil,
        destinationThumbnailPath: String? = nil,
        db: Database
    ) throws {
        let name = relativePath.rawValue.split(separator: "/").last.map(String.init) ?? relativePath.rawValue
        let contentType = UTType(filenameExtension: (name as NSString).pathExtension)?.identifier
        let file = ScannedMediaFile(
            relativePath: relativePath,
            name: name,
            contentTypeIdentifier: contentType,
            byteSize: byteSize,
            createdAt: contentModifiedAt,
            contentModifiedAt: contentModifiedAt
        )
        _ = try upsertScannedFile(
            file,
            libraryRootPath: destinationRootPath,
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
                content_hash_source_mtime = ?
            WHERE library_root_id = ? AND relative_path = ?
            """,
            arguments: [
                batch.unixMilliseconds,
                operation.sourceRootPath.rawValue,
                operation.sourceRelativePath.rawValue,
                operation.sourceByteSize,
                operation.sourceModifiedAt.timeIntervalSince1970,
                byteSize,
                contentModifiedAt.timeIntervalSince1970,
                operation.contentHash?.data,
                operation.contentHash == nil ? nil : byteSize,
                operation.contentHash == nil ? nil : Int(contentModifiedAt.timeIntervalSince1970.rounded(.down)),
                destinationRootID,
                relativePath.rawValue,
            ]
        )
        if let reusableOverlay, let contentHash = operation.contentHash {
            try writeReusableEnrichmentOverlay(
                reusableOverlay,
                destinationRootID: destinationRootID,
                destinationRelativePath: relativePath,
                destinationByteSize: byteSize,
                destinationMTimeSeconds: Int(contentModifiedAt.timeIntervalSince1970.rounded(.down)),
                contentHash: contentHash,
                thumbnailPath: destinationThumbnailPath,
                db: db
            )
        }
        for companion in companions {
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
                   m.ts_original_unix, m.ts_quicktime_creation_unix,
                   m.ts_digitized_unix, m.ts_gps_unix,
                   m.enriched_kind, m.enriched_format, m.duration_seconds,
                   m.enriched_source_size, m.enriched_source_mtime,
                   m.content_hash_xxh3_128, m.content_hash_source_size,
                   m.content_hash_source_mtime, m.thumbnail_path,
                   a.metadata_extra_json
            FROM media_asset m
            LEFT JOIN asset_metadata a
              ON a.library_root_id = m.library_root_id
             AND a.relative_path = m.relative_path
            WHERE m.library_root_id = ? AND m.relative_path = ?
            """,
            arguments: [sourceRootID, sourceRelativePath.rawValue]
        ),
            let metadataJSON: String = row["metadata_extra_json"],
            let metadata = CatalogStore.decodeMetadataExtraJSON(metadataJSON)
        else {
            return nil
        }
        let modified: Double? = row["content_modified_at_unix"]
        let original: Double? = row["ts_original_unix"]
        let quickTime: Double? = row["ts_quicktime_creation_unix"]
        let digitized: Double? = row["ts_digitized_unix"]
        let gps: Double? = row["ts_gps_unix"]
        let enrichedKindRaw: String? = row["enriched_kind"]
        let enrichedFormatRaw: String? = row["enriched_format"]
        let contentHashData: Data? = row["content_hash_xxh3_128"]
        return ReusableEnrichmentOverlay(
            metadata: metadata,
            originalTimestamp: original.map(Date.init(timeIntervalSince1970:)),
            quickTimeCreationTimestamp: quickTime.map(Date.init(timeIntervalSince1970:)),
            digitizedTimestamp: digitized.map(Date.init(timeIntervalSince1970:)),
            gpsTimestamp: gps.map(Date.init(timeIntervalSince1970:)),
            enrichedKind: enrichedKindRaw.flatMap(MediaKind.init(rawValue:)),
            enrichedFormat: enrichedFormatRaw.map(MediaFormatToken.init(rawValue:)),
            durationSeconds: row["duration_seconds"],
            sourceByteSize: row["byte_size"],
            sourceMTimeSeconds: modified.map { Int($0.rounded(.down)) } ?? -1,
            contentHash: contentHashData.flatMap(XXH3Digest128.init(data:)),
            contentHashSourceSize: row["content_hash_source_size"],
            contentHashSourceMTimeSeconds: row["content_hash_source_mtime"],
            thumbnailPath: row["thumbnail_path"]
        )
    }

    private static func activeFileOperationArguments(_ operation: ActiveFileOperation) -> StatementArguments {
        [
            operation.operationKey.rawValue,
            operation.mode,
            operation.sourceKind.rawValue,
            operation.sourceDeviceIdentity,
            operation.sourceRootPath.rawValue,
            operation.sourceRelativePath.rawValue,
            operation.destinationRootPath.rawValue,
            operation.destinationRelativePath.rawValue,
            operation.stagingPath,
            operation.contentHash?.data,
            operation.importBatchUnixMs,
            operation.sourceByteSize,
            operation.sourceModifiedAt.timeIntervalSince1970,
            operation.destinationModifiedAt?.timeIntervalSince1970,
            operation.phase.rawValue,
            operation.deleteSourceRequested ? 1 : 0,
            operation.updatedAt.timeIntervalSince1970,
        ]
    }

    private static func activeFileOperation(from row: Row) -> ActiveFileOperation? {
        guard let phase = ActiveFileOperationPhase(rawValue: row["phase"]),
              let kind = LibraryRootKind(rawValue: row["source_kind"])
        else {
            return nil
        }
        let sourceModified: Double = row["source_modified_at"]
        let destinationModified: Double? = row["destination_modified_at"]
        let updated: Double = row["updated_at"]
        let deleteRequested: Int = row["delete_source_requested"]
        return ActiveFileOperation(
            operationKey: ActiveFileOperationKey(rawValue: row["operation_key"]),
            mode: row["mode"],
            sourceKind: kind,
            sourceDeviceIdentity: row["source_device_identity"],
            sourceRootPath: LibraryRootPath(rawValue: row["source_root_path"]),
            sourceRelativePath: MediaRelativePath(rawValue: row["source_relative_path"]),
            destinationRootPath: LibraryRootPath(rawValue: row["destination_root_path"]),
            destinationRelativePath: MediaRelativePath(rawValue: row["destination_relative_path"]),
            stagingPath: row["staging_path"],
            contentHash: (row["content_hash_xxh3_128"] as Data?).flatMap(XXH3Digest128.init(data:)),
            importBatchUnixMs: row["import_batch_unix_ms"],
            sourceByteSize: row["source_byte_size"],
            sourceModifiedAt: Date(timeIntervalSince1970: sourceModified),
            destinationModifiedAt: destinationModified.map(Date.init(timeIntervalSince1970:)),
            phase: phase,
            deleteSourceRequested: deleteRequested != 0,
            updatedAt: Date(timeIntervalSince1970: updated)
        )
    }
}
