import Foundation
import GRDB
@testable import OtosKit
import Testing

/// Plan 0116: a candidate walk visits every row exactly once, in its index's order, whatever
/// the page size: rows tied at one capture time, rows with none, and a cursor whose root has
/// gone.
struct CandidateWalkTests {
    private static func table() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try db.execute(sql: """
            CREATE TABLE t (library_root_id INTEGER NOT NULL, relative_path TEXT NOT NULL, best_capture_local DOUBLE,
                PRIMARY KEY (library_root_id, relative_path));
            CREATE INDEX t_order ON t(best_capture_local DESC, library_root_id, relative_path);
            """)
            let rows: [(Int64, String, Double?)] = [
                (1, "a", 30), (1, "b", 20), (1, "c", 20), (2, "a", 20), (2, "b", nil), (1, "d", nil),
                (2, "c", 10), (3, "a", 20), (3, "b", 40), (1, "e", 20),
            ]
            for row in rows {
                try db.execute(sql: "INSERT INTO t VALUES (?, ?, ?)", arguments: [row.0, row.1, row.2])
            }
        }
        return dbQueue
    }

    @Test(arguments: [1, 2, 3, 4, 7, 50])
    func aCaptureWalkReadsTheNewestFirstOrderOnceAtAnyPageSize(limit: Int) async throws {
        let dbQueue = try Self.table()
        try await dbQueue.read { db in
            let expected = try Row.fetchAll(db, sql: """
            SELECT library_root_id, relative_path FROM t WHERE library_root_id IN (1, 2)
            ORDER BY best_capture_local DESC, library_root_id, relative_path
            """).map { "\($0[0] as Int64)/\($0[1] as String)" }
            var walked: [String] = []
            var cursor: CaptureOrderCursor?
            repeat {
                let (rows, next) = try CandidateWalk.capturePage(
                    row: "a", after: cursor, limit: limit, arguments: [1, 2], db: db
                ) { position, order in
                    """
                    SELECT a.best_capture_local, a.library_root_id, a.relative_path FROM t AS a INDEXED BY t_order
                    WHERE a.library_root_id IN (?, ?) AND \(position) \(order) LIMIT ?
                    """
                }
                #expect(rows.count <= limit)
                walked += rows.map { "\($0["library_root_id"] as Int64)/\($0["relative_path"] as String)" }
                cursor = next
            } while cursor != nil
            #expect(walked == expected)
        }
    }

    @Test(arguments: [1, 2, 3, 10])
    func aKeyWalkReadsEachRootInPathOrderOnce(limit: Int) async throws {
        let dbQueue = try Self.table()
        try await dbQueue.read { db in
            var walked: [String] = []
            var cursor: AssetKeyCursor?
            repeat {
                let (rows, next) = try CandidateWalk.keyPage(
                    sql: "SELECT library_root_id, relative_path FROM t WHERE library_root_id = ? AND relative_path > ? ORDER BY relative_path LIMIT ?",
                    rootIDs: [3, 1], after: cursor, limit: limit, db: db
                )
                walked += rows.map { "\($0["library_root_id"] as Int64)/\($0["relative_path"] as String)" }
                cursor = next
            } while cursor != nil
            #expect(walked == ["1/a", "1/b", "1/c", "1/d", "1/e", "3/a", "3/b"])
        }
    }

    /// A root that left between pages: the walk goes on with the next root.
    @Test func aKeyWalkWhoseRootLeftGoesOnWithTheNext() async throws {
        let dbQueue = try Self.table()
        try await dbQueue.read { db in
            let (rows, next) = try CandidateWalk.keyPage(
                sql: "SELECT library_root_id, relative_path FROM t WHERE library_root_id = ? AND relative_path > ? ORDER BY relative_path LIMIT ?",
                rootIDs: [1, 3], after: AssetKeyCursor(rootID: 2, relativePath: "a"), limit: 10, db: db
            )
            #expect(rows.map { $0["relative_path"] as String } == ["a", "b"])
            #expect(next == nil)
        }
    }
}
