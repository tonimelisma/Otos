import Foundation
import GRDB

/// Catalog query gateway guide
///
/// Pure SQL/mapping helpers for the catalog read surface. `CatalogStore` owns
/// orchestration (root-id resolution, `timedRead`, slow-query diagnostics); this
/// type groups ordered-ID / count / filter / detail / metadata / enrichment-candidate
/// SQL and `Row`→model mapping synchronously inside Store isolation — not a second
/// actor. Depends on free `StoredAsset` / `StoredTileDetail` / `SQLQuery` types, not
/// on `CatalogStore` itself.
nonisolated enum CatalogQueryGateway {
    /// Reads one asset's full preserved metadata JSON on demand. The scalar
    /// columns stay queryable; this JSON preserves the long-tail extraction payload
    /// for future inspector/detail work without making the grid load it.
    static func metadataExtra(
        libraryRootID: Int64,
        relativePath: MediaRelativePath,
        db: Database
    ) throws -> AssetMetadata? {
        let json: String? = try Row.fetchOne(
            db,
            sql: "SELECT metadata_extra_json FROM asset_metadata WHERE library_root_id = ? AND relative_path = ?",
            arguments: [libraryRootID, relativePath.rawValue]
        )?["metadata_extra_json"]
        return json.flatMap(CatalogStore.decodeMetadataExtraJSON)
    }

    static func fetchOrderedAssetIDRows(
        descriptor: CatalogQueryDescriptor,
        rootIDs: [Int64],
        db: Database,
        importBatchUnixMs: Int64? = nil
    ) throws -> [(Int64, MediaRelativePath)] {
        guard let query = orderedAssetIDQuery(
            descriptor: descriptor,
            rootIDs: rootIDs,
            importBatchUnixMs: importBatchUnixMs
        ) else {
            return []
        }
        return try Row.fetchAll(
            db,
            sql: query.sql,
            arguments: query.arguments
        ).map { row in
            (row["library_root_id"], MediaRelativePath(rawValue: row["relative_path"]))
        }
    }

    static func orderedAssetIDQuery(
        descriptor: CatalogQueryDescriptor,
        rootIDs: [Int64],
        importBatchUnixMs: Int64? = nil
    ) -> SQLQuery? {
        guard !rootIDs.isEmpty else {
            return nil
        }
        let order = orderPlan(for: descriptor.sort, rootLocal: rootIDs.count == 1)
        var arguments: [any DatabaseValueConvertible] = []
        let rootPredicate: String
        if rootIDs.count == 1, let rootID = rootIDs.first {
            rootPredicate = "library_root_id = ?"
            arguments.append(rootID)
        } else {
            let placeholders = sqlPlaceholders(count: rootIDs.count)
            rootPredicate = "library_root_id IN (\(placeholders))"
            arguments.append(contentsOf: rootIDs)
        }
        var batchSQL = ""
        if let importBatchUnixMs {
            batchSQL = "\n  AND import_batch_unix_ms = ?"
            arguments.append(importBatchUnixMs)
        }
        let filter = filterPredicate(for: descriptor.filter)
        arguments.append(contentsOf: filter.arguments)
        let filterSQL = filter.sql.map { "\n  AND \($0)" } ?? ""
        return SQLQuery(
            sql: """
            SELECT library_root_id, relative_path
            FROM media_asset INDEXED BY \(order.indexName)
            WHERE \(rootPredicate)\(batchSQL)\(filterSQL)
            ORDER BY \(order.orderBy)
            """,
            arguments: StatementArguments(arguments)
        )
    }

    static func filterOptions(rootIDs: [Int64], db: Database) throws -> CatalogFilterOptions {
        guard let query = distinctFilterableTypesQuery(rootIDs: rootIDs) else {
            return .empty
        }
        let rows = try Row.fetchAll(db, sql: query.sql, arguments: query.arguments)
        var formatsByKind: [MediaKind: Set<MediaFormatToken>] = [:]
        for row in rows {
            let kindValue: String? = row["best_kind"]
            let formatValue: String? = row["best_format"]
            guard let kindValue, let kind = MediaKind(rawValue: kindValue) else {
                continue
            }
            var formats = formatsByKind[kind, default: []]
            if let formatValue {
                formats.insert(MediaFormatToken(rawValue: formatValue))
            }
            formatsByKind[kind] = formats
        }
        return CatalogFilterOptions(
            formatsByKind: formatsByKind.mapValues { $0.sorted() }
        )
    }

    static func distinctFilterableTypesQuery(rootIDs: [Int64]) -> SQLQuery? {
        guard !rootIDs.isEmpty else {
            return nil
        }
        let placeholders = sqlPlaceholders(count: rootIDs.count)
        return SQLQuery(
            sql: """
            SELECT DISTINCT best_kind, best_format
            FROM media_asset
            WHERE library_root_id IN (\(placeholders))
              AND best_kind IS NOT NULL
            ORDER BY best_kind, best_format
            """,
            arguments: StatementArguments(rootIDs)
        )
    }

    static func countAssets(rootIDs: [Int64], db: Database) throws -> Int {
        guard !rootIDs.isEmpty else {
            return 0
        }
        let placeholders = sqlPlaceholders(count: rootIDs.count)
        return try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*)
            FROM media_asset
            WHERE library_root_id IN (\(placeholders))
            """,
            arguments: StatementArguments(rootIDs)
        ) ?? 0
    }

    static func fetchStoredAssets(
        ids: [MediaAssetID],
        rootIDsByPath: [LibraryRootPath: Int64],
        db: Database
    ) throws -> [StoredAsset] {
        guard !ids.isEmpty else {
            return []
        }
        let idsByRootPath = Dictionary(grouping: ids, by: \.libraryRootPath)
        var assets: [StoredAsset] = []
        assets.reserveCapacity(ids.count)

        for (rootPath, idsForRoot) in idsByRootPath {
            guard let rootID = rootIDsByPath[rootPath] else {
                continue
            }
            let relativePaths = idsForRoot.map(\.relativePath.rawValue)
            let placeholders = sqlPlaceholders(count: relativePaths.count)
            var argumentValues: [any DatabaseValueConvertible] = [rootID]
            argumentValues.append(contentsOf: relativePaths)
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT library_root_id, relative_path, name, content_type_identifier, byte_size,
                       created_at_unix, content_modified_at_unix,
                       enriched_source_size, enriched_source_mtime,
                       content_hash_xxh3_128, content_hash_source_size, content_hash_source_mtime,
                       thumbnail_path,
                       duration_seconds,
                       best_capture_unix, best_kind, best_format
                FROM media_asset
                WHERE library_root_id = ? AND relative_path IN (\(placeholders))
                """,
                arguments: StatementArguments(argumentValues)
            )
            assets.append(contentsOf: rows.map(storedAsset(from:)))
        }
        return assets
    }

    static func fetchStoredTileDetails(
        ids: [MediaAssetID],
        rootIDsByPath: [LibraryRootPath: Int64],
        db: Database
    ) throws -> [StoredTileDetail] {
        guard !ids.isEmpty else {
            return []
        }
        let idsByRootPath = Dictionary(grouping: ids, by: \.libraryRootPath)
        var details: [StoredTileDetail] = []
        details.reserveCapacity(ids.count)

        for (rootPath, idsForRoot) in idsByRootPath {
            guard let rootID = rootIDsByPath[rootPath] else {
                continue
            }
            let relativePaths = idsForRoot.map(\.relativePath.rawValue)
            let placeholders = sqlPlaceholders(count: relativePaths.count)
            var argumentValues: [any DatabaseValueConvertible] = [rootID]
            argumentValues.append(contentsOf: relativePaths)
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT library_root_id, relative_path,
                       enriched_source_size, enriched_source_mtime, thumbnail_path,
                       duration_seconds, best_kind
                FROM media_asset
                WHERE library_root_id = ? AND relative_path IN (\(placeholders))
                """,
                arguments: StatementArguments(argumentValues)
            )
            details.append(contentsOf: rows.map(storedTileDetail(from:)))
        }
        return details
    }
}

private nonisolated func orderPlan(
    for sort: MediaSortOrder,
    rootLocal: Bool
) -> (indexName: String, orderBy: String) {
    let direction = sort.direction.sqlKeyword
    let suffix = direction.lowercased()
    switch (sort.field, rootLocal) {
    case (.bestDate, true):
        return (
            "idx_media_asset_best_capture_root_\(suffix)",
            "best_capture_unix \(direction), relative_path"
        )
    case (.bestDate, false):
        return (
            "idx_media_asset_best_capture_global_\(suffix)",
            "best_capture_unix \(direction), library_root_id, relative_path"
        )
    case (.name, true):
        return (
            "idx_media_asset_name_root_\(suffix)",
            "name_sort_key \(direction), relative_path"
        )
    case (.name, false):
        return (
            "idx_media_asset_name_global_\(suffix)",
            "name_sort_key \(direction), library_root_id, relative_path"
        )
    case (.size, true):
        return (
            "idx_media_asset_size_root_\(suffix)",
            "(byte_size IS NULL), byte_size \(direction), relative_path"
        )
    case (.size, false):
        return (
            "idx_media_asset_size_global_\(suffix)",
            "(byte_size IS NULL), byte_size \(direction), library_root_id, relative_path"
        )
    }
}

private nonisolated func filterPredicate(
    for filter: MediaFilter
) -> (sql: String?, arguments: [any DatabaseValueConvertible]) {
    guard filter.isActive else {
        return (nil, [])
    }
    var clauses: [String] = []
    var arguments: [any DatabaseValueConvertible] = []
    let kinds = filter.kinds.sorted { $0.rawValue < $1.rawValue }
    if !kinds.isEmpty {
        clauses.append("best_kind IN (\(sqlPlaceholders(count: kinds.count)))")
        arguments.append(contentsOf: kinds.map(\.rawValue))
    }
    let formats = filter.formats.sorted()
    if !formats.isEmpty {
        clauses.append("best_format IN (\(sqlPlaceholders(count: formats.count)))")
        arguments.append(contentsOf: formats.map(\.rawValue))
    }
    return ("(\(clauses.joined(separator: " OR ")))", arguments)
}

private extension MediaSortDirection {
    nonisolated var sqlKeyword: String {
        switch self {
        case .ascending:
            "ASC"
        case .descending:
            "DESC"
        }
    }
}

private nonisolated func sqlPlaceholders(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ",")
}

/// Converts nullable SQLite timestamps at the persistence edge so the rest of
/// the Store works with `Date?` rather than storage-format doubles.
private nonisolated func storedAsset(from row: Row) -> StoredAsset {
    let createdUnix: Double? = row["created_at_unix"]
    let modifiedUnix: Double? = row["content_modified_at_unix"]
    let bestCaptureUnix: Double? = row["best_capture_unix"]
    let bestKindRaw: String? = row["best_kind"]
    let bestFormatRaw: String? = row["best_format"]
    return StoredAsset(
        libraryRootID: row["library_root_id"],
        relativePath: MediaRelativePath(rawValue: row["relative_path"]),
        name: row["name"],
        contentTypeIdentifier: row["content_type_identifier"],
        byteSize: row["byte_size"],
        createdAt: createdUnix.map(Date.init(timeIntervalSince1970:)),
        contentModifiedAt: modifiedUnix.map(Date.init(timeIntervalSince1970:)),
        thumbnailPath: row["thumbnail_path"],
        bestCaptureDate: bestCaptureUnix.map(Date.init(timeIntervalSince1970:)),
        bestKind: bestKindRaw.flatMap(MediaKind.init(rawValue:)),
        bestFormat: bestFormatRaw.map(MediaFormatToken.init(rawValue:)),
        durationSeconds: row["duration_seconds"],
        enrichedSourceSize: row["enriched_source_size"],
        enrichedSourceMTimeSeconds: row["enriched_source_mtime"],
        contentHash: (row["content_hash_xxh3_128"] as Data?).flatMap(XXH3Digest128.init(data:)),
        contentHashSourceSize: row["content_hash_source_size"],
        contentHashSourceMTimeSeconds: row["content_hash_source_mtime"]
    )
}

private nonisolated func storedTileDetail(from row: Row) -> StoredTileDetail {
    let bestKindRaw: String? = row["best_kind"]
    return StoredTileDetail(
        libraryRootID: row["library_root_id"],
        relativePath: MediaRelativePath(rawValue: row["relative_path"]),
        thumbnailPath: row["thumbnail_path"],
        bestKind: bestKindRaw.flatMap(MediaKind.init(rawValue:)),
        durationSeconds: row["duration_seconds"],
        enrichedSourceSize: row["enriched_source_size"],
        enrichedSourceMTimeSeconds: row["enriched_source_mtime"]
    )
}
