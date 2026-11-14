import Foundation
import GRDB
@testable import OtosKit
import Testing

@Suite(.testDirectory)
struct CatalogStoreQueryPlanTests {
    @Test func descriptorQueryFiltersAndSortsBySQLiteBestValues() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        let rootID = try await insertDescriptorFixture(dbQueue)
        let descriptor = CatalogQueryDescriptor(
            scope: .allMedia,
            filter: MediaFilter(
                kinds: [.image],
                fileTypes: [FilterFileType(kind: .raw, format: MediaFormatToken(rawValue: "DNG"))]
            ),
            sort: MediaSortOrder(field: .name, direction: .ascending)
        )

        let ids = try await dbQueue.read { db in
            try CatalogQueryGateway.fetchOrderedAssetIDRows(
                descriptor: descriptor,
                scope: CatalogScopePredicate(rootIDs: [rootID]),
                db: db
            )
        }

        #expect(ids.map(\.relativePath.rawValue) == ["alpha.jpg", "raw-original.nef", "retagged.mov"])

        // A file type matches only under the kind it was chosen in.
        let wrongKind = try await dbQueue.read { db in
            try CatalogQueryGateway.fetchOrderedAssetIDRows(
                descriptor: CatalogQueryDescriptor(
                    scope: .allMedia,
                    filter: MediaFilter(fileTypes: [FilterFileType(kind: .image, format: MediaFormatToken(rawValue: "DNG"))])
                ),
                scope: CatalogScopePredicate(rootIDs: [rootID]),
                db: db
            )
        }
        #expect(wrongKind.isEmpty)
    }

    @Test func querySchemaStreamsCatalogOrderAndEnrichmentCandidatesFromIndexes() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        let (rootID1, rootID2) = try await insertPlanFixture(dbQueue)
        let rootOrderQuery = try #require(try CatalogQueryGateway.orderedAssetIDQuery(
            descriptor: .default,
            scope: CatalogScopePredicate(rootIDs: [rootID1])
        ))
        let globalOrderQuery = try #require(try CatalogQueryGateway.orderedAssetIDQuery(
            descriptor: .default,
            scope: CatalogScopePredicate(rootIDs: [rootID1, rootID2])
        ))
        let rootEnrichmentQuery = try #require(EnrichmentClaimGateway.enrichmentClaimQuery(
            rootIDs: [rootID1],
            limit: 4,
            claim: .products
        ))
        let globalEnrichmentQuery = try #require(EnrichmentClaimGateway.enrichmentClaimQuery(
            rootIDs: [rootID1, rootID2],
            limit: 4,
            claim: .products
        ))

        let plans = try await dbQueue.read { db in
            try QueryPlans(
                rootOrder: explainPlan(db, query: rootOrderQuery),
                globalOrder: explainPlan(db, query: globalOrderQuery),
                rootEnrichment: explainPlan(db, query: rootEnrichmentQuery),
                globalEnrichment: explainPlan(db, query: globalEnrichmentQuery)
            )
        }

        #expect(plans.rootOrder.contains("idx_media_asset_best_capture_root_desc"))
        #expect(plans.globalOrder.contains("idx_media_asset_best_capture_global_desc"))
        #expect(plans.rootEnrichment.contains("idx_media_asset_needs_enrichment_root"))
        #expect(plans.globalEnrichment.contains("idx_media_asset_needs_enrichment_global"))
        #expect(!usesTemporarySort(plans.rootOrder))
        #expect(!usesTemporarySort(plans.globalOrder))
        #expect(!usesTemporarySort(plans.rootEnrichment))
        #expect(!usesTemporarySort(plans.globalEnrichment))
    }

    /// The Places scopes join `asset_metadata` for the coordinate (ADR 0040). The order
    /// must still come from the capture index — a walk, never a temporary sort — and the
    /// join must be a primary-key lookup per row, which is what makes the deferred
    /// partial index on `primary_latitude` unnecessary (measured 2026-10-31,
    /// `docs/research/2026-10-31-map-views-in-photo-managers.md`).
    @Test func locatedOrderQueryKeepsTheCaptureIndexAndLooksUpMetadataByKey() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        let (rootID1, rootID2) = try await insertPlanFixture(dbQueue)
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO asset_metadata (library_root_id, relative_path, primary_latitude, primary_longitude)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [rootID1, "a.jpg", 60.17, 24.94]
            )
        }
        let rootLocated = try #require(try CatalogQueryGateway.orderedAssetIDQuery(
            descriptor: .default,
            scope: CatalogScopePredicate(rootIDs: [rootID1], location: .located)
        ))
        let globalLocated = try #require(try CatalogQueryGateway.orderedAssetIDQuery(
            descriptor: .default,
            scope: CatalogScopePredicate(rootIDs: [rootID1, rootID2], location: .located)
        ))
        let onePlace = try #require(try CatalogQueryGateway.orderedAssetIDQuery(
            descriptor: .default,
            scope: CatalogScopePredicate(
                rootIDs: [rootID1, rootID2],
                location: .within(MapArea(south: 60, north: 61, west: 24, east: 25))
            )
        ))

        let (rootPlan, globalPlan, placePlan, rows) = try await dbQueue.read { db in
            try (
                explainPlan(db, query: rootLocated),
                explainPlan(db, query: globalLocated),
                explainPlan(db, query: onePlace),
                CatalogQueryGateway.fetchOrderedAssetIDRows(
                    descriptor: .default,
                    scope: CatalogScopePredicate(rootIDs: [rootID1, rootID2], location: .located),
                    db: db
                )
            )
        }

        for plan in [rootPlan, globalPlan, placePlan] {
            #expect(plan.contains("idx_media_asset_best_capture_"))
            #expect(plan.contains("SEARCH asset_metadata USING INDEX sqlite_autoindex_asset_metadata_1"))
            #expect(!usesTemporarySort(plan))
        }
        #expect(rootPlan.contains("idx_media_asset_best_capture_root_desc"))
        #expect(globalPlan.contains("idx_media_asset_best_capture_global_desc"))
        #expect(rows.map(\.relativePath.rawValue) == ["a.jpg"])
        #expect(rows.first?.coordinate == PlaceCoordinate(latitude: 60.17, longitude: 24.94))
    }

    /// Place names (ADR 0051): the unnamed cells' read walks the place-cell index in its own
    /// order — no scan of every location, no temporary sort — and the filter options' read
    /// starts from the named cells and reaches each located row through that index, not
    /// from every row of the scope. SQLite generates each row's cell exactly as
    /// `PlaceCell.init` computes it, on the pole and the 180th meridian too. The launch's
    /// hand-back of undecodable stills seeks them by their index.
    @Test func placeCellAndUndecodableReadsAreIndexDriven() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        let (rootID1, rootID2) = try await insertPlanFixture(dbQueue)
        let coordinates: [(Int64, String, PlaceCoordinate)] = [
            (rootID1, "a.jpg", PlaceCoordinate(latitude: 60.17, longitude: 24.94)),
            (rootID1, "b.jpg", PlaceCoordinate(latitude: -33.87, longitude: -0.001)),
            (rootID2, "c.jpg", PlaceCoordinate(latitude: 90, longitude: 180)),
        ]
        try await dbQueue.write { db in
            for (rootID, path, coordinate) in coordinates {
                try db.execute(
                    sql: """
                    INSERT INTO asset_metadata (library_root_id, relative_path, primary_latitude, primary_longitude)
                    VALUES (?, ?, ?, ?)
                    """,
                    arguments: [rootID, path, coordinate.latitude, coordinate.longitude]
                )
            }
        }
        let scope = CatalogScopePredicate(rootIDs: [rootID1, rootID2])

        let (unnamedPlan, nextPagePlan, optionsPlan, undecodablePlans, cells) = try await dbQueue.read { db in
            let optionsQuery = try #require(try CatalogQueryGateway.placeOptionsQuery(
                scope: scope, language: PlaceNameLanguage(identifier: "en-Latn"), db: db
            ))
            return try (
                explainPlan(db, sql: CatalogQueryGateway.unnamedPlaceCellsSQL(after: false), arguments: ["en-Latn", 32]),
                explainPlan(db, sql: CatalogQueryGateway.unnamedPlaceCellsSQL(after: true), arguments: [0, 0, "en-Latn", 32]),
                explainPlan(db, query: optionsQuery),
                [CatalogStore.releaseUndecodedStillsSQL, CatalogStore.releaseUndecodedVideosSQL].map { sql in
                    try explainPlan(db, sql: sql, arguments: ["otos2"])
                },
                Row.fetchAll(
                    db,
                    sql: "SELECT relative_path, place_cell_latitude, place_cell_longitude FROM asset_metadata"
                ).reduce(into: [String: PlaceCell]()) { cells, row in
                    cells[row["relative_path"]] = PlaceCell(
                        latitude: row["place_cell_latitude"], longitude: row["place_cell_longitude"]
                    )
                }
            )
        }

        for plan in [unnamedPlan, nextPagePlan] {
            #expect(plan.contains("USING INDEX idx_asset_metadata_place_cell"))
            #expect(!plan.contains("SCAN"))
            #expect(!usesTemporarySort(plan))
        }
        #expect(optionsPlan.contains("SEARCH place_metadata USING INDEX idx_asset_metadata_place_cell"))
        #expect(!optionsPlan.contains("SCAN media_asset"))
        #expect(!optionsPlan.contains("SCAN place_metadata"))
        for undecodablePlan in undecodablePlans {
            #expect(undecodablePlan.contains("USING INDEX idx_media_asset_undecodable"))
            #expect(!undecodablePlan.contains("SCAN media_asset"))
        }
        for (_, path, coordinate) in coordinates {
            #expect(cells[path] == PlaceCell(coordinate))
        }
        #expect(cells["c.jpg"] == PlaceCell(latitude: 4499, longitude: 8999))
    }

    @Test func enrichmentClaimUpdateReturningClaimsRows() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        let rootID = try await insertEnrichmentClaimFixture(dbQueue, assetCount: 3, claimedCount: 0)

        let claimed = try await dbQueue.write { db in
            try EnrichmentClaimGateway.fetchStoredAssetsNeedingEnrichment(
                rootIDs: [rootID],
                limit: 2,
                claim: .products,
                db: db
            )
        }
        #expect(claimed.count == 2)

        let stillClaimed = try await dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM media_asset
                WHERE library_root_id = ?
                  AND enrichment_claimed IS NOT NULL
                """,
                arguments: [rootID]
            ) ?? 0
        }
        #expect(stillClaimed == 2)
    }

    /// ARC-037: `.removableVolume` roots claim with the metadata-only predicate and
    /// index. Assert the index choice on EXPLAIN QUERY PLAN — a correctness-only
    /// assertion would not catch a narrow query silently planning against the broad
    /// index.
    /// ADR 0052: the stack candidates' read seeks the RAW folders and each folder's stills
    /// through the candidate index. Without it each folder scanned its whole root, and on the
    /// owner's 10,917 RAW folders the window's first publication took minutes.
    @Test func stackCandidatesSeekTheirFoldersThroughTheCandidateIndex() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        let (rootID1, rootID2) = try await insertPlanFixture(dbQueue)
        let query = try #require(PhotoStackSQL.candidateQuery(rootIDs: [rootID1, rootID2]))
        let plan = try await dbQueue.read { db in try explainPlan(db, query: query) }
        #expect(plan.contains("SEARCH still USING INDEX idx_media_asset_stack_candidate"))
        // The burst stills are found through their own partial index, and no arm — the RAW
        // folders' CTE included, whatever alias it reads under — scans the table.
        #expect(plan.contains("SEARCH still USING INDEX idx_media_asset_burst"))
        #expect(plan.contains("SEARCH media_asset USING"))
        #expect(!plan.contains("SCAN media_asset"))
        #expect(!plan.contains("SCAN still"))
    }

    /// v55: the window's reads test every row they walk for whether it is shown and whether it
    /// is a Live Photo's movie. Each walks an index that carries those columns, so a row is
    /// tested without its table row being read (one random page read per row on the owner's
    /// catalog, `docs/research/2026-11-14-window-reads-and-launch.md`); and the launch's
    /// maintenance writes find their few rows through partial indexes, never a table walk.
    @Test func theWindowReadsTestRowsInTheirIndexesAndLaunchWritesFindTheirRowsByIndex() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        let (rootID1, rootID2) = try await insertPlanFixture(dbQueue)
        let tested: Set = ["pending_trash_batch_unix_ms", "awaiting_presence", "hidden_by_source", "best_kind", "content_identifier"]
        var orderQueries: [(String, SQLQuery)] = []
        for (direction, suffix) in [(MediaSortDirection.descending, "desc"), (.ascending, "asc")] {
            let descriptor = CatalogQueryDescriptor(scope: .allMedia, sort: MediaSortOrder(field: .bestDate, direction: direction))
            for (name, roots) in [("root", [rootID1]), ("global", [rootID1, rootID2])] {
                let query = try #require(try CatalogQueryGateway.orderedAssetIDQuery(
                    descriptor: descriptor, scope: CatalogScopePredicate(rootIDs: roots)
                ))
                orderQueries.append(("idx_media_asset_best_capture_\(name)_\(suffix)", query))
            }
        }
        let orders = orderQueries
        let (plans, typesPlan, batchesPlan, claimsPlan, editsPlan, indexColumns) = try await dbQueue.read { db in
            let types = try #require(try CatalogQueryGateway.distinctFilterableTypesQuery(
                scope: CatalogScopePredicate(rootIDs: [rootID1, rootID2]), db: db
            ))
            var columns: [String: Set<String>] = [:]
            for index in orders.map(\.0) + ["idx_media_asset_stack_candidate", "idx_media_asset_import_batch"] {
                columns[index] = try Set(String.fetchAll(db, sql: "SELECT name FROM pragma_index_info(?)", arguments: [index]))
            }
            return try (
                orders.map { name, query in try (name, explainPlan(db, query: query)) },
                explainPlan(db, query: types),
                explainPlan(db, sql: "SELECT batch_ms FROM (\(CatalogQueryGateway.importBatchesSQL))"),
                explainPlan(db, sql: EnrichmentClaimGateway.clearEnrichmentClaimsSQL),
                explainPlan(db, sql: CatalogStore.releaseAllUnrenderedEditsSQL),
                columns
            )
        }
        for (index, plan) in plans {
            #expect(plan.contains("USING INDEX \(index)") || plan.contains("USING COVERING INDEX \(index)"), "\(plan)")
            #expect(!usesTemporarySort(plan), "\(plan)")
            #expect(tested.isSubset(of: indexColumns[index] ?? []), "\(index): \(indexColumns[index] ?? [])")
        }
        #expect(typesPlan.contains("idx_media_asset_stack_candidate"), "\(typesPlan)")
        #expect(tested.union(["best_format"]).isSubset(of: indexColumns["idx_media_asset_stack_candidate"] ?? []))
        #expect(batchesPlan.contains("idx_media_asset_import_batch"), "\(batchesPlan)")
        #expect(tested.isSubset(of: indexColumns["idx_media_asset_import_batch"] ?? []))
        #expect(claimsPlan.contains("USING INDEX idx_media_asset_enrichment_claimed"), "\(claimsPlan)")
        #expect(editsPlan.contains("USING INDEX idx_media_asset_unrendered_edit"), "\(editsPlan)")
    }

    /// Search's reads (ADR 0048): what is owed walks each root's assets by an index and looks
    /// each up in the reading table by its key; what is current is read by the reading table's
    /// key, each asset looked up by its own. Nothing scans a table whole.
    @Test func searchReadsSeekByKeyAndRootIndexes() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        let (rootID1, rootID2) = try await insertPlanFixture(dbQueue)
        let roots: [DatabaseValue] = [rootID1.databaseValue, rootID2.databaseValue]
        let order = "ORDER BY a.best_capture_local DESC, a.library_root_id, a.relative_path LIMIT 16"
        let plans = try await dbQueue.read { db in
            try [
                "owedEmbeddings": explainPlan(
                    db, sql: "SELECT a.relative_path \(SearchEmbeddingStorage.owedFrom(rootCount: 2)) \(order)",
                    arguments: StatementArguments(roots)
                ),
                "owedTexts": explainPlan(
                    db, sql: "SELECT a.relative_path \(SearchTextStorage.owedFrom(rootCount: 2)) \(order)",
                    arguments: StatementArguments(roots)
                ),
                "currentEmbeddings": explainPlan(
                    db, sql: SearchEmbeddingStorage.currentEmbeddingsSQL(rootCount: 2, vectors: false),
                    arguments: StatementArguments(roots)
                ),
                "currentTexts": explainPlan(
                    db, sql: SearchTextStorage.currentReadingsSQL(rootCount: 2, lines: false), arguments: StatementArguments(roots)
                ),
            ]
        }
        for (name, plan) in plans.sorted(by: { $0.key < $1.key }) {
            let lines = plan.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            #expect(!lines.contains { $0.hasPrefix("SCAN ") }, "\(name): \(plan)")
        }
    }

    /// v53's one-time cleanup visits each text reading once, as it must to find the empty ones,
    /// and finds each reading's asset by the asset's key: it never scans `media_asset`.
    @Test func theEmptyTextReadingsCleanupFindsEachAssetByItsKey() async throws {
        let dbQueue = try DatabaseQueue()
        try CatalogStore.migrator.migrate(dbQueue)
        let plan = try await dbQueue.read { db in
            try explainPlan(db, sql: CatalogSchema.unreadTextPreviewsStatements[0])
        }
        let lines = plan.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.filter { $0.hasPrefix("SCAN ") } == ["SCAN search_text"], "\(plan)")
        #expect(lines.contains { $0.hasPrefix("SEARCH a USING") && $0.hasSuffix("(library_root_id=? AND relative_path=?)") }, "\(plan)")
    }

    /// The filter's options are read over the shown row's scope (APP-013, APP-025), whatever
    /// that row is: the file types from the scope's own rows, the places from the named cells
    /// in the catalog's language reaching each located row through the place-cell index —
    /// never a scan of every row, every location or every search row. Measured on the owner's
    /// 166,554-photo catalog (2026-11-13): every row's two reads about a second at most warm, the same
    /// scale as the every-source read they replace. The languages read scans only
    /// `place_cell`, one row per named cell.
    @Test func theOptionsReadsOfEveryRowAreIndexDriven() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        let (rootID1, rootID2) = try await insertPlanFixture(dbQueue)
        let roots = [rootID1, rootID2]
        let scopes: [(String, CatalogScopePredicate)] = [
            ("allMedia", CatalogScopePredicate(rootIDs: roots)),
            ("library", CatalogScopePredicate(rootIDs: [rootID1])),
            ("places", CatalogScopePredicate(rootIDs: roots, location: .located)),
            ("onThisDay", CatalogScopePredicate(rootIDs: roots, date: .anniversary(CalendarDay(year: 2026, month: 11, day: 13)))),
            ("duplicates", CatalogScopePredicate(rootIDs: roots, content: .duplicated)),
            ("people", CatalogScopePredicate(rootIDs: roots, content: .withPerson)),
            ("importBatch", CatalogScopePredicate(rootIDs: roots, importBatchUnixMs: 1_785_908_514_176)),
        ]
        let (plans, languagesPlan) = try await dbQueue.read { db in
            var plans: [(String, String)] = []
            for (name, scope) in scopes {
                let types = try #require(try CatalogQueryGateway.distinctFilterableTypesQuery(scope: scope, db: db))
                let places = try #require(try CatalogQueryGateway.placeOptionsQuery(
                    scope: scope, language: PlaceNameLanguage(identifier: "en-Latn"), db: db
                ))
                try plans.append(("\(name).types", explainPlan(db, query: types)))
                try plans.append(("\(name).places", explainPlan(db, query: places)))
            }
            return try (plans, explainPlan(db, sql: CatalogQueryGateway.placeNameLanguagesSQL))
        }
        for (name, plan) in plans {
            let lines = plan.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            for table in ["media_asset", "place_metadata", "asset_metadata", "search_embedding", "face"] {
                #expect(!lines.contains { $0 == "SCAN \(table)" || $0.hasPrefix("SCAN \(table) ") }, "\(name): \(plan)")
            }
            if name.hasSuffix(".places") {
                #expect(plan.contains("SEARCH place_metadata USING INDEX idx_asset_metadata_place_cell"), "\(name): \(plan)")
            }
        }
        #expect(!languagesPlan.contains("media_asset") && !languagesPlan.contains("asset_metadata"))
    }

    /// Duplicates group copies by digest through the digest index alone: the copies read and
    /// the Duplicates scope's group subquery never visit a row without a digest and never
    /// group through a temporary B-tree. On the owner's catalog (2026-11-14) the copies read
    /// fell from 1.4 s to 0.04 s warm, since most of its rows, an Immich account's, have none.
    @Test func duplicatesGroupThroughTheDigestIndex() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        let (rootID1, rootID2) = try await insertPlanFixture(dbQueue)
        let plans = try await dbQueue.read { db in
            try [[rootID1], [rootID1, rootID2]].flatMap { roots in
                let scope = try #require(try CatalogQueryGateway.orderedAssetIDQuery(
                    descriptor: CatalogQueryDescriptor(scope: .duplicates),
                    scope: CatalogScopePredicate(rootIDs: roots, content: .duplicated),
                    db: db
                ))
                return try [
                    ("copies \(roots.count)", explainPlan(
                        db, sql: DuplicatesGateway.duplicateCopiesSQL(rootCount: roots.count),
                        arguments: StatementArguments(roots + roots)
                    )),
                    ("scope \(roots.count)", explainPlan(db, query: scope)),
                ]
            }
        }
        for (name, plan) in plans {
            #expect(!plan.contains("TEMP B-TREE FOR GROUP BY"), "\(name): \(plan)")
            #expect(plan.contains("USING INDEX idx_media_asset_content_hash"), "\(name): \(plan)")
        }
    }

    /// Whether a row holds a face of one person is answered with one seek by person and
    /// photo, never by walking every face of the person: the person's own photos (in date
    /// and likeness order), the People filter, for one library and for several. On the
    /// owner's catalog (2026-11-14: 147,024 rows of one account, 14,614 faces of its most
    /// photographed person) the walk never let a person's photos open.
    @Test func whetherARowHoldsAPersonIsOneSeekByPersonAndPhoto() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        let (rootID1, rootID2) = try await insertPlanFixture(dbQueue)
        let person = PersonID(rawValue: 1)
        var filter = MediaFilter.all
        filter.people = [person]
        let reads: [(String, CatalogQueryDescriptor, CatalogScopePredicate)] = [[rootID1], [rootID1, rootID2]]
            .flatMap { roots in
                let name = "\(roots.count) libraries"
                return [
                    ("person \(name)", CatalogQueryDescriptor(scope: .person(person)),
                     CatalogScopePredicate(rootIDs: roots, content: .person(person.rawValue))),
                    ("person by likeness \(name)",
                     CatalogQueryDescriptor(scope: .person(person), sort: MediaSortOrder(field: .likeness, direction: .descending)),
                     CatalogScopePredicate(rootIDs: roots, content: .person(person.rawValue))),
                    ("People filter \(name)", CatalogQueryDescriptor(scope: .allMedia, filter: filter),
                     CatalogScopePredicate(rootIDs: roots)),
                ]
            }
        let plans = try await dbQueue.read { db in
            try reads.map { name, descriptor, scope in
                let query = try #require(try CatalogQueryGateway.orderedAssetIDQuery(descriptor: descriptor, scope: scope, db: db))
                return try (name, explainPlan(db, query: query))
            }
        }
        for (name, plan) in plans {
            let faceLines = plan.split(separator: "\n").filter { $0.contains(" face ") }
            #expect(!faceLines.isEmpty, "\(name): \(plan)")
            for line in faceLines {
                #expect(line.contains("idx_face_person_photo (person_id=? AND library_root_id=? AND relative_path=?"),
                        "\(name): \(plan)")
            }
        }
    }

    /// On This Day's left-out photos are sought by each row's key, never by a scan of every
    /// search row — which a `NOT IN` list did once per outer row when the read started from
    /// the place cells (the filter's place options).
    @Test func onThisDaysLeftOutPhotosAreSoughtByKey() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        let plan = try await dbQueue.read { db in
            try explainPlan(db, sql: "SELECT 1 FROM media_asset WHERE 1\(OnThisDayPicks.exclusionSQL)")
        }
        #expect(plan.contains("SEARCH search_embedding USING"))
        #expect(plan.contains("(library_root_id=? AND relative_path=?)"))
        #expect(!plan.contains("SCAN search_embedding"))
    }

    /// On This Day's years-or-months match walks a year's rows through a capture-time index
    /// of their roots, bounded by the year's start, never by a scan of every row.
    @Test func onThisDaysYearRowsAreWalkedThroughTheCaptureIndex() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        let match = try #require(AnniversaryMatch.years(for: CalendarDay(year: 2026, month: 11, day: 9)))
        let plans = try await dbQueue.read { db in
            try [1, 3].map { rootCount in
                let scope = CatalogScopePredicate(rootIDs: Array(1 ... Int64(rootCount)))
                let query = try #require(try CatalogQueryGateway.anniversaryRowsQuery(scope: scope, match: match))
                return try explainPlan(db, sql: query.sql, arguments: query.arguments)
            }
        }
        for plan in plans {
            let lines = plan.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            #expect(lines.contains { $0.hasPrefix("SEARCH media_asset USING") && $0.contains("best_capture_local<?") }, "\(plan)")
            #expect(!lines.contains { $0.hasPrefix("SCAN media_asset") }, "\(plan)")
        }
    }

    @Test func metadataOnlyClaimQueriesUseMetadataOnlyIndexes() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        let (rootID1, rootID2) = try await insertPlanFixture(dbQueue)
        let rootMetadataOnlyQuery = try #require(EnrichmentClaimGateway.enrichmentClaimQuery(
            rootIDs: [rootID1],
            limit: 4,
            claim: .metadata
        ))
        let globalMetadataOnlyQuery = try #require(EnrichmentClaimGateway.enrichmentClaimQuery(
            rootIDs: [rootID1, rootID2],
            limit: 4,
            claim: .metadata
        ))

        let plans = try await dbQueue.read { db in
            let root = try explainPlan(db, query: rootMetadataOnlyQuery)
            let global = try explainPlan(db, query: globalMetadataOnlyQuery)
            return (root: root, global: global)
        }
        #expect(plans.root.contains(EnrichmentClaimGateway.metadataOnlyRootIndexName))
        #expect(plans.global.contains(EnrichmentClaimGateway.metadataOnlyGlobalIndexName))
    }

    /// Regression guard: a metadata-current asset with no digest is claimed by
    /// the metadata-only claim (a `.removableVolume` root) never, and by the broad claim
    /// (a library root) still — the wiring that must hold or removable enrichment spins
    /// forever.
    @Test func metadataCurrentNoHashIsClaimedOnlyWhenHashRequired() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        let rootID = try await dbQueue.write { db in
            try db.execute(sql: "INSERT INTO library_root (path) VALUES (?)", arguments: ["/tmp/otos-nohash"])
            let rootID = db.lastInsertedRowID
            try db.execute(
                sql: """
                INSERT INTO media_asset (
                    library_root_id, relative_path, sort_key, name_sort_key, name,
                    content_type_identifier, byte_size, content_modified_at_unix,
                    metadata_source_size, metadata_source_mtime
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [rootID, "a.jpg", "a.jpg", "a.jpg", "a.jpg", "public.jpeg", 1, 1000, 1, 1000]
            )
            return rootID
        }

        let metadataOnlyClaimed = try await dbQueue.write { db in
            try EnrichmentClaimGateway.fetchStoredAssetsNeedingEnrichment(
                rootIDs: [rootID],
                limit: 4,
                claim: .metadata,
                db: db
            )
        }
        #expect(metadataOnlyClaimed.isEmpty)

        let broadClaimed = try await dbQueue.write { db in
            try EnrichmentClaimGateway.fetchStoredAssetsNeedingEnrichment(
                rootIDs: [rootID],
                limit: 4,
                claim: .products,
                db: db
            )
        }
        #expect(broadClaimed.map(\.relativePath.rawValue) == ["a.jpg"])
    }
}

private struct QueryPlans {
    let rootOrder: String
    let globalOrder: String
    let rootEnrichment: String
    let globalEnrichment: String
}

private func insertDescriptorFixture(_ dbQueue: DatabaseQueue) async throws -> Int64 {
    try await dbQueue.write { db in
        try db.execute(sql: "INSERT INTO library_root (path) VALUES (?)", arguments: ["/tmp/otos-descriptor"])
        let rootID = db.lastInsertedRowID
        for fixture in descriptorFixtures() {
            try insertDescriptorFixtureRow(fixture, rootID: rootID, db: db)
        }
        return rootID
    }
}

private func descriptorFixtures() -> [DescriptorFixture] {
    [
        DescriptorFixture(
            relativePath: "video.mov",
            nameSortKey: "video.mov",
            kind: "video",
            format: "MOV",
            enrichedKind: nil,
            enrichedFormat: nil,
            originalDate: 400,
            byteSize: 40
        ),
        DescriptorFixture(
            relativePath: "raw-original.nef",
            nameSortKey: "raw-original.nef",
            kind: "raw",
            format: "NEF",
            enrichedKind: nil,
            enrichedFormat: "DNG",
            originalDate: 300,
            byteSize: 30
        ),
        DescriptorFixture(
            relativePath: "alpha.jpg",
            nameSortKey: "alpha.jpg",
            kind: "image",
            format: "JPEG",
            enrichedKind: nil,
            enrichedFormat: nil,
            originalDate: 200,
            byteSize: 20
        ),
        DescriptorFixture(
            relativePath: "retagged.mov",
            nameSortKey: "retagged.mov",
            kind: "video",
            format: "MOV",
            enrichedKind: "image",
            enrichedFormat: "JPEG",
            originalDate: 100,
            byteSize: 10
        ),
    ]
}

private func insertDescriptorFixtureRow(_ fixture: DescriptorFixture, rootID: Int64, db: Database) throws {
    try db.execute(
        sql: """
        INSERT INTO media_asset (
            library_root_id,
            relative_path,
            sort_key,
            name_sort_key,
            name,
            content_type_identifier,
            kind,
            format,
            byte_size,
            content_modified_at_unix,
            capture_instant_unix,
            enriched_kind,
            enriched_format
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        arguments: [
            rootID,
            fixture.relativePath,
            fixture.relativePath,
            fixture.nameSortKey,
            fixture.relativePath,
            "public.item",
            fixture.kind,
            fixture.format,
            fixture.byteSize,
            10,
            fixture.originalDate,
            fixture.enrichedKind,
            fixture.enrichedFormat,
        ]
    )
}

private struct DescriptorFixture {
    let relativePath: String
    let nameSortKey: String
    let kind: String
    let format: String
    let enrichedKind: String?
    let enrichedFormat: String?
    let originalDate: Double
    let byteSize: Int
}

private func insertPlanFixture(_ dbQueue: DatabaseQueue) async throws -> (Int64, Int64) {
    try await dbQueue.write { db in
        try db.execute(sql: "INSERT INTO library_root (path) VALUES (?)", arguments: ["/tmp/otos-a"])
        let rootID1 = db.lastInsertedRowID
        try db.execute(sql: "INSERT INTO library_root (path) VALUES (?)", arguments: ["/tmp/otos-b"])
        let rootID2 = db.lastInsertedRowID
        for (rootID, relativePath, sortKey) in [
            (rootID1, "b.jpg", "b.jpg"),
            (rootID1, "a.jpg", "a.jpg"),
            (rootID2, "c.jpg", "c.jpg"),
        ] {
            try db.execute(
                sql: """
                INSERT INTO media_asset (
                    library_root_id,
                    relative_path,
                    sort_key,
                    name_sort_key,
                    name,
                    content_type_identifier,
                    byte_size,
                    content_modified_at_unix
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [rootID, relativePath, sortKey, sortKey, relativePath, "public.jpeg", 1, 1000]
            )
        }
        return (rootID1, rootID2)
    }
}

private func insertEnrichmentClaimFixture(
    _ dbQueue: DatabaseQueue,
    assetCount: Int,
    claimedCount: Int
) async throws -> Int64 {
    try await dbQueue.write { db in
        try db.execute(sql: "INSERT INTO library_root (path) VALUES (?)", arguments: ["/tmp/otos-claim"])
        let rootID = db.lastInsertedRowID
        for index in 0 ..< assetCount {
            let relativePath = String(format: "asset-%04d.jpg", index)
            let claimed: Int? = index < claimedCount ? 1 : nil
            try db.execute(
                sql: """
                INSERT INTO media_asset (
                    library_root_id,
                    relative_path,
                    sort_key,
                    name_sort_key,
                    name,
                    content_type_identifier,
                    byte_size,
                    content_modified_at_unix,
                    enrichment_claimed
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    rootID,
                    relativePath,
                    relativePath,
                    relativePath,
                    relativePath,
                    "public.jpeg",
                    1,
                    1000,
                    claimed,
                ]
            )
        }
        return rootID
    }
}

private func explainPlan(
    _ db: Database,
    sql: String,
    arguments: StatementArguments = StatementArguments()
) throws -> String {
    try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(sql)", arguments: arguments)
        .map { row in row["detail"] as String }
        .joined(separator: "\n")
}

private func explainPlan(_ db: Database, query: SQLQuery) throws -> String {
    try explainPlan(db, sql: query.sql, arguments: query.arguments)
}

private func usesTemporarySort(_ plan: String) -> Bool {
    plan.localizedCaseInsensitiveContains("TEMP B-TREE")
}

extension CatalogStoreQueryPlanTests {
    /// ADR 0047: what is owed faces is read from partial indexes over only the rows that owe
    /// them, never a walk of every row, which the preview reader's candidates and People's
    /// unchecked count each did on every catalog change. Each query states its index's
    /// condition, so SQLite reads it from that index.
    @Test func whatIsOwedFacesIsReadFromItsPartialIndexes() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        let (rootID1, rootID2) = try await insertPlanFixture(dbQueue)
        let (candidates, unchecked) = try await dbQueue.read { db in
            try (
                explainPlan(
                    db, sql: PreviewFaceSQL.candidatesSQL(rootCount: 2),
                    arguments: [rootID1, rootID2, Int64.min, "", 32]
                ),
                explainPlan(
                    db, sql: PreviewFaceSQL.uncheckedSQL(rootCount: 2),
                    arguments: [rootID1, rootID2, rootID1, rootID2, rootID1, rootID2]
                )
            )
        }
        #expect(candidates.contains("USING INDEX \(CatalogSchema.stillOwesFacesIndexName)"))
        #expect(!candidates.contains("SCAN media_asset"))
        #expect(!usesTemporarySort(candidates))
        for index in [CatalogSchema.stillOwesFacesIndexName, CatalogSchema.stillAwaitsPreviewIndexName, CatalogSchema.videoOwesFacesIndexName] {
            #expect(unchecked.contains("USING INDEX \(index)") || unchecked.contains("USING COVERING INDEX \(index)"), "\(unchecked)")
        }
        #expect(!unchecked.contains("SCAN media_asset"))
    }
}
