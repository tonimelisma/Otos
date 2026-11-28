import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// Background reads take at most `CatalogReadAdmission.backgroundReaders` of the pool's
/// readers, in the order asked, so a window read always finds one free (ADR 0002).
/// The machine is tested as a sequence of events; the Store with every competing
/// event delivered while the background reads are held on their readers' queues.
struct ReadAdmissionMachineTests {
    // Validates: ARC-067
    @Test func readsBeyondTheCapacityWaitInTheOrderAsked() {
        var machine = ReadAdmissionMachine(capacity: 2)
        #expect(machine.handle(.request(1)) == [.grant(1)])
        #expect(machine.handle(.request(2)) == [.grant(2)])
        #expect(machine.handle(.request(3)).isEmpty)
        #expect(machine.handle(.request(4)).isEmpty)
        #expect(machine.waiting == [3, 4])
        #expect(machine.handle(.release(2)) == [.grant(3)])
        #expect(machine.handle(.release(1)) == [.grant(4)])
        #expect(machine.running == [3, 4])
    }

    // Validates: ARC-067
    @Test func aWithdrawnWaiterTakesNoTurnAndAReleaseNamesOnlyARunningRead() {
        var machine = ReadAdmissionMachine(capacity: 1)
        #expect(machine.handle(.request(1)) == [.grant(1)])
        #expect(machine.handle(.request(2)).isEmpty)
        #expect(machine.handle(.withdraw(2)) == [.refuse(2)])
        // A waiter already granted or gone withdraws nothing; a release of a waiter frees no turn.
        #expect(machine.handle(.withdraw(1)).isEmpty)
        #expect(machine.handle(.release(2)).isEmpty)
        #expect(machine.running == [1])
        #expect(machine.handle(.release(1)).isEmpty)
        #expect(machine.running.isEmpty && machine.waiting.isEmpty)
    }
}

@Suite(.testScope)
struct CatalogReadLanesTests {
    // Validates: ARC-067
    /// With every background turn held on its reader, the next background read waits for a
    /// turn, a window read is answered, and the waiting read enters as soon as one ends.
    @Test func aWindowReadIsAnsweredWhileBackgroundReadsHoldEveryTurn() async throws {
        let store = try await Self.fileBackedStore()
        var held: [HeldRead] = []
        for _ in 0 ..< CatalogReadAdmission.backgroundReaders {
            try await held.append(HeldRead.start(on: store.backgroundReads))
        }
        let next = HeldRead.starting(on: store.backgroundReads)
        try await waitUntil { store.backgroundReadTurns.waiting.count == 1 }
        #expect(store.backgroundReadTurns.running.count == CatalogReadAdmission.backgroundReaders)

        let order = try await store.windowReads.orderedAssetIDs(for: .allMedia, availableLibraryPaths: [])
        #expect(order.isEmpty)
        try await store.windowReads.holdRead {}

        try await held.removeFirst().release()
        try await next.entered()
        #expect(store.backgroundReadTurns.waiting.isEmpty)
        try await next.release()
        for read in held {
            try await read.release()
        }
        #expect(store.backgroundReadTurns.running.isEmpty)
    }

    // Validates: ARC-067
    /// A background read cancelled while it waits for a turn throws, leaves the queue and takes
    /// no turn: the turns stay with the reads that hold them, and none is left taken after.
    @Test func aCancelledWaiterLeavesTheQueueAndTakesNoTurn() async throws {
        let store = try await Self.fileBackedStore()
        var held: [HeldRead] = []
        for _ in 0 ..< CatalogReadAdmission.backgroundReaders {
            try await held.append(HeldRead.start(on: store.backgroundReads))
        }
        let waiter = HeldRead.starting(on: store.backgroundReads)
        try await waitUntil { store.backgroundReadTurns.waiting.count == 1 }

        waiter.task.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.task.value }
        #expect(store.backgroundReadTurns.waiting.isEmpty)
        #expect(store.backgroundReadTurns.running.count == CatalogReadAdmission.backgroundReaders)
        #expect(!waiter.didEnter)

        for read in held {
            try await read.release()
        }
        #expect(store.backgroundReadTurns.running.isEmpty)
    }

    private static func fileBackedStore() async throws -> CatalogStore {
        let directory = try makeTestDirectory()
        let store = makeTestStore(location: .databaseFile(directory.appending(path: "Catalog.sqlite")))
        try await store.start(scansSavedLibraries: false)
        return store
    }
}

/// A read parked on its reader's own queue until the test releases it: the queue's thread
/// blocks, as a long read's does.
private final class HeldRead: Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let entry = AsyncStream<Void>.makeStream()
    private let state = Mutex<(task: Task<Void, any Error>?, entered: Bool)>((nil, false))

    var task: Task<Void, any Error> {
        state.withLock { $0.task! }
    }

    var didEnter: Bool {
        state.withLock(\.entered)
    }

    /// Starts the read and returns once it holds its reader.
    static func start(on reads: BackgroundReads) async throws -> HeldRead {
        let read = starting(on: reads)
        try await read.entered()
        return read
    }

    /// Starts the read and returns at once: it may still be waiting for its turn.
    static func starting(on reads: BackgroundReads) -> HeldRead {
        let read = HeldRead()
        let task = Task { [read] in
            defer { read.entry.continuation.finish() }
            try await reads.holdRead {
                read.state.withLock { $0.entered = true }
                read.entry.continuation.yield()
                read.gate.wait()
            }
        }
        read.state.withLock { $0.task = task }
        return read
    }

    func entered() async throws {
        for await _ in entry.stream {
            return
        }
        try await task.value
    }

    func release() async throws {
        gate.signal()
        try await task.value
    }
}
