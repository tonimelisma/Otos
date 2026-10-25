import CoreGraphics
import Foundation
import GRDB

/// Catalog query gateway guide
///
/// Pure SQL/mapping helpers for the catalog read surface. `CatalogStore` owns
/// orchestration (`timedRead`, slow-query diagnostics) and asks `RootRegistry` to
/// resolve a `SidebarSelection` into one `CatalogScopePredicate`; this type groups
/// ordered-ID / count / filter / detail / metadata / enrichment-candidate SQL and
/// `Row`→model mapping synchronously inside Store isolation — not a second actor.
/// Every scoped read takes the resolved scope rather than bare root IDs, so no
/// query can honor one scope dimension and forget another. Depends on free
/// `StoredAsset` / `StoredTileDetail` / `SQLQuery` / `CatalogScopePredicate` types,
/// not on `CatalogStore` itself.
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
        return try json.map(CatalogStore.decodeMetadataExtraJSON)
    }

    /// `bestCaptureUnix` is carried alongside identity purely as a day-grouping
    /// key for the grid (DES-069) — a single scalar already read by the index
    /// for `ORDER BY`, not a step toward per-asset detail in window state.
    /// `nil` under any sort other than `.bestDate`: the value is date-contiguous
    /// only under that sort, so callers that don't ask for it don't pay to
    /// decode it (see `orderPlan`).
    static func fetchOrderedAssetIDRows(
        descriptor: CatalogQueryDescriptor,
        scope: CatalogScopePredicate,
        db: Database
    ) throws -> [(libraryRootID: Int64, relativePath: MediaRelativePath, bestCaptureUnix: Double?)] {
        guard let query = orderedAssetIDQuery(descriptor: descriptor, scope: scope) else {
            return []
        }
        return try Row.fetchAll(
            db,
            sql: query.sql,
            arguments: query.arguments
        ).map { row in
            (row["library_root_id"], MediaRelativePath(rawValue: row["relative_path"]), row["best_capture_unix"])
        }
    }

    static func orderedAssetIDQuery(
        descriptor: CatalogQueryDescriptor,
        scope: CatalogScopePredicate
    ) -> SQLQuery? {
        guard let scopeClause = scopeClause(scope) else {
            return nil
        }
        let order = orderPlan(for: descriptor.sort, rootLocal: scope.rootIDs.count == 1)
        var arguments = scopeClause.arguments
        let filter = filterPredicate(for: descriptor.filter)
        arguments.append(contentsOf: filter.arguments)
        let filterSQL = filter.sql.map { "\n  AND \($0)" } ?? ""
        return SQLQuery(
            sql: """
            SELECT library_root_id, relative_path, best_capture_unix
            FROM media_asset INDEXED BY \(order.indexName)
            WHERE \(scopeClause.sql)\(filterSQL)
            ORDER BY \(order.orderBy)
            """,
            arguments: StatementArguments(arguments)
        )
    }

    static func filterOptions(scope: CatalogScopePredicate, db: Database) throws -> CatalogFilterOptions {
        guard let query = distinctFilterableTypesQuery(scope: scope) else {
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

    static func distinctFilterableTypesQuery(scope: CatalogScopePredicate) -> SQLQuery? {
        guard let scopeClause = scopeClause(scope) else {
            return nil
        }
        return SQLQuery(
            sql: """
            SELECT DISTINCT best_kind, best_format
            FROM media_asset
            WHERE \(scopeClause.sql)
              AND best_kind IS NOT NULL
            ORDER BY best_kind, best_format
            """,
            arguments: StatementArguments(scopeClause.arguments)
        )
    }

    static func countAssets(scope: CatalogScopePredicate, db: Database) throws -> Int {
        guard let scopeClause = scopeClause(scope) else {
            return 0
        }
        return try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*)
            FROM media_asset
            WHERE \(scopeClause.sql)
            """,
            arguments: StatementArguments(scopeClause.arguments)
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
                       best_capture_unix, best_kind, best_format, media_choice
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
                SELECT m.library_root_id, m.relative_path, m.byte_size,
                       m.enriched_source_size, m.enriched_source_mtime, m.thumbnail_path, m.preview_path,
                       m.duration_seconds, m.best_kind, m.media_choice,
                       a.pixel_width, a.pixel_height, a.orientation
                FROM media_asset m
                LEFT JOIN asset_metadata a
                  ON a.library_root_id = m.library_root_id AND a.relative_path = m.relative_path
                WHERE m.library_root_id = ? AND m.relative_path IN (\(placeholders))
                """,
                arguments: StatementArguments(argumentValues)
            )
            details.append(contentsOf: rows.map(storedTileDetail(from:)))
        }
        return details
    }

    static func fetchImportBatches(db: Database) throws -> [ImportBatchSummary] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT import_batch_unix_ms AS batch_ms, COUNT(*) AS asset_count
            FROM media_asset
            WHERE import_batch_unix_ms IS NOT NULL
              AND pending_trash_batch_unix_ms IS NULL
            GROUP BY import_batch_unix_ms
            ORDER BY import_batch_unix_ms DESC
            """
        ).map { row in
            let batchMs: Int64 = row["batch_ms"]
            let count: Int = row["asset_count"]
            return ImportBatchSummary(
                batchID: ImportBatchID(unixMilliseconds: batchMs),
                assetCount: count
            )
        }
    }

    static func fetchAssetIDs(
        inImportBatch batchID: ImportBatchID,
        pathsByRowID: [Int64: LibraryRootPath],
        db: Database
    ) throws -> [MediaAssetID] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT library_root_id, relative_path
            FROM media_asset
            WHERE import_batch_unix_ms = ?
            ORDER BY library_root_id, relative_path
            """,
            arguments: [batchID.unixMilliseconds]
        ).compactMap { row in
            let rootRowID: Int64 = row["library_root_id"]
            let relativePath: String = row["relative_path"]
            guard let rootPath = pathsByRowID[rootRowID] else {
                return nil
            }
            return MediaAssetID(
                libraryRootPath: rootPath,
                relativePath: MediaRelativePath(rawValue: relativePath)
            )
        }
    }

    static func fetchAssetIDsMissingBestDate(
        pathsByRowID: [Int64: LibraryRootPath],
        db: Database
    ) throws -> [MediaAssetID] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT library_root_id, relative_path
            FROM media_asset
            WHERE best_capture_unix IS NULL
            ORDER BY library_root_id, relative_path
            """
        ).compactMap { row in
            let rootRowID: Int64 = row["library_root_id"]
            let relativePath: String = row["relative_path"]
            guard let rootPath = pathsByRowID[rootRowID] else {
                return nil
            }
            return MediaAssetID(
                libraryRootPath: rootPath,
                relativePath: MediaRelativePath(rawValue: relativePath)
            )
        }
    }

    static func fetchCaptureWall(
        id: MediaAssetID,
        rootRowID: Int64,
        db: Database
    ) throws -> CaptureWallClock.Selection? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT capture_wall_compact, capture_wall_precision
            FROM media_asset
            WHERE library_root_id = ? AND relative_path = ?
            """,
            arguments: [rootRowID, id.relativePath.rawValue]
        ) else {
            return nil
        }
        let compact: Int64? = row["capture_wall_compact"]
        let precision: String? = row["capture_wall_precision"]
        guard let compact, let precision else {
            return nil
        }
        return CaptureWallClock.Selection(compact: compact, precision: precision)
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

/// Builds the `WHERE` fragment for a resolved scope, or `nil` when the scope
/// selects nothing and the caller should skip SQLite entirely.
///
/// Every scoped read goes through here, which is what keeps root membership and
/// batch membership from drifting apart between queries. A single-root scope uses
/// `=` so the root-local ordering indexes stay usable.
private nonisolated func scopeClause(
    _ scope: CatalogScopePredicate
) -> (sql: String, arguments: [any DatabaseValueConvertible])? {
    guard !scope.selectsNothing else {
        return nil
    }
    var arguments: [any DatabaseValueConvertible] = []
    let rootPredicate: String
    if scope.rootIDs.count == 1, let rootID = scope.rootIDs.first {
        rootPredicate = "library_root_id = ?"
        arguments.append(rootID)
    } else {
        rootPredicate = "library_root_id IN (\(sqlPlaceholders(count: scope.rootIDs.count)))"
        arguments.append(contentsOf: scope.rootIDs)
    }
    // Items waiting to move to the Trash are hidden from every user-facing media
    // query; this scope clause is the one choke point those queries share.
    let visiblePredicate = "\(rootPredicate)\n  AND pending_trash_batch_unix_ms IS NULL"
    guard let importBatchUnixMs = scope.importBatchUnixMs else {
        return (visiblePredicate, arguments)
    }
    arguments.append(importBatchUnixMs)
    return ("\(visiblePredicate)\n  AND import_batch_unix_ms = ?", arguments)
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
    var mediaClauses: [String] = []
    if !kinds.isEmpty {
        mediaClauses.append("best_kind IN (\(sqlPlaceholders(count: kinds.count)))")
        arguments.append(contentsOf: kinds.map(\.rawValue))
    }
    let formats = filter.formats.sorted()
    if !formats.isEmpty {
        mediaClauses.append("best_format IN (\(sqlPlaceholders(count: formats.count)))")
        arguments.append(contentsOf: formats.map(\.rawValue))
    }
    if !mediaClauses.isEmpty {
        clauses.append("(\(mediaClauses.joined(separator: " OR ")))")
    }
    let choices = filter.choices.sorted { $0.rawValue < $1.rawValue }
    if !choices.isEmpty {
        clauses.append("media_choice IN (\(sqlPlaceholders(count: choices.count)))")
        arguments.append(contentsOf: choices.map(\.rawValue))
    }
    return (clauses.isEmpty ? nil : clauses.joined(separator: " AND "), arguments)
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
        contentHashSourceMTimeSeconds: row["content_hash_source_mtime"],
        mediaChoice: MediaChoice(rawValue: row["media_choice"] ?? "") ?? .default
    )
}

private nonisolated func storedTileDetail(from row: Row) -> StoredTileDetail {
    let bestKindRaw: String? = row["best_kind"]
    let pixelWidth: Int? = row["pixel_width"]
    let pixelHeight: Int? = row["pixel_height"]
    let orientation: Int? = row["orientation"]
    // EXIF orientations 5–8 rotate the stored dimensions a quarter turn.
    let nativePixelSize: CGSize? = if let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 {
        (orientation ?? 1) >= 5
            ? CGSize(width: pixelHeight, height: pixelWidth)
            : CGSize(width: pixelWidth, height: pixelHeight)
    } else {
        nil
    }
    return StoredTileDetail(
        libraryRootID: row["library_root_id"],
        relativePath: MediaRelativePath(rawValue: row["relative_path"]),
        byteSize: row["byte_size"],
        thumbnailPath: row["thumbnail_path"],
        previewPath: row["preview_path"],
        nativePixelSize: nativePixelSize,
        bestKind: bestKindRaw.flatMap(MediaKind.init(rawValue:)),
        durationSeconds: row["duration_seconds"],
        enrichedSourceSize: row["enriched_source_size"],
        enrichedSourceMTimeSeconds: row["enriched_source_mtime"],
        mediaChoice: MediaChoice(rawValue: row["media_choice"] ?? "") ?? .default
    )
}
