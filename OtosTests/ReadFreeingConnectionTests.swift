import Dispatch
import Foundation
import GRDB
@testable import OtosKit
import Synchronization
import Testing

/// A store read frees its connection as its body ends, whatever its caller is waiting for
/// (`DatabaseReader.readFreeingConnection`), and a cancelled read stops its statement.
@Suite(.testDirectory)
struct ReadFreeingConnectionTests {
    /// A task executor whose jobs wait while its queue is suspended: a reading task held on
    /// it cannot resume, as a background read cannot when no thread of its priority is free.
    private final class HeldExecutor: TaskExecutor {
        let queue = DispatchQueue(label: "net.melisma.Otos.tests.heldExecutor")

        func enqueue(_ job: consuming ExecutorJob) {
            let job = UnownedJob(job)
            queue.async {
                job.runSynchronously(on: self.asUnownedTaskExecutor())
            }
        }
    }

    /// With one connection, a read whose task cannot resume after its body ends does not
    /// hold up the next read: the connection is back in the pool before its caller runs again.
    @Test func aReadsConnectionIsFreeBeforeItsCallerResumes() async throws {
        let directory = try makeTestDirectory()
        var configuration = Configuration()
        configuration.maximumReaderCount = 1
        let pool = try DatabasePool(path: directory.appending(path: "reads.sqlite").path(percentEncoded: false), configuration: configuration)
        try await pool.write { db in try db.execute(sql: "CREATE TABLE t (x)") }
        let executor = HeldExecutor()
        let gate = DispatchSemaphore(value: 0)
        let (entered, enter) = AsyncStream<Void>.makeStream()
        let held = Task(executorPreference: executor) {
            try await pool.readFreeingConnection { _ in
                enter.yield()
                gate.wait()
                return 1
            }
        }
        for await _ in entered {
            break
        }
        executor.queue.suspend()
        gate.signal()

        let next = try await pool.readFreeingConnection { _ in 2 }

        #expect(next == 2)
        executor.queue.resume()
        #expect(try await held.value == 1)
        try pool.close()
    }

    /// Cancelling the reading task interrupts the statement its body runs and the read throws
    /// `CancellationError`, as GRDB's own read does, so a superseded build stops at once.
    @Test func aCancelledReadStopsItsStatement() async throws {
        let directory = try makeTestDirectory()
        let pool = try DatabasePool(path: directory.appending(path: "reads.sqlite").path(percentEncoded: false))
        try await pool.write { db in try db.execute(sql: "CREATE TABLE t (x)") }
        let (entered, enter) = AsyncStream<Void>.makeStream()
        let reading = Task {
            try await pool.readFreeingConnection { db in
                enter.yield()
                // Counts to a trillion: it ends only when interrupted.
                return try Int.fetchOne(db, sql: """
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 1000000000000)
                SELECT count(*) FROM n
                """)
            }
        }
        for await _ in entered {
            break
        }
        reading.cancel()

        await #expect(throws: CancellationError.self) {
            try await reading.value
        }
        // The connection was given back, so the next read runs.
        #expect(try await pool.readFreeingConnection { _ in 1 } == 1)
        try pool.close()
    }

    /// A cancel that lands while the body runs no statement still stops the statement the body
    /// starts next: SQLite clears an interrupt that finds the connection idle.
    @Test func aCancelBetweenStatementsStopsTheNextStatement() async throws {
        let directory = try makeTestDirectory()
        let pool = try DatabasePool(path: directory.appending(path: "reads.sqlite").path(percentEncoded: false))
        let (entered, enter) = AsyncStream<Void>.makeStream()
        let cancelled = DispatchSemaphore(value: 0)
        let reading = Task {
            try await pool.readFreeingConnection { db in
                enter.yield()
                // The body is on the reader's queue, not the cooperative pool, so it may block.
                cancelled.wait()
                return try Int.fetchOne(db, sql: """
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 1000000000000)
                SELECT count(*) FROM n
                """)
            }
        }
        for await _ in entered {
            break
        }
        // The cancellation handler runs inside `cancel()`, so the read is cancelled before the
        // body goes on to its statement.
        reading.cancel()
        cancelled.signal()

        await #expect(throws: CancellationError.self) {
            try await reading.value
        }
        #expect(try await pool.readFreeingConnection { _ in 1 } == 1)
        try pool.close()
    }

    /// A task cancelled before its read starts reads nothing.
    @Test func aReadCancelledBeforeItStartsRunsNoBody() async throws {
        let directory = try makeTestDirectory()
        let pool = try DatabasePool(path: directory.appending(path: "reads.sqlite").path(percentEncoded: false))
        let ran = Mutex(false)
        let reading = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await pool.readFreeingConnection { _ in
                ran.withLock { $0 = true }
            }
        }
        await #expect(throws: CancellationError.self) {
            try await reading.value
        }
        #expect(!ran.withLock { $0 })
        try pool.close()
    }
}
