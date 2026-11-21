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
        try db.execute(sql: ImportJournalSQL.writeEraseSQL, arguments: [
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
        try db.execute(sql: ImportJournalSQL.deleteEraseSQL, arguments: [key.rawValue])
    }

    /// A row whose source kind this build does not know is kept and reported, never
    /// read as some other kind: an erase acts on the source it names.
    nonisolated static func fetchAllActiveSourceErases(db: Database) throws -> [ActiveSourceEraseOperation] {
        try Row.fetchAll(db, sql: ImportJournalSQL.erasesSQL).compactMap { row in
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
            sql: ImportJournalSQL.insertOperationSQL,
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
            sql: ImportJournalSQL.updateOperationSQL,
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
            sql: ImportJournalSQL.deleteCompanionStagingSQL,
            arguments: [operation.operationKey.rawValue]
        )
        for url in operation.companionStagingURLs {
            try db.execute(
                sql: ImportJournalSQL.insertCompanionStagingSQL,
                arguments: [operation.operationKey.rawValue, url.path(percentEncoded: false)]
            )
        }
    }

    static func deleteActiveFileOperation(key: ActiveFileOperationKey, db: Database) throws {
        try db.execute(
            sql: ImportJournalSQL.deleteOperationSQL,
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
            sql: ImportJournalSQL.companionStagingSQL
        )
        var companionStaging: [String: [URL]] = [:]
        for row in stagingRows {
            let key: String = row["operation_key"]
            let path: String = row["staging_path"]
            companionStaging[key, default: []].append(URL(fileURLWithPath: path, isDirectory: false))
        }
        return try Row.fetchAll(db, sql: ImportJournalSQL.operationsSQL).compactMap { row in
            activeFileOperation(from: row, companionStaging: companionStaging)
        }
    }

    /// Returns what writing the copy's own row did (`ScannedFileUpsert`): a new row, or one the
    /// copy's path, or a witness of its move, already held.
    @discardableResult
    static func settleImportedAsset(_ landed: LandedImport, db: Database) throws -> ScannedFileUpsert {
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
        let upsert = try upsertScannedFile(
            file,
            libraryRootPath: operation.destinationRootPath,
            libraryRootID: destinationRootID,
            capabilities: capabilities,
            db: db
        )
        // The source's choice and edit carry to the copy; a source outside the catalog binds no
        // key and carries nothing.
        let source = landed.sourceRootID.map { AssetKey(rootID: $0, path: operation.sourceRelativePath).arguments } ?? [nil, nil]
        try db.execute(
            sql: AssetRowSQL.settleImportedAssetSQL,
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
            ] + source + source + source
                + AssetKey(rootID: destinationRootID, path: relativePath).arguments
        )
        try writeLandedProducts(landed, db: db)
        // A rendering was drawn with the source's last rendered edit; an edit saved after
        // it is enrichment's to render for the copy (ADR 0036).
        try releaseUnrenderedEdits(db: db, rootID: destinationRootID, relativePath: relativePath)
        for companion in landed.companions {
            try upsertCompanion(companion, libraryRootID: destinationRootID, capabilities: capabilities, db: db)
        }
        return upsert
    }

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
            sql: AssetEnrichmentSQL.reusableEnrichmentOverlaySQL,
            arguments: AssetKey(rootID: sourceRootID, path: sourceRelativePath).arguments
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

/// Import journal SQL guide (ADR 0002)
///
/// The statements of the file-operation journals: `active_file_operation` (an import's or
/// export's copies, with the staging of their companions) and `active_source_erase` (a card
/// Erase), which let interrupted work recover at launch. The rows an import settles are
/// `AssetRowSQL`'s. `CatalogStore` owns when each runs; this enum owns only the text.
nonisolated enum ImportJournalSQL {
    static let setPhaseSQL = "UPDATE active_file_operation SET phase = ?, updated_at = ? WHERE operation_key = ?"

    static let writeEraseSQL = """
    INSERT OR REPLACE INTO active_source_erase
        (operation_key, source_kind, source_device_identity, source_root_path,
         source_relative_path, source_byte_size, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    """

    static let deleteEraseSQL = "DELETE FROM active_source_erase WHERE operation_key = ?"

    static let erasesSQL = "SELECT * FROM active_source_erase ORDER BY operation_key"

    static let insertOperationSQL = """
    INSERT INTO active_file_operation (
        operation_key, source_kind, source_device_identity,
        source_root_path, source_relative_path,
        destination_root_path, destination_relative_path,
        staging_path, content_sha1, import_batch_unix_ms,
        source_byte_size, source_modified_at, destination_modified_at,
        phase, updated_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """

    static let updateOperationSQL = """
    UPDATE active_file_operation SET
        staging_path = ?,
        content_sha1 = ?,
        destination_modified_at = ?,
        phase = ?,
        updated_at = ?
    WHERE operation_key = ?
    """

    static let deleteCompanionStagingSQL = "DELETE FROM active_file_operation_companion_staging WHERE operation_key = ?"

    static let insertCompanionStagingSQL = "INSERT INTO active_file_operation_companion_staging (operation_key, staging_path) VALUES (?, ?)"

    static let deleteOperationSQL = "DELETE FROM active_file_operation WHERE operation_key = ?"

    static let companionStagingSQL = "SELECT operation_key, staging_path FROM active_file_operation_companion_staging ORDER BY staging_path"

    static let operationsSQL = "SELECT * FROM active_file_operation ORDER BY updated_at"

    /// Points `table`'s journal rows that name a source root (bound: new, then old) at its new
    /// path. `table` is `active_file_operation` or `active_source_erase`.
    static func moveSourceRootSQL(in table: String) -> String {
        "UPDATE \(table) SET source_root_path = ? WHERE source_root_path = ?"
    }
}
