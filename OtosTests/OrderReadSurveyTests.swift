import Foundation
import GRDB
@testable import OtosKit
import SQLite3
import Testing

/// Every order the window can ask for, on a generated catalog of the owner's shape: each sort
/// under each kind of scope, with no filter and with each filter the window offers. For each,
/// the plan, whether it sorts in a temporary b-tree, whether its walk is covering, the pages a
/// cold connection reads, the rows SQLite visits for each row returned, and the time. A
/// measurement at the owner's size, on demand
/// (`OTOS_SCALE_TEST=1 script/check.sh --only OrderReadSurveyTests`): it writes a 2.3 GB file.
/// The report goes to `build/order-survey/owner.txt`, and each read's SQL with its arguments
/// written in, to `build/order-survey/sql/`, so the same reads can be asked of another catalog
/// read-only with `sqlite3`.
@Suite(.testScope, .serialized)
struct OrderReadSurveyTests {
    @Test(.enabled(if: StallReproductionTests.ownerSize))
    func everyOrderTheWindowAsksForOnTheOwnersShape() throws {
        let directory = try makeTestDirectory()
        let catalog = try OwnerShapedCatalog.make(in: directory, scale: 1)
        let path = catalog.databaseURL.path(percentEncoded: false)
        let queue = try makeTestDatabaseQueue(path: path)
        try queue.writeWithoutTransaction { db in
            // One photo in a hundred Liked, as a choices filter finds them.
            try db.execute(sql: "UPDATE media_asset SET media_choice = 'liked' WHERE byte_size % 100 = 0")
            try db.checkpoint(.truncate)
        }
        let picks = try queue.read { db in try Picks(db) }
        try queue.close()
        let reads = OrderReadSurvey.reads(picks)
        var lines: [String] = []
        let sqlDirectory = SourceTree.root.appending(path: "build/order-survey/sql")
        try? FileManager.default.removeItem(at: sqlDirectory)
        try FileManager.default.createDirectory(at: sqlDirectory, withIntermediateDirectories: true)
        for read in reads {
            guard let measured = try OrderReadSurvey.measure(read, path: path) else {
                lines.append("op=orderSurvey read=\(read.name) outcome=selectsNothing")
                continue
            }
            lines.append(measured.line)
            try Data((measured.literalSQL + ";\n").utf8).write(to: sqlDirectory.appending(path: "\(read.name).sql"))
        }
        let url = SourceTree.root.appending(path: "build/order-survey/owner.txt")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        try FileManager.default.removeItem(at: directory)
    }

    /// The rows the narrow scopes and the filters name, read from the generated catalog.
    struct Picks {
        let person: Int64
        let batch: Int64
        let digest: Data
        let members: [CatalogScopePredicate.MemberKey]
        let area: MapArea
        let place: PlaceFilter

        init(_ db: Database) throws {
            person = try Int64.fetchOne(db, sql: """
            SELECT person_id FROM face WHERE person_id IS NOT NULL GROUP BY person_id ORDER BY count(*) DESC LIMIT 1
            """) ?? 0
            batch = try Int64.fetchOne(db, sql: "SELECT max(import_batch_unix_ms) FROM media_asset") ?? 0
            digest = try Data.fetchOne(db, sql: """
            SELECT content_sha1 FROM media_asset WHERE content_sha1 IS NOT NULL GROUP BY content_sha1 ORDER BY count(*) DESC LIMIT 1
            """) ?? Data(count: 20)
            members = try Row.fetchAll(db, sql: """
            SELECT library_root_id, relative_path FROM media_asset WHERE library_root_id = 7 ORDER BY relative_path LIMIT 40
            """).map { CatalogScopePredicate.MemberKey(rootID: $0[0], relativePath: $0[1]) }
            let point = try Row.fetchOne(db, sql: """
            SELECT primary_latitude, primary_longitude FROM asset_metadata WHERE primary_latitude IS NOT NULL LIMIT 1
            """)
            let latitude: Double = point?[0] ?? 0
            let longitude: Double = point?[1] ?? 0
            area = MapArea(south: latitude - 0.5, north: latitude + 0.5, west: longitude - 0.5, east: longitude + 0.5)
            let named = try Row.fetchOne(db, sql: "SELECT language, country FROM place_cell WHERE country IS NOT NULL LIMIT 1")
            guard let place = PlaceFilter(
                language: PlaceNameLanguage(identifier: named?[0] ?? "en"),
                keys: [PlaceFilterKey(country: named?[1] ?? "", town: nil)]
            ) else {
                throw CocoaError(.coderValueNotFound)
            }
            self.place = place
        }
    }
}

/// The survey's reads and their measurement, shared with the plan tests.
enum OrderReadSurvey {
    struct Read {
        let name: String
        let descriptor: CatalogQueryDescriptor
        let scope: CatalogScopePredicate
    }

    struct Measured {
        let line: String
        let literalSQL: String
        let rows: Int
        let pages: Int64
        let plan: [String]
        let loops: [(name: String, visited: Int64)]
        let tempBTree: Bool
    }

    static let sorts: [(String, MediaSortOrder)] = [
        ("dateNewest", .dateNewest), ("dateOldest", .dateOldest),
        ("nameAsc", .filenameAscending), ("nameDesc", .filenameDescending),
        ("sizeLargest", .sizeLargest), ("sizeSmallest", .sizeSmallest),
    ]

    static func reads(_ picks: OrderReadSurveyTests.Picks) -> [Read] {
        let all: [Int64] = [6, 7, 15]
        let person = PersonID(rawValue: picks.person)
        let scopes: [(String, SidebarSelection, CatalogScopePredicate)] = [
            ("allMedia", .allMedia, CatalogScopePredicate(rootIDs: all, showsOneCopy: true, holdsEveryCopyRoot: true)),
            ("allMediaOneLibraryOffline", .allMedia, CatalogScopePredicate(rootIDs: [7, 15], showsOneCopy: true)),
            ("library15", .allMedia, CatalogScopePredicate(rootIDs: [15])),
            ("library7", .allMedia, CatalogScopePredicate(rootIDs: [7])),
            ("places", .places, CatalogScopePredicate(rootIDs: all, location: .located, showsOneCopy: true, holdsEveryCopyRoot: true)),
            ("mapArea", .mapArea(picks.area), CatalogScopePredicate(
                rootIDs: all, location: .within(picks.area), showsOneCopy: true, holdsEveryCopyRoot: true
            )),
            ("people", .people, CatalogScopePredicate(rootIDs: all, content: .withPerson, showsOneCopy: true, holdsEveryCopyRoot: true)),
            ("person", .person(person), CatalogScopePredicate(
                rootIDs: all, content: .person(picks.person), showsOneCopy: true, holdsEveryCopyRoot: true
            )),
            ("importBatch", .allMedia, CatalogScopePredicate(rootIDs: all, importBatchUnixMs: picks.batch)),
            ("duplicates", .allMedia, CatalogScopePredicate(rootIDs: all, content: .duplicated(.acrossLibraries))),
            ("identical", .allMedia, CatalogScopePredicate(rootIDs: all, content: .identical(ContentDigest(data: picks.digest) ?? .empty))),
            ("members", .allMedia, CatalogScopePredicate(rootIDs: all, content: .members(picks.members))),
        ]
        let filters: [(String, MediaFilter)] = [
            ("none", .all),
            ("video", MediaFilter(kinds: [.video])),
            ("image", MediaFilter(kinds: [.image])),
            ("raw", MediaFilter(kinds: [.raw])),
            ("imageRaw", MediaFilter(kinds: [.image, .raw])),
            ("heif", MediaFilter(fileTypes: [FilterFileType(kind: .image, format: MediaFormatToken(rawValue: "HEIF"))])),
            ("liked", MediaFilter(choices: [.liked])),
            ("notRated", MediaFilter(choices: [.notRated])),
            ("personFilter", MediaFilter(people: [person])),
            ("unassignedFaces", MediaFilter(unassignedFaces: true)),
            ("placeFilter", MediaFilter(places: picks.place)),
            ("videoLiked", MediaFilter(kinds: [.video], choices: [.liked])),
        ]
        var reads: [Read] = []
        for (scopeName, selection, scope) in scopes {
            var orders = sorts
            if case .person = selection {
                orders += [("likenessMost", .likenessMost), ("likenessLeast", .likenessLeast)]
            }
            for (filterName, filter) in filters {
                for (sortName, sort) in orders {
                    reads.append(Read(
                        name: "\(scopeName).\(filterName).\(sortName)",
                        descriptor: CatalogQueryDescriptor(scope: selection, filter: filter, sort: sort),
                        scope: scope
                    ))
                }
            }
        }
        let day = CalendarDay(year: 2026, month: 11, day: 16)
        reads.append(Read(
            name: "onThisDay.none.fixed",
            descriptor: CatalogQueryDescriptor(scope: .onThisDay(day)),
            scope: CatalogScopePredicate(rootIDs: all, date: .anniversary(day), showsOneCopy: true, holdsEveryCopyRoot: true)
        ))
        return reads
    }

    /// One read on a fresh connection with no memory map and a cache that holds every page it
    /// reads, so each page is read from the file once: its plan, pages, rows, the rows its
    /// loops visit and its time. Nil when the scope selects nothing.
    static func measure(_ read: Read, path: String) throws -> Measured? {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA mmap_size = 0")
            try db.execute(sql: "PRAGMA cache_size = -4000000")
        }
        let queue = try makeTestDatabaseQueue(path: path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.read { db -> Measured? in
            guard let query = try CatalogQueryGateway.orderedAssetIDQuery(
                descriptor: read.descriptor, scope: read.scope, stacks: .readWhenNeeded(.paired), db: db
            ) else {
                return nil
            }
            let plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(query.sql)", arguments: query.arguments)
                .map { $0["detail"] as String }
            var baseline: Int32 = 0
            var highest: Int32 = 0
            sqlite3_db_status(db.sqliteConnection, SQLITE_DBSTATUS_CACHE_MISS, &baseline, &highest, 0)
            let statement = try db.makeStatement(sql: query.sql)
            try statement.setArguments(query.arguments)
            let start = ContinuousClock.now
            var rows = 0
            let cursor = try Row.fetchCursor(statement)
            while try cursor.next() != nil {
                rows += 1
            }
            let milliseconds = DiagnosticsTiming.milliseconds(since: start)
            var current: Int32 = 0
            sqlite3_db_status(db.sqliteConnection, SQLITE_DBSTATUS_CACHE_MISS, &current, &highest, 0)
            let visits = loopVisits(statement.sqliteStatement)
            let sorts = sqlite3_stmt_status(statement.sqliteStatement, SQLITE_STMTSTATUS_SORT, 0)
            let main = plan.first ?? ""
            let tempBTree = plan.contains { $0.contains("TEMP B-TREE") }
            let covering = main.contains("COVERING INDEX")
            let visited = visits.map(\.visited).reduce(0, +)
            let perRow = rows == 0 ? Double(visited) : Double(visited) / Double(rows)
            let line = """
            op=orderSurvey read=\(read.name) rows=\(rows) pages=\(current - baseline) ms=\(milliseconds) \
            visited=\(visited) visitedPerRow=\(String(format: "%.2f", perRow)) sorts=\(sorts) tempBTree=\(tempBTree) \
            coveringWalk=\(covering) loops=\(visits.map { "\($0.name):\($0.visited)" }.joined(separator: ",")) \
            plan=\(plan.joined(separator: " | "))
            """
            return Measured(
                line: line, literalSQL: literal(statement), rows: rows, pages: Int64(current - baseline), plan: plan,
                loops: visits, tempBTree: tempBTree
            )
        }
    }

    /// The rows each loop of the statement visited (`SQLITE_SCANSTAT_NVISIT`), by its table or
    /// index.
    static func loopVisits(_ statement: OpaquePointer) -> [(name: String, visited: Int64)] {
        var loops: [(String, Int64)] = []
        var loop: Int32 = 0
        while true {
            var visited: Int64 = 0
            guard sqlite3_stmt_scanstatus(statement, loop, SQLITE_SCANSTAT_NVISIT, &visited) == 0 else { break }
            var name: UnsafePointer<CChar>?
            _ = sqlite3_stmt_scanstatus(statement, loop, SQLITE_SCANSTAT_NAME, &name)
            loops.append((name.map { String(cString: $0) } ?? "loop\(loop)", visited))
            loop += 1
        }
        return loops
    }

    /// The statement's SQL with its bound arguments written in (`sqlite3_expanded_sql`).
    static func literal(_ statement: Statement) -> String {
        guard let expanded = sqlite3_expanded_sql(statement.sqliteStatement) else {
            return statement.sql
        }
        defer { sqlite3_free(expanded) }
        return String(cString: expanded)
    }
}
