import Foundation
import GRDB
import OSLog
import UniformTypeIdentifiers

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
    }

    static func deleteActiveFileOperation(key: ActiveFileOperationKey, db: Database) throws {
        try db.execute(
            sql: "DELETE FROM active_file_operation WHERE operation_key = ?",
            arguments: [key.rawValue]
        )
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
        for companion in companions {
            try upsertCompanion(companion, libraryRootID: destinationRootID, db: db)
        }
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
            contentHash: XXH3Digest128(data: row["content_hash_xxh3_128"]),
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
