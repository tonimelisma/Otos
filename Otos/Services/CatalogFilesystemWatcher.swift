import CoreServices
import Foundation
import OSLog
import Synchronization

/// Filesystem watcher guide
///
/// Subscribes to macOS File System Events for saved library roots and forwards
/// file-level notifications to a Store-owned handler. This type never decides
/// persistence, debounce policy, or scan scheduling.
nonisolated struct FilesystemEvent: Equatable {
    let path: String
    let flags: UInt32
}

nonisolated struct CatalogFilesystemWatcher {
    var start: @Sendable (
        _ roots: [LibraryRootPath],
        _ handler: @Sendable @escaping (FilesystemEvent) -> Void
    ) -> Void
    var addRoot: @Sendable (LibraryRootPath) -> Void
    var removeRoot: @Sendable (LibraryRootPath) -> Void
    var stop: @Sendable () -> Void

    static let live = CatalogFilesystemWatcher(
        start: { roots, handler in
            LiveCatalogFilesystemWatcher.start(roots: roots, handler: handler)
        },
        addRoot: { root in
            LiveCatalogFilesystemWatcher.addRoot(root)
        },
        removeRoot: { root in
            LiveCatalogFilesystemWatcher.removeRoot(root)
        },
        stop: {
            LiveCatalogFilesystemWatcher.stop()
        }
    )

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

// MARK: - Live

private nonisolated enum LiveCatalogFilesystemWatcher {
    private static let state = WatcherState()

    static func start(roots: [LibraryRootPath], handler: @escaping @Sendable (FilesystemEvent) -> Void) {
        state.start(roots: roots, handler: handler)
    }

    static func addRoot(_ root: LibraryRootPath) {
        state.addRoot(root)
    }

    static func removeRoot(_ root: LibraryRootPath) {
        state.removeRoot(root)
    }

    static func stop() {
        state.stop()
    }
}

private nonisolated struct WatcherStorage {
    var roots: [LibraryRootPath] = []
    var handler: (@Sendable (FilesystemEvent) -> Void)?
    var stream: FSEventStreamRef?
}

private final nonisolated class WatcherState: Sendable {
    private let queue = DispatchQueue(label: "net.melisma.Otos.filesystem-events")
    private let storage = Mutex(WatcherStorage())

    func start(roots: [LibraryRootPath], handler: @escaping @Sendable (FilesystemEvent) -> Void) {
        queue.sync {
            storage.withLock { storage in
                storage.roots = roots
                storage.handler = handler
                recreateStreamLocked(storage: &storage)
            }
        }
    }

    func addRoot(_ root: LibraryRootPath) {
        queue.sync {
            storage.withLock { storage in
                guard !storage.roots.contains(root) else {
                    return
                }
                storage.roots.append(root)
                recreateStreamLocked(storage: &storage)
            }
        }
    }

    func removeRoot(_ root: LibraryRootPath) {
        queue.sync {
            storage.withLock { storage in
                storage.roots.removeAll { $0 == root }
                recreateStreamLocked(storage: &storage)
            }
        }
    }

    func stop() {
        queue.sync {
            storage.withLock { storage in
                invalidateStreamLocked(storage: &storage)
                storage.roots = []
                storage.handler = nil
            }
        }
    }

    private func recreateStreamLocked(storage: inout WatcherStorage) {
        invalidateStreamLocked(storage: &storage)
        guard !storage.roots.isEmpty else {
            return
        }

        let state = OtosSignpost.fileAccess.beginInterval("FilesystemWatcherStart")
        defer {
            OtosSignpost.fileAccess.endInterval("FilesystemWatcherStart", state)
        }

        let paths = storage.roots.map(\.rawValue) as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagIgnoreSelf
                | kFSEventStreamCreateFlagMarkSelf
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            filesystemEventStreamCallback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            flags
        ) else {
            OtosLog.fileAccess.error("Filesystem watcher stream creation failed")
            return
        }

        storage.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        let rootCount = storage.roots.count
        OtosLog.fileAccess.info("Filesystem watcher started roots=\(rootCount, privacy: .public)")
    }

    private func invalidateStreamLocked(storage: inout WatcherStorage) {
        guard let stream = storage.stream else {
            return
        }
        let signpostState = OtosSignpost.fileAccess.beginInterval("FilesystemWatcherStop")
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        OtosSignpost.fileAccess.endInterval("FilesystemWatcherStop", signpostState)
        storage.stream = nil
        OtosLog.fileAccess.info("Filesystem watcher stopped")
    }

    fileprivate func deliver(events: [FilesystemEvent]) {
        let handler = storage.withLock { storage in
            storage.handler
        }
        guard let handler else {
            return
        }
        for event in events {
            let signpost = OtosSignpost.fileAccess.beginInterval("FilesystemWatcherEvent")
            OtosLog.fileAccess.debug(
                "Filesystem event path=\(event.path, privacy: .public) flags=\(event.flags, privacy: .public)"
            )
            OtosSignpost.fileAccess.endInterval("FilesystemWatcherEvent", signpost)
            handler(event)
        }
    }
}

// swiftlint:disable function_parameter_count
private nonisolated func filesystemEventStreamCallback(
    _: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _: UnsafePointer<FSEventStreamEventId>
) {
    guard let clientCallBackInfo,
          numEvents > 0
    else {
        return
    }

    let client = Unmanaged<WatcherState>
        .fromOpaque(clientCallBackInfo)
        .takeUnretainedValue()

    let pathsArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
    var events: [FilesystemEvent] = []
    events.reserveCapacity(numEvents)
    for index in 0 ..< numEvents {
        guard let path = pathsArray[index] as? String else {
            continue
        }
        events.append(FilesystemEvent(path: path, flags: eventFlags[index]))
    }
    client.deliver(events: events)
}

// swiftlint:enable function_parameter_count

// MARK: - Testing

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
