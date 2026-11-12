import CoreGraphics
import Foundation
import GRDB
import MediaMetadata

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

    /// `captureLocalTime` is carried alongside identity purely as a day-grouping
    /// key for the grid (DES-069) — a single scalar already read by the index
    /// for `ORDER BY`, not a step toward per-asset detail in window state.
    /// `nil` under any sort other than `.bestDate`: the value is date-contiguous
    /// only under that sort, so callers that don't ask for it don't pay to
    /// decode it (see `orderPlan`).
    static func fetchOrderedAssetIDRows(
        descriptor: CatalogQueryDescriptor,
        scope: CatalogScopePredicate,
        db: Database
    ) throws -> [OrderedAssetIDRow] {
        guard let query = try orderedAssetIDQuery(descriptor: descriptor, scope: scope, db: db) else {
            return []
        }
        return try Row.fetchAll(
            db,
            sql: query.sql,
            arguments: query.arguments
        ).map { row in
            let coordinate: PlaceCoordinate? = if scope.requiresLocation,
                                                  let latitude: Double = row["primary_latitude"],
                                                  let longitude: Double = row["primary_longitude"]
            {
                PlaceCoordinate(latitude: latitude, longitude: longitude)
            } else {
                nil
            }
            return OrderedAssetIDRow(
                libraryRootID: row["library_root_id"],
                relativePath: MediaRelativePath(rawValue: row["relative_path"]),
                captureLocalTime: (row["best_capture_local"] as Double?).map(CaptureLocalTime.init(seconds:)),
                coordinate: coordinate
            )
        }
    }

    /// One row of the ordered-ID query. `coordinate` is set only for a scope that
    /// requires a location, where the join guarantees one (ADR 0040).
    struct OrderedAssetIDRow {
        let libraryRootID: Int64
        let relativePath: MediaRelativePath
        let captureLocalTime: CaptureLocalTime?
        let coordinate: PlaceCoordinate?
    }

    /// `db` is the read's own transaction: a scope with a date dimension reads its year
    /// floor there (`scopeClause`), so the ranges and the rows come from one snapshot.
    static func orderedAssetIDQuery(
        descriptor: CatalogQueryDescriptor,
        scope: CatalogScopePredicate,
        db: Database
    ) throws -> SQLQuery? {
        guard let scopeClause = try scopeClause(scope, db: db) else {
            return nil
        }
        let order = orderPlan(
            for: descriptor.effectiveSort,
            person: descriptor.scope.person,
            rootLocal: scope.rootIDs.count == 1
        )
        var arguments = scopeClause.arguments
        let filter = filterPredicate(for: descriptor.filter)
        arguments.append(contentsOf: filter.arguments)
        arguments.append(contentsOf: order.arguments)
        let filterSQL = filter.sql.map { "\n  AND \($0)" } ?? ""
        let locationColumns = scope.requiresLocation
            ? ", asset_metadata.primary_latitude, asset_metadata.primary_longitude"
            : ""
        return SQLQuery(
            sql: """
            SELECT media_asset.library_root_id, media_asset.relative_path, media_asset.best_capture_local\(locationColumns)
            FROM media_asset INDEXED BY \(order.indexName)\(scopeClause.join)
            WHERE \(scopeClause.sql)\(filterSQL)
            ORDER BY \(order.orderBy)
            """,
            arguments: StatementArguments(arguments)
        )
    }

    static func filterOptions(scope: CatalogScopePredicate, db: Database) throws -> CatalogFilterOptions {
        guard let query = try distinctFilterableTypesQuery(scope: scope, db: db) else {
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
        return try CatalogFilterOptions(
            formatsByKind: formatsByKind.mapValues { $0.sorted() },
            countries: placeOptions(scope: scope, db: db)
        )
    }

    /// The countries and towns Maps named for the located items in scope, most items first,
    /// then the name in the locale's order (ADR 0051). A cell named nothing offers nothing.
    static func placeOptions(scope: CatalogScopePredicate, db: Database) throws -> [PlaceFilterCountry] {
        guard let scopeClause = try scopeClause(scope, db: db) else {
            return []
        }
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT place_cell.country, place_cell.town, COUNT(*) AS items
            FROM media_asset\(scopeClause.join)
            \(placeJoin)
            WHERE \(scopeClause.sql) AND place_cell.country IS NOT NULL
            GROUP BY place_cell.country, place_cell.town
            """,
            arguments: StatementArguments(scopeClause.arguments)
        )
        var countryItems: [String: Int] = [:]
        var townItems: [String: [String: Int]] = [:]
        for row in rows {
            let country: String = row["country"]
            let items: Int = row["items"]
            countryItems[country, default: 0] += items
            if let town = row["town"] as String? {
                townItems[country, default: [:]][town, default: 0] += items
            }
        }
        return PlaceFilterCountry.mostItemsFirst(countryItems).map { country in
            PlaceFilterCountry(name: country, towns: PlaceFilterCountry.mostItemsFirst(townItems[country] ?? [:]))
        }
    }

    static func distinctFilterableTypesQuery(scope: CatalogScopePredicate, db: Database) throws -> SQLQuery? {
        guard let scopeClause = try scopeClause(scope, db: db) else {
            return nil
        }
        return SQLQuery(
            sql: """
            SELECT DISTINCT best_kind, best_format
            FROM media_asset\(scopeClause.join)
            WHERE \(scopeClause.sql)
              AND best_kind IS NOT NULL
            ORDER BY best_kind, best_format
            """,
            arguments: StatementArguments(scopeClause.arguments)
        )
    }

    /// Rows in scope, optionally narrowed by the user filter.
    static func countAssets(
        scope: CatalogScopePredicate,
        filter: MediaFilter = .all,
        db: Database
    ) throws -> Int {
        guard let scopeClause = try scopeClause(scope, db: db) else {
            return 0
        }
        var arguments = scopeClause.arguments
        let filterPredicate = filterPredicate(for: filter)
        arguments.append(contentsOf: filterPredicate.arguments)
        let filterSQL = filterPredicate.sql.map { "\n  AND \($0)" } ?? ""
        return try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*)
            FROM media_asset\(scopeClause.join)
            WHERE \(scopeClause.sql)\(filterSQL)
            """,
            arguments: StatementArguments(arguments)
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
                       metadata_source_size, metadata_source_mtime, rendered_source_size, rendered_source_mtime,
                       content_hash_xxh3_128, content_hash_source_size, content_hash_source_mtime,
                       faces_source_size, faces_source_mtime,
                       thumbnail_path,
                       duration_seconds,
                       best_capture_local, best_kind, best_format, media_choice
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
                       m.rendered_source_size, m.rendered_source_mtime, m.thumbnail_path, m.preview_path,
                       m.duration_seconds, m.best_kind, m.media_choice,
                       m.edit_recipe_json, m.rendered_revision,
                       a.pixel_width, a.pixel_height, a.orientation
                FROM media_asset m
                LEFT JOIN asset_metadata a
                  ON a.library_root_id = m.library_root_id AND a.relative_path = m.relative_path
                WHERE m.library_root_id = ? AND m.relative_path IN (\(placeholders))
                """,
                arguments: StatementArguments(argumentValues)
            )
            try details.append(contentsOf: rows.map(storedTileDetail(from:)))
        }
        return details
    }

    /// The motion movie of each still in `stillPaths` that is a Live Photo (ADR 0041), with
    /// its cataloged size. A still that pairs nothing is absent from the result.
    static func fetchLivePhotoMotions(
        libraryRootID: Int64,
        stillPaths: [MediaRelativePath],
        db: Database
    ) throws -> [MediaRelativePath: LivePhotoMotion] {
        guard !stillPaths.isEmpty else { return [:] }
        var argumentValues: [any DatabaseValueConvertible] = [libraryRootID]
        argumentValues.append(contentsOf: stillPaths.map(\.rawValue))
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT still.relative_path AS still_path, motion.relative_path AS motion_path,
                motion.byte_size AS motion_size
            FROM media_asset AS still
            \(LivePhotoSQL.motionJoin(stills: "still", motion: "motion"))
            WHERE still.library_root_id = ?
                AND still.relative_path IN (\(sqlPlaceholders(count: stillPaths.count)))
            """,
            arguments: StatementArguments(argumentValues)
        )
        var motions: [MediaRelativePath: LivePhotoMotion] = [:]
        for row in rows {
            motions[MediaRelativePath(rawValue: row["still_path"])] = LivePhotoMotion(
                relativePath: MediaRelativePath(rawValue: row["motion_path"]),
                byteSize: row["motion_size"]
            )
        }
        return motions
    }

    static func fetchImportBatches(db: Database) throws -> [ImportBatchSummary] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT import_batch_unix_ms AS batch_ms, COUNT(*) AS asset_count
            FROM media_asset
            WHERE import_batch_unix_ms IS NOT NULL
              AND pending_trash_batch_unix_ms IS NULL
              AND NOT \(LivePhotoSQL.isPairedMotion("media_asset"))
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
            WHERE best_capture_local IS NULL
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

/// The Live Photo pair rule (ADR 0041), the one place it is written. A still and a movie
/// are one Live Photo when they share a root, a folder and Apple's content identifier, and
/// are the only still and the only movie there that do. Any other count pairs nothing.
///
/// Whether a row's file is one the user sees at all: not waiting for the Trash, seen by its
/// source's current attachment (ADR 0013), not hidden by its source (ADR 0046). The scope
/// clause and the stack candidates (ADR 0052) share it, so a file on its way to the Trash
/// neither shows nor holds another file in a stack.
nonisolated enum CatalogVisibilitySQL {
    static func isPresent(_ row: String) -> String {
        """
        \(row).pending_trash_batch_unix_ms IS NULL
          AND \(row).awaiting_presence = 0
          AND \(row).hidden_by_source = 0
        """
    }
}

/// The stills that can be in a stack (ADR 0052): every present RAW and processed image in
/// a folder that holds a present RAW, in the given roots, whatever the scope or filter, so
/// a filter that hides one file of a pair never unpairs the other. `PhotoStackRule`
/// decides the stacks from these.
nonisolated enum PhotoStackSQL {
    static func fetchCandidates(
        rootIDs: [Int64],
        db: Database
    ) throws -> [Int64: [PhotoStackCandidate]] {
        guard let query = candidateQuery(rootIDs: rootIDs) else {
            return [:]
        }
        let rows = try Row.fetchAll(db, sql: query.sql, arguments: query.arguments)
        var byRoot: [Int64: [PhotoStackCandidate]] = [:]
        for row in rows {
            let kindValue: String = row["best_kind"]
            guard let kind = MediaKind(rawValue: kindValue) else {
                continue
            }
            byRoot[row["library_root_id"], default: []].append(PhotoStackCandidate(
                relativePath: MediaRelativePath(rawValue: row["relative_path"]),
                kind: kind,
                keyChosenAtUnixMs: row["stack_key_chosen_at_unix_ms"]
            ))
        }
        return byRoot
    }

    /// The candidates' read: the folders holding a present RAW, then each folder's present
    /// stills, both through `idx_media_asset_stack_candidate` (root, kind, folder).
    static func candidateQuery(rootIDs: [Int64]) -> SQLQuery? {
        guard !rootIDs.isEmpty else {
            return nil
        }
        let placeholders = sqlPlaceholders(count: rootIDs.count)
        return SQLQuery(
            sql: """
            WITH raw_folder AS (
                SELECT DISTINCT library_root_id, parent_path FROM media_asset
                WHERE library_root_id IN (\(placeholders)) AND best_kind = 'raw'
                  AND \(CatalogVisibilitySQL.isPresent("media_asset"))
            )
            SELECT still.library_root_id, still.relative_path, still.best_kind, still.stack_key_chosen_at_unix_ms
            FROM raw_folder
            JOIN media_asset AS still
              ON still.library_root_id = raw_folder.library_root_id
              AND still.parent_path = raw_folder.parent_path
            WHERE still.best_kind IN ('raw', 'image')
              AND \(CatalogVisibilitySQL.isPresent("still"))
            """,
            arguments: StatementArguments(rootIDs)
        )
    }
}

/// The rule is evaluated where it is used, never stored: it reads only facts each row
/// already holds, so a rename, move, deletion, enrichment or refresh can never leave it
/// stale. `idx_media_asset_content_identifier` makes each test one indexed lookup, and only
/// a movie with an identifier reaches it.
nonisolated enum LivePhotoSQL {
    /// True for a movie that a Live Photo's still stands for. `row` names the table or
    /// alias the predicate tests; an unaliased scoped query passes `media_asset`.
    static func isPairedMotion(_ row: String) -> String {
        """
        (\(row).best_kind = 'video' AND \(row).content_identifier IS NOT NULL
            AND (SELECT COUNT(*) \(group(of: row)) AND member.best_kind = 'video') = 1
            AND (SELECT COUNT(*) \(group(of: row)) AND member.best_kind != 'video') = 1)
        """
    }

    /// Joins each still in `stills` to its Live Photo's movie: `motion` is a paired movie of
    /// the still's group, and the rule's single-still count makes that still `stills`.
    static func motionJoin(stills: String, motion: String) -> String {
        """
        JOIN media_asset AS \(motion)
            ON \(motion).library_root_id = \(stills).library_root_id
            AND \(motion).content_identifier = \(stills).content_identifier
            AND \(motion).parent_path = \(stills).parent_path
            AND \(stills).best_kind != 'video'
            AND \(isPairedMotion(motion))
        """
    }

    /// The relative path of the still whose Live Photo `row` is the movie of, or NULL.
    static func stillPath(ofMotion row: String) -> String {
        """
        (SELECT still.relative_path FROM media_asset AS still
            WHERE \(isPairedMotion(row))
            AND still.library_root_id = \(row).library_root_id
            AND still.content_identifier = \(row).content_identifier
            AND still.parent_path = \(row).parent_path
            AND still.best_kind != 'video')
        """
    }

    private static func group(of row: String) -> String {
        """
        FROM media_asset AS member
            WHERE member.library_root_id = \(row).library_root_id
            AND member.content_identifier = \(row).content_identifier
            AND member.parent_path = \(row).parent_path
        """
    }
}

/// The index the read goes through and its `ORDER BY`, with the order's own arguments. The
/// likeness order reads the person's face of each photo (`person`, which
/// `CatalogQueryDescriptor.effectiveSort` guarantees under it); a face alone in its person
/// has no likeness and goes last; ties go newest first.
private nonisolated func orderPlan(
    for sort: MediaSortOrder,
    person: PersonID?,
    rootLocal: Bool
) -> (indexName: String, orderBy: String, arguments: [any DatabaseValueConvertible]) {
    let direction = sort.direction.sqlKeyword
    let suffix = direction.lowercased()
    if sort.field == .likeness, let person {
        let likeness = """
        (SELECT face.likeness FROM face WHERE face.library_root_id = media_asset.library_root_id
            AND face.relative_path = media_asset.relative_path AND face.person_id = ?)
        """
        return (
            "idx_media_asset_best_capture_\(rootLocal ? "root" : "global")_desc",
            """
            (\(likeness) IS NULL), \(likeness) \(direction), media_asset.best_capture_local DESC, \
            media_asset.library_root_id, media_asset.relative_path
            """,
            [person.rawValue, person.rawValue]
        )
    }
    let plan: (indexName: String, orderBy: String) = switch (sort.field, rootLocal) {
    case (.bestDate, true), (.likeness, true):
        (
            "idx_media_asset_best_capture_root_\(suffix)",
            "media_asset.best_capture_local \(direction), media_asset.relative_path"
        )
    case (.bestDate, false), (.likeness, false):
        (
            "idx_media_asset_best_capture_global_\(suffix)",
            "media_asset.best_capture_local \(direction), media_asset.library_root_id, media_asset.relative_path"
        )
    case (.name, true):
        (
            "idx_media_asset_name_root_\(suffix)",
            "media_asset.name_sort_key \(direction), media_asset.relative_path"
        )
    case (.name, false):
        (
            "idx_media_asset_name_global_\(suffix)",
            "media_asset.name_sort_key \(direction), media_asset.library_root_id, media_asset.relative_path"
        )
    case (.size, true):
        (
            "idx_media_asset_size_root_\(suffix)",
            "(media_asset.byte_size IS NULL), media_asset.byte_size \(direction), media_asset.relative_path"
        )
    case (.size, false):
        (
            "idx_media_asset_size_global_\(suffix)",
            """
            (media_asset.byte_size IS NULL), media_asset.byte_size \(direction), \
            media_asset.library_root_id, media_asset.relative_path
            """
        )
    }
    return (plan.indexName, plan.orderBy, [])
}

/// Builds the `FROM` join and `WHERE` fragment for a resolved scope, or `nil` when the
/// scope selects nothing and the caller should skip SQLite entirely.
///
/// Every scoped read goes through here, which is what keeps root membership, batch
/// membership and location membership from drifting apart between queries. A
/// single-root scope uses `=` so the root-local ordering indexes stay usable. A scope
/// that requires a location joins `asset_metadata`, where the primary location lives,
/// so the same read can also carry each row's coordinate; columns are qualified with
/// their table so the join introduces no ambiguity. A scope with a date dimension decides
/// its anniversary match in `db`, the caller's read (`anniversaryMatch`), so the match and
/// the rows it selects come from one snapshot (ADR 0049).
private nonisolated func scopeClause(
    _ scope: CatalogScopePredicate,
    db: Database
) throws -> ScopeClause? {
    guard !scope.selectsNothing else {
        return nil
    }
    switch scope.date {
    case .any:
        return try scopeClause(scope, anniversary: nil)
    case let .anniversary(day):
        guard let match = try anniversaryMatch(for: day, scope: scope, db: db) else {
            return nil
        }
        return try scopeClause(scope, anniversary: match)
    }
}

private typealias ScopeClause = (join: String, sql: String, arguments: [any DatabaseValueConvertible])

/// On This Day's match (ADR 0049): the day in earlier years while any row of the scope
/// falls on one, else the day in earlier months. The question is asked of the scope alone
/// — its roots and visibility rules — never of the filter, so the filter only narrows what
/// the scope holds and never turns years into months. Nil only for a day no calendar
/// starts, which `CalendarDay.today()` never is.
private nonisolated func anniversaryMatch(
    for day: CalendarDay,
    scope: CatalogScopePredicate,
    db: Database
) throws -> AnniversaryMatch? {
    if let years = AnniversaryMatch.years(for: day), let clause = try scopeClause(scope, anniversary: years) {
        let holdsAYear = try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS (SELECT 1 FROM media_asset\(clause.join) WHERE \(clause.sql))",
            arguments: StatementArguments(clause.arguments)
        ) ?? false
        if holdsAYear {
            logAnniversaryMatch(day: day, unit: .years)
            return years
        }
    }
    let months = AnniversaryMatch.months(for: day)
    if let months {
        logAnniversaryMatch(day: day, unit: months.unit)
    }
    return months
}

private nonisolated func logAnniversaryMatch(day: CalendarDay, unit: AnniversaryMatch.Unit) {
    OtosLog.catalog.noticeOperation("onThisDay.match", phase: "resolved", fields: [
        "day": day.diagnosticDescription,
        "unit": unit.rawValue,
    ])
}

/// The scope's `FROM` join and `WHERE` fragment with its date dimension already decided
/// (`anniversary` nil: any date), or nil when the scope selects nothing.
private nonisolated func scopeClause(
    _ scope: CatalogScopePredicate,
    anniversary: AnniversaryMatch?
) throws -> ScopeClause? {
    var arguments: [any DatabaseValueConvertible] = []
    let rootPredicate: String
    if scope.rootIDs.count == 1, let rootID = scope.rootIDs.first {
        rootPredicate = "media_asset.library_root_id = ?"
        arguments.append(rootID)
    } else {
        rootPredicate = "media_asset.library_root_id IN (\(sqlPlaceholders(count: scope.rootIDs.count)))"
        arguments.append(contentsOf: scope.rootIDs)
    }
    // Items waiting to move to the Trash, the movie of a Live Photo — a member of its
    // still's item (ADR 0041) — a card's or camera's retained rows its current
    // attachment has not yet seen (ADR 0013), and items their source hides (an Immich
    // asset in Immich's trash, ADR 0046) are hidden from every user-facing media query;
    // this scope clause is the one choke point those queries share.
    var predicate = """
    \(rootPredicate)
      AND \(CatalogVisibilitySQL.isPresent("media_asset"))
      AND NOT \(LivePhotoSQL.isPairedMotion("media_asset"))
    """
    if let importBatchUnixMs = scope.importBatchUnixMs {
        arguments.append(importBatchUnixMs)
        predicate += "\n  AND media_asset.import_batch_unix_ms = ?"
    }
    // A duplicate's digest must be current for its file; the group subquery repeats the
    // visibility rules so a copy waiting for the Trash makes no one else a duplicate.
    let currentDigest = """
      AND media_asset.content_hash_xxh3_128 IS NOT NULL
      AND length(media_asset.content_hash_xxh3_128) = 16
      AND media_asset.content_hash_source_size = COALESCE(media_asset.byte_size, -1)
      AND media_asset.content_hash_source_mtime = CAST(COALESCE(media_asset.content_modified_at_unix, -1) AS INTEGER)
    """
    switch scope.content {
    case .any:
        break
    case .duplicated:
        predicate += currentDigest
        predicate += """

          AND media_asset.content_hash_xxh3_128 IN (
              SELECT twin.content_hash_xxh3_128 FROM media_asset AS twin
              WHERE twin.library_root_id IN (\(sqlPlaceholders(count: scope.rootIDs.count)))
                AND twin.pending_trash_batch_unix_ms IS NULL
                AND twin.trash_path IS NULL
                AND twin.hidden_by_source = 0
                AND NOT \(LivePhotoSQL.isPairedMotion("twin"))
                AND twin.content_hash_source_size = COALESCE(twin.byte_size, -1)
                AND twin.content_hash_source_mtime = CAST(COALESCE(twin.content_modified_at_unix, -1) AS INTEGER)
              GROUP BY twin.content_hash_xxh3_128
              HAVING COUNT(*) > 1
          )
        """
        arguments.append(contentsOf: scope.rootIDs)
    case let .identical(digest):
        predicate += currentDigest
        predicate += "\n  AND media_asset.content_hash_xxh3_128 = ?"
        arguments.append(digest.data)
    case let .members(keys):
        guard !keys.isEmpty else {
            return nil
        }
        // One JSON argument, not two per member: a stack opened zoomed out holds tens of
        // thousands of items, past SQLite's bound-parameter limit.
        predicate += """

          AND (media_asset.library_root_id, media_asset.relative_path) IN (
              SELECT json_extract(member.value, '$[0]'), json_extract(member.value, '$[1]')
              FROM json_each(?) AS member
          )
        """
        try arguments.append(CatalogScopePredicate.MemberKey.json(keys))
    case .withPerson:
        predicate += """

          AND EXISTS (
              SELECT 1 FROM face
              WHERE face.library_root_id = media_asset.library_root_id
                AND face.relative_path = media_asset.relative_path
                AND face.is_not_face = 0
                AND face.person_id IS NOT NULL
          )
        """
    case let .person(person):
        predicate += """

          AND EXISTS (
              SELECT 1 FROM face
              WHERE face.library_root_id = media_asset.library_root_id
                AND face.relative_path = media_asset.relative_path
                AND face.is_not_face = 0
                AND face.person_id = ?
          )
        """
        arguments.append(person)
    }
    if let anniversary {
        predicate += "\n  AND \(anniversary.sql(column: "media_asset.best_capture_local"))"
        arguments.append(anniversary.end)
        arguments.append(anniversary.date)
    }
    var join = ""
    switch scope.location {
    case .any:
        break
    case .located:
        join = locationJoin
        predicate += "\n  AND asset_metadata.primary_latitude IS NOT NULL"
        predicate += "\n  AND asset_metadata.primary_longitude IS NOT NULL"
    case let .within(area):
        join = locationJoin
        arguments.append(area.south)
        arguments.append(area.north)
        arguments.append(area.west)
        arguments.append(area.east)
        // A box across the antimeridian holds longitudes east of `west` or west of `east`.
        let longitude = area.crossesAntimeridian ? "OR" : "AND"
        predicate += "\n  AND asset_metadata.primary_latitude BETWEEN ? AND ?"
        predicate += "\n  AND (asset_metadata.primary_longitude >= ? \(longitude) asset_metadata.primary_longitude <= ?)"
    }
    return (join, predicate, arguments)
}

/// Each row's place cell, through its primary location (ADR 0040). A row with no location,
/// or in a cell not named yet, joins nothing.
private nonisolated let placeJoin = """

JOIN asset_metadata AS place_metadata
  ON place_metadata.library_root_id = media_asset.library_root_id
  AND place_metadata.relative_path = media_asset.relative_path
JOIN place_cell
  ON place_cell.cell_latitude = \(PlaceCell.sql("place_metadata.primary_latitude"))
  AND place_cell.cell_longitude = \(PlaceCell.sql("place_metadata.primary_longitude"))
"""

private nonisolated let locationJoin = """

JOIN asset_metadata
  ON asset_metadata.library_root_id = media_asset.library_root_id
  AND asset_metadata.relative_path = media_asset.relative_path
"""

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
    let fileTypes = filter.fileTypes.sorted { ($0.kind.rawValue, $0.format.rawValue) < ($1.kind.rawValue, $1.format.rawValue) }
    for fileType in fileTypes {
        mediaClauses.append("(best_kind = ? AND best_format = ?)")
        arguments.append(fileType.kind.rawValue)
        arguments.append(fileType.format.rawValue)
    }
    if !mediaClauses.isEmpty {
        clauses.append("(\(mediaClauses.joined(separator: " OR ")))")
    }
    let choices = filter.choices.sorted { $0.rawValue < $1.rawValue }
    if !choices.isEmpty {
        clauses.append("media_choice IN (\(sqlPlaceholders(count: choices.count)))")
        arguments.append(contentsOf: choices.map(\.rawValue))
    }
    // The People filter (ADR 0047): a photo holding a face of each person checked, and with
    // `Unidentified Faces` a face with no person too.
    var peopleClauses: [String] = []
    let face = """
    EXISTS (SELECT 1 FROM face WHERE face.library_root_id = media_asset.library_root_id
        AND face.relative_path = media_asset.relative_path AND face.is_not_face = 0 AND
    """
    for person in filter.people.sorted() {
        peopleClauses.append("\(face) face.person_id = ?)")
        arguments.append(person.rawValue)
    }
    if filter.unassignedFaces {
        peopleClauses.append("\(face) face.person_id IS NULL)")
    }
    clauses += peopleClauses
    // The Places filter (ADR 0040): a photo whose cell Maps named as one of the countries or
    // towns checked.
    if !filter.places.isEmpty {
        var placeClauses: [String] = []
        for place in filter.places.sorted() {
            if let town = place.town {
                placeClauses.append("(place_cell.country = ? AND place_cell.town = ?)")
                arguments.append(place.country)
                arguments.append(town)
            } else {
                placeClauses.append("place_cell.country = ?")
                arguments.append(place.country)
            }
        }
        clauses.append("""
        EXISTS (SELECT 1 FROM asset_metadata AS place_metadata
            JOIN place_cell
              ON place_cell.cell_latitude = \(PlaceCell.sql("place_metadata.primary_latitude"))
              AND place_cell.cell_longitude = \(PlaceCell.sql("place_metadata.primary_longitude"))
            WHERE place_metadata.library_root_id = media_asset.library_root_id
              AND place_metadata.relative_path = media_asset.relative_path
              AND (\(placeClauses.joined(separator: " OR "))))
        """)
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
    let bestCaptureLocal: Double? = row["best_capture_local"]
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
        captureLocalTime: bestCaptureLocal.map(CaptureLocalTime.init(seconds:)),
        bestKind: bestKindRaw.flatMap(MediaKind.init(rawValue:)),
        bestFormat: bestFormatRaw.map(MediaFormatToken.init(rawValue:)),
        durationSeconds: row["duration_seconds"],
        metadataSourceSize: row["metadata_source_size"],
        metadataSourceMTimeSeconds: row["metadata_source_mtime"],
        renderedSourceSize: row["rendered_source_size"],
        renderedSourceMTimeSeconds: row["rendered_source_mtime"],
        contentHash: (row["content_hash_xxh3_128"] as Data?).flatMap(XXH3Digest128.init(data:)),
        contentHashSourceSize: row["content_hash_source_size"],
        contentHashSourceMTimeSeconds: row["content_hash_source_mtime"],
        facesSourceSize: row["faces_source_size"],
        facesSourceMTimeSeconds: row["faces_source_mtime"],
        mediaChoice: MediaChoice(rawValue: row["media_choice"] ?? "") ?? .default
    )
}

/// Throws when the row's edit recipe cannot be decoded: an unreadable recipe is a
/// failed read, never an unedited photo (ADR 0036).
private nonisolated func storedTileDetail(from row: Row) throws -> StoredTileDetail {
    let bestKindRaw: String? = row["best_kind"]
    let pixelWidth: Int? = row["pixel_width"]
    let pixelHeight: Int? = row["pixel_height"]
    let orientation: Int? = row["orientation"]
    // The upright size is the library's answer for the stored size and orientation
    // (ADR 0039): `PixelGeometry` turns a quarter-turned orientation's dimensions itself.
    let geometry = PixelGeometry(
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        orientation: orientation.flatMap(MediaMetadata.Orientation.init(rawValue:))
    )
    let nativePixelSize: CGSize? = if let width = geometry.displayPixelWidth,
                                      let height = geometry.displayPixelHeight,
                                      width > 0, height > 0
    {
        CGSize(width: width, height: height)
    } else {
        nil
    }
    return try StoredTileDetail(
        libraryRootID: row["library_root_id"],
        relativePath: MediaRelativePath(rawValue: row["relative_path"]),
        byteSize: row["byte_size"],
        thumbnailPath: row["thumbnail_path"],
        previewPath: row["preview_path"],
        nativePixelSize: nativePixelSize,
        editRecipe: CatalogStore.editRecipe(json: row["edit_recipe_json"]),
        renderedRevision: row["rendered_revision"] ?? 0,
        bestKind: bestKindRaw.flatMap(MediaKind.init(rawValue:)),
        durationSeconds: row["duration_seconds"],
        renderedSourceSize: row["rendered_source_size"],
        renderedSourceMTimeSeconds: row["rendered_source_mtime"],
        mediaChoice: MediaChoice(rawValue: row["media_choice"] ?? "") ?? .default
    )
}
