import Foundation
import Testing

/// Test directory guide
///
/// A test that needs real files gets them from `makeTestDirectory()`, and the
/// directory's lifetime is the test's: the `.testDirectory` trait creates one unique
/// root per test case before it runs, publishes it through a task-local, and removes
/// it — every file and SQLite database a test wrote under it — when the test case
/// ends, however it ends. Nothing a test writes outlives it, and parallel runs in
/// several worktrees never share a path.
///
/// The root is published only inside the trait's scope, so `makeTestDirectory()`
/// called from a suite that forgot the trait throws instead of quietly falling back
/// to a directory nothing would remove.
struct TestDirectoryTrait: SuiteTrait, TestTrait, TestScoping {
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
        try await TestDirectory.$root.withValue(root) {
            try await function()
        }
    }
}

extension Trait where Self == TestDirectoryTrait {
    /// Gives each test case its own directory for `makeTestDirectory()`, removed
    /// when the test case ends.
    static var testDirectory: Self {
        Self()
    }
}

enum TestDirectory {
    /// The running test case's root, set only inside `TestDirectoryTrait`'s scope.
    /// Child and unstructured tasks the test starts inherit it; detached ones do not.
    @TaskLocal static var root: URL?

    struct OutsideScope: Error, CustomStringConvertible {
        var description: String {
            "makeTestDirectory() was called outside a test with the .testDirectory trait; "
                + "add it to the test or its suite so the directory is removed when the test ends"
        }
    }
}

/// Creates a new, empty directory under the running test's root and returns it. Each
/// call returns a distinct directory; all of them go when the test ends.
func makeTestDirectory() throws -> URL {
    guard let root = TestDirectory.root else {
        throw TestDirectory.OutsideScope()
    }
    let url = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}
