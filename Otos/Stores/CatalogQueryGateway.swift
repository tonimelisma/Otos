import CoreGraphics
import Foundation
import GRDB
import MediaMetadata
import SQLite3

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
    static let metadataExtraSQL = "SELECT metadata_extra_json FROM asset_metadata WHERE \(AssetKey.exactText())"

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
            sql: Self.metadataExtraSQL,
            arguments: AssetKey(rootID: libraryRootID, path: relativePath).arguments
        )?["metadata_extra_json"]
        return try json.map(CatalogStore.decodeMetadataExtraJSON)
    }

    /// `captureLocalTime` is carried alongside identity purely as a day-grouping
    /// key for the grid (DES-069) — a single scalar already read by the index
    /// for `ORDER BY`, not a step toward per-asset detail in window state.
    /// `nil` under any sort other than `.bestDate`: the value is date-contiguous
    /// only under that sort, so callers that don't ask for it don't pay to
    /// read it: the query selects NULL in its place (`orderedAssetIDQuery`).
    static func fetchOrderedAssetIDRows(
        descriptor: CatalogQueryDescriptor,
        scope: CatalogScopePredicate,
        stacks: AnniversaryStacks,
        db: Database
    ) throws -> [OrderedAssetIDRow] {
        guard let clause = try scopeClause(scope, stacks: stacks, ordering: true, db: db) else {
            return []
        }
        return try fetchOrderedAssetIDRows(descriptor: descriptor, scope: scope, clause: clause, db: db)
    }

    private static func fetchOrderedAssetIDRows(
        descriptor: CatalogQueryDescriptor,
        scope: CatalogScopePredicate,
        clause: ScopeClause,
        db: Database
    ) throws -> [OrderedAssetIDRow] {
        let query = orderedAssetIDQuery(descriptor: descriptor, scope: scope, clause: clause)
        // Read by position, in `orderedAssetIDQuery`'s column order: a name lookup per column
        // per row is the read's own cost on a large order. Each row is mapped as the cursor
        // reaches it, so no copy of every row is made first, and the order is built in mapped
        // regions (`MappedArrayBuilder`).
        let likedColumn = scope.requiresLocation ? 5 : 3
        let burstColumn: Int? = clause.seek != nil ? likedColumn + (scope.isAnniversary ? 1 : 0) : nil
        return try MappedArrayBuilder.collect(Row.fetchCursor(
            db,
            sql: query.sql,
            arguments: query.arguments
        )) { row in
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
        }
    }

    /// The order's rows and the stacks that judge them, in the caller's read (`db`), so every
    /// stack and row comes from one snapshot (ADR 0052). `held` — every stack of
    /// `stackRootPaths`' roots, which the caller holds while nothing they are built from
    /// moved — is used when given. Otherwise a scope whose reads seek its rows
    /// (`ScopeClause.Seek`) reads its rows first and, while they are at most
    /// `PhotoStackSQL.rowsSpanMostRows`, builds only the stacks that hold them
    /// (`PhotoStackSQL.build(rootPaths:holding:pairing:db:)`); more rows, and a scope whose reads walk
    /// the order, build every stack of its roots: a build from thousands of rows' folders reads
    /// about every candidate and costs more than reading them all does
    /// (`docs/research/2026-11-15-large-narrow-scopes.md`,
    /// `docs/research/2026-11-17-a-persons-photos-in-order.md`).
    static func readOrder(
        descriptor: CatalogQueryDescriptor,
        scope: CatalogScopePredicate,
        stackRootPaths: [Int64: LibraryRootPath],
        held: PhotoStackSQL.Built?,
        pairing: RawPairing,
        db: Database
    ) throws -> (rows: [OrderedAssetIDRow], stacks: PhotoStackSQL.Built) {
        guard let clause = try scopeClause(
            scope, stacks: held.map(AnniversaryStacks.built) ?? .readWhenNeeded(pairing), ordering: true, db: db
        ) else {
            return try ([], held ?? PhotoStackSQL.build(rootPaths: stackRootPaths, holding: [], pairing: pairing, db: db))
        }
        if held == nil, clause.seek != nil {
            let rows = try fetchOrderedAssetIDRows(descriptor: descriptor, scope: scope, clause: clause, db: db)
            guard rows.count <= PhotoStackSQL.rowsSpanMostRows else {
                return try (rows, PhotoStackSQL.build(rootPaths: stackRootPaths, pairing: pairing, db: db))
            }
            return try (rows, PhotoStackSQL.build(rootPaths: stackRootPaths, holding: rows, pairing: pairing, db: db))
        }
        let stacks = try held ?? PhotoStackSQL.build(rootPaths: stackRootPaths, pairing: pairing, db: db)
        return try (fetchOrderedAssetIDRows(descriptor: descriptor, scope: scope, clause: clause, db: db), stacks)
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
        /// its rows (`PhotoStackSQL.build(rootPaths:holding:pairing:db:)`).
        var burstIdentifier: String?
    }

    /// `db` is the read's own transaction: a scope with a date dimension decides its
    /// anniversary match there (`scopeClause`), judging stacks by `stacks`, so the match and
    /// the rows come from one snapshot.
    static func orderedAssetIDQuery(
        descriptor: CatalogQueryDescriptor,
        scope: CatalogScopePredicate,
        stacks: AnniversaryStacks,
        db: Database
    ) throws -> SQLQuery? {
        try scopeClause(scope, stacks: stacks, ordering: true, db: db).map { clause in
            orderedAssetIDQuery(descriptor: descriptor, scope: scope, clause: clause)
        }
    }

    private static func orderedAssetIDQuery(
        descriptor: CatalogQueryDescriptor,
        scope: CatalogScopePredicate,
        clause scopeClause: ScopeClause
    ) -> SQLQuery {
        if case let .personPhotos(person) = scopeClause.seek {
            return PersonPhotoSQL.orderQuery(descriptor: descriptor, person: person, clause: scopeClause)
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
        let chosen = scopeClause.seek == nil && ChosenRowsSQL.seeks(descriptor.filter)
        let filterSQL = (filter.sql.map { "\n  AND \($0)" } ?? "") + (chosen ? "\n  AND \(ChosenRowsSQL.predicate)" : "")
        let from = chosen
            ? "media_asset INDEXED BY \(ChosenRowsSQL.indexName)\(scopeClause.join)"
            : scopeClause.seekFrom ?? "media_asset INDEXED BY \(order.indexName)\(scopeClause.join)"
        let locationColumns = scope.requiresLocation
            ? ", asset_metadata.primary_latitude, asset_metadata.primary_longitude"
            : ""
        // The capture time is read only where the order is by date, from the date index's key:
        // the day buckets and a keyed re-read's placement need it under that order alone, and
        // no other order index holds it. Read under the name or size order, it was the table
        // row of every row returned: 20,317 pages for All Media's 20,325 videos by name on the
        // owner's catalog, 1.1 s cold, against 6,271 without it
        // (`docs/research/2026-11-17-every-order-the-window-asks-for.md`). Under the likeness
        // order, which walks a date index, it is not read either: nothing groups by it.
        let captureColumn = descriptor.effectiveSort.field == .bestDate ? "media_asset.best_capture_local" : "NULL"
        // Read by position in `fetchOrderedAssetIDRows`: keep this column order.
        let likedColumn = scope.isAnniversary ? ", media_asset.media_choice = 'liked' AS is_liked" : ""
        // A sought scope's stacks are built from its rows, so its rows carry their stills' bursts.
        let burstColumn = scopeClause.seek != nil
            ? ", CASE WHEN media_asset.best_kind IN ('raw', 'image') THEN media_asset.burst_identifier END"
            : ""
        // A wide scope walks the order's index, which hands its rows over in order. A narrow
        // scope seeks its own rows and sorts the few it finds: walking the order index for them
        // reads every row of the catalog (`ScopeClause.Seek`). So does a wide scope filtered to
        // chosen rows (`ChosenRowsSQL`).
        return SQLQuery(
            sql: """
            SELECT media_asset.library_root_id, media_asset.relative_path, \(captureColumn)\(locationColumns)\(likedColumn)\(burstColumn)
            FROM \(from)
            WHERE \(scopeClause.sql)\(filterSQL)
            ORDER BY \(order.orderBy)
            """,
            arguments: StatementArguments(arguments)
        )
    }

    /// The rows of `scope` that `match` selects and On This Day's exclusion leaves in, by key,
    /// with their stills' bursts (`StackJudgedRows`): what the years-or-months match judges
    /// (`anniversaryMatch`), sought through the day's index however many rows the day holds: the
    /// match stops at the first row shown, which a seek reaches first. Nil when the scope
    /// selects nothing.
    static func anniversaryRowsQuery(scope: CatalogScopePredicate, match: AnniversaryMatch) throws -> SQLQuery? {
        guard !scope.selectsNothing, let clause = try scopeClause(scope, anniversary: match, seeks: true) else {
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

    /// Counts each row of `scope` into `tally` (`CatalogFilterOptionTally`): its id, its file
    /// type and the map cell of its coordinate. False for a scope that selects nothing, which
    /// counts no row. Each row is read from the statement by position, with no GRDB row value
    /// per column (`FilterOptionColumns`), its type compared by its bytes with the last row's,
    /// and its id and slots appended to the tally's columns, built in mapped regions; runs of one
    /// type or cell are counted at their end. A row makes no string and no heap copy, and All
    /// Media's read costs about what SQLite's walk does
    /// (`docs/research/2026-11-17-bench-flag-filter-options-and-pairs.md`).
    static func tallyFilterOptionRows(
        scope: CatalogScopePredicate,
        into tally: inout CatalogFilterOptionTally,
        pairing: RawPairing,
        db: Database
    ) throws -> Bool {
        guard let query = try filterOptionRowsQuery(scope: scope, pairing: pairing, db: db) else {
            return false
        }
        let statement = try db.cachedStatement(sql: query.sql)
        let sqlite = statement.sqliteStatement
        // The tally's columns, built in mapped regions and made once at their length
        // (`MappedArrayBuilder`).
        var rowIDs = MappedArrayBuilder<Int64>()
        var typeOfRow = MappedArrayBuilder<UInt16>()
        var cellOfRow = MappedArrayBuilder<UInt32>()
        var types = FilterOptionColumns.Types()
        var typeSlots: [UInt16] = []
        // Rows of one type and of one cell come in runs (the walk is by folder), so a row takes
        // the last row's slots unless its own differ, and each run is counted once, at its end.
        var lastSeen = -1
        var type = CatalogFilterOptionTally.TypeRun(slot: tally.typeSlot(nil))
        var cell: PlaceCell?
        var cellRun = CatalogFilterOptionTally.CellRun(slot: tally.cellSlot(nil))
        // `forEach` steps the statement with GRDB's checks, and makes no value of a row.
        try Row.fetchCursor(statement, arguments: query.arguments).forEach { _ in
            let seen = types.index(of: sqlite)
            if seen != lastSeen {
                while typeSlots.count <= seen {
                    typeSlots.append(tally.typeSlot(types.type(at: typeSlots.count)))
                }
                lastSeen = seen
                if typeSlots[seen] != type.slot {
                    tally.count(type)
                    type = CatalogFilterOptionTally.TypeRun(slot: typeSlots[seen])
                }
            }
            let rowCell = FilterOptionColumns.cell(sqlite)
            if rowCell != cell {
                cell = rowCell
                tally.count(cellRun)
                cellRun = CatalogFilterOptionTally.CellRun(slot: tally.cellSlot(rowCell))
            }
            type.rows += 1
            cellRun.rows += 1
            rowIDs.append(FilterOptionColumns.rowID(sqlite))
            typeOfRow.append(type.slot)
            cellOfRow.append(cellRun.slot)
        }
        tally.count(type)
        tally.count(cellRun)
        tally.take(rowIDs: rowIDs.finish(), types: typeOfRow.finish(), cells: cellOfRow.finish())
        return true
    }

    /// Each row of `scope` with what it gives the options: what a keyed re-read reads for the
    /// few rows its changes name (`CatalogStore.filterOptionsOfRows`).
    static func filterOptionRows(
        scope: CatalogScopePredicate,
        pairing: RawPairing,
        db: Database
    ) throws -> [CatalogFilterOptionTally.Row] {
        guard let query = try filterOptionRowsQuery(scope: scope, pairing: pairing, db: db) else {
            return []
        }
        let statement = try db.cachedStatement(sql: query.sql)
        let sqlite = statement.sqliteStatement
        var types = FilterOptionColumns.Types()
        var rows: [CatalogFilterOptionTally.Row] = []
        try Row.fetchCursor(statement, arguments: query.arguments).forEach { _ in
            let seen = types.index(of: sqlite)
            rows.append(CatalogFilterOptionTally.Row(
                rowID: FilterOptionColumns.rowID(sqlite),
                fact: CatalogFilterOptionTally.Fact(type: types.type(at: seen), cell: FilterOptionColumns.cell(sqlite))
            ))
        }
        return rows
    }

    /// The options' read: every row of the scope with its row id, its kind and format, and the
    /// coordinate found by the row's key in `LocationIndexSQL`'s index when it is located, so no
    /// table row of either table is read. The coordinate's cell is the one the stored cell
    /// columns are generated by (`PlaceCellSQL.cell`), computed as the row is read
    /// (`FilterOptionColumns.cell`): evaluated by SQLite, the expression was a third of All
    /// Media's read (`docs/research/2026-11-17-bench-flag-filter-options-and-pairs.md`). A narrow scope
    /// (`ScopeClause.Seek`) reaches its rows through its seek; a wide scope walks
    /// `idx_media_asset_stack_candidate`, led by the root, which holds the kind, the format, the
    /// key and what tests a row's visibility: the date order index holds no format, so walking
    /// it would read every table row. Starting from the named cells instead read every located
    /// row of the catalog through its table row — 168,765 pages, 8.4 s cold for All Media on
    /// the owner's catalog against 6,748 pages walking an index
    /// (`docs/research/2026-11-16-window-reads-owner-catalog.md`) — and 21 s for an import
    /// batch of 210 rows (`docs/research/2026-11-15-keyed-scope-query-plans.md`). The join
    /// order is fixed: the planner cannot tell a wide scope from a keyed one.
    static func filterOptionRowsQuery(scope: CatalogScopePredicate, pairing: RawPairing, db: Database) throws -> SQLQuery? {
        guard let scopeClause = try scopeClause(scope, stacks: .readWhenNeeded(pairing), db: db) else {
            return nil
        }
        let rows = scopeClause.seekFrom ?? "media_asset INDEXED BY \(PhotoStackSQL.candidateIndexName)\(scopeClause.join)"
        return SQLQuery(
            sql: """
            SELECT media_asset.rowid, media_asset.best_kind, media_asset.best_format,
                   place_metadata.primary_latitude, place_metadata.primary_longitude
            FROM \(rows)
            LEFT JOIN asset_metadata AS place_metadata INDEXED BY \(LocationIndexSQL.indexName)
              ON place_metadata.library_root_id = media_asset.library_root_id
              AND place_metadata.relative_path = media_asset.relative_path
              AND \(LocationIndexSQL.locatedSQL(row: "place_metadata"))
            WHERE \(scopeClause.sql)
            """,
            arguments: StatementArguments(scopeClause.arguments)
        )
    }

    /// The names Maps gave `cells` in `language`, each by one seek of its key: a scope's
    /// options read the names of the cells its rows give, so an import of 254 rows reads at most
    /// its own cells' names, not the 1,435 named cells of the owner's catalog. A cell with no
    /// name in `language` has none.
    static func placeCellNames(of cells: some Sequence<PlaceCell>, language: PlaceNameLanguage, db: Database) throws -> [PlaceCell: PlaceNames] {
        let statement = try db.cachedStatement(sql: placeCellNameSQL)
        var names: [PlaceCell: PlaceNames] = [:]
        for cell in cells {
            if let row = try Row.fetchOne(statement, arguments: [cell.latitude, cell.longitude, language.identifier]) {
                names[cell] = PlaceNames(country: row[0], town: row[1])
            }
        }
        return names
    }

    /// One cell's name in a language, by the cell's key (binds latitude, longitude, language).
    static let placeCellNameSQL = "SELECT country, town FROM place_cell WHERE cell_latitude = ? AND cell_longitude = ? AND language = ?"

    /// The row id of the row at a key; a key with no row has none.
    static let rowIDOfKeySQL = "SELECT rowid FROM media_asset WHERE \(AssetKey.exactText())"

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

    /// The cells of `count` rows of one root with no name in the language argued, by key;
    /// binds the root, the paths, the language.
    static func unnamedPlaceCellsOfRowsSQL(count: Int) -> String {
        """
        SELECT DISTINCT place_cell_latitude, place_cell_longitude FROM asset_metadata AS cells
        WHERE library_root_id = ?
          AND relative_path IN (\(Array(repeating: "?", count: count).joined(separator: ",")))
          AND place_cell_latitude IS NOT NULL AND place_cell_longitude IS NOT NULL
          AND NOT EXISTS (
            SELECT 1 FROM place_cell
            WHERE place_cell.cell_latitude = cells.place_cell_latitude
              AND place_cell.cell_longitude = cells.place_cell_longitude
              AND place_cell.language = ?
          )
        """
    }

    /// The count of a scope other than On This Day's (whose count judges its stacks in
    /// Swift, `countAssets`); a narrow scope counts from its seek (`ScopeClause.from`).
    static func countQuery(
        scope: CatalogScopePredicate,
        filter: MediaFilter = .all,
        pairing: RawPairing,
        db: Database
    ) throws -> SQLQuery? {
        guard let scopeClause = try scopeClause(scope, stacks: .readWhenNeeded(pairing), db: db) else {
            return nil
        }
        let filterPredicate = filterPredicate(for: filter)
        let chosen = scopeClause.seek == nil && ChosenRowsSQL.seeks(filter)
        let filterSQL = (filterPredicate.sql.map { "\n  AND \($0)" } ?? "") + (chosen ? "\n  AND \(ChosenRowsSQL.predicate)" : "")
        let from = chosen ? "media_asset INDEXED BY \(ChosenRowsSQL.indexName)\(scopeClause.join)" : scopeClause.from
        return SQLQuery(
            sql: """
            SELECT COUNT(*)
            FROM \(from)
            WHERE \(scopeClause.sql)\(filterSQL)
            """,
            arguments: StatementArguments(scopeClause.arguments + filterPredicate.arguments)
        )
    }

    /// Rows in scope, optionally narrowed by the user filter. On This Day's are the rows it
    /// shows (`OnThisDayPicks.shows`), so its empty state never counts a file of a stack
    /// whose key is Disliked: a scope whose cards are all left out reads as nothing on this
    /// day, never as a filter's doing or an offline library's. The match and the count each
    /// judge their rows by stacks built in this read (`AnniversaryStacks.judging`): the count's
    /// are the stacks that hold its rows when the scope seeks them, every stack of its roots
    /// when it walks.
    static func countAssets(
        scope: CatalogScopePredicate,
        filter: MediaFilter = .all,
        pairing: RawPairing,
        db: Database
    ) throws -> Int {
        guard scope.isAnniversary, !scope.selectsNothing else {
            guard let query = try countQuery(scope: scope, filter: filter, pairing: pairing, db: db) else {
                return 0
            }
            return try Int.fetchOne(db, sql: query.sql, arguments: query.arguments) ?? 0
        }
        guard let scopeClause = try scopeClause(scope, stacks: .readWhenNeeded(pairing), db: db) else {
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
        let picks = try AnniversaryStacks.readWhenNeeded(pairing).judging(
            rows, rootIDs: scope.rootIDs, span: scopeClause.seek != nil ? .rows : .roots, db: db
        )
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
        let idsByRootPath = Dictionary(exactlyGrouping: ids, by: \.libraryRootPath)
        var assets: [StoredAsset] = []
        assets.reserveCapacity(ids.count)

        for (rootPath, idsForRoot) in idsByRootPath {
            guard let rootID = rootIDsByPath[rootPath] else {
                continue
            }
            let relativePaths = idsForRoot.map(\.relativePath.rawValue)
            let placeholders = sqlPlaceholders(count: relativePaths.count)
            var argumentValues: [any DatabaseValueConvertible] = []
            argumentValues.reserveCapacity(relativePaths.count + 1)
            argumentValues.append(rootID)
            argumentValues.append(contentsOf: relativePaths)
            let rows = try Row.fetchCursor(
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
            while let row = try rows.next() {
                assets.append(storedAsset(from: row))
            }
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
        let idsByRootPath = Dictionary(exactlyGrouping: ids, by: \.libraryRootPath)
        var details: [StoredTileDetail] = []
        details.reserveCapacity(ids.count)

        for (rootPath, idsForRoot) in idsByRootPath {
            guard let rootID = rootIDsByPath[rootPath] else {
                continue
            }
            let relativePaths = idsForRoot.map(\.relativePath.rawValue)
            let placeholders = sqlPlaceholders(count: relativePaths.count)
            var argumentValues: [any DatabaseValueConvertible] = []
            argumentValues.reserveCapacity(relativePaths.count + 1)
            argumentValues.append(rootID)
            argumentValues.append(contentsOf: relativePaths)
            let rows = try Row.fetchCursor(
                db,
                sql: """
                SELECT m.library_root_id, m.relative_path, m.byte_size,
                       m.rendered_source_size, m.rendered_source_mtime, m.thumbnail_path, m.preview_path,
                       m.duration_seconds, m.best_kind, m.media_choice,
                       m.edit_recipe_json, m.rendered_revision,
                       m.copy_key AS copy_key,
                       a.pixel_width, a.pixel_height, a.orientation
                FROM media_asset m
                LEFT JOIN asset_metadata a
                  ON a.library_root_id = m.library_root_id AND a.relative_path = m.relative_path
                WHERE m.library_root_id = ? AND m.relative_path IN (\(placeholders))
                """,
                arguments: StatementArguments(argumentValues)
            )
            while let row = try rows.next() {
                try details.append(storedTileDetail(from: row))
            }
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
    /// stack counts once) for the batches `counting` names, and no count for the rest. A batch counts as its grid does: its rows collapsed by the
    /// stacks that hold them (`PhotoStackSQL.build(rootPaths:holding:pairing:db:)`), so a RAW+JPEG
    /// pair imported together is one photo, and a pair whose files came in two batches is a
    /// file in each.
    static func fetchImportBatches(
        counting: ImportBatchCounting,
        rootPaths: [Int64: LibraryRootPath],
        pairing: RawPairing,
        db: Database
    ) throws -> [ImportBatchSummary] {
        let ids = try Int64.fetchAll(db.cachedStatement(sql: importBatchIDsSQL)).map(ImportBatchID.init(unixMilliseconds:))
        let counted = counting.batches(ids)
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
        var held: [OrderedAssetIDRow] = []
        held.reserveCapacity(rowsByBatch.values.reduce(0) { $0 + $1.count })
        for rows in rowsByBatch.values {
            held += rows
        }
        let stacks = try PhotoStackSQL.build(rootPaths: rootPaths, holding: held, pairing: pairing, db: db).stacks
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

    static let captureWallSQL = """
    SELECT capture_wall_compact, capture_wall_precision
    FROM media_asset
    WHERE \(AssetKey.exactText())
    """

    static func fetchCaptureWall(
        id: MediaAssetID,
        rootRowID: Int64,
        db: Database
    ) throws -> CaptureWallClock.Selection? {
        guard let row = try Row.fetchOne(
            db,
            sql: captureWallSQL,
            arguments: AssetKey(rootID: rootRowID, path: id.relativePath).arguments
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

/// A face test of a photo, not of one of its copies (ADR 0054; owner, 2026-11-15: a face
/// named on one copy names the photo). Faces are read from each copy's own preview and stay
/// on it, so a test of a row asks its own faces, and then — only for a row with a present
/// copy (`has_copies`, which the window's indexes carry) — its copies' faces, through the
/// copy key's index. A row with no copy costs what it did. `condition` is over `face`, and its
/// arguments are bound twice, in order.
nonisolated enum PhotoFaceSQL {
    /// Whether `row` or a present copy of it holds a face `condition` selects; `index` is the
    /// face index a seek by photo reads, when the planner must be told.
    static func holds(_ row: String, index: String? = nil, condition: String) -> String {
        let face = index.map { "face INDEXED BY \($0)" } ?? "face"
        return """
        (EXISTS (
            SELECT 1 FROM \(face)
            WHERE face.library_root_id = \(row).library_root_id
              AND face.relative_path = \(row).relative_path
              AND \(condition)
        ) OR (\(row).has_copies = 1 AND EXISTS (
            SELECT 1 FROM media_asset AS face_copy INDEXED BY \(PhotoCopySQL.indexName)
            CROSS JOIN \(face)
              ON face.library_root_id = face_copy.library_root_id AND face.relative_path = face_copy.relative_path
            WHERE \(PhotoCopySQL.isCopy("face_copy", of: row))
              AND \(CatalogVisibilitySQL.isPresent("face_copy"))
              AND NOT (face_copy.library_root_id = \(row).library_root_id AND face_copy.relative_path = \(row).relative_path)
              AND \(condition)
        )))
        """
    }

    /// The keys of the rows that hold a face `condition` selects, and of every present copy of
    /// such a row: the photos a person's narrow scope seeks. One select, not a compound one:
    /// SQLite seeks a row's key in a compound `IN` list by its first column alone, which read
    /// a whole root for a person of 24 photos.
    static func photos(condition: String) -> String {
        """
        SELECT COALESCE(face_copy.library_root_id, face.library_root_id), COALESCE(face_copy.relative_path, face.relative_path)
        FROM face
        LEFT JOIN media_asset AS face_photo INDEXED BY \(mediaAssetKeyIndexName)
          ON face_photo.library_root_id = face.library_root_id AND face_photo.relative_path = face.relative_path
        LEFT JOIN media_asset AS face_copy INDEXED BY \(PhotoCopySQL.indexName)
          ON face_photo.has_copies = 1
          AND \(PhotoCopySQL.isCopy("face_copy", of: "face_photo"))
          AND \(CatalogVisibilitySQL.isPresent("face_copy"))
        WHERE \(condition)
        """
    }

    /// Every present copy of the photo whose files share the bound copy key: the copies People
    /// resolves a photo's faces through (`PeopleSnapshot.copies`), asked for each key of a
    /// file with a face and `has_copies`, read with the file's faces
    /// (`PeopleFaceColumn.copiedKey`). The same relation as `holds` — a row with
    /// `has_copies`, its copies through the copy key's index — so the faces People shows on a photo
    /// are the faces its scopes find it by. A file with no copy costs nothing here: the faces'
    /// own read has already sought it by its key.
    static let presentCopiesOfKey = """
    SELECT face_copy.library_root_id, face_copy.relative_path
    FROM media_asset AS face_copy INDEXED BY \(PhotoCopySQL.indexName)
    WHERE \(PhotoCopySQL.isCopy("face_copy", ofKey: "?"))
      AND \(CatalogVisibilitySQL.isPresent("face_copy"))
    """
}

/// A person's photos in the window's order (ADR 0047, "A person's photos"; schema v78): the
/// person's own rows of `person_photo`, read as `media_asset`, and the photos the person is in
/// only through a copy (ADR 0054), merged in one order.
///
/// The person's rows are one range of the table's key, so the read visits only them and
/// sorts what it finds: a few photos, or the 17,000 of the most photographed person — 803
/// pages cold, 10–98 ms, on a generated catalog of the owner's shape, where walking the
/// catalog's order index to test each of its rows read 7,881 pages in 907 ms
/// (`docs/research/2026-11-17-a-persons-photos-in-order.md`). The photos through a copy are
/// the present copies of the person's photos that have copies (`idx_person_photo_copies`),
/// which hold no face of the person themselves: the relation `PhotoFaceSQL.holds` tests, from
/// the face's side. The two are one compound select, so SQLite merges the two orders; the
/// copies' rows are few, and a copy found from two of the person's photos is one row.
nonisolated enum PersonPhotoSQL {
    /// The table's key, `(person_id, library_root_id, relative_path)`: a person's rows are one
    /// range of it. SQLite names a constraint's index itself, and `INDEXED BY` accepts that name.
    static let keyIndexName = "sqlite_autoindex_person_photo_1"
    static let copiesIndexName = "idx_person_photo_copies"

    /// The copies index's condition. The read through it states it literally: SQLite uses a
    /// partial index only for a condition it can prove at prepare.
    static let copiesPredicate = "has_copies = 1"

    fileprivate static func orderQuery(descriptor: CatalogQueryDescriptor, person: PersonID, clause: ScopeClause) -> SQLQuery {
        let sort = descriptor.effectiveSort
        let direction = sort.direction.sqlKeyword
        let filter = filterPredicate(for: descriptor.filter)
        let filterSQL = filter.sql.map { "\n  AND \($0)" } ?? ""
        // The likeness of the person's first face on the photo; a photo the person is in only
        // through a copy holds none, and goes last.
        let likeness = """
        (SELECT face.likeness FROM face WHERE face.person_id = ? \
        AND face.library_root_id = media_asset.library_root_id AND face.relative_path = media_asset.relative_path)
        """
        let keys: (columns: String, orderBy: String, arguments: [any DatabaseValueConvertible]) = switch sort.field {
        case .bestDate:
            ("media_asset.best_capture_local AS order_key", "order_key \(direction)", [])
        case .name:
            ("media_asset.name_sort_key AS order_key", "order_key \(direction)", [])
        case .size:
            (
                "(media_asset.byte_size IS NULL) AS order_absent, media_asset.byte_size AS order_key",
                "order_absent, order_key \(direction)",
                []
            )
        case .likeness:
            (
                "(\(likeness) IS NULL) AS order_absent, \(likeness) AS order_key, media_asset.best_capture_local AS order_tie",
                "order_absent, order_key \(direction), order_tie DESC",
                [person.rawValue, person.rawValue]
            )
        }
        let captureColumn = sort.field == .bestDate ? "media_asset.best_capture_local" : "NULL"
        // Read by position in `fetchOrderedAssetIDRows`, as the other order reads are: the key,
        // the capture time, the still's burst; the order's keys follow.
        let columns = """
        media_asset.library_root_id AS library_root_id, media_asset.relative_path AS relative_path, \(captureColumn), \
        CASE WHEN media_asset.best_kind IN ('raw', 'image') THEN media_asset.burst_identifier END, \(keys.columns)
        """
        var arguments = keys.arguments + clause.arguments + filter.arguments + [person.rawValue]
        arguments += keys.arguments + [person.rawValue, person.rawValue] + clause.arguments + filter.arguments
        return SQLQuery(
            sql: """
            SELECT \(columns)
            FROM person_photo AS media_asset INDEXED BY \(keyIndexName)
            WHERE \(clause.sql)\(filterSQL)
              AND media_asset.person_id = ?
            UNION
            SELECT \(columns)
            FROM person_photo AS member INDEXED BY \(copiesIndexName)
            CROSS JOIN media_asset AS member_photo INDEXED BY \(mediaAssetKeyIndexName)
              ON member_photo.library_root_id = member.library_root_id AND member_photo.relative_path = member.relative_path
            CROSS JOIN media_asset INDEXED BY \(PhotoCopySQL.indexName)
              ON \(PhotoCopySQL.isCopy("member_photo", of: "media_asset"))
            WHERE member.person_id = ? AND member.\(copiesPredicate)
              AND \(CatalogVisibilitySQL.isPresent("member_photo"))
              AND NOT (media_asset.library_root_id = member.library_root_id AND media_asset.relative_path = member.relative_path)
              AND media_asset.has_copies = 1
              AND NOT EXISTS (
                  SELECT 1 FROM person_photo AS own
                  WHERE own.person_id = ? AND own.library_root_id = media_asset.library_root_id
                    AND own.relative_path = media_asset.relative_path
              )
              AND \(clause.sql)\(filterSQL)
            ORDER BY \(keys.orderBy), library_root_id, relative_path
            """,
            arguments: StatementArguments(arguments)
        )
    }
}

/// The map cells a located photo falls in (ADR 0051): a fiftieth of a degree each way,
/// `asset_metadata.place_cell_latitude` and `place_cell_longitude`, generated from the
/// primary location (schema v43). The cells are what Maps names, and an area's rows are
/// sought through their index.
/// The columns of a row of `CatalogQueryGateway.filterOptionRowsQuery`, read from the stepped
/// statement by position. The read walks every row of the shown scope — All Media's 159,000 —
/// so a row makes no GRDB value and no string: the row id and coordinate are C reads, and the
/// kind and format are compared by their bytes with the few types already seen, a string made
/// once per distinct type (`Types`).
nonisolated enum FilterOptionColumns {
    static func rowID(_ statement: SQLiteStatement) -> Int64 {
        sqlite3_column_int64(statement, 0)
    }

    /// The cell of the row's coordinate, when it is located: the cell the stored cell columns'
    /// expression gives (`PlaceCellSQL.cell(of:cells:)`).
    static func cell(_ statement: SQLiteStatement) -> PlaceCell? {
        guard sqlite3_column_type(statement, 3) != SQLITE_NULL, sqlite3_column_type(statement, 4) != SQLITE_NULL else {
            return nil
        }
        return PlaceCell(
            latitude: PlaceCellSQL.cell(of: sqlite3_column_double(statement, 3), cells: PlaceCellSQL.latitudeCells),
            longitude: PlaceCellSQL.cell(of: sqlite3_column_double(statement, 4), cells: PlaceCellSQL.longitudeCells)
        )
    }

    /// The file types one read has seen, each by its kind's and format's bytes. A library holds
    /// a few dozen, and rows of one type come in runs, so a row is compared with the last row's
    /// type first: its kind and format, each held as up to 8 bytes in an integer (every kind
    /// and every format MediaMetadata names fits), compared by `memcmp`. Only a row whose type
    /// differs looks among the types seen, and a type is decoded into strings once.
    struct Types {
        private struct Seen {
            let kind: [UInt8]?
            let format: [UInt8]?
            let type: CatalogFilterOptionTally.FileType?
        }

        private var seen: [Seen] = []
        private var last = 0
        /// The last row's kind and format bytes and their lengths: -1 for NULL, and -2 before
        /// the first row and for a value longer than 8 bytes, which never matches.
        private var lastKind: UInt64 = 0
        private var lastKindCount = -2
        private var lastFormat: UInt64 = 0
        private var lastFormatCount = -2

        /// The index of the current row's type among those seen, made seen when it is new.
        mutating func index(of statement: SQLiteStatement) -> Int {
            let kind = sqlite3_column_text(statement, 1)
            let kindCount = kind == nil ? -1 : Int(sqlite3_column_bytes(statement, 1))
            let format = sqlite3_column_text(statement, 2)
            let formatCount = format == nil ? -1 : Int(sqlite3_column_bytes(statement, 2))
            if kindCount == lastKindCount, formatCount == lastFormatCount,
               kindCount <= 0 || memcmp(kind, &lastKind, kindCount) == 0,
               formatCount <= 0 || memcmp(format, &lastFormat, formatCount) == 0
            {
                return last
            }
            let kindBytes = kind.map { Array(UnsafeBufferPointer(start: $0, count: kindCount)) }
            let formatBytes = format.map { Array(UnsafeBufferPointer(start: $0, count: formatCount)) }
            if let found = seen.firstIndex(where: { $0.kind == kindBytes && $0.format == formatBytes }) {
                last = found
            } else {
                let mediaKind = kindBytes.flatMap { MediaKind(rawValue: String(decoding: $0, as: UTF8.self)) }
                seen.append(Seen(
                    kind: kindBytes,
                    format: formatBytes,
                    type: mediaKind.map { kind in
                        CatalogFilterOptionTally.FileType(
                            kind: kind,
                            format: formatBytes.map { MediaFormatToken(rawValue: String(decoding: $0, as: UTF8.self)) }
                        )
                    }
                ))
                last = seen.count - 1
            }
            lastKindCount = kindCount <= 8 ? kindCount : -2
            lastFormatCount = formatCount <= 8 ? formatCount : -2
            if kindCount > 0, kindCount <= 8 {
                memcpy(&lastKind, kind, kindCount)
            }
            if formatCount > 0, formatCount <= 8 {
                memcpy(&lastFormat, format, formatCount)
            }
            return last
        }

        /// The type seen at `index`; nil for a row of no known kind, which gives no type.
        func type(at index: Int) -> CatalogFilterOptionTally.FileType? {
            seen[index].type
        }
    }
}

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

    static let writeNamesSQL = """
    INSERT INTO place_cell (cell_latitude, cell_longitude, country, town, language) VALUES (?, ?, ?, ?, ?)
    ON CONFLICT(cell_latitude, cell_longitude) DO UPDATE SET
        country = excluded.country, town = excluded.town, language = excluded.language
    """

    static let deleteOtherLanguagesSQL = "DELETE FROM place_cell WHERE language <> ?"
}

/// The located rows' coordinates by key (schema v63): what the Places scope's reads join
/// `asset_metadata` through, so a row's coordinate is read from the index and never from its
/// table row, which also holds the metadata record. Partial, so it holds exactly the rows
/// Places requires; a read through it tests a row with the index's own condition, which
/// SQLite requires before it uses a partial index.
nonisolated enum LocationIndexSQL {
    static let indexName = "idx_asset_metadata_location"

    /// A row has a primary location: the index's condition (`CatalogSchema` writes it
    /// unqualified, as an index's expression must be to survive a table rename) and Places'
    /// test.
    static func locatedSQL(row: String) -> String {
        "\(row).primary_latitude IS NOT NULL AND \(row).primary_longitude IS NOT NULL"
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
    /// reads, and what visibility, Duplicates and the Live Photo rule test a row by, an
    /// external library's path checksum among them (v64).
    static let indexedColumns = "\(CatalogSchema.copiesDigestIndexColumns), source_path_sha1"

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

/// Which rows are copies of one photo (ADR 0054): the rows that share a copy key
/// (`media_asset.copy_key`, schema v79). The catalog's triggers keep the key — a row's
/// current digest of some bytes in a library or an account, or the key its mirror pair
/// gives both its rows — so a reader asks only whether two keys are equal, through
/// `idx_media_asset_copy_key`, which holds the key with the row's key and presence.
nonisolated enum PhotoCopySQL {
    static let indexName = "idx_media_asset_copy_key"

    /// Whether `row` is a copy of some photo at all.
    static func isCopy(_ row: String) -> String {
        "\(row).copy_key IS NOT NULL"
    }

    /// Whether `copy` is a copy of the photo `row` is a copy of (`row` itself included),
    /// whatever its presence.
    static func isCopy(_ copy: String, of row: String) -> String {
        "\(copy).copy_key = \(row).copy_key"
    }

    /// Whether `copy` is a copy of the photo whose copies share `key` (a SQL value).
    static func isCopy(_ copy: String, ofKey key: String) -> String {
        "\(copy).copy_key = \(key)"
    }
}

/// The stills that can be in a stack (ADR 0052): every present RAW and processed image in
/// a folder that holds a present RAW and another present still, and every present still
/// carrying a burst identifier, in the given roots, whatever the scope or filter, so
/// a filter that hides one file of a pair never unpairs the other. `PhotoStackRule`
/// decides the stacks from these.
nonisolated enum PhotoStackSQL {
    /// Every row by root, kind and folder, with its format, key and what tests its visibility
    /// (v59): what the candidates are read through, and what the filter's options walk
    /// (`CatalogQueryGateway.filterOptionRowsQuery`).
    static let candidateIndexName = "idx_media_asset_stack_candidate"

    /// The most rows a sought order builds only its own rows' stacks for. Past it, the rows'
    /// folders hold about every candidate of the roots and their build costs more than every
    /// stack's: on a generated catalog of the owner's shape, warm, 174 ms against 177 for a
    /// person's 1,856 photos, 193 against 172 for 3,424, 284 against 186 for 17,284 (715 against
    /// 204 cold), and 27 against 173 for 30
    /// (`docs/research/2026-11-17-a-persons-photos-in-order.md`).
    static let rowsSpanMostRows = 2000

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
    static func build(rootPaths: [Int64: LibraryRootPath], pairing: RawPairing, db: Database) throws -> Built {
        let candidates = try fetchCandidates(rootIDs: rootPaths.keys.sorted(), db: db)
        let ruleStart = ContinuousClock.now
        return Built(
            stacks: CatalogStacks(stacks(of: candidates, rootPaths: rootPaths, pairing: pairing)),
            rootPaths: rootPaths,
            span: .roots,
            candidateCount: candidates.count,
            readDuration: candidates.readDuration,
            ruleDuration: ContinuousClock.now - ruleStart
        )
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
        pairing: RawPairing,
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
        var stacks = stacks(of: candidates, rootPaths: rootPaths, pairing: pairing)
        if !stacks.isEmpty {
            var held = Set<MediaAssetID>(minimumCapacity: rows.count)
            for row in rows {
                if let rootPath = rootPaths[row.libraryRootID] {
                    held.insert(MediaAssetID(libraryRootPath: rootPath, relativePath: row.relativePath))
                }
            }
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

        /// `[[rootID, "name"], …]`, written into one string sized for it: a scope's folders are
        /// thousands of names, and an encoder's growing buffers were freed into malloc
        /// (`MappedArrayBuilder`). A name's quote, backslash and control characters are
        /// escaped; every other character is JSON as it stands.
        static func json(_ names: Set<Self>) -> String {
            var json = "["
            json.reserveCapacity(names.reduce(2) { $0 + $1.name.utf8.count + 26 })
            for (offset, name) in names.enumerated() {
                json += offset == 0 ? "[" : ",["
                json += String(name.rootID)
                json += ",\""
                for scalar in name.name.unicodeScalars {
                    switch scalar {
                    case "\"": json += "\\\""
                    case "\\": json += "\\\\"
                    case _ where scalar.value < 0x20: json += String(format: "\\u%04x", scalar.value)
                    default: json.unicodeScalars.append(scalar)
                    }
                }
                json += "\"]"
            }
            json += "]"
            return json
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

    static func stacks(of candidates: Candidates, rootPaths: [Int64: LibraryRootPath], pairing: RawPairing) -> [PhotoStack] {
        var stacks = MappedArrayBuilder<PhotoStack>()
        for (rowID, rootCandidates) in candidates.byRoot {
            guard let rootPath = rootPaths[rowID] else {
                continue
            }
            for stack in PhotoStackRule.stacks(candidates: rootCandidates, libraryRootPath: rootPath, pairing: pairing) {
                stacks.append(stack)
            }
        }
        return stacks.finish()
    }

    /// The columns `candidateQuery` selects, in order: each row is read by position.
    private enum Column: Int {
        case libraryRootID, relativePath, bestKind, nameKey, keyChosenAt
        case burstIdentifier, captureLocal, choice, burstKeyChosenAt
    }

    static func fetchCandidates(rootIDs: [Int64], db: Database) throws -> Candidates {
        let start = ContinuousClock.now
        guard let query = candidateQuery(rootIDs: rootIDs) else {
            return Candidates(byRoot: [:], count: 0, readDuration: .zero)
        }
        return try fetchCandidates(query: query, start: start, db: db)
    }

    /// The candidates `query` reads, selecting `candidateColumns`.
    static func fetchCandidates(query: SQLQuery, start: ContinuousClock.Instant, db: Database) throws -> Candidates {
        // Prepared once per connection: the text depends only on the root count, and a narrow
        // scope's read runs on every publication of a batch while it imports.
        let rows = try Row.fetchCursor(db.cachedStatement(sql: query.sql), arguments: query.arguments)
        // Read in mapped regions, then each root's candidates into an array of its exact
        // count, in the order read (`MappedArrayBuilder`).
        var read = MappedArrayBuilder<(rootID: Int64, candidate: PhotoStackCandidate)>()
        while let row = try rows.next() {
            let kindValue: String = row[Column.bestKind.rawValue]
            guard let kind = MediaKind(rawValue: kindValue) else {
                continue
            }
            let choice: String = row[Column.choice.rawValue]
            read.append((row[Column.libraryRootID.rawValue], PhotoStackCandidate(
                relativePath: MediaRelativePath(rawValue: row[Column.relativePath.rawValue]),
                kind: kind,
                nameKey: FilesystemNameKey(rawValue: row[Column.nameKey.rawValue]),
                burstIdentifier: row[Column.burstIdentifier.rawValue],
                captureLocal: row[Column.captureLocal.rawValue],
                // The column's CHECK admits only the three choices.
                choice: MediaChoice(rawValue: choice) ?? .default,
                keyChosenAtUnixMs: row[Column.keyChosenAt.rawValue],
                burstKeyChosenAtUnixMs: row[Column.burstKeyChosenAt.rawValue]
            )))
        }
        let count = read.count
        let byRoot = read.withElements { read in
            var counts: [Int64: Int] = [:]
            for element in read {
                counts[element.rootID, default: 0] += 1
            }
            var byRoot = counts.mapValues { count in
                var candidates: [PhotoStackCandidate] = []
                candidates.reserveCapacity(count)
                return candidates
            }
            for element in read {
                byRoot[element.rootID]?.append(element.candidate)
            }
            return byRoot
        }
        return Candidates(byRoot: byRoot, count: count, readDuration: ContinuousClock.now - start)
    }

    /// The columns every candidate read selects from `still`, in `Column`'s order.
    private static let candidateColumns = """
    still.library_root_id, still.relative_path, still.best_kind, still.relative_path_key,
               still.stack_key_chosen_at_unix_ms, still.burst_identifier,
               still.best_capture_local, still.media_choice, still.burst_key_chosen_at_unix_ms
    """

    /// Whether the folder `folder` names (an alias with `library_root_id` and `parent_path`)
    /// holds two or more present stills: a pair is a RAW and a processed still of one folder,
    /// so a folder with fewer can hold none. One seek of `idx_media_asset_stack_candidate`
    /// (root, kind, folder) that stops at the second still. An Immich account stages each
    /// asset in its own folder, so its RAWs are each alone there: on the owner's catalog 10,906
    /// of 10,917 RAW folders, whose stills were 10,906 of 25,944 candidates read for nothing
    /// (`docs/research/2026-11-16-window-reads-owner-catalog.md`).
    private static func holdsTwoStills(_ folder: String) -> String {
        """
        (SELECT count(*) FROM (
                SELECT 1 FROM media_asset AS other INDEXED BY idx_media_asset_stack_candidate
                WHERE other.library_root_id = \(folder).library_root_id
                  AND other.best_kind IN ('raw', 'image')
                  AND other.parent_path = \(folder).parent_path
                  AND \(CatalogVisibilitySQL.isPresent("other"))
                LIMIT 2
            )) = 2
        """
    }

    /// Whether `folder` holds a present RAW, one seek of `idx_media_asset_stack_candidate`.
    private static func holdsRaw(_ folder: String) -> String {
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

    /// Whether `folder` can hold a pair (ADR 0052): a present RAW and another present still.
    /// The one test of a pairing folder every candidate read applies.
    private static func canHoldPair(_ folder: String) -> String {
        "\(holdsRaw(folder)) AND \(holdsTwoStills(folder))"
    }

    /// The candidates' read: the folders that can hold a pair (`canHoldPair`) — the distinct
    /// folders holding a present RAW, each kept when it holds another present still — then
    /// each such folder's present stills, all through `idx_media_asset_stack_candidate` (root,
    /// kind, folder); and every present still carrying a burst identifier in any other
    /// folder, through `idx_media_asset_burst` by name: the planner otherwise picks the
    /// primary key and walks every row of a root. The two arms hold no row in common, so
    /// they are joined without the temporary B-tree a `UNION` sorts every candidate through.
    static func candidateQuery(rootIDs: [Int64]) -> SQLQuery? {
        guard !rootIDs.isEmpty else {
            return nil
        }
        let placeholders = sqlPlaceholders(count: rootIDs.count)
        return SQLQuery(
            sql: """
            WITH raw_folder AS MATERIALIZED (
                SELECT DISTINCT library_root_id, parent_path FROM media_asset INDEXED BY idx_media_asset_stack_candidate
                WHERE library_root_id IN (\(placeholders)) AND best_kind = 'raw'
                  AND \(CatalogVisibilitySQL.isPresent("media_asset"))
            ),
            pairing_folder AS MATERIALIZED (
                SELECT library_root_id, parent_path FROM raw_folder
                WHERE \(holdsTwoStills("raw_folder"))
            )
            SELECT \(candidateColumns)
            FROM pairing_folder
            CROSS JOIN media_asset AS still INDEXED BY idx_media_asset_stack_candidate
              ON still.library_root_id = pairing_folder.library_root_id
              AND still.best_kind IN ('raw', 'image')
              AND still.parent_path = pairing_folder.parent_path
            WHERE \(CatalogVisibilitySQL.isPresent("still"))
            UNION ALL
            SELECT \(candidateColumns)
            FROM media_asset AS still INDEXED BY idx_media_asset_burst
            WHERE still.library_root_id IN (\(placeholders)) AND still.burst_identifier IS NOT NULL
              AND still.best_kind IN ('raw', 'image')
              AND \(CatalogVisibilitySQL.isPresent("still"))
              AND NOT (\(canHoldPair("still")))
            """,
            arguments: StatementArguments(rootIDs + rootIDs)
        )
    }

    /// The candidates of the stacks that can hold some rows, from `folders` (`[[rootID,
    /// folder], …]`: the rows' folders) and `bursts` (`[[rootID, identifier], …]`: the bursts
    /// the rows' stills carry): the present RAWs and processed images of each folder that can
    /// hold a pair (`canHoldPair`); every still of those bursts and of the bursts those
    /// folders' stills carry, through `idx_media_asset_burst`; and the RAWs and processed
    /// images of those stills' folders that can hold a pair. Folders are read through
    /// `idx_media_asset_stack_candidate` (root, kind, folder), and a folder that cannot hold a
    /// pair is never walked: the rows in it name their own bursts. The candidates
    /// `candidateQuery` reads for these folders and bursts, and no others. The join order is
    /// fixed (`CROSS JOIN`): each step starts from the few rows the step before found.
    static func scopedCandidateQuery(folders: String, bursts: String) -> SQLQuery {
        let columns = candidateColumns
        return SQLQuery(
            sql: """
            WITH seed_folder AS (
                SELECT json_extract(seed.value, '$[0]') AS library_root_id,
                       json_extract(seed.value, '$[1]') AS parent_path
                FROM json_each(?) AS seed
            ),
            seed_raw_folder AS (
                SELECT seed_folder.library_root_id, seed_folder.parent_path FROM seed_folder
                WHERE \(canHoldPair("seed_folder"))
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
                WHERE \(canHoldPair("burst_still"))
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

/// The rows the user chose, Liked or Disliked (v71): a few dozen of a library's hundred
/// thousand — 21 Liked and 3 Disliked on the owner's catalog — so a wide scope filtered to
/// chosen rows seeks `indexName`, which holds exactly them with every column the order and
/// the window's tests read, and sorts the few it finds. Walking the order instead read every
/// row of the table: 25,897 pages for 1,647 Liked rows of an owner-shaped catalog. A filter
/// that takes Not Rated rows, most of the library, walks the order.
nonisolated enum ChosenRowsSQL {
    static let indexName = "idx_media_asset_chosen"

    /// The index's condition. A read through it states it literally: the filter binds its
    /// choices, and SQLite uses a partial index only for a condition it can prove at prepare.
    static let predicate = "media_choice <> 'notRated'"

    /// Whether a filter selects only chosen rows.
    static func seeks(_ filter: MediaFilter) -> Bool {
        !filter.choices.isEmpty && !filter.choices.contains(.notRated)
    }
}

/// The rule is evaluated where it is used, never stored: it reads only facts each row
/// already holds, so a rename, move, deletion, enrichment or refresh can never leave it
/// stale. `idx_media_asset_content_identifier` makes each test one indexed lookup, and only
/// a movie with an identifier reaches it.
nonisolated enum LivePhotoSQL {
    /// The other members of one asset's Live Photo group (binds the root and the path), through
    /// `idx_media_asset_content_identifier`: the rows whose pairing a change to that asset
    /// moves — a movie that is paired or no longer is, its still.
    static let partnersSQL = """
    SELECT m.relative_path
    FROM media_asset AS k
    JOIN media_asset AS m
        ON m.library_root_id = k.library_root_id AND m.content_identifier = k.content_identifier
        AND m.parent_path = k.parent_path AND m.relative_path != k.relative_path
    WHERE \(AssetKey.exactText("k")) AND k.content_identifier IS NOT NULL
    """

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
///
/// `ordering` is true for the order read, which reaches a person's photos through their own
/// rows (`PersonPhotoSQL`); every other read finds them from the person's faces.
private nonisolated func scopeClause(
    _ scope: CatalogScopePredicate,
    stacks: AnniversaryStacks,
    ordering: Bool = false,
    db: Database
) throws -> ScopeClause? {
    guard !scope.selectsNothing else {
        return nil
    }
    let anniversary: AnniversaryMatch?
    switch scope.date {
    case .any:
        anniversary = nil
    case let .anniversary(day):
        guard let match = try anniversaryMatch(for: day, scope: scope, stacks: stacks, db: db) else {
            return nil
        }
        anniversary = match
    }
    guard let sought = try scopeClause(scope, anniversary: anniversary, seeks: true, ordering: ordering) else {
        return nil
    }
    guard let size = sought.size, try !size.seeks(scope: scope, db: db) else {
        return sought
    }
    return try scopeClause(scope, anniversary: anniversary, seeks: false, ordering: ordering)
}

/// What decides whether a scope's reads seek its rows or walk the order: the rows its seek
/// would visit against the rows a walk would. A person, a day and a map area are a few dozen
/// rows of the catalog or most of it — the most photographed person, a day of a library taken
/// in one day, the whole world as an area — and a seek costs a random page or two a row where
/// a walk costs a small, fixed share of a page a row (`walkRowsPerSoughtRow`,
/// `docs/research/2026-11-15-large-narrow-scopes.md`). Both counts are read in the read
/// itself, from indexes alone: the seek's in proportion to its own rows, the walk's no
/// further than the seek's count times the ratio, so deciding costs a small share of the
/// cheaper plan.
nonisolated struct SeekSize {
    /// Counts the index entries the seek visits, every one of which it then looks up.
    let candidatesSQL: String
    let arguments: [any DatabaseValueConvertible]
    /// How many rows a walk visits for the pages one row a seek finds costs, measured on a
    /// generated catalog of the owner's size and shape.
    let walkRowsPerSoughtRow: Int

    static let personRatio = 40
    static let dayRatio = 2
    static let areaRatio = 10

    /// Whether the seek costs less than the walk: whether the rows the walk visits — every
    /// row of a root a one-root scope's order index is led by, else every row of the catalog,
    /// which the global order indexes hold in one sequence — outnumber the seek's candidates
    /// by more than the ratio.
    func seeks(scope: CatalogScopePredicate, db: Database) throws -> Bool {
        let candidates = try Int.fetchOne(db.cachedStatement(sql: candidatesSQL), arguments: StatementArguments(arguments)) ?? 0
        let (bound, overflow) = candidates.multipliedReportingOverflow(by: walkRowsPerSoughtRow)
        let walked: Int = if overflow || bound == .max {
            0
        } else if scope.rootIDs.count == 1, let rootID = scope.rootIDs.first {
            try Int.fetchOne(
                db.cachedStatement(sql: "SELECT count(*) FROM (SELECT 1 FROM media_asset WHERE library_root_id = ? LIMIT ?)"),
                arguments: [rootID, bound + 1]
            ) ?? 0
        } else {
            try Int.fetchOne(
                db.cachedStatement(sql: "SELECT count(*) FROM (SELECT 1 FROM media_asset LIMIT ?)"),
                arguments: [bound + 1]
            ) ?? 0
        }
        let seeks = walked > bound
        OtosLog.catalog.debugOperation("catalog.query.reach", phase: "decided", fields: [
            "candidates": "\(candidates)",
            "walkedAtLeast": "\(walked)",
            "ratio": "\(walkRowsPerSoughtRow)",
            "reach": seeks ? "seek" : "walk",
        ])
        return seeks
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
        /// A person's own rows of `person_photo`, read as `media_asset`: they carry, under the
        /// same names, every column the scope's and the filter's tests read. Only the order
        /// read reaches a person this way (`PersonPhotoSQL.orderQuery`).
        case personPhotos(PersonID)
    }

    let join: String
    let sql: String
    let arguments: [any DatabaseValueConvertible]
    let seek: Seek?
    /// What decides whether `seek` costs less than walking the order, for a seek whose rows can
    /// be any share of the catalog; nil for one whose rows are always few, or no seek.
    let size: SeekSize?

    /// The tables a narrow scope's reads start from, through its seek, with its join; nil for
    /// a wide scope.
    var seekFrom: String? {
        switch seek {
        case nil:
            nil
        case let .rows(index):
            "media_asset INDEXED BY \(index)" + join
        case .personPhotos:
            "person_photo AS media_asset" + join
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
/// stack of the scope's roots, which the read's caller holds, or none yet, built in the read
/// when rows are judged — `span` `.rows`: only the stacks that hold one of them
/// (`PhotoStackSQL.build(rootPaths:holding:pairing:db:)`), which judge those rows exactly as every
/// stack would; `.roots`: every stack of the roots, for rows that are a large share of them.
/// Either way they come from the snapshot the rows do.
nonisolated enum AnniversaryStacks {
    case built(PhotoStackSQL.Built)
    /// Built when a read needs them, under the Store's pairing.
    case readWhenNeeded(RawPairing)

    func judging(
        _ rows: [CatalogQueryGateway.OrderedAssetIDRow],
        rootIDs: [Int64],
        span: PhotoStackSQL.Span = .rows,
        db: Database
    ) throws -> PhotoStackSQL.Built {
        switch self {
        case let .built(built):
            return built
        case let .readWhenNeeded(pairing):
            var rootPaths: [Int64: LibraryRootPath] = [:]
            let roots = try Row.fetchAll(
                db,
                sql: "SELECT id, path FROM library_root WHERE id IN (\(sqlPlaceholders(count: rootIDs.count)))",
                arguments: StatementArguments(rootIDs)
            )
            for root in roots {
                rootPaths[root[0]] = LibraryRootPath(rawValue: root[1])
            }
            switch span {
            case .rows:
                return try PhotoStackSQL.build(rootPaths: rootPaths, holding: rows, pairing: pairing, db: db)
            case .roots:
                return try PhotoStackSQL.build(rootPaths: rootPaths, pairing: pairing, db: db)
            }
        }
    }
}

/// Rows read to be judged by their stacks, with what builds the stacks that hold them
/// (`PhotoStackSQL.build(rootPaths:holding:pairing:db:)`): each row's key and its still's burst.
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
/// (`anniversary` nil: any date), or nil when the scope selects nothing. `seeks` false leaves
/// out the seeks whose rows can be any share of the catalog (`SeekSize`): a person's photos,
/// On This Day's day and a map area's cells are then tested on each row the order walks.
/// `ordering` reaches a person's photos through `person_photo` (`ScopeClause.Seek.personPhotos`).
private nonisolated func scopeClause(
    _ scope: CatalogScopePredicate,
    anniversary: AnniversaryMatch?,
    seeks: Bool,
    ordering: Bool = false
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
    var size: SeekSize?
    var personPhotos: PersonID?
    if let importBatchUnixMs = scope.importBatchUnixMs {
        arguments.append(importBatchUnixMs)
        predicate += "\n  AND media_asset.import_batch_unix_ms = ?"
        keyIndex = "idx_media_asset_import_batch"
    }
    // A combined scope shows one copy of each set of identical copies (ADR 0054): the best
    // copy among the scope's roots. A row stands aside when its shown copy — the best present
    // copy in any root — is in the scope. `shown_copy_root_id` is kept by the catalog's
    // triggers and the date indexes carry it (v60), so that test reads no table row. Only a
    // row whose best copy's root is out of the scope (a library not available) asks whether
    // a copy ranked before it is in the scope, through the digest index: the next best
    // reachable copy shows, and only it. The two are separate terms: SQLite tests a term with
    // a subquery after the others, and a filter's term that reads the table (a choice) would
    // then read it for every hidden copy too, which tripled the pages a Liked filter read on a
    // generated owner-shaped catalog.
    // A scope that holds every library and account root has every best copy in reach, and
    // asks nothing more.
    if scope.showsOneCopy {
        let roots = sqlPlaceholders(count: scope.rootIDs.count)
        predicate += """

          AND (media_asset.shown_copy_root_id IS NULL OR media_asset.shown_copy_root_id NOT IN (\(roots)))
        """
        arguments.append(contentsOf: scope.rootIDs)
    }
    if scope.showsOneCopy, !scope.holdsEveryCopyRoot {
        let roots = sqlPlaceholders(count: scope.rootIDs.count)
        predicate += """

          AND (media_asset.shown_copy_root_id IS NULL
               OR NOT EXISTS (
                   SELECT 1 FROM media_asset AS better INDEXED BY \(PhotoCopySQL.indexName)
                   WHERE \(PhotoCopySQL.isCopy("better", of: "media_asset"))
                     AND better.library_root_id IN (\(roots))
                     AND \(CatalogVisibilitySQL.isPresent("better"))
                     AND (\(CatalogSchema.copyRank("better"))) < (\(CatalogSchema.copyRank("media_asset")))
               ))
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
        predicate += "\n  AND \(PhotoFaceSQL.holds("media_asset", condition: "face.is_not_face = 0 AND face.person_id IS NOT NULL"))"
    case let .person(person) where ordering:
        // The order reads the person's own rows, which carry every column the scope and the
        // filter test, and the photos the person is in through a copy (`PersonPhotoSQL`),
        // which names the person in each of the two.
        personPhotos = PersonID(rawValue: person)
    case let .person(person):
        // A person's photos are named by their faces (`idx_face_person_photo`), and so are the
        // copies of those photos (ADR 0054): a face on any copy is the photo's. A person of a
        // few dozen to a few thousand photos seeks them there and finds each by its key:
        // testing every row of the catalog for one of their faces read 3,500–157,000 pages per
        // read on the owner's catalog (`docs/research/2026-11-15-small-scope-reads-and-tile-waits.md`).
        // A person in a large share of the catalog is tested on each row the order walks, one
        // seek of that index a row (`SeekSize`).
        let condition = "face.person_id = ? AND face.is_not_face = 0"
        if seeks {
            predicate += """

              AND (media_asset.library_root_id, media_asset.relative_path) IN (\(PhotoFaceSQL.photos(condition: condition)))
            """
            keyIndex = mediaAssetKeyIndexName
            size = SeekSize(
                candidatesSQL: """
                SELECT count(*) FROM face INDEXED BY idx_face_person_photo
                WHERE face.person_id = ? AND face.is_not_face = 0
                """,
                arguments: [person],
                walkRowsPerSoughtRow: SeekSize.personRatio
            )
            arguments.append(person)
        } else {
            predicate += "\n  AND \(PhotoFaceSQL.holds("media_asset", index: "idx_face_person_photo", condition: condition))"
            arguments.append(person)
            arguments.append(person)
        }
    }
    if let anniversary {
        // The day's own index is sought only when no key narrows the scope further; otherwise
        // its date is tested on each row found, from the capture time the order indexes hold.
        let seeksDay = seeks && keyIndex == nil
        predicate += "\n  AND \(anniversary.sql(row: "media_asset", seeksDay: seeksDay))"
        arguments.append(contentsOf: anniversary.arguments(seeksDay: seeksDay))
        predicate += OnThisDayPicks.exclusionSQL
        if seeksDay {
            keyIndex = AnniversaryMatch.indexName
            size = SeekSize(
                candidatesSQL: """
                SELECT count(*) FROM media_asset INDEXED BY \(AnniversaryMatch.indexName)
                WHERE \(anniversary.sql(row: "media_asset", seeksDay: true))
                """,
                arguments: anniversary.arguments(seeksDay: true),
                walkRowsPerSoughtRow: SeekSize.dayRatio
            )
        }
    }
    var seek = personPhotos.map(ScopeClause.Seek.personPhotos) ?? keyIndex.map(ScopeClause.Seek.rows(index:))
    var join = ""
    switch scope.location {
    case .any:
        break
    case .located:
        join = locatedJoin
        predicate += "\n  AND \(LocationIndexSQL.locatedSQL(row: "asset_metadata"))"
    case let .within(area):
        // Located first, in the index's own words: an area's walk joins through the same
        // index, which rejects a row outside the box's latitudes before its table row is read.
        join = locatedJoin
        predicate += "\n  AND \(LocationIndexSQL.locatedSQL(row: "asset_metadata"))"
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
        if seeks, seek == nil {
            seek = .placeCells
            size = SeekSize(
                candidatesSQL: """
                SELECT count(*) FROM asset_metadata INDEXED BY \(PlaceCellSQL.indexName)
                WHERE place_cell_latitude IS NOT NULL AND place_cell_longitude IS NOT NULL
                  AND place_cell_latitude BETWEEN ? AND ?
                  AND (place_cell_longitude >= ? \(longitude) place_cell_longitude <= ?)
                """,
                arguments: [cells.south, cells.north, cells.west, cells.east],
                walkRowsPerSoughtRow: SeekSize.areaRatio
            )
        }
    }
    return ScopeClause(join: join, sql: predicate, arguments: arguments, seek: seek, size: size)
}

/// The join of a scope that requires a location: each row's coordinate from
/// `LocationIndexSQL`'s index. Places reads nothing else of `asset_metadata`, so its join never
/// reads the table; an area also tests its rows' place cells, virtual columns SQLite computes
/// from the table row, which it reads only for a row the index finds inside the box's
/// latitudes.
private nonisolated let locatedJoin = """

JOIN asset_metadata INDEXED BY \(LocationIndexSQL.indexName)
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
        mediaClauses.append("media_asset.best_kind IN (\(sqlPlaceholders(count: kinds.count)))")
        arguments.append(contentsOf: kinds.map(\.rawValue))
    }
    let fileTypes = filter.fileTypes.sorted { ($0.kind.rawValue, $0.format.rawValue) < ($1.kind.rawValue, $1.format.rawValue) }
    for fileType in fileTypes {
        mediaClauses.append("(media_asset.best_kind = ? AND media_asset.best_format = ?)")
        arguments.append(fileType.kind.rawValue)
        arguments.append(fileType.format.rawValue)
    }
    if !mediaClauses.isEmpty {
        clauses.append("(\(mediaClauses.joined(separator: " OR ")))")
    }
    let choices = filter.choices.sorted { $0.rawValue < $1.rawValue }
    if !choices.isEmpty {
        clauses.append("media_asset.media_choice IN (\(sqlPlaceholders(count: choices.count)))")
        arguments.append(contentsOf: choices.map(\.rawValue))
    }
    // The People filter (ADR 0047): a photo holding a face of each person checked, and with
    // `Unidentified Faces` a face with no person too, on any of its copies (ADR 0054).
    for person in filter.people.sorted() {
        clauses.append(PhotoFaceSQL.holds("media_asset", condition: "face.is_not_face = 0 AND face.person_id = ?"))
        arguments.append(person.rawValue)
        arguments.append(person.rawValue)
    }
    if filter.unassignedFaces {
        clauses.append(PhotoFaceSQL.holds("media_asset", condition: "face.is_not_face = 0 AND face.person_id IS NULL"))
    }
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
        // Each walked row's coordinate is sought in the location index and its cell computed
        // from it, the expression the generated cell columns are: SQLite never serves a virtual
        // column from an index, so joining by `place_cell_latitude` read the row's
        // `asset_metadata` table row, 52,000–81,000 pages for All Media on a generated catalog
        // of the owner's shape (`docs/research/2026-11-17-every-order-the-window-asks-for.md`).
        let latitudeCell = PlaceCellSQL.cell("place_metadata.primary_latitude", cells: PlaceCellSQL.latitudeCells)
        let longitudeCell = PlaceCellSQL.cell("place_metadata.primary_longitude", cells: PlaceCellSQL.longitudeCells)
        clauses.append("""
        EXISTS (SELECT 1 FROM asset_metadata AS place_metadata INDEXED BY \(LocationIndexSQL.indexName)
            JOIN place_cell
              ON place_cell.cell_latitude = \(latitudeCell)
              AND place_cell.cell_longitude = \(longitudeCell)
            WHERE place_metadata.library_root_id = media_asset.library_root_id
              AND place_metadata.relative_path = media_asset.relative_path
              AND \(LocationIndexSQL.locatedSQL(row: "place_metadata"))
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
        mediaChoice: MediaChoice(rawValue: row["media_choice"] ?? "") ?? .default,
        copyKey: (row["copy_key"] as Data?).flatMap(PhotoCopyKey.init(data:))
    )
}
