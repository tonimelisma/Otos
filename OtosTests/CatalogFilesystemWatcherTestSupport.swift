import Foundation
@testable import OtosKit
import Synchronization

/// Filesystem watcher test harness
///
/// Watchers that never create an `FSEventStream`: `noop` ignores everything, and the
/// `testing` variants hand the test an `emit` that calls the handler the Store
/// registered, so a test delivers an event at exactly the point it chooses.
extension CatalogFilesystemWatcher {
    static let noop = CatalogFilesystemWatcher(
        start: { _, _ in },
        addRoot: { _ in },
        removeRoot: { _ in },
        stop: {}
    )

    /// Test harness that invokes the registered handler without `FSEventStream`.
    static func testing() -> (watcher: CatalogFilesystemWatcher, emit: @Sendable (FilesystemEvent) -> Void) {
        TestingCatalogFilesystemWatcher.make()
    }

    static func testingWithRootInspection() -> (
        CatalogFilesystemWatcherInspection
    ) {
        TestingCatalogFilesystemWatcher.makeWithRootInspection()
    }
}

nonisolated struct CatalogFilesystemWatcherInspection {
    let watcher: CatalogFilesystemWatcher
    let emit: @Sendable (FilesystemEvent) -> Void
    let roots: @Sendable () -> [LibraryRootPath]
}

private nonisolated struct TestingWatcherStorage {
    var handler: (@Sendable (FilesystemEvent) -> Void)?
    var roots: [LibraryRootPath] = []
}

private final nonisolated class TestingCatalogFilesystemWatcher: Sendable {
    private let storage = Mutex(TestingWatcherStorage())

    static func make() -> (watcher: CatalogFilesystemWatcher, emit: @Sendable (FilesystemEvent) -> Void) {
        let harness = TestingCatalogFilesystemWatcher()
        let watcher = CatalogFilesystemWatcher(
            start: { _, handler in
                harness.setHandler(handler)
            },
            addRoot: { _ in },
            removeRoot: { _ in },
            stop: {
                harness.setHandler(nil)
            }
        )
        return (watcher, harness.emit)
    }

    static func makeWithRootInspection() -> CatalogFilesystemWatcherInspection {
        let harness = TestingCatalogFilesystemWatcher()
        let watcher = CatalogFilesystemWatcher(
            start: { roots, handler in
                harness.setRoots(roots)
                harness.setHandler(handler)
            },
            addRoot: { root in
                harness.addRoot(root)
            },
            removeRoot: { root in
                harness.removeRoot(root)
            },
            stop: {
                harness.setRoots([])
                harness.setHandler(nil)
            }
        )
        return CatalogFilesystemWatcherInspection(watcher: watcher, emit: harness.emit, roots: harness.roots)
    }

    func emit(_ event: FilesystemEvent) {
        let handler = storage.withLock { storage in
            storage.handler
        }
        handler?(event)
    }

    private func setHandler(_ handler: (@Sendable (FilesystemEvent) -> Void)?) {
        storage.withLock { storage in
            storage.handler = handler
        }
    }

    private func setRoots(_ roots: [LibraryRootPath]) {
        storage.withLock { storage in
            storage.roots = roots
        }
    }

    private func addRoot(_ root: LibraryRootPath) {
        storage.withLock { storage in
            guard !storage.roots.contains(root) else {
                return
            }
            storage.roots.append(root)
        }
    }

    private func removeRoot(_ root: LibraryRootPath) {
        storage.withLock { storage in
            storage.roots.removeAll { $0 == root }
        }
    }

    private func roots() -> [LibraryRootPath] {
        storage.withLock { storage in
            storage.roots
        }
    }
}
