import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// The catalog's write-ahead log stays bounded without waiting on a reader (ADR 0002,
/// ARC-063). A long background read is held open on the main pool's snapshot
/// (`CatalogStore.holdRead`) while bulk writes pass the WAL's budget: the writes,
/// the window's reads and a user's write go on, and once the read ends the file returns to
/// its limit. Every competing event is delivered while the read is held; nothing waits on time.
@Suite(.testScope)
struct CatalogWALBoundTests {
    private static let server = URL(string: "https://photos.example.com")!

    // Validates: ARC-063
    /// A long read in flight when a bulk write passes the WAL's budget holds up neither that
    /// write, nor a window read, nor a user's write. A checkpoint that waits for readers would
    /// keep every one of them waiting until the read ended.
    @Test func aLongReadHoldsUpNoWindowReadOrUserWriteWhenTheWALPassesItsBudget() async throws {
        try await Catalog.with(budget: 0) { catalog in
            try await catalog.whileReadIsHeld {
                try await catalog.list(count: 500, prefix: "a")
                _ = try await catalog.store.windowReads.orderedAssetIDs(for: .allMedia, availableLibraryPaths: [catalog.rootPath])
                let person = try await catalog.store.perform(.moveToNewPerson([], name: "Ian")).person
                #expect(person != nil)
            }
        }
    }

    // Validates: ARC-063
    /// Writes during a long read grow the file past its limit, since the frames that read's
    /// snapshot needs stay in the log. Once it ends, the next write's checkpoint copies every
    /// frame, the write after it restarts the log, and that commit truncates the file to the
    /// limit (SQLite keeps at least the commit's own frames, here far under the 1 MiB limit:
    /// about 120 KB for one listed item, against about 6 MB written during the read).
    @Test func theWALReturnsToItsLimitAfterTheLongReadEnds() async throws {
        let budget: Int64 = 1024 * 1024
        try await Catalog.with(budget: budget) { catalog in
            var sizes = try await catalog.whileReadIsHeld {
                for batch in 0 ..< 3 {
                    try await catalog.list(count: 500, prefix: "held\(batch)")
                }
                return try [catalog.walBytes()]
            }
            #expect(sizes[0] > budget)
            for batch in 0 ..< 2 {
                try await catalog.list(count: 1, prefix: "after\(batch)")
                try sizes.append(catalog.walBytes())
            }
            #expect(sizes[2] <= budget, "WAL bytes after each step: \(sizes)")
        }
    }

    /// A file-backed catalog with one Immich account being listed: its listing batches are the
    /// bulk writes that bound the WAL.
    private struct Catalog {
        let store: CatalogStore
        let rootPath: LibraryRootPath
        let scan: CatalogStore.ActiveScan
        let wal: String

        static func make(budget: Int64) async throws -> Catalog {
            let temp = try makeTestDirectory()
            let file = temp.appending(path: "Catalog.sqlite")
            let store = makeTestStore(
                location: .databaseFile(file), walByteBudget: budget, stagingContainers: StagingContainers(base: temp)
            )
            try await store.start(scansSavedLibraries: false)
            let rootPath = try await store.addImmichAccount(server: server, userID: "user-1", displayName: "Family")
            let scan = try await store.beginSourceListing(rootPath: rootPath)
            return Catalog(store: store, rootPath: rootPath, scan: scan, wal: file.path(percentEncoded: false) + "-wal")
        }

        func walBytes() throws -> Int64 {
            try #require(FileManager.default.attributesOfItem(atPath: wal)[.size] as? Int64)
        }

        func list(count: Int, prefix: String) async throws {
            let items = (0 ..< count).map { index in
                SourceListedItem(
                    file: ScannedMediaFile(
                        relativePath: MediaRelativePath(rawValue: "\(prefix)-\(index)/IMG.JPG"),
                        name: "IMG.JPG",
                        contentTypeIdentifier: "public.jpeg",
                        byteSize: 10,
                        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                        contentModifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
                    ),
                    sourceItemID: "\(prefix)-\(index)",
                    isInSourceTrash: false,
                    sourceHasProducts: true
                )
            }
            try await store.applySourceListingChanges(SourceListingChanges(listed: items), scan: scan)
        }

        /// A catalog for `body`, finished whether `body` returns or throws: a store left
        /// running keeps the test's folder and its writer open past the test.
        static func with(budget: Int64, _ body: (Catalog) async throws -> Void) async throws {
            let catalog = try await make(budget: budget)
            let outcome: Result<Void, any Error>
            do {
                try await body(catalog)
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            await catalog.finish()
            try outcome.get()
        }

        /// Runs `body` while a background read holds its snapshot, and releases the read
        /// whether `body` returns or throws. A read never released parks its reader's thread
        /// for good, and the store's shutdown then waits on it: a failure would become a hang.
        func whileReadIsHeld<Value>(_ body: () async throws -> Value) async throws -> Value {
            let read = try await holdRead()
            let outcome: Result<Value, any Error>
            do {
                let value = try await body()
                outcome = .success(value)
            } catch {
                outcome = .failure(error)
            }
            try await read.release()
            return try outcome.get()
        }

        /// Starts a background read and returns once it holds its snapshot.
        private func holdRead() async throws -> HeldRead {
            let held = HeldRead()
            let entered = AsyncStream<Void>.makeStream()
            held.task = Task { [store] in
                defer { entered.continuation.finish() }
                try await store.backgroundReads.holdRead {
                    entered.continuation.yield()
                    held.gate.wait()
                }
            }
            for await _ in entered.stream {
                break
            }
            return held
        }

        func finish() async {
            await store.endSourceListing(scan: scan)
            await store.shutdown()
        }
    }

    /// A read parked on its reader's own queue until the test releases it: the queue's thread
    /// blocks, as a long read's does.
    private final class HeldRead: Sendable {
        let gate = DispatchSemaphore(value: 0)
        private let state = Mutex<Task<Void, any Error>?>(nil)

        var task: Task<Void, any Error>? {
            get { state.withLock { $0 } }
            set { state.withLock { $0 = newValue } }
        }

        func release() async throws {
            gate.signal()
            try await task?.value
        }
    }
}
