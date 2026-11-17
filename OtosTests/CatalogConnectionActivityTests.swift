import Dispatch
import Foundation
import GRDB
@testable import OtosKit
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

        let use = activity.use()
        let reads = try #require(use.holds.first { $0.operation == "countRows" })
        #expect(reads.role == "main.reader")
        #expect(reads.count == 3)
        #expect(reads.longest <= reads.total)
        #expect(use.busy["main.reader"] == use.holds.filter { $0.role == "main.reader" }.reduce(.zero) { $0 + $1.total })
        #expect(CatalogConnectionActivity.role(of: "main.reader.7") == "main.reader")
        #expect(CatalogConnectionActivity.role(of: "main.writer") == "main.writer")
        try pool.close()
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

    /// A read that brings pages into SQLite's cache is charged their bytes, and a read of pages
    /// already cached is not: what each operation asked of the file.
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
        for operation in ["coldRead", "warmRead"] {
            _ = try await pool.readFreeingConnection(operation: operation) { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM t WHERE x LIKE '%9'") ?? 0
            }
        }

        let holds = activity.use().holds
        let cold = try #require(holds.first { $0.operation == "coldRead" })
        let warm = try #require(holds.first { $0.operation == "warmRead" })
        #expect(cold.readBytes >= (pages / 2) * pageSize, "\(cold.readBytes) of \(pages * pageSize)")
        #expect(warm.readBytes < cold.readBytes / 10, "\(warm.readBytes)")
        #expect(activity.use().readBytes["main.reader"] == holds.filter { $0.role == "main.reader" }.reduce(0) { $0 + $1.readBytes })
        try pool.close()
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
