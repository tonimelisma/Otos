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
        let burstColumn: Int? = try PhotoStackSQL.isBuiltFromRows(scope) ? likedColumn + (scope.isAnniversary ? 1 : 0) : nil
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
                isLiked: scope.isAnniversary ? row[likedColumn] : false,
                burstIdentifier: burstColumn.flatMap { row[$0] }
            )
        })
    }

    /// The order's rows and the stacks that judge them, in the caller's read (`db`), so every
    /// stack and row comes from one snapshot (ADR 0052). `held` — every stack of
    /// `stackRootPaths`' roots, which the caller holds while nothing they are built from
    /// moved — is used when given. Otherwise a narrow scope (`PhotoStackSQL.isBuiltFromRows`)
    /// reads its rows first and builds only the stacks that hold them
    /// (`PhotoStackSQL.build(rootPaths:holding:db:)`), and a wide scope builds every stack of
    /// its roots before its rows.
    static func readOrder(
        descriptor: CatalogQueryDescriptor,
        scope: CatalogScopePredicate,
        stackRootPaths: [Int64: LibraryRootPath],
        held: PhotoStackSQL.Built?,
        db: Database
    ) throws -> (rows: [OrderedAssetIDRow], stacks: PhotoStackSQL.Built) {
        if held == nil, try PhotoStackSQL.isBuiltFromRows(scope) {
            let rows = try fetchOrderedAssetIDRows(descriptor: descriptor, scope: scope, db: db)
            return try (rows, PhotoStackSQL.build(rootPaths: stackRootPaths, holding: rows, db: db))
        }
        let stacks = try held ?? PhotoStackSQL.build(rootPaths: stackRootPaths, db: db)
        return try (fetchOrderedAssetIDRows(descriptor: descriptor, scope: scope, stacks: .built(stacks), db: db), stacks)
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
        /// The burst a still carries, read only for a narrow scope, whose stacks are built from
        /// its rows (`PhotoStackSQL.build(rootPaths:holding:db:)`).
        var burstIdentifier: String?
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
        // A narrow scope's stacks are built from its rows, so its rows carry their stills' bursts.
        let burstColumn = try PhotoStackSQL.isBuiltFromRows(scope)
            ? ", CASE WHEN media_asset.best_kind IN ('raw', 'image') THEN media_asset.burst_identifier END"
            : ""
        // A wide scope walks the order's index, which hands its rows over in order. A narrow
        // scope seeks its own rows and sorts the few it finds: walking the order index for them
        // reads every row of the catalog (`ScopeClause.Seek`).
        return SQLQuery(
            sql: """
            SELECT media_asset.library_root_id, media_asset.relative_path, media_asset.best_capture_local\(locationColumns)\(likedColumn)\(burstColumn)
            FROM \(scopeClause.seekFrom ?? "media_asset INDEXED BY \(order.indexName)\(scopeClause.join)")
            WHERE \(scopeClause.sql)\(filterSQL)
            ORDER BY \(order.orderBy)
            """,
            arguments: StatementArguments(arguments)
        )
    }

    /// The rows of `scope` that `match` selects and On This Day's exclusion leaves in, by key,
    /// with their stills' bursts (`StackJudgedRows`): what the years-or-months match judges
    /// (`anniversaryMatch`), sought through the day's index. Nil when the scope selects nothing.
    static func anniversaryRowsQuery(scope: CatalogScopePredicate, match: AnniversaryMatch) throws -> SQLQuery? {
        guard !scope.selectsNothing, let clause = try scopeClause(scope, anniversary: match) else {
            return nil
        }
        return SQLQuery(
            sql: """
            SELECT \(StackJudgedRows.columns)
            FROM \(clause.from)
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

    /// The options' read. The join order is fixed (`CROSS JOIN`) by the scope's width, because
    /// the planner cannot tell a wide scope from a keyed one. A wide scope starts from the named
    /// cells: each country and town's cells, their located rows through
    /// `idx_asset_metadata_place_cell`, and each row's scope by its key — work in the located
    /// rows of named cells, not in every row of the scope. A narrow scope (`ScopeClause.Seek`)
    /// starts from its own rows, each row's metadata and cell by key: walking every named cell
    /// for an import batch's 210 rows read 21 s on the owner's catalog, its rows first 20 ms
    /// (`docs/research/2026-11-15-keyed-scope-query-plans.md`).
    static func placeOptionsQuery(
        scope: CatalogScopePredicate,
        language: PlaceNameLanguage,
        db: Database
    ) throws -> SQLQuery? {
        guard let scopeClause = try scopeClause(scope, db: db) else {
            return nil
        }
        let from = if let seekFrom = scopeClause.seekFrom {
            """
            FROM \(seekFrom)
            CROSS JOIN asset_metadata AS place_metadata
              ON place_metadata.library_root_id = media_asset.library_root_id
              AND place_metadata.relative_path = media_asset.relative_path
            CROSS JOIN place_cell
              ON place_cell.cell_latitude = place_metadata.place_cell_latitude
              AND place_cell.cell_longitude = place_metadata.place_cell_longitude
            """
        } else {
            """
            FROM place_cell
            CROSS JOIN asset_metadata AS place_metadata
              ON place_metadata.place_cell_latitude = place_cell.cell_latitude
              AND place_metadata.place_cell_longitude = place_cell.cell_longitude
            CROSS JOIN media_asset
              ON media_asset.library_root_id = place_metadata.library_root_id
              AND media_asset.relative_path = place_metadata.relative_path\(scopeClause.join)
            """
        }
        return SQLQuery(
            sql: """
            SELECT place_cell.country, place_cell.town, COUNT(*) AS items
            \(from)
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
            FROM \(scopeClause.from)
            WHERE \(scopeClause.sql)
              AND best_kind IS NOT NULL
            ORDER BY best_kind, best_format
            """,
            arguments: StatementArguments(scopeClause.arguments)
        )
    }

    /// The count of a scope other than On This Day's (whose count judges its stacks in
    /// Swift, `countAssets`); a narrow scope counts from its seek (`ScopeClause.from`).
    static func countQuery(scope: CatalogScopePredicate, filter: MediaFilter = .all, db: Database) throws -> SQLQuery? {
        guard let scopeClause = try scopeClause(scope, db: db) else {
            return nil
        }
        let filterPredicate = filterPredicate(for: filter)
        let filterSQL = filterPredicate.sql.map { "\n  AND \($0)" } ?? ""
        return SQLQuery(
            sql: """
            SELECT COUNT(*)
            FROM \(scopeClause.from)
            WHERE \(scopeClause.sql)\(filterSQL)
            """,
            arguments: StatementArguments(scopeClause.arguments + filterPredicate.arguments)
        )
    }

    /// Rows in scope, optionally narrowed by the user filter. On This Day's are the rows it
    /// shows (`OnThisDayPicks.shows`), so its empty state never counts a file of a stack
    /// whose key is Disliked: a scope whose cards are all left out reads as nothing on this
    /// day, never as a filter's doing or an offline library's. The match and the count each
    /// judge their rows by the stacks that hold them, built in this read
    /// (`AnniversaryStacks.judging`).
    static func countAssets(
        scope: CatalogScopePredicate,
        filter: MediaFilter = .all,
        db: Database
    ) throws -> Int {
        guard scope.isAnniversary, !scope.selectsNothing else {
            guard let query = try countQuery(scope: scope, filter: filter, db: db) else {
                return 0
            }
            return try Int.fetchOne(db, sql: query.sql, arguments: query.arguments) ?? 0
        }
        guard let scopeClause = try scopeClause(scope, stacks: .readWhenNeeded, db: db) else {
            return 0
        }
        var arguments = scopeClause.arguments
        let filterPredicate = filterPredicate(for: filter)
        arguments.append(contentsOf: filterPredicate.arguments)
        let filterSQL = filterPredicate.sql.map { "\n  AND \($0)" } ?? ""
        let rows = try StackJudgedRows.fetch(
            SQLQuery(
                sql: """
                SELECT \(StackJudgedRows.columns)
                FROM \(scopeClause.from)
                WHERE \(scopeClause.sql)\(filterSQL)
                """,
                arguments: StatementArguments(arguments)
            ),
            db: db
        )
        let picks = try AnniversaryStacks.readWhenNeeded.judging(rows, rootIDs: scope.rootIDs, db: db)
        return rows.count { row in
            picks.rootPaths[row.libraryRootID].map { rootPath in
                OnThisDayPicks.shows(MediaAssetID(libraryRootPath: rootPath, relativePath: row.relativePath), stacks: picks.stacks)
            } ?? false
        }
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
                       content_sha1, content_hash_source_size, content_hash_source_mtime,
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

    /// What makes a row an import batch's shown row: stamped, not on its way to the Trash,
    /// not a Live Photo's movie (ADR 0041). Every column it tests is in
    /// `idx_media_asset_import_batch` (v55).
    private static let importBatchRowTest = """
    import_batch_unix_ms IS NOT NULL
      AND pending_trash_batch_unix_ms IS NULL
      AND NOT \(LivePhotoSQL.isPairedMotion("media_asset"))
    """

    /// Every nonempty import batch, newest first, in `idx_media_asset_import_batch`'s order.
    static let importBatchIDsSQL = """
    SELECT DISTINCT import_batch_unix_ms
    FROM media_asset INDEXED BY idx_media_asset_import_batch
    WHERE \(importBatchRowTest)
    ORDER BY import_batch_unix_ms DESC
    """

    /// The rows of the batches the argument names (a JSON array of batch milliseconds), newest
    /// batch first: the index carries the batch, the root and the path; the burst identifier,
    /// for the batches' stacks, is the one column read from the row.
    static let importBatchRowsSQL = """
    SELECT import_batch_unix_ms, library_root_id, relative_path, burst_identifier
    FROM media_asset INDEXED BY idx_media_asset_import_batch
    WHERE import_batch_unix_ms IN (SELECT value FROM json_each(?))
      AND \(importBatchRowTest)
    ORDER BY import_batch_unix_ms DESC
    """

    /// Every nonempty import batch, newest first, with how many photos it shows (ADR 0052: a
    /// stack counts once) for the batches `selection` shows (`ImportBatchListing.counted`),
    /// and no count for the rest. A batch counts as its grid does: its rows collapsed by the
    /// stacks that hold them (`PhotoStackSQL.build(rootPaths:holding:db:)`), so a RAW+JPEG
    /// pair imported together is one photo, and a pair whose files came in two batches is a
    /// file in each.
    static func fetchImportBatches(
        countingFor selection: SidebarSelection,
        rootPaths: [Int64: LibraryRootPath],
        db: Database
    ) throws -> [ImportBatchSummary] {
        let ids = try Int64.fetchAll(db.cachedStatement(sql: importBatchIDsSQL)).map(ImportBatchID.init(unixMilliseconds:))
        let counted = ImportBatchListing.counted(ids, selection: selection)
        guard !counted.isEmpty else {
            return ids.map { ImportBatchSummary(batchID: $0, photoCount: nil) }
        }
        let names = try String(decoding: JSONEncoder().encode(counted.map(\.unixMilliseconds)), as: UTF8.self)
        var rowsByBatch: [ImportBatchID: [OrderedAssetIDRow]] = [:]
        let cursor = try Row.fetchCursor(db.cachedStatement(sql: importBatchRowsSQL), arguments: [names])
        while let row = try cursor.next() {
            var assetRow = OrderedAssetIDRow(
                libraryRootID: row[1],
                relativePath: MediaRelativePath(rawValue: row[2]),
                captureLocalTime: nil,
                coordinate: nil
            )
            assetRow.burstIdentifier = row[3]
            rowsByBatch[ImportBatchID(unixMilliseconds: row[0]), default: []].append(assetRow)
        }
        let stacks = try PhotoStackSQL.build(rootPaths: rootPaths, holding: rowsByBatch.values.flatMap(\.self), db: db).stacks
        return ids.map { id in
            guard let rows = rowsByBatch[id] else {
                return ImportBatchSummary(batchID: id, photoCount: nil)
            }
            let shown = rows.compactMap { row in
                rootPaths[row.libraryRootID].map { MediaAssetID(libraryRootPath: $0, relativePath: row.relativePath) }
            }
            let photos = PhotoStackCollapse.collapse(
                ids: shown,
                dayBuckets: [],
                coordinates: [],
                stacks: stacks,
                expanded: []
            ).ids.count
            return ImportBatchSummary(batchID: id, photoCount: photos)
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

/// The map cells a located photo falls in (ADR 0051): a fiftieth of a degree each way,
/// `asset_metadata.place_cell_latitude` and `place_cell_longitude`, generated from the
/// primary location (schema v43). The cells are what Maps names, and an area's rows are
/// sought through their index.
nonisolated enum PlaceCellSQL {
    static let indexName = "idx_asset_metadata_place_cell"

    /// The cells in a degree, each way.
    static let cellsPerDegree = 50.0
    static let latitudeCells = -4500 ... 4499
    static let longitudeCells = -9000 ... 8999

    /// The cell of `column`, a coordinate in degrees, clamped to `cells`: the floor of its
    /// scaled value, written with `CAST` because SQLite's has no `floor` in every build.
    static func cell(_ column: String, cells: ClosedRange<Int>) -> String {
        let scaled = "(\(column) * \(cellsPerDegree))"
        return "MIN(MAX(CAST(\(scaled) AS INTEGER) - (\(scaled) < CAST(\(scaled) AS INTEGER)), \(cells.lowerBound)), \(cells.upperBound))"
    }

    /// The cell `cell(_:cells:)` gives a coordinate of `degrees`: the same floor of the same
    /// product of doubles, clamped alike.
    static func cell(of degrees: Double, cells: ClosedRange<Int>) -> Int {
        min(max(Int((degrees * cellsPerDegree).rounded(.down)), cells.lowerBound), cells.upperBound)
    }

    /// The cells whose union holds every point of `area`: the floor is monotonic, so a point
    /// inside the box has a cell inside the box's corner cells, across the antimeridian alike.
    static func cells(covering area: MapArea) -> CellBox {
        CellBox(
            south: cell(of: area.south, cells: latitudeCells),
            north: cell(of: area.north, cells: latitudeCells),
            west: cell(of: area.west, cells: longitudeCells),
            east: cell(of: area.east, cells: longitudeCells)
        )
    }

    /// An area's corner cells.
    struct CellBox: Equatable {
        let south: Int
        let north: Int
        let west: Int
        let east: Int
    }
}

/// Whether a row's SHA-1 names its current bytes (ADR 0018): the one definition every
/// reader of the digest uses, the copy triggers included (ADR 0054). It reads the stored
/// columns, never a generated one, so `idx_media_asset_content_sha1`, which holds them with
/// what a copy is tested by, answers a scan of every digest without a table read: SQLite
/// never serves a virtual column from an index, and that scan took 14–30 s on the owner's
/// catalog (`docs/research/2026-11-14-one-photo-many-copies.md`).
nonisolated enum ContentDigestSQL {
    static let indexName = "idx_media_asset_content_sha1"

    /// The index's columns: the digest, the row's key, the stamps and file facts currency
    /// reads, and what visibility, Duplicates and the Live Photo rule test a row by.
    static let indexedColumns = """
    content_sha1, library_root_id, relative_path, content_hash_source_size, content_hash_source_mtime, \
    byte_size, content_modified_at_unix, pending_trash_batch_unix_ms, awaiting_presence, hidden_by_source, \
    trash_path, best_kind, content_identifier
    """

    /// The SHA-1 of no bytes, as a SQL literal. Every empty file has it, and an empty file is
    /// a broken file, not a copy of another (ADR 0042), so no two rows are copies by it.
    static let empty = "X'\(ContentDigest.empty.hexString)'"

    static func isCurrent(_ row: String) -> String {
        """
        \(row).content_sha1 IS NOT NULL
          AND length(\(row).content_sha1) = 20
          AND \(row).content_hash_source_size = COALESCE(\(row).byte_size, -1)
          AND \(row).content_hash_source_mtime = CAST(COALESCE(\(row).content_modified_at_unix, -1) AS INTEGER)
        """
    }

    /// The row's digest while it is current, else NULL, as a value.
    static func current(_ row: String) -> String {
        "CASE WHEN \(isCurrent(row)) THEN \(row).content_sha1 END"
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

    /// What one build of stacks covers. `.roots`: every stack of its roots, which answers any
    /// scope over them and is what a reader holds. `.rows`: only the stacks that hold one of
    /// the rows a narrow scope's order read found, which answers that read alone.
    enum Span: Equatable, Sendable {
        case roots
        case rows
    }

    /// Stacks of some roots as one read built them: the stacks, the root paths their files are
    /// named under, what they cover, and what the read and the rule cost, which the order
    /// query reports apart from its own work.
    struct Built: Sendable {
        let stacks: CatalogStacks
        let rootPaths: [Int64: LibraryRootPath]
        let span: Span
        let candidateCount: Int
        let readDuration: Duration
        let ruleDuration: Duration
    }

    /// Every stack of `rootPaths`' roots, from every candidate (`Span.roots`), in the
    /// caller's read, so the stacks come from the snapshot its rows do.
    static func build(rootPaths: [Int64: LibraryRootPath], db: Database) throws -> Built {
        let candidates = try fetchCandidates(rootIDs: rootPaths.keys.sorted(), db: db)
        let ruleStart = ContinuousClock.now
        return Built(
            stacks: CatalogStacks(stacks(of: candidates, rootPaths: rootPaths)),
            rootPaths: rootPaths,
            span: .roots,
            candidateCount: candidates.count,
            readDuration: candidates.readDuration,
            ruleDuration: ContinuousClock.now - ruleStart
        )
    }

    /// Whether `scope` is narrow (`ScopeClause.Seek`): a few hundred or thousand rows of a
    /// catalog of hundreds of thousands, whose stacks are built from its own rows
    /// (`build(rootPaths:holding:db:)`). On This Day decides its match inside its read, and
    /// either match seeks its day (`AnniversaryMatch`), so it is always narrow.
    static func isBuiltFromRows(_ scope: CatalogScopePredicate) throws -> Bool {
        guard !scope.selectsNothing else {
            return false
        }
        return try scope.isAnniversary || scopeClause(scope, anniversary: nil)?.seek != nil
    }

    /// The stacks that hold one of `rows` (`Span.rows`), in the caller's read, after the rows.
    /// A pair is two files of one folder and a burst is its frames' identifier within a root,
    /// so every such stack is built whole from the candidates of the rows' folders that hold
    /// a RAW, the stills of the bursts the rows and those candidates carry, and the candidates
    /// of those stills' folders that hold a RAW; a stack the rule builds there that holds none
    /// of the rows may be partial, so it is left out. Every candidate of every root was 25,700
    /// rows for a batch of two, read in 2–7 s on the owner's loaded machine
    /// (`docs/research/2026-11-15-small-scope-reads-and-tile-waits.md`).
    static func build(
        rootPaths: [Int64: LibraryRootPath],
        holding rows: [CatalogQueryGateway.OrderedAssetIDRow],
        db: Database
    ) throws -> Built {
        let start = ContinuousClock.now
        var folders = Set<RootedName>()
        var bursts = Set<RootedName>()
        // A root's and a folder's rows mostly come together in the order, so a row of the root
        // and folder before it costs two comparisons, not a lookup and an insertion: this loop
        // was most of a day's stack read when the day holds 15,000 photos.
        var lastRootID: Int64?
        var lastRootIsRead = false
        var lastFolder: String?
        for row in rows {
            if row.libraryRootID != lastRootID {
                lastRootID = row.libraryRootID
                lastRootIsRead = rootPaths[row.libraryRootID] != nil
                lastFolder = nil
            }
            guard lastRootIsRead else {
                continue
            }
            let rowFolder = folder(of: row.relativePath)
            if rowFolder != lastFolder {
                folders.insert(RootedName(rootID: row.libraryRootID, name: rowFolder))
                lastFolder = rowFolder
            }
            if let burst = row.burstIdentifier {
                bursts.insert(RootedName(rootID: row.libraryRootID, name: burst))
            }
        }
        let candidates = try folders.isEmpty
            ? Candidates(byRoot: [:], count: 0, readDuration: ContinuousClock.now - start)
            : fetchCandidates(
                query: scopedCandidateQuery(folders: RootedName.json(folders), bursts: RootedName.json(bursts)),
                start: start,
                db: db
            )
        let ruleStart = ContinuousClock.now
        var stacks = stacks(of: candidates, rootPaths: rootPaths)
        if !stacks.isEmpty {
            let held = Set(rows.compactMap { row in
                rootPaths[row.libraryRootID].map { MediaAssetID(libraryRootPath: $0, relativePath: row.relativePath) }
            })
            stacks.removeAll { stack in !stack.members.contains(where: held.contains) }
        }
        return Built(
            stacks: CatalogStacks(stacks),
            rootPaths: rootPaths,
            span: .rows,
            candidateCount: candidates.count,
            readDuration: candidates.readDuration,
            ruleDuration: ContinuousClock.now - ruleStart
        )
    }

    /// A folder or a burst identifier within one root: `[rootID, name]` in the scoped
    /// candidates' arguments.
    private struct RootedName: Hashable, Encodable {
        let rootID: Int64
        let name: String

        func encode(to encoder: any Encoder) throws {
            var row = encoder.unkeyedContainer()
            try row.encode(rootID)
            try row.encode(name)
        }

        static func json(_ names: Set<Self>) throws -> String {
            try String(decoding: JSONEncoder().encode(Array(names)), as: UTF8.self)
        }
    }

    /// A path's folder as `media_asset.parent_path` stores it (schema v9): through its last
    /// `/`, empty at the root.
    ///
    /// It looks for the `/` in the path's UTF-8 bytes: a search of its `Character`s breaks
    /// graphemes on every one, and cost about 10,000 instructions a row, most of a narrow
    /// scope's stack read on a day of 15,000 photos.
    private static func folder(of path: MediaRelativePath) -> String {
        let utf8 = path.rawValue.utf8
        guard let slash = utf8.lastIndex(of: UInt8(ascii: "/")) else {
            return ""
        }
        return String(path.rawValue[...slash])
    }

    private static func stacks(of candidates: Candidates, rootPaths: [Int64: LibraryRootPath]) -> [PhotoStack] {
        var stacks: [PhotoStack] = []
        for (rowID, rootCandidates) in candidates.byRoot {
            guard let rootPath = rootPaths[rowID] else {
                continue
            }
            stacks += PhotoStackRule.stacks(candidates: rootCandidates, libraryRootPath: rootPath)
        }
        return stacks
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
        return try fetchCandidates(query: query, start: start, db: db)
    }

    private static func fetchCandidates(query: SQLQuery, start: ContinuousClock.Instant, db: Database) throws -> Candidates {
        // Prepared once per connection: the text depends only on the root count, and a narrow
        // scope's read runs on every publication of a batch while it imports.
        let rows = try Row.fetchCursor(db.cachedStatement(sql: query.sql), arguments: query.arguments)
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

    /// The candidates of the stacks that can hold some rows, from `folders` (`[[rootID,
    /// folder], …]`: the rows' folders) and `bursts` (`[[rootID, identifier], …]`: the bursts
    /// the rows' stills carry): the present RAWs and processed images of each folder that holds
    /// a present RAW; every still of those bursts and of the bursts those folders' stills
    /// carry, through `idx_media_asset_burst`; and the RAWs and processed images of those
    /// stills' folders that hold a present RAW. Folders are read through
    /// `idx_media_asset_stack_candidate` (root, kind, folder), and a folder without a RAW is
    /// never walked: it pairs nothing, and the rows in it name their own bursts. The
    /// candidates `candidateQuery` reads for these folders and bursts, and no others. The join
    /// order is fixed (`CROSS JOIN`): each step starts from the few rows the step before found.
    static func scopedCandidateQuery(folders: String, bursts: String) -> SQLQuery {
        let columns = """
        still.library_root_id, still.relative_path, still.best_kind, still.relative_path_key,
                   still.sort_key, still.stack_key_chosen_at_unix_ms, still.burst_identifier,
                   still.best_capture_local, still.media_choice, still.burst_key_chosen_at_unix_ms
        """
        func holdsRaw(_ folder: String) -> String {
            """
            EXISTS (
                    SELECT 1 FROM media_asset AS raw INDEXED BY idx_media_asset_stack_candidate
                    WHERE raw.library_root_id = \(folder).library_root_id
                      AND raw.best_kind = 'raw'
                      AND raw.parent_path = \(folder).parent_path
                      AND \(CatalogVisibilitySQL.isPresent("raw"))
                )
            """
        }
        return SQLQuery(
            sql: """
            WITH seed_folder AS (
                SELECT json_extract(seed.value, '$[0]') AS library_root_id,
                       json_extract(seed.value, '$[1]') AS parent_path
                FROM json_each(?) AS seed
            ),
            seed_raw_folder AS (
                SELECT seed_folder.library_root_id, seed_folder.parent_path FROM seed_folder
                WHERE \(holdsRaw("seed_folder"))
            ),
            seed_burst AS (
                SELECT json_extract(seed.value, '$[0]') AS library_root_id,
                       json_extract(seed.value, '$[1]') AS burst_identifier
                FROM json_each(?) AS seed
                UNION
                SELECT still.library_root_id, still.burst_identifier
                FROM seed_raw_folder
                CROSS JOIN media_asset AS still INDEXED BY idx_media_asset_stack_candidate
                  ON still.library_root_id = seed_raw_folder.library_root_id
                  AND still.best_kind IN ('raw', 'image')
                  AND still.parent_path = seed_raw_folder.parent_path
                WHERE still.burst_identifier IS NOT NULL
                  AND \(CatalogVisibilitySQL.isPresent("still"))
            ),
            burst_still AS (
                SELECT still.rowid AS still_rowid, still.library_root_id, still.parent_path
                FROM seed_burst
                CROSS JOIN media_asset AS still INDEXED BY idx_media_asset_burst
                  ON still.library_root_id = seed_burst.library_root_id
                  AND still.burst_identifier = seed_burst.burst_identifier
                WHERE still.best_kind IN ('raw', 'image')
                  AND \(CatalogVisibilitySQL.isPresent("still"))
            ),
            raw_folder AS (
                SELECT library_root_id, parent_path FROM seed_raw_folder
                UNION
                SELECT burst_still.library_root_id, burst_still.parent_path FROM burst_still
                WHERE \(holdsRaw("burst_still"))
            )
            SELECT \(columns)
            FROM raw_folder
            CROSS JOIN media_asset AS still INDEXED BY idx_media_asset_stack_candidate
              ON still.library_root_id = raw_folder.library_root_id
              AND still.best_kind IN ('raw', 'image')
              AND still.parent_path = raw_folder.parent_path
            WHERE \(CatalogVisibilitySQL.isPresent("still"))
            UNION
            SELECT \(columns)
            FROM burst_still
            CROSS JOIN media_asset AS still ON still.rowid = burst_still.still_rowid
            """,
            arguments: [folders, bursts]
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

/// A resolved scope's `FROM` join and `WHERE` fragment, and how its reads reach its rows.
private nonisolated struct ScopeClause {
    /// How a narrow scope's reads find its rows: through an index that holds them and little
    /// else. A narrow scope is a few hundred or thousand rows of a catalog of hundreds of
    /// thousands, so every read of it starts here; a read that walks an order index or every
    /// named place cell first reads the whole catalog to find them (16–36 s on the owner's
    /// catalog, `docs/research/2026-11-15-keyed-scope-query-plans.md` and
    /// `docs/research/2026-11-15-proportional-small-scopes.md`). A wide scope — whole
    /// libraries, or a part of them no index narrows — has no seek, and its reads keep their
    /// own fixed plans.
    enum Seek {
        /// `media_asset` through an index led by what names the scope's rows: a stack's
        /// members, a set of identical copies, an import batch, a person's photos, the digests
        /// Duplicates shows, On This Day's day.
        case rows(index: String)
        /// The located rows of the map cells an area covers (`PlaceCellSQL.indexName`), each
        /// row's `media_asset` found by its key.
        case placeCells
    }

    let join: String
    let sql: String
    let arguments: [any DatabaseValueConvertible]
    let seek: Seek?

    /// The tables a narrow scope's reads start from, through its seek, with its join; nil for
    /// a wide scope.
    var seekFrom: String? {
        switch seek {
        case nil:
            nil
        case let .rows(index):
            "media_asset INDEXED BY \(index)" + join
        case .placeCells:
            """
            asset_metadata INDEXED BY \(PlaceCellSQL.indexName)
            CROSS JOIN media_asset INDEXED BY \(mediaAssetKeyIndexName)
              ON media_asset.library_root_id = asset_metadata.library_root_id
              AND media_asset.relative_path = asset_metadata.relative_path
            """
        }
    }

    /// `media_asset` as a read that has no order of its own reaches the scope's rows: through
    /// the seek of a narrow scope, else with the scope's join.
    var from: String {
        seekFrom ?? "media_asset" + join
    }
}

/// `media_asset`'s primary key, `(library_root_id, relative_path)`: what a stack's members are
/// named by. SQLite names a constraint's index itself, and `INDEXED BY` accepts that name.
private nonisolated let mediaAssetKeyIndexName = "sqlite_autoindex_media_asset_1"

/// The stacks On This Day's match judges a stack's files by (`OnThisDayPicks.shows`): every
/// stack of the scope's roots, which the read's caller holds or built in the read, or none
/// yet, built in the read from the rows being judged — only the stacks that hold one of them
/// (`PhotoStackSQL.build(rootPaths:holding:db:)`), which judge those rows exactly as every
/// stack would. Either way they come from the snapshot the rows do.
nonisolated enum AnniversaryStacks {
    case built(PhotoStackSQL.Built)
    case readWhenNeeded

    func judging(
        _ rows: [CatalogQueryGateway.OrderedAssetIDRow],
        rootIDs: [Int64],
        db: Database
    ) throws -> PhotoStackSQL.Built {
        switch self {
        case let .built(built):
            return built
        case .readWhenNeeded:
            var rootPaths: [Int64: LibraryRootPath] = [:]
            let roots = try Row.fetchAll(
                db,
                sql: "SELECT id, path FROM library_root WHERE id IN (\(sqlPlaceholders(count: rootIDs.count)))",
                arguments: StatementArguments(rootIDs)
            )
            for root in roots {
                rootPaths[root[0]] = LibraryRootPath(rawValue: root[1])
            }
            return try PhotoStackSQL.build(rootPaths: rootPaths, holding: rows, db: db)
        }
    }
}

/// Rows read to be judged by their stacks, with what builds the stacks that hold them
/// (`PhotoStackSQL.build(rootPaths:holding:db:)`): each row's key and its still's burst.
private nonisolated enum StackJudgedRows {
    /// The columns `fetch` reads, in its order.
    static let columns = """
    media_asset.library_root_id, media_asset.relative_path, \
    CASE WHEN media_asset.best_kind IN ('raw', 'image') THEN media_asset.burst_identifier END
    """

    static func fetch(_ query: SQLQuery, db: Database) throws -> [CatalogQueryGateway.OrderedAssetIDRow] {
        try Array(cursor(query, db: db))
    }

    static func cursor(_ query: SQLQuery, db: Database) throws -> some Cursor<CatalogQueryGateway.OrderedAssetIDRow> {
        try Row.fetchCursor(db, sql: query.sql, arguments: query.arguments).map { row in
            CatalogQueryGateway.OrderedAssetIDRow(
                libraryRootID: row[0],
                relativePath: MediaRelativePath(rawValue: row[1]),
                captureLocalTime: nil,
                coordinate: nil,
                burstIdentifier: row[2]
            )
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
/// The year's rows are sought through the day's index (`AnniversaryMatch`) and judged one at a
/// time, each by the stacks that hold it, and the walk stops at the first one shown: a day
/// whose first row is shown costs what an `EXISTS` would, however many rows it holds.
private nonisolated func anniversaryMatch(
    for day: CalendarDay,
    scope: CatalogScopePredicate,
    stacks: AnniversaryStacks,
    db: Database
) throws -> AnniversaryMatch? {
    if let years = AnniversaryMatch.years(for: day),
       let query = try CatalogQueryGateway.anniversaryRowsQuery(scope: scope, match: years)
    {
        let rows = try StackJudgedRows.cursor(query, db: db)
        while let row = try rows.next() {
            let built = try stacks.judging([row], rootIDs: scope.rootIDs, db: db)
            guard let rootPath = built.rootPaths[row.libraryRootID] else {
                continue
            }
            if OnThisDayPicks.shows(MediaAssetID(libraryRootPath: rootPath, relativePath: row.relativePath), stacks: built.stacks) {
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
    // The narrowest index that holds the scope's rows (`ScopeClause.Seek`); a content key
    // below names fewer rows than a batch, so it takes over, and a key names fewer than a day
    // or an area.
    var keyIndex: String?
    if let importBatchUnixMs = scope.importBatchUnixMs {
        arguments.append(importBatchUnixMs)
        predicate += "\n  AND media_asset.import_batch_unix_ms = ?"
        keyIndex = "idx_media_asset_import_batch"
    }
    // A combined scope shows one copy of each set of identical copies (ADR 0054): a row
    // whose shown copy is in a root of the scope stands aside for it. `shown_copy_root_id`
    // is kept by the catalog's triggers, and the date indexes carry it (v60), so the test
    // reads no table row.
    if scope.showsOneCopy {
        predicate += """

          AND (media_asset.shown_copy_root_id IS NULL
               OR media_asset.shown_copy_root_id NOT IN (\(sqlPlaceholders(count: scope.rootIDs.count))))
        """
        arguments.append(contentsOf: scope.rootIDs)
    }
    // A duplicate's digest must be current for its file; the group subquery repeats the
    // visibility rules so a copy waiting for the Trash makes no one else a duplicate. The
    // group subquery walks only the rows that have a current digest, in digest order, so it
    // groups without a temporary B-tree over every row of the scope
    // (`docs/research/2026-11-14-owner-scale-query-plans.md`), and the scope's rows are then
    // sought by the digests it found: walking every row of the catalog to test it against
    // the groups read 150,000–190,000 pages for 126 copies on the owner's catalog
    // (`docs/research/2026-11-15-proportional-small-scopes.md`).
    switch scope.content {
    case .any:
        break
    case let .duplicated(reach):
        let shared = DuplicatesReachSQL.shared(
            row: "media_asset", twin: "twin", reach: reach,
            twinFilter: """
            twin.library_root_id IN (\(sqlPlaceholders(count: scope.rootIDs.count)))
                AND \(DuplicatesGateway.countsAsCopy("twin"))
            """
        )
        predicate += """

          AND \(DuplicatesGateway.countsAsCopy("media_asset"))
          AND \(shared)
        """
        arguments.append(contentsOf: scope.rootIDs)
        keyIndex = ContentDigestSQL.indexName
    case let .identical(digest):
        predicate += "\n  AND \(ContentDigestSQL.isCurrent("media_asset"))\n  AND media_asset.content_sha1 = ?"
        arguments.append(digest.data)
        keyIndex = ContentDigestSQL.indexName
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
        keyIndex = mediaAssetKeyIndexName
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
        // A person's photos are named by their faces (`idx_face_person_photo`), and each is
        // then found by its key: a person is a few dozen to a few thousand photos, and
        // testing every row of the catalog for one of their faces read 3,500–157,000 pages
        // per read on the owner's catalog
        // (`docs/research/2026-11-15-small-scope-reads-and-tile-waits.md`).
        predicate += """

          AND (media_asset.library_root_id, media_asset.relative_path) IN (
              SELECT face.library_root_id, face.relative_path FROM face
              WHERE face.person_id = ? AND face.is_not_face = 0
          )
        """
        arguments.append(person)
        keyIndex = mediaAssetKeyIndexName
    }
    if let anniversary {
        predicate += "\n  AND \(anniversary.sql(row: "media_asset"))"
        arguments.append(contentsOf: anniversary.arguments)
        predicate += OnThisDayPicks.exclusionSQL
        keyIndex = keyIndex ?? AnniversaryMatch.indexName
    }
    var seek = keyIndex.map(ScopeClause.Seek.rows(index:))
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
        // The cells the box covers hold every row inside it (`PlaceCellSQL.cells`), so an
        // area no key narrows is sought through the cell index and each row tested by its
        // own coordinate: walking the date index tested every row of the catalog, 56,000
        // pages for 283 rows of Helsinki on the owner's catalog.
        let cells = PlaceCellSQL.cells(covering: area)
        predicate += """

          AND asset_metadata.place_cell_latitude IS NOT NULL AND asset_metadata.place_cell_longitude IS NOT NULL
          AND asset_metadata.place_cell_latitude BETWEEN ? AND ?
          AND (asset_metadata.place_cell_longitude >= ? \(longitude) asset_metadata.place_cell_longitude <= ?)
        """
        arguments.append(contentsOf: [cells.south, cells.north, cells.west, cells.east])
        seek = seek ?? .placeCells
    }
    return ScopeClause(join: join, sql: predicate, arguments: arguments, seek: seek)
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
        contentHash: (row["content_sha1"] as Data?).flatMap(ContentDigest.init(data:)),
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
