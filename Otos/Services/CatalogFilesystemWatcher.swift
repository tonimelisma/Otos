import CoreServices
import Foundation
import OSLog

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

private final nonisolated class WatcherState: @unchecked Sendable {
    private let queue = DispatchQueue(label: "net.melisma.Otos.filesystem-events")
    private let lock = NSLock()
    private var roots: [LibraryRootPath] = []
    private var handler: (@Sendable (FilesystemEvent) -> Void)?
    private var stream: FSEventStreamRef?

    func start(roots: [LibraryRootPath], handler: @escaping @Sendable (FilesystemEvent) -> Void) {
        queue.sync {
            self.roots = roots
            self.handler = handler
            recreateStreamLocked()
        }
    }

    func addRoot(_ root: LibraryRootPath) {
        queue.sync {
            guard !roots.contains(root) else {
                return
            }
            roots.append(root)
            recreateStreamLocked()
        }
    }

    func removeRoot(_ root: LibraryRootPath) {
        queue.sync {
            roots.removeAll { $0 == root }
            recreateStreamLocked()
        }
    }

    func stop() {
        queue.sync {
            invalidateStreamLocked()
            roots = []
            handler = nil
        }
    }

    private func recreateStreamLocked() {
        invalidateStreamLocked()
        guard !roots.isEmpty else {
            return
        }

        let state = OtosSignpost.fileAccess.beginInterval("FilesystemWatcherStart")
        defer {
            OtosSignpost.fileAccess.endInterval("FilesystemWatcherStart", state)
        }

        let paths = roots.map(\.rawValue) as CFArray
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

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        let rootCount = roots.count
        OtosLog.fileAccess.info("Filesystem watcher started roots=\(rootCount, privacy: .public)")
    }

    private func invalidateStreamLocked() {
        guard let stream else {
            return
        }
        let signpostState = OtosSignpost.fileAccess.beginInterval("FilesystemWatcherStop")
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        OtosSignpost.fileAccess.endInterval("FilesystemWatcherStop", signpostState)
        self.stream = nil
        OtosLog.fileAccess.info("Filesystem watcher stopped")
    }

    fileprivate func deliver(events: [FilesystemEvent]) {
        lock.lock()
        let handler = handler
        lock.unlock()
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

private final nonisolated class TestingCatalogFilesystemWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (FilesystemEvent) -> Void)?

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

    func emit(_ event: FilesystemEvent) {
        lock.lock()
        let handler = handler
        lock.unlock()
        handler?(event)
    }

    private func setHandler(_ handler: (@Sendable (FilesystemEvent) -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }
}
