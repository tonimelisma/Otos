import Foundation
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
        let root = FileManager.default.temporaryDirectory
            .appending(path: "OtosTests-\(UUID().uuidString)", directoryHint: .isDirectory)
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

/// A `CatalogStore` the running test case owns: the `.testScope` trait shuts it down when
/// the test ends. Its parameters are `CatalogStore.init`'s.
func makeTestStore(
    location: CatalogStore.Location,
    scanner: CatalogScanner = .live,
    filesystemWatcher: CatalogFilesystemWatcher = .live(),
    scanCadence: Duration = .seconds(1),
    wallClock: @escaping @Sendable () -> Date = { Date() },
    initialLoadDidRead: (@Sendable () async -> Void)? = nil,
    importJournalFailure: (@Sendable (ImportJournalTransition) throws -> Void)? = nil,
    walByteBudget: Int64 = CatalogStore.defaultWALByteBudget,
    stagingContainers: StagingContainers? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) -> CatalogStore {
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
        stagingContainers: stagingContainers
    )
    if let stores = TestScope.stores {
        stores.own(store)
    } else {
        Issue.record(TestScope.OutsideScope(made: "makeTestStore(...)"), sourceLocation: sourceLocation)
    }
    return store
}
