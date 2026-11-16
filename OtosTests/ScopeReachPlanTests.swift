import Foundation
import GRDB
@testable import OtosKit
import Testing

/// A person, On This Day's day and a map area seek their own rows while the seek visits fewer
/// rows than the walk of the order would by the measured ratio (`SeekSize`), and walk the
/// order once they hold more: the most photographed person, a day of a library taken in one
/// day and the whole world as an area are most of the catalog, which a seek reads a random
/// page or two a row of where the walk reads a fixed share of a page a row
/// (`docs/research/2026-11-15-large-narrow-scopes.md`). Each pair below sits on either side of
/// the boundary: one candidate fewer than the catalog's rows divided by the ratio seeks, one
/// more walks.
@Suite(.testDirectory)
struct ScopeReachPlanTests {
    /// The catalog's rows, all in the first of two roots: the walk visits every row of the
    /// catalog under the global order indexes.
    static let rows = 300

    @Test func aPersonSeeksTheirPhotosUntilTheyAreTooManyAndThenWalksTheOrder() async throws {
        let seeking = (Self.rows - 1) / SeekSize.personRatio
        let dbQueue = try await Self.catalog { db, rootID in
            try Self.addPerson(1, photos: 0 ..< seeking, rootID: rootID, db: db)
            try Self.addPerson(2, photos: 100 ..< 100 + seeking + 1, rootID: rootID, db: db)
        }
        let sought = try await Self.problems(
            dbQueue,
            seeking: CatalogScopePredicate(rootIDs: [1, 2], content: .person(1)),
            seekLine: "SEARCH media_asset USING INDEX sqlite_autoindex_media_asset_1",
            rows: seeking
        )
        let walked = try await Self.problems(
            dbQueue,
            walking: CatalogScopePredicate(rootIDs: [1, 2], content: .person(2)),
            rows: seeking + 1
        )
        #expect(sought.isEmpty, "\(sought)")
        #expect(walked.isEmpty, "\(walked)")
    }

    @Test func onThisDaySeeksItsDayUntilTheDayIsTooLargeAndThenWalksTheOrder() async throws {
        let seeking = (Self.rows - 1) / SeekSize.dayRatio
        let dbQueue = try await Self.catalog { db, _ in
            // Earlier years' 15 November holds `seeking` rows, their 16 November one more.
            try db.execute(
                sql: "UPDATE media_asset SET capture_wall_compact = 20201115120000 + rowid % 60 WHERE rowid <= ?",
                arguments: [seeking]
            )
            try db.execute(
                sql: "UPDATE media_asset SET capture_wall_compact = 20201116120000 + rowid % 60 WHERE rowid > ? AND rowid <= ?",
                arguments: [seeking, 2 * seeking + 1]
            )
        }
        let sought = try await Self.problems(
            dbQueue,
            seeking: CatalogScopePredicate(rootIDs: [1, 2], date: .anniversary(CalendarDay(year: 2026, month: 11, day: 15))),
            seekLine: "SEARCH media_asset USING INDEX \(AnniversaryMatch.indexName) (capture_day=?",
            rows: seeking
        )
        let walked = try await Self.problems(
            dbQueue,
            walking: CatalogScopePredicate(rootIDs: [1, 2], date: .anniversary(CalendarDay(year: 2026, month: 11, day: 16))),
            rows: seeking + 1
        )
        #expect(sought.isEmpty, "\(sought)")
        #expect(walked.isEmpty, "\(walked)")
    }

    @Test func aMapAreaSeeksItsCellsUntilTheyHoldTooManyRowsAndThenWalksTheOrder() async throws {
        let seeking = (Self.rows - 1) / SeekSize.areaRatio
        let dbQueue = try await Self.catalog { db, rootID in
            try Self.locate(0 ..< seeking, latitude: 10, rootID: rootID, db: db)
            try Self.locate(100 ..< 100 + seeking + 1, latitude: 40, rootID: rootID, db: db)
        }
        let sought = try await Self.problems(
            dbQueue,
            seeking: CatalogScopePredicate(rootIDs: [1, 2], location: .within(MapArea(south: 9, north: 11, west: 19, east: 21))),
            seekLine: "SEARCH asset_metadata USING INDEX \(PlaceCellSQL.indexName) (place_cell_latitude>?",
            rows: seeking
        )
        let walked = try await Self.problems(
            dbQueue,
            walking: CatalogScopePredicate(rootIDs: [1, 2], location: .within(MapArea(south: 39, north: 41, west: 19, east: 21))),
            rows: seeking + 1
        )
        #expect(sought.isEmpty, "\(sought)")
        #expect(walked.isEmpty, "\(walked)")
    }

    // MARK: - Expectations

    private static let sorts = [
        MediaSortOrder(field: .bestDate, direction: .descending),
        MediaSortOrder(field: .name, direction: .ascending),
        MediaSortOrder(field: .size, direction: .descending),
    ]

    /// What is wrong with `scope`'s reads for a scope that seeks: every read seeks its rows
    /// (`seekLine`) and scans no `media_asset`, its order builds the stacks of its rows, and
    /// its order and count hold `rows` rows. Empty when nothing is.
    private static func problems(
        _ dbQueue: DatabaseQueue,
        seeking scope: CatalogScopePredicate,
        seekLine: String,
        rows: Int
    ) async throws -> [String] {
        let read = try await reads(dbQueue, scope: scope)
        var problems = read.plans.filter { plan in
            !plan.contains { $0.hasPrefix(seekLine) } || plan.contains { $0.hasPrefix("SCAN media_asset") }
        }.map { "plan does not seek: \($0)" }
        problems += read.problems(span: .rows, rows: rows)
        return problems
    }

    /// What is wrong with `scope`'s reads for a scope that walks: every order walks its order
    /// index with no temporary sort, no read seeks the cells or the day, the order builds
    /// every stack of its roots, and its order and count hold `rows` rows.
    private static func problems(
        _ dbQueue: DatabaseQueue,
        walking scope: CatalogScopePredicate,
        rows: Int
    ) async throws -> [String] {
        let read = try await reads(dbQueue, scope: scope)
        let orderIndexes = ["idx_media_asset_best_capture_global_", "idx_media_asset_name_global_", "idx_media_asset_size_global_"]
        var problems = read.plans.prefix(sorts.count).filter { plan in
            plan.first.map { line in orderIndexes.contains { line.contains($0) } } != true
                || plan.contains { $0.localizedCaseInsensitiveContains("TEMP B-TREE") }
        }.map { "order does not walk: \($0)" }
        problems += read.plans.filter { plan in
            plan.contains { $0.contains(PlaceCellSQL.indexName) || $0.contains(AnniversaryMatch.indexName) }
        }.map { "plan seeks: \($0)" }
        problems += read.problems(span: .roots, rows: rows)
        return problems
    }

    /// The plans of the order under each sort, the filter's types and the count; the rows and
    /// stack span the order reads with no stacks held, and the count.
    private static func reads(
        _ dbQueue: DatabaseQueue,
        scope: CatalogScopePredicate
    ) async throws -> Reads {
        try await dbQueue.read { db in
            var queries = try sorts.map { sort in
                try #require(try CatalogQueryGateway.orderedAssetIDQuery(
                    descriptor: CatalogQueryDescriptor(scope: .allMedia, sort: sort), scope: scope, db: db
                ))
            }
            try queries.append(#require(try CatalogQueryGateway.distinctFilterableTypesQuery(scope: scope, db: db)))
            if !scope.isAnniversary {
                try queries.append(#require(try CatalogQueryGateway.countQuery(scope: scope, db: db)))
            }
            let plans = try queries.map { query in
                try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(query.sql)", arguments: query.arguments)
                    .map { ($0["detail"] as String).trimmingCharacters(in: .whitespaces) }
            }
            let order = try CatalogQueryGateway.readOrder(
                descriptor: CatalogQueryDescriptor(scope: .allMedia),
                scope: scope,
                stackRootPaths: [1: LibraryRootPath(rawValue: "/tmp/otos-reach-a/")],
                held: nil,
                db: db
            )
            return try Reads(
                plans: plans, span: order.stacks.span, rows: order.rows.count,
                count: CatalogQueryGateway.countAssets(scope: scope, db: db)
            )
        }
    }

    private struct Reads {
        let plans: [[String]]
        let span: PhotoStackSQL.Span
        let rows: Int
        let count: Int

        func problems(span expected: PhotoStackSQL.Span, rows expectedRows: Int) -> [String] {
            var problems: [String] = []
            if span != expected {
                problems.append("stacks span \(span), not \(expected)")
            }
            if rows != expectedRows || count != expectedRows {
                problems.append("order \(rows) and count \(count) rows, not \(expectedRows)")
            }
            return problems
        }
    }

    // MARK: - Fixture

    /// `rows` rows in the first of two roots, each taken on 3 March 2019 unless `shape` says
    /// otherwise.
    private static func catalog(_ shape: @escaping @Sendable (Database, Int64) throws -> Void) async throws -> DatabaseQueue {
        let url = try makeTestDirectory().appending(path: "catalog.sqlite")
        let dbQueue = try DatabaseQueue(path: url.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        try await dbQueue.write { db in
            try db.execute(sql: "INSERT INTO library_root (id, path) VALUES (1, '/tmp/otos-reach-a/'), (2, '/tmp/otos-reach-b/')")
            try db.execute(sql: """
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?)
            INSERT INTO media_asset (
                library_root_id, relative_path, sort_key, name_sort_key, name, content_type_identifier,
                byte_size, content_modified_at_unix, capture_wall_compact, enriched_kind
            )
            SELECT 1, printf('IMG_%04d.JPG', i), printf('img_%04d', i), printf('img_%04d', i), printf('IMG_%04d.JPG', i),
                   'public.jpeg', i, 1000, 20190303120000 + i % 60, 'image'
            FROM n
            """, arguments: [rows])
            try shape(db, 1)
        }
        return dbQueue
    }

    private static func addPerson(_ person: Int64, photos: Range<Int>, rootID: Int64, db: Database) throws {
        try db.execute(sql: "INSERT INTO person (id, name) VALUES (?, ?)", arguments: [person, "Person \(person)"])
        for index in photos {
            try db.execute(sql: """
            INSERT INTO face (library_root_id, relative_path, face_index, box_x, box_y, box_width, box_height,
                              landmarks, quality, analysis_revision, person_id)
            VALUES (?, ?, 0, 0.1, 0.1, 0.2, 0.2, x'00', 0.8, 1, ?)
            """, arguments: [rootID, String(format: "IMG_%04d.JPG", index + 1), person])
        }
    }

    private static func locate(_ photos: Range<Int>, latitude: Double, rootID: Int64, db: Database) throws {
        for index in photos {
            try db.execute(sql: """
            INSERT INTO asset_metadata (library_root_id, relative_path, primary_latitude, primary_longitude)
            VALUES (?, ?, ?, 20)
            """, arguments: [rootID, String(format: "IMG_%04d.JPG", index + 1), latitude])
        }
    }
}
