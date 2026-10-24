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

    /// A watcher with its own `FSEventStream`, root list and handler. Each call is
    /// independent: two stores never share a stream, so one store's `stop()` or `start`
    /// cannot silence or redirect another's events. The stream stops when `stop()` is
    /// called or when the last copy of the returned watcher is released.
    static func live() -> CatalogFilesystemWatcher {
        let lifetime = LiveCatalogFilesystemWatcher()
        return CatalogFilesystemWatcher(
            start: { roots, handler in
                lifetime.state.start(roots: roots, handler: handler)
            },
            addRoot: { root in
                lifetime.state.addRoot(root)
            },
            removeRoot: { root in
                lifetime.state.removeRoot(root)
            },
            stop: {
                lifetime.state.stop()
            }
        )
    }
}

// MARK: - Live

/// Owns one `WatcherState` for as long as any copy of its `CatalogFilesystemWatcher`
/// exists. The stream's callback context points at the state unretained; releasing this
/// owner stops the stream on its queue first, so no callback can run against a freed state.
/// The owner is never released on the watcher queue: handlers forward events and hold no
/// reference back to the watcher.
private final nonisolated class LiveCatalogFilesystemWatcher: Sendable {
    let state = WatcherState()

    deinit {
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
        dispatchPrecondition(condition: .notOnQueue(queue))
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
                | kFSEventStreamCreateFlagWatchRoot
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

// The parameter list is `FSEventStreamCallback`'s, fixed by CoreServices.
// swiftlint:disable:next function_parameter_count
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
