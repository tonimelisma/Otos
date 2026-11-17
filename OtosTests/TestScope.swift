import Darwin
import Foundation
import GRDB
@testable import OtosKit
import Synchronization
import Testing

/// Test scope guide
///
/// A test case's resources live exactly as long as the test case. The `.testScope` trait
/// wraps each test case in one scope that owns two kinds of resource:
///
/// - **Files.** The scope creates one unique root before the test runs and publishes it
///   through a task-local; `makeTestDirectory()` hands out directories under it. When the
///   test case ends, however it ends, the root is removed with every file and SQLite
///   database the test wrote, so nothing outlives it and parallel runs in several
///   worktrees never share a path.
/// - **Catalog stores.** A test makes every `CatalogStore` through `makeTestStore(...)`,
///   which hands it to the scope. When the test case ends the scope shuts each one down,
///   before the files go, so a store's reconcile loop, scans, filesystem watching and
///   integrity scheduler end with the test rather than idling in the test host for the rest
///   of the run. A test may still shut a store down itself, mid-test, when that is what it
///   tests; shutting down again is a no-op.
///
/// The process owns the roots too (`TestTemporaryFolders`). Each root's name carries the
/// process id (`OtosTests-<pid>-<uuid>`), so whose it is can be read from the name. A root
/// written again after its test removed it is removed when the process exits, and a process
/// that starts removes the roots of processes that no longer run, which a host killed mid-run
/// leaves. `script/test.sh` fails a run that leaves one (`op=test.tempLeak`).
///
/// Both are published only inside the scope. `makeTestDirectory()` called from a suite that
/// forgot the trait throws, and `makeTestStore(...)` records an issue, rather than quietly
/// handing out something nothing would clean up. Constructing a `CatalogStore` directly in
/// a test is a lint error (`test_store_owned_by_scope`), so a test cannot make a store the
/// scope does not own.
struct TestScopeTrait: SuiteTrait, TestTrait, TestScoping {
    /// Applied to a suite, the scope wraps each test case in it (and in nested
    /// suites), never the suite as a whole.
    var isRecursive: Bool {
        true
    }

    @concurrent
    func provideScope(
        for _: Test,
        testCase _: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        let root = TestTemporaryFolders.makeRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                Issue.record(error, "the test directory \(root.path) could not be removed")
            }
        }
        let stores = TestScopeStores()
        do {
            try await TestScope.$root.withValue(root) {
                try await TestScope.$stores.withValue(stores) {
                    try await function()
                }
            }
        } catch {
            await stores.shutDownAll()
            throw error
        }
        await stores.shutDownAll()
    }
}

extension Trait where Self == TestScopeTrait {
    /// Gives each test case its own directory for `makeTestDirectory()` and owns the stores
    /// it makes with `makeTestStore(...)`: both end when the test case ends.
    static var testScope: Self {
        Self()
    }
}

enum TestScope {
    /// The running test case's root, set only inside `TestScopeTrait`'s scope.
    /// Child and unstructured tasks the test starts inherit it; detached ones do not.
    @TaskLocal static var root: URL?
    /// The stores the running test case made, set only inside `TestScopeTrait`'s scope.
    @TaskLocal static var stores: TestScopeStores?

    struct OutsideScope: Error, CustomStringConvertible {
        let made: String

        var description: String {
            "\(made) was called outside a test with the .testScope trait; add it to the test "
                + "or its suite so what it makes ends when the test ends"
        }
    }
}

/// The stores one test case made, in the order it made them. They are held weakly: the
/// scope never keeps a store alive, so a test that proves a store is released (by a sentinel
/// only the store holds) still sees it go, and a store released mid-test has already ended
/// its own loops (`CatalogStore.deinit`).
final class TestScopeStores: Sendable {
    private struct Owned {
        weak var store: CatalogStore?
    }

    private let stores = Mutex<[Owned]>([])

    func own(_ store: CatalogStore) {
        stores.withLock { $0.append(Owned(store: store)) }
    }

    /// Shuts every store still alive down, newest first, so a store made over another's
    /// files ends before the one it was made from.
    func shutDownAll() async {
        let alive = stores.withLock { stores in
            defer { stores.removeAll() }
            return stores.compactMap(\.store)
        }
        for store in alive.reversed() {
            await store.shutdown()
        }
    }
}

/// Creates a new, empty directory under the running test's root and returns it. Each
/// call returns a distinct directory; all of them go when the test ends.
func makeTestDirectory() throws -> URL {
    guard let root = TestScope.root else {
        throw TestScope.OutsideScope(made: "makeTestDirectory()")
    }
    let url = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

/// What a store made on a database file that does not exist yet opens.
enum TestCatalogStart {
    /// A copy of the empty catalog at the current schema (`TestCatalogTemplate`): the open
    /// has nothing to migrate.
    case currentSchema
    /// No file: the open creates it and runs every migration from the baseline, for a test
    /// about that open.
    case nothing
}

/// A `CatalogStore` the running test case owns: the `.testScope` trait shuts it down when
/// the test ends. Its other parameters are `CatalogStore.init`'s. A `.databaseFile` location
/// with no file yet starts as `start` says; an existing file is opened as it is, and an
/// in-memory location starts at the current schema in the Store itself.
func makeTestStore(
    location: CatalogStore.Location,
    startingFrom start: TestCatalogStart = .currentSchema,
    scanner: CatalogScanner = .live,
    filesystemWatcher: CatalogFilesystemWatcher = .liveWithoutHistory(),
    scanCadence: Duration = .seconds(1),
    wallClock: @escaping @Sendable () -> Date = { Date() },
    initialLoadDidRead: (@Sendable () async -> Void)? = nil,
    importJournalFailure: (@Sendable (ImportJournalTransition) throws -> Void)? = nil,
    walByteBudget: Int64 = CatalogStore.defaultWALByteBudget,
    stagingContainers: StagingContainers? = nil,
    stallThreshold: Duration = CatalogConnectionActivity.defaultStallThreshold,
    sourceLocation: SourceLocation = #_sourceLocation
) -> CatalogStore {
    if case let .databaseFile(url) = location, start == .currentSchema,
       !FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    {
        do {
            try TestCatalogTemplate.copy(to: url)
        } catch {
            Issue.record(error, "the current-schema catalog could not be copied to \(url.path)", sourceLocation: sourceLocation)
        }
    }
    // swiftlint:disable:next test_store_owned_by_scope
    let store = CatalogStore(
        location: location,
        scanner: scanner,
        filesystemWatcher: filesystemWatcher,
        scanCadence: scanCadence,
        wallClock: wallClock,
        initialLoadDidRead: initialLoadDidRead,
        importJournalFailure: importJournalFailure,
        walByteBudget: walByteBudget,
        stagingContainers: stagingContainers,
        stallThreshold: stallThreshold
    )
    if let stores = TestScope.stores {
        stores.own(store)
    } else {
        Issue.record(TestScope.OutsideScope(made: "makeTestStore(...)"), sourceLocation: sourceLocation)
    }
    return store
}

/// A test's own connection to a database file, which waits on another connection's lock on the
/// file as the Store's connections do (`ConnectionLockWait`). GRDB's default for a queue is no
/// wait at all, and a test's connection meets a store's: the last connection of a store the
/// test released closes on its own time, holding the file's exclusive lock while it
/// checkpoints the log and removes it, and a store's writer holds the log's write lock while
/// it commits. `configuration`'s own busy mode is replaced.
func makeTestDatabaseQueue(path: String, configuration: Configuration = Configuration()) throws -> DatabaseQueue {
    var configuration = configuration
    configuration.busyMode = ConnectionLockWait.busyMode()
    // swiftlint:disable:next test_connection_waits_on_locks
    return try DatabaseQueue(path: path, configuration: configuration)
}

/// One empty catalog file at the current schema per test process, which every store a test
/// makes on a new database file starts as. A full run opened about 750 new catalogs (about 280
/// of them files) within 15 s; each ran every migration from the baseline, about 100 ms of a
/// cooperative thread, and no store's first read resumed until the burst was over. The
/// template is built by the first test that needs one, with the migrator the Store runs and
/// the pool it opens a file with (WAL), so it is always the schema a store would have
/// migrated to; nothing about it is checked in. Each test gets its own copy, an APFS clone
/// (`COPYFILE_CLONE`, a plain copy where cloning is not supported), and its store opens it
/// with nothing to migrate. The folder is the process's (`TestTemporaryFolders`), removed at
/// exit.
nonisolated enum TestCatalogTemplate {
    private static let file = Result<URL, any Error> {
        let root = TestTemporaryFolders.makeRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "catalog.sqlite", directoryHint: .notDirectory)
        let pool = try DatabasePool(path: url.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(pool)
        // Everything in the main file, so the copy needs no log beside it.
        try pool.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
        try pool.close()
        return url
    }

    /// Copies the template to `url`, creating its folder.
    static func copy(to url: URL) throws {
        let template = try file.get()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard copyfile(template.path(percentEncoded: false), url.path(percentEncoded: false), nil, copyfile_flags_t(COPYFILE_CLONE)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

/// The test process's own temporary folders: every root it named, removed again at exit,
/// and the roots of processes that no longer run, removed when it starts.
nonisolated enum TestTemporaryFolders {
    /// The prefix every root's name starts with; `script/test.sh` reads the same.
    static let prefix = "OtosTests-"

    private static let registry = Mutex<[URL]>([])

    /// Installed once, on the first root: the stale sweep and the exit sweep.
    private static let installed: Void = {
        sweepRootsOfProcessesThatEnded()
        atexit {
            TestTemporaryFolders.removeRootsAtExit()
        }
    }()

    /// A new root's URL, named for this process and registered for the exit sweep.
    static func makeRoot() -> URL {
        _ = installed
        let root = FileManager.default.temporaryDirectory
            .appending(path: "\(prefix)\(getpid())-\(UUID().uuidString)", directoryHint: .isDirectory)
        registry.withLock { $0.append(root) }
        return root
    }

    /// The process id a root's name carries, or nil for a name not of this form.
    static func processID(ofRootNamed name: String) -> pid_t? {
        guard name.hasPrefix(prefix) else {
            return nil
        }
        let rest = name.dropFirst(prefix.count)
        guard let dash = rest.firstIndex(of: "-") else {
            return nil
        }
        return pid_t(rest[rest.startIndex ..< dash])
    }

    /// Whether a process with this id runs now: `kill(pid, 0)` reports `ESRCH` for one that
    /// does not.
    static func isRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }

    /// Removes every root, under the temporary folder, whose process no longer runs.
    static func sweepRootsOfProcessesThatEnded() {
        let folder = FileManager.default.temporaryDirectory
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
        } catch {
            report("sweepEnded", phase: "unreadable", error: error)
            return
        }
        let roots = names.compactMap { name -> URL? in
            guard let pid = processID(ofRootNamed: name), pid != getpid(), !isRunning(pid) else {
                return nil
            }
            return folder.appending(path: name, directoryHint: .isDirectory)
        }
        remove(roots, phase: "sweptEnded")
    }

    /// Removes this process's roots that exist again at exit.
    private static func removeRootsAtExit() {
        let roots = registry.withLock { $0 }.filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        remove(roots, phase: "sweptAtExit")
    }

    private static func remove(_ roots: [URL], phase: String) {
        var removed = 0
        for root in roots {
            do {
                try FileManager.default.removeItem(at: root)
                removed += 1
            } catch {
                report(root.lastPathComponent, phase: "removeFailed", error: error)
            }
        }
        if removed > 0 {
            FileHandle.standardError.write(Data("op=test.tempFolders phase=\(phase) removed=\(removed)\n".utf8))
        }
    }

    private static func report(_ subject: String, phase: String, error: any Error) {
        FileHandle.standardError.write(Data("op=test.tempFolders phase=\(phase) subject=\(subject) error=\(error)\n".utf8))
    }
}
