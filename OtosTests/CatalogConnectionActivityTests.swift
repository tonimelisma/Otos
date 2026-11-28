import Dispatch
import Foundation
import GRDB
@testable import OtosKit
import SQLite3
import Synchronization
import Testing

/// A read that waited names what held it as its body starts (`CatalogConnectionActivity`):
/// the connection whose transaction ended during its wait, or the ones still in one, with
/// what the Store named each for and its first statement.
@Suite(.testScope)
struct CatalogConnectionActivityTests {
    /// A pool configured as the Store configures its file's, reporting every read as a stall
    /// and keeping every transaction, so a test sees the report without waiting a second.
    private final class Stalls: Sendable {
        private let reported = Mutex<[CatalogConnectionActivity.Stall]>([])

        func append(_ stall: CatalogConnectionActivity.Stall) {
            reported.withLock { $0.append(stall) }
        }

        func first(_ operation: String) -> CatalogConnectionActivity.Stall? {
            reported.withLock { $0.first { $0.operation == operation } }
        }
    }

    private func makePool(readers: Int) throws -> (DatabasePool, Stalls) {
        let stalls = Stalls()
        let activity = CatalogConnectionActivity(stallThreshold: .zero, keptTransactionMinimum: .zero) { stalls.append($0) }
        var configuration = CatalogStore.fileBackedDatabaseConfiguration(activity: activity)
        configuration.maximumReaderCount = readers
        let directory = try makeTestDirectory()
        let pool = try DatabasePool(path: directory.appending(path: "activity.sqlite").path(percentEncoded: false), configuration: configuration)
        return (pool, stalls)
    }

    /// What an open on a held file reports, in the order it happens.
    private enum OpenEvent: Sendable {
        case waiting(connection: String)
        case opened(Result<DatabasePool, any Error>)
    }

    // Validates: ARC-072
    /// A catalog opened while another connection holds the file's exclusive lock (the last
    /// connection to a WAL file holds it while it closes, to checkpoint and remove the log)
    /// waits for the lock, writer first, and opens once it is let go, rather than failing the
    /// open with `SQLITE_BUSY` at its first pragma. The holder lets go when the writer reports
    /// that it waits, not after a time.
    @Test func aCatalogOpenedWhileAnotherConnectionHoldsTheFileWaitsForIt() async throws {
        let url = try makeTestDirectory().appending(path: "catalog.sqlite")
        try TestCatalogTemplate.copy(to: url)
        var holding = Configuration()
        holding.prepareDatabase { db in try db.execute(sql: "PRAGMA locking_mode = EXCLUSIVE") }
        let holder = try makeTestDatabaseQueue(path: url.path(percentEncoded: false), configuration: holding)
        // A write in exclusive locking mode takes the file's exclusive lock and keeps it.
        try await holder.write { db in try db.execute(sql: "PRAGMA user_version = 1") }

        let (events, event) = AsyncStream<OpenEvent>.makeStream()
        let activity = CatalogConnectionActivity(reportLockWait: { event.yield(.waiting(connection: $0)) })
        let configuration = CatalogStore.fileBackedDatabaseConfiguration(activity: activity)
        // The open blocks its thread for as long as it waits, so it runs on one of its own.
        DispatchQueue.global().async {
            event.yield(.opened(Result { try DatabasePool(path: url.path(percentEncoded: false), configuration: configuration) }))
        }
        var iterator = events.makeAsyncIterator()
        guard case let .waiting(connection) = await iterator.next() else {
            Issue.record("the open finished before it waited on the held lock")
            try holder.close()
            return
        }
        #expect(connection == "main.writer")
        try holder.close()
        guard case let .opened(opened) = await iterator.next() else {
            Issue.record("the open reported a second wait instead of opening")
            return
        }
        let pool = try opened.get()
        #expect(try await pool.read { db in try Int.fetchOne(db, sql: "PRAGMA synchronous") } == 1)
        try pool.close()
    }

    /// With one reader, a read asked while another holds the connection reports, as its body
    /// starts, the holder's transaction as ended during its wait, named and with its statement.
    @Test func aReadThatWaitedNamesTheReadThatHeldItsConnection() async throws {
        let (pool, stalls) = try makePool(readers: 1)
        try await pool.write { db in try db.execute(sql: "CREATE TABLE t (x)") }
        let gate = DispatchSemaphore(value: 0)
        let (entered, enter) = AsyncStream<Void>.makeStream()
        let holder = Task {
            try await pool.readFreeingConnection(operation: "holdingRead(of:)") { db in
                _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM t")
                enter.yield()
                gate.wait()
                return 1
            }
        }
        for await _ in entered {
            break
        }
        let asked = ContinuousClock.now
        let waiter = Task {
            try await pool.readFreeingConnection(operation: "waitingRead()", askedAt: asked) { _ in 2 }
        }
        gate.signal()
        #expect(try await holder.value == 1)
        #expect(try await waiter.value == 2)

        let stall = try #require(stalls.first("waitingRead"))
        #expect(stall.connection == "main.reader.1")
        let held = try #require(stall.endedDuringWait.first { $0.operation == "holdingRead" })
        #expect(held.connection == "main.reader.1")
        #expect(held.statement == "SELECT count(*) FROM t")
        #expect(held.endedAgoMs != nil)
        try pool.close()
    }

    /// A read reports every other connection still in a transaction: here the writer, named
    /// for its write, inside the statement that began it.
    @Test func aReadReportsTheWriteStillRunning() async throws {
        let (pool, stalls) = try makePool(readers: 1)
        try await pool.write { db in try db.execute(sql: "CREATE TABLE t (x)") }
        let gate = DispatchSemaphore(value: 0)
        let (entered, enter) = AsyncStream<Void>.makeStream()
        let writer = Task {
            try await pool.write { db in
                CatalogConnectionActivity.Connection.attached(to: db)?.named(operation: "applyBatch(_:)")
                try db.execute(sql: "INSERT INTO t (x)\n    VALUES (1)")
                enter.yield()
                gate.wait()
            }
        }
        for await _ in entered {
            break
        }

        _ = try await pool.readFreeingConnection(operation: "visibleRead()") { _ in 0 }

        gate.signal()
        try await writer.value
        let stall = try #require(stalls.first("visibleRead"))
        let running = try #require(stall.running.first { $0.connection == "main.writer" })
        #expect(running.operation == "applyBatch")
        #expect(running.statement == "INSERT INTO t (x) VALUES (1)")
        #expect(running.endedAgoMs == nil)
        #expect(stall.snapshotMs != nil)
        try pool.close()
    }

    /// A read reports the operation whose caller last resumed after a read: what a Store that
    /// holds its actor after a read is still doing.
    @Test func aReadReportsTheLastCallerToResume() async throws {
        let (pool, stalls) = try makePool(readers: 1)
        _ = try await pool.readFreeingConnection(operation: "orderedAssets(for:)") { _ in 0 }

        _ = try await pool.readFreeingConnection(operation: "visibleRead()") { _ in 0 }

        let stall = try #require(stalls.first("visibleRead"))
        #expect(stall.lastResumed == "orderedAssets")
        try pool.close()
    }

    /// Every transaction adds to its role's and operation's totals, however short, so the
    /// totals say who held the connections whether or not anyone waited.
    @Test func everyTransactionCountsTowardItsRoleAndOperation() async throws {
        let activity = CatalogConnectionActivity()
        var configuration = CatalogStore.fileBackedDatabaseConfiguration(activity: activity)
        configuration.maximumReaderCount = 2
        let directory = try makeTestDirectory()
        let pool = try DatabasePool(path: directory.appending(path: "use.sqlite").path(percentEncoded: false), configuration: configuration)
        try await pool.write { db in try db.execute(sql: "CREATE TABLE t (x)") }
        for _ in 0 ..< 3 {
            _ = try await pool.readFreeingConnection(operation: "countRows()") { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM t") ?? 0
            }
        }
        // A read resumes its caller from inside its transaction, and the connection's trace
        // counts the transaction as it ends, after that. Closing the pool waits for every
        // reader's queue, so each read's end is counted before the totals are read.
        try pool.close()

        let use = activity.use()
        let reads = try #require(use.holds.first { $0.operation == "countRows" })
        #expect(reads.role == "main.reader")
        #expect(reads.count == 3)
        #expect(reads.longest <= reads.total)
        #expect(use.busy["main.reader"] == use.holds.filter { $0.role == "main.reader" }.reduce(.zero) { $0 + $1.total })
        #expect(CatalogConnectionActivity.role(of: "main.reader.7") == "main.reader")
        #expect(CatalogConnectionActivity.role(of: "main.writer") == "main.writer")
    }

    /// A `CatalogWriter` names every transaction for its caller, a body's statements outside
    /// any `BEGIN` included (the pragmas a durable write sets around its transaction), and the open's own
    /// work is accounted to it: no transaction is left unnamed.
    @Test func everyWriteThroughTheCatalogWriterIsNamedForItsCaller() async throws {
        let activity = CatalogConnectionActivity()
        let directory = try makeTestDirectory()
        let pool = try activity.naming("catalogOpen") {
            let pool = try DatabasePool(
                path: directory.appending(path: "named.sqlite").path(percentEncoded: false),
                configuration: CatalogStore.fileBackedDatabaseConfiguration(activity: activity)
            )
            try pool.write { db in try db.execute(sql: "CREATE TABLE t (x)") }
            return pool
        }
        let writer = CatalogWriter(pool)
        func insertRow() async throws {
            try await writer.write { db in try db.execute(sql: "INSERT INTO t (x) VALUES (1)") }
        }
        try await insertRow()
        try await writer.writeWithoutTransaction(operation: "durableWrite") { db in
            try db.execute(sql: "PRAGMA synchronous = FULL")
            try db.inTransaction {
                try db.execute(sql: "INSERT INTO t (x) VALUES (2)")
                return .commit
            }
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        try await writer.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA user_version = 1") }

        let holds = activity.use().holds
        #expect(holds.allSatisfy { $0.operation != CatalogConnectionActivity.unnamed }, "\(holds.map(\.operation))")
        #expect(holds.first { $0.operation == "insertRow" }?.count == 1)
        #expect(holds.first { $0.operation == "durableWrite" }?.count == 3)
        #expect(holds.contains { $0.operation == "catalogOpen" })
        #expect(holds.contains { $0.operation == "everyWriteThroughTheCatalogWriterIsNamedForItsCaller" })
        try pool.close()
    }

    /// A read that brings pages into SQLite's cache is charged their bytes, and the pages it
    /// finds already cached are not: what each operation asked of the file.
    @Test func aReadIsChargedThePagesItReadFromTheFile() async throws {
        let activity = CatalogConnectionActivity()
        var configuration = CatalogStore.fileBackedDatabaseConfiguration(activity: activity)
        configuration.maximumReaderCount = 1
        configuration.prepareDatabase { db in
            // Past the mapped region, as most of a large catalog is: pages are read, not faulted.
            try db.execute(sql: "PRAGMA mmap_size = 0")
        }
        let directory = try makeTestDirectory()
        let pool = try DatabasePool(path: directory.appending(path: "pages.sqlite").path(percentEncoded: false), configuration: configuration)
        let writer = CatalogWriter(pool)
        try await writer.write(operation: "fill") { db in
            try db.execute(sql: "CREATE TABLE t (x)")
            for index in 0 ..< 2000 {
                try db.execute(sql: "INSERT INTO t (x) VALUES (?)", arguments: [String(repeating: "x", count: 400) + "\(index)"])
            }
        }
        let pageSize = try await pool.read { db in try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 4096 }
        let pages = try await pool.read { db in try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0 }
        // SQLite's own account of each read's pages: those it found in its cache and those it
        // read from the file. Whether a page is still cached for the second read is the
        // kernel's to decide: the system SQLite keeps its page cache in purgeable memory
        // (`vm_purgable_control`), which memory pressure reclaims between two reads.
        var served: [String: PageService] = [:]
        for operation in ["coldRead", "warmRead"] {
            served[operation] = try await pool.readFreeingConnection(operation: operation) { db in
                let hitsBefore = Self.pageCount(db, SQLITE_DBSTATUS_CACHE_HIT)
                _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM t WHERE x LIKE '%9'")
                return PageService(
                    cached: Self.pageCount(db, SQLITE_DBSTATUS_CACHE_HIT) - hitsBefore,
                    read: Self.pageCount(db, SQLITE_DBSTATUS_CACHE_MISS)
                )
            }
        }
        // The last read's end is counted after it resumes this caller (above).
        try pool.close()

        let holds = activity.use().holds
        let cold = try #require(holds.first { $0.operation == "coldRead" })
        let warm = try #require(holds.first { $0.operation == "warmRead" })
        let coldPages = try #require(served["coldRead"])
        let warmPages = try #require(served["warmRead"])
        #expect(coldPages.read >= pages / 2, "\(coldPages) of \(pages)")
        #expect(warmPages.cached + warmPages.read >= pages / 2, "\(warmPages) of \(pages)")
        #expect(cold.readBytes == coldPages.read * pageSize, "\(cold.readBytes): \(coldPages)")
        #expect(warm.readBytes == warmPages.read * pageSize, "\(warm.readBytes): \(warmPages)")
        #expect(activity.use().readBytes["main.reader"] == holds.filter { $0.role == "main.reader" }.reduce(0) { $0 + $1.readBytes })
    }

    /// The pages one read's statements took from SQLite's cache and from the file.
    private struct PageService: Sendable {
        let cached: Int64
        let read: Int64
    }

    /// SQLite's count of `status` on `db`'s connection, left as it is.
    private static func pageCount(_ db: Database, _ status: Int32) -> Int64 {
        var current: Int32 = 0
        var highwater: Int32 = 0
        sqlite3_db_status(db.sqliteConnection, status, &current, &highwater, 0)
        return Int64(current)
    }

    /// A stall's holders leave in parts the unified log keeps whole, none splitting a holder.
    @Test func holdersLeaveInPartsTheLogKeepsWhole() {
        let holders = (0 ..< 20).map { index in
            CatalogConnectionActivity.Holder(
                connection: "main.reader.\(index % 4 + 1)",
                milliseconds: 1000 + index,
                endedAgoMs: index,
                operation: "renderSignatureCandidates",
                statement: String(repeating: "SELECT x FROM t, u WHERE y ", count: 3)
            )
        }
        let parts = CatalogConnectionActivity.holderParts(holders)
        #expect(parts.count > 1)
        #expect(parts.allSatisfy { $0.count <= CatalogConnectionActivity.holderPartLength })
        #expect(parts.flatMap { $0.split(separator: ",") }.count == holders.count)
        #expect(parts.allSatisfy { !$0.contains(" ") })
    }
}
