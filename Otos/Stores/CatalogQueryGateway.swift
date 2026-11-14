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
        stacks: AnniversaryStacks = .readWhenNeeded,
        db: Database
    ) throws -> [OrderedAssetIDRow] {
        guard let query = try orderedAssetIDQuery(descriptor: descriptor, scope: scope, stacks: stacks, db: db) else {
            return []
        }
        // Read by position, in `orderedAssetIDQuery`'s column order: a name lookup per column
        // per row is the read's own cost on a large order. Each row is mapped as the cursor
        // reaches it, so no copy of every row is made first.
        let likedColumn = scope.requiresLocation ? 5 : 3
        return try Array(Row.fetchCursor(
            db,
            sql: query.sql,
            arguments: query.arguments
        ).map { row in
            let coordinate: PlaceCoordinate? = if scope.requiresLocation,
                                                  let latitude: Double = row[3],
                                                  let longitude: Double = row[4]
            {
                PlaceCoordinate(latitude: latitude, longitude: longitude)
            } else {
                nil
            }
            return OrderedAssetIDRow(
                libraryRootID: row[0],
                relativePath: MediaRelativePath(rawValue: row[1]),
                captureLocalTime: (row[2] as Double?).map(CaptureLocalTime.init(seconds:)),
                coordinate: coordinate,
                isLiked: scope.isAnniversary ? row[likedColumn] : false
            )
        })
    }

    /// One row of the ordered-ID query. `coordinate` is set only for a scope that
    /// requires a location, where the join guarantees one (ADR 0040).
    struct OrderedAssetIDRow {
        let libraryRootID: Int64
        let relativePath: MediaRelativePath
        let captureLocalTime: CaptureLocalTime?
        let coordinate: PlaceCoordinate?
        /// Read only for On This Day, which puts a day's Liked photos first.
        var isLiked = false
    }

    /// `db` is the read's own transaction: a scope with a date dimension decides its
    /// anniversary match there (`scopeClause`), judging stacks by `stacks`, so the match and
    /// the rows come from one snapshot.
    static func orderedAssetIDQuery(
        descriptor: CatalogQueryDescriptor,
        scope: CatalogScopePredicate,
        stacks: AnniversaryStacks = .readWhenNeeded,
        db: Database
    ) throws -> SQLQuery? {
        guard let scopeClause = try scopeClause(scope, stacks: stacks, db: db) else {
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
        // Read by position in `fetchOrderedAssetIDRows`: keep this column order.
        let likedColumn = scope.isAnniversary ? ", media_asset.media_choice = 'liked' AS is_liked" : ""
        return SQLQuery(
            sql: """
            SELECT media_asset.library_root_id, media_asset.relative_path, media_asset.best_capture_local\(locationColumns)\(likedColumn)
            FROM media_asset INDEXED BY \(order.indexName)\(scopeClause.join)
            WHERE \(scopeClause.sql)\(filterSQL)
            ORDER BY \(order.orderBy)
            """,
            arguments: StatementArguments(arguments)
        )
    }

    /// The rows of `scope` that `match` selects and On This Day's exclusion leaves in, by key:
    /// what the years-or-months match walks (`anniversaryMatch`). Nil when the scope selects
    /// nothing.
    static func anniversaryRowsQuery(scope: CatalogScopePredicate, match: AnniversaryMatch) throws -> SQLQuery? {
        guard !scope.selectsNothing, let clause = try scopeClause(scope, anniversary: match) else {
            return nil
        }
        return SQLQuery(
            sql: """
            SELECT media_asset.library_root_id, media_asset.relative_path
            FROM media_asset\(clause.join)
            WHERE \(clause.sql)
            """,
            arguments: StatementArguments(clause.arguments)
        )
    }

    /// The options for the row whose scope is `scope`, the places among them named in
    /// `placeNameLanguage` (none without one).
    static func filterOptions(
        scope: CatalogScopePredicate,
        placeNameLanguage: PlaceNameLanguage?,
        db: Database
    ) throws -> CatalogFilterOptions {
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
        guard let placeNameLanguage else {
            return CatalogFilterOptions(formatsByKind: formatsByKind.mapValues { $0.sorted() })
        }
        return try CatalogFilterOptions(
            formatsByKind: formatsByKind.mapValues { $0.sorted() },
            countries: placeOptions(scope: scope, language: placeNameLanguage, db: db),
            placeNameLanguage: placeNameLanguage
        )
    }

    /// The countries and towns Maps named in `language` for the located items in scope, most
    /// items first, then the name in the locale's order (ADR 0051). A cell named nothing
    /// offers nothing.
    static func placeOptions(
        scope: CatalogScopePredicate,
        language: PlaceNameLanguage,
        db: Database
    ) throws -> [PlaceFilterCountry] {
        guard let query = try placeOptionsQuery(scope: scope, language: language, db: db) else {
            return []
        }
        let rows = try Row.fetchAll(db, sql: query.sql, arguments: query.arguments)
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

    /// The options' read, from the named cells: each country and town's cells, their located
    /// rows through `idx_asset_metadata_place_cell`, and each row's scope by its key — work in
    /// the located rows of named cells, not in every row of the scope. The join order is
    /// fixed (`CROSS JOIN`) because the planner otherwise starts from the scope's rows.
    static func placeOptionsQuery(
        scope: CatalogScopePredicate,
        language: PlaceNameLanguage,
        db: Database
    ) throws -> SQLQuery? {
        guard let scopeClause = try scopeClause(scope, db: db) else {
            return nil
        }
        return SQLQuery(
            sql: """
            SELECT place_cell.country, place_cell.town, COUNT(*) AS items
            FROM place_cell
            CROSS JOIN asset_metadata AS place_metadata
              ON place_metadata.place_cell_latitude = place_cell.cell_latitude
              AND place_metadata.place_cell_longitude = place_cell.cell_longitude
            CROSS JOIN media_asset
              ON media_asset.library_root_id = place_metadata.library_root_id
              AND media_asset.relative_path = place_metadata.relative_path\(scopeClause.join)
            WHERE place_cell.language = ? AND place_cell.country IS NOT NULL AND \(scopeClause.sql)
            GROUP BY place_cell.country, place_cell.town
            """,
            arguments: StatementArguments([language.identifier] + scopeClause.arguments)
        )
    }

    /// The languages the catalog holds place names in (ADR 0051): one, once the reader has
    /// forgotten every other; none before anything is named. A scan of `place_cell`, which
    /// holds one row per map cell a located photo falls in — a few thousand at most — and is
    /// read with no other table.
    static let placeNameLanguagesSQL = "SELECT DISTINCT language FROM place_cell"

    /// The read of `CatalogStore.unnamedPlaceCells`: the distinct cells of located rows in
    /// index order, from after a cell when `after`, with no name in the language argued.
    static func unnamedPlaceCellsSQL(after: Bool) -> String {
        """
        SELECT DISTINCT place_cell_latitude, place_cell_longitude FROM asset_metadata AS cells
        WHERE place_cell_latitude IS NOT NULL AND place_cell_longitude IS NOT NULL\(
            after ? "\n  AND (place_cell_latitude, place_cell_longitude) > (?, ?)" : ""
        )
          AND NOT EXISTS (
            SELECT 1 FROM place_cell
            WHERE place_cell.cell_latitude = cells.place_cell_latitude
              AND place_cell.cell_longitude = cells.place_cell_longitude
              AND place_cell.language = ?
          )
        ORDER BY place_cell_latitude, place_cell_longitude
        LIMIT ?
        """
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

    /// Rows in scope, optionally narrowed by the user filter. On This Day's are the rows it
    /// shows (`OnThisDayPicks.shows`), so its empty state never counts a file of a stack
    /// whose key is Disliked: a scope whose cards are all left out reads as nothing on this
    /// day, never as a filter's doing or an offline library's. Its stacks are built once,
    /// in this read, for the match and the count alike.
    static func countAssets(
        scope: CatalogScopePredicate,
        filter: MediaFilter = .all,
        db: Database
    ) throws -> Int {
        let picks: PhotoStackSQL.Built? = scope.isAnniversary && !scope.selectsNothing
            ? try AnniversaryStacks.readWhenNeeded.resolved(rootIDs: scope.rootIDs, db: db)
            : nil
        guard let scopeClause = try scopeClause(scope, stacks: picks.map(AnniversaryStacks.built) ?? .readWhenNeeded, db: db) else {
            return 0
        }
        var arguments = scopeClause.arguments
        let filterPredicate = filterPredicate(for: filter)
        arguments.append(contentsOf: filterPredicate.arguments)
        let filterSQL = filterPredicate.sql.map { "\n  AND \($0)" } ?? ""
        guard let picks else {
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
        let rows = try Row.fetchCursor(
            db,
            sql: """
            SELECT media_asset.library_root_id, media_asset.relative_path
            FROM media_asset\(scopeClause.join)
            WHERE \(scopeClause.sql)\(filterSQL)
            """,
            arguments: StatementArguments(arguments)
        )
        var shown = 0
        while let row = try rows.next() {
            guard let rootPath = picks.rootPaths[row[0]] else {
                continue
            }
            let id = MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: row[1]))
            if OnThisDayPicks.shows(id, stacks: picks.stacks) {
                shown += 1
            }
        }
        return shown
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

    /// Each import batch with its items, read every pass: through
    /// `idx_media_asset_import_batch`, which carries the columns its tests read (v55).
    static let importBatchesSQL = """
    SELECT import_batch_unix_ms AS batch_ms, COUNT(*) AS asset_count
    FROM media_asset
    WHERE import_batch_unix_ms IS NOT NULL
      AND pending_trash_batch_unix_ms IS NULL
      AND NOT \(LivePhotoSQL.isPairedMotion("media_asset"))
    GROUP BY import_batch_unix_ms
    ORDER BY import_batch_unix_ms DESC
    """

    static func fetchImportBatches(db: Database) throws -> [ImportBatchSummary] {
        try Row.fetchAll(db, sql: importBatchesSQL).map { row in
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
    /// One read of every root's candidates, and how long the read took, which the order
    /// query reports apart from its own work (`stackReadMs`).
    struct Candidates: Sendable {
        let byRoot: [Int64: [PhotoStackCandidate]]
        let count: Int
        let readDuration: Duration
    }

    /// Every stack of some roots as one read built them: the stacks, the root paths their
    /// files are named under, and what the read and the rule cost, which the order query
    /// reports apart from its own work.
    struct Built: Sendable {
        let stacks: CatalogStacks
        let rootPaths: [Int64: LibraryRootPath]
        let candidateCount: Int
        let readDuration: Duration
        let ruleDuration: Duration
    }

    /// Reads the candidates of `rootPaths`' roots and runs `PhotoStackRule` over them, in the
    /// caller's read, so the stacks come from the snapshot its rows do.
    static func build(rootPaths: [Int64: LibraryRootPath], db: Database) throws -> Built {
        let candidates = try fetchCandidates(rootIDs: rootPaths.keys.sorted(), db: db)
        let ruleStart = ContinuousClock.now
        var stacks: [PhotoStack] = []
        for (rowID, rootCandidates) in candidates.byRoot {
            guard let rootPath = rootPaths[rowID] else {
                continue
            }
            stacks += PhotoStackRule.stacks(candidates: rootCandidates, libraryRootPath: rootPath)
        }
        return Built(
            stacks: CatalogStacks(stacks),
            rootPaths: rootPaths,
            candidateCount: candidates.count,
            readDuration: candidates.readDuration,
            ruleDuration: ContinuousClock.now - ruleStart
        )
    }

    /// The columns `candidateQuery` selects, in order: each row is read by position.
    private enum Column: Int {
        case libraryRootID, relativePath, bestKind, nameKey, sortKey, keyChosenAt
        case burstIdentifier, captureLocal, choice, burstKeyChosenAt
    }

    static func fetchCandidates(rootIDs: [Int64], db: Database) throws -> Candidates {
        let start = ContinuousClock.now
        guard let query = candidateQuery(rootIDs: rootIDs) else {
            return Candidates(byRoot: [:], count: 0, readDuration: .zero)
        }
        let rows = try Row.fetchCursor(db, sql: query.sql, arguments: query.arguments)
        var byRoot: [Int64: [PhotoStackCandidate]] = [:]
        var count = 0
        while let row = try rows.next() {
            let kindValue: String = row[Column.bestKind.rawValue]
            guard let kind = MediaKind(rawValue: kindValue) else {
                continue
            }
            count += 1
            let choice: String = row[Column.choice.rawValue]
            byRoot[row[Column.libraryRootID.rawValue], default: []].append(PhotoStackCandidate(
                relativePath: MediaRelativePath(rawValue: row[Column.relativePath.rawValue]),
                kind: kind,
                nameKey: FilesystemNameKey(rawValue: row[Column.nameKey.rawValue]),
                sortKey: row[Column.sortKey.rawValue],
                burstIdentifier: row[Column.burstIdentifier.rawValue],
                captureLocal: row[Column.captureLocal.rawValue],
                // The column's CHECK admits only the three choices.
                choice: MediaChoice(rawValue: choice) ?? .default,
                keyChosenAtUnixMs: row[Column.keyChosenAt.rawValue],
                burstKeyChosenAtUnixMs: row[Column.burstKeyChosenAt.rawValue]
            ))
        }
        return Candidates(byRoot: byRoot, count: count, readDuration: ContinuousClock.now - start)
    }

    /// The candidates' read: the folders holding a present RAW, then each folder's present
    /// stills, both through `idx_media_asset_stack_candidate` (root, kind, folder); and every
    /// present still carrying a burst identifier, through `idx_media_asset_burst` by name: the
    /// planner otherwise picks the primary key and walks every row of a root.
    static func candidateQuery(rootIDs: [Int64]) -> SQLQuery? {
        guard !rootIDs.isEmpty else {
            return nil
        }
        let placeholders = sqlPlaceholders(count: rootIDs.count)
        let columns = """
        still.library_root_id, still.relative_path, still.best_kind, still.relative_path_key,
                   still.sort_key, still.stack_key_chosen_at_unix_ms, still.burst_identifier,
                   still.best_capture_local, still.media_choice, still.burst_key_chosen_at_unix_ms
        """
        return SQLQuery(
            sql: """
            WITH raw_folder AS (
                SELECT DISTINCT library_root_id, parent_path FROM media_asset
                WHERE library_root_id IN (\(placeholders)) AND best_kind = 'raw'
                  AND \(CatalogVisibilitySQL.isPresent("media_asset"))
            )
            SELECT \(columns)
            FROM raw_folder
            JOIN media_asset AS still
              ON still.library_root_id = raw_folder.library_root_id
              AND still.parent_path = raw_folder.parent_path
            WHERE still.best_kind IN ('raw', 'image')
              AND \(CatalogVisibilitySQL.isPresent("still"))
            UNION
            SELECT \(columns)
            FROM media_asset AS still INDEXED BY idx_media_asset_burst
            WHERE still.library_root_id IN (\(placeholders)) AND still.burst_identifier IS NOT NULL
              AND still.best_kind IN ('raw', 'image')
              AND \(CatalogVisibilitySQL.isPresent("still"))
            """,
            arguments: StatementArguments(rootIDs + rootIDs)
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
/// the rows it selects come from one snapshot (ADR 0049); `stacks` are what the match judges
/// a stack's files by.
private nonisolated func scopeClause(
    _ scope: CatalogScopePredicate,
    stacks: AnniversaryStacks = .readWhenNeeded,
    db: Database
) throws -> ScopeClause? {
    guard !scope.selectsNothing else {
        return nil
    }
    switch scope.date {
    case .any:
        return try scopeClause(scope, anniversary: nil)
    case let .anniversary(day):
        guard let match = try anniversaryMatch(for: day, scope: scope, stacks: stacks, db: db) else {
            return nil
        }
        return try scopeClause(scope, anniversary: match)
    }
}

private typealias ScopeClause = (join: String, sql: String, arguments: [any DatabaseValueConvertible])

/// The stacks On This Day's match judges a stack's files by (`OnThisDayPicks.shows`): the
/// ones the read already built from its own transaction, or none yet, built from the same
/// transaction when a year's rows first need them. Either way they come from the snapshot
/// the rows do.
nonisolated enum AnniversaryStacks {
    case built(PhotoStackSQL.Built)
    case readWhenNeeded

    func resolved(rootIDs: [Int64], db: Database) throws -> PhotoStackSQL.Built {
        switch self {
        case let .built(built):
            return built
        case .readWhenNeeded:
            var rootPaths: [Int64: LibraryRootPath] = [:]
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, path FROM library_root WHERE id IN (\(sqlPlaceholders(count: rootIDs.count)))",
                arguments: StatementArguments(rootIDs)
            )
            for row in rows {
                rootPaths[row[0]] = LibraryRootPath(rawValue: row[1])
            }
            return try PhotoStackSQL.build(rootPaths: rootPaths, db: db)
        }
    }
}

/// On This Day's match (ADR 0049): the day in earlier years while the scope holds a photo
/// On This Day would show on one, else the day in earlier months. "Would show" is the rule
/// that fills the cards (`OnThisDayPicks.shows`): a row the exclusion leaves in, unless it is
/// a file of a stack whose key is Disliked. So a year is offered exactly when its card would
/// hold a photo. The question is asked of the scope alone — its roots and visibility rules
/// — never of the filter, so the filter only narrows what the scope holds and never turns
/// years into months. Nil only for a day no calendar starts, which `CalendarDay.today()`
/// never is.
///
/// The year's rows are walked in their index's order and the walk stops at the first one
/// shown, so a day whose first row is shown costs what an `EXISTS` would.
private nonisolated func anniversaryMatch(
    for day: CalendarDay,
    scope: CatalogScopePredicate,
    stacks: AnniversaryStacks,
    db: Database
) throws -> AnniversaryMatch? {
    if let years = AnniversaryMatch.years(for: day),
       let query = try CatalogQueryGateway.anniversaryRowsQuery(scope: scope, match: years)
    {
        let rows = try Row.fetchCursor(db, sql: query.sql, arguments: query.arguments)
        var judged: PhotoStackSQL.Built?
        while let row = try rows.next() {
            let built = try judged ?? stacks.resolved(rootIDs: scope.rootIDs, db: db)
            judged = built
            guard let rootPath = built.rootPaths[row[0]] else {
                continue
            }
            let id = MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: row[1]))
            if OnThisDayPicks.shows(id, stacks: built.stacks) {
                logAnniversaryMatch(day: day, unit: .years)
                return years
            }
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
    // visibility rules so a copy waiting for the Trash makes no one else a duplicate. The
    // group subquery walks only the rows that have a digest, in digest order, so it groups
    // without a temporary B-tree over every row of the scope: most of the owner's rows (an
    // Immich account's) have none (`docs/research/2026-11-14-owner-scale-query-plans.md`).
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
              SELECT twin.content_hash_xxh3_128 FROM media_asset AS twin INDEXED BY idx_media_asset_content_hash
              WHERE twin.content_hash_xxh3_128 IS NOT NULL
                AND twin.library_root_id IN (\(sqlPlaceholders(count: scope.rootIDs.count)))
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
        predicate += OnThisDayPicks.exclusionSQL
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
    // The Places filter (ADR 0051): a photo whose cell Maps named, in the filter's language,
    // as one of the countries or towns checked.
    if let places = filter.places {
        var placeClauses: [String] = []
        arguments.append(places.language.identifier)
        for place in places.keys.sorted() {
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
              ON place_cell.cell_latitude = place_metadata.place_cell_latitude
              AND place_cell.cell_longitude = place_metadata.place_cell_longitude
            WHERE place_metadata.library_root_id = media_asset.library_root_id
              AND place_metadata.relative_path = media_asset.relative_path
              AND place_cell.language = ?
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
