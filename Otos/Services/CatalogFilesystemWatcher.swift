import CoreServices
import Darwin
import Foundation
import OSLog
import Synchronization

/// Filesystem watcher guide
///
/// Subscribes to macOS File System Events for saved library roots, one stream per root,
/// and forwards what each stream delivers to a Store-owned handler. A root watched from a
/// stored event ID replays the volume's FSEvents history since that ID before its live
/// events, then reports `historyDone`; that replay is how a launch learns what changed
/// while Otos was not running (ADR 0002, "Change Journal"). This type never decides
/// persistence, scan scheduling or what an event means.
nonisolated struct FilesystemEvent: Equatable {
    let path: String
    let flags: UInt32
    /// The event's FSEvents ID. Zero where FSEvents gives none (`RootChanged`).
    let id: UInt64

    init(path: String, flags: UInt32, id: UInt64 = 0) {
        self.path = path
        self.flags = flags
        self.id = id
    }
}

/// What a root's stream delivered: one event, or the end of its history replay.
nonisolated enum FilesystemWatcherDelivery: Equatable {
    case event(FilesystemEvent)
    /// Every event the volume recorded under the root before its stream started has been
    /// delivered (`kFSEventStreamEventFlagHistoryDone`). Sent only to a root watched from
    /// an event ID.
    case historyDone(LibraryRootPath)
}

/// Where a root's change journal stands now (`CatalogFilesystemWatcher.probe`).
nonisolated struct FilesystemJournalProbe: Equatable {
    /// `FSEventsCopyUUIDForDevice` of the root's volume: the identity of its event
    /// database. Nil when the volume keeps no history (FSEvents: read-only, network).
    let volumeUUID: String?
    /// `FSEventsGetCurrentEventId()` when probed: a stream started from it misses nothing
    /// that happens after the probe.
    let currentEventID: UInt64
    /// The root folder's inode: a folder replaced at the same path has another.
    let rootIdentity: UInt64
}

nonisolated struct CatalogFilesystemWatcher {
    /// The root's journal facts, or nil when the root cannot be read.
    var probe: @Sendable (LibraryRootPath) -> FilesystemJournalProbe?
    var start: @Sendable (_ handler: @Sendable @escaping (FilesystemWatcherDelivery) -> Void) -> Void
    /// Watches `root` from event `since` (replaying history after it, then `historyDone`),
    /// or from now when `since` is nil. A root already watched keeps its stream.
    var watch: @Sendable (_ root: LibraryRootPath, _ since: UInt64?) -> Void
    var unwatch: @Sendable (LibraryRootPath) -> Void
    var stop: @Sendable () -> Void

    /// A watcher with its own streams and handler. Each call is independent: two stores
    /// never share a stream, so one store's `stop()` cannot silence another's events. The
    /// streams stop when `stop()` is called or when the last copy of the watcher is released.
    static func live() -> CatalogFilesystemWatcher {
        let lifetime = LiveCatalogFilesystemWatcher()
        return CatalogFilesystemWatcher(
            probe: { root in
                LiveFilesystemJournal.probe(root)
            },
            start: { handler in
                lifetime.state.start(handler: handler)
            },
            watch: { root, since in
                lifetime.state.watch(root, since: since)
            },
            unwatch: { root in
                lifetime.state.unwatch(root)
            },
            stop: {
                lifetime.state.stop()
            }
        )
    }
}

// MARK: - Live

nonisolated enum LiveFilesystemJournal {
    static func probe(_ root: LibraryRootPath) -> FilesystemJournalProbe? {
        var info = stat()
        guard stat(root.rawValue, &info) == 0 else {
            return nil
        }
        let uuid = FSEventsCopyUUIDForDevice(info.st_dev).map { CFUUIDCreateString(nil, $0) as String }
        return FilesystemJournalProbe(
            volumeUUID: uuid,
            currentEventID: FSEventsGetCurrentEventId(),
            rootIdentity: UInt64(info.st_ino)
        )
    }
}

/// Owns one `WatcherState` for as long as any copy of its `CatalogFilesystemWatcher`
/// exists. Releasing this owner stops every stream on the watcher's queue first, so no
/// callback can run against a freed state. Handlers forward deliveries and hold no
/// reference back to the watcher, so the owner is never released on that queue.
private final nonisolated class LiveCatalogFilesystemWatcher: Sendable {
    let state = WatcherState()

    deinit {
        state.stop()
    }
}

/// One root's stream and the context its callback reads. The context lives as long as
/// the stream: it is released only after `FSEventStreamInvalidate`, on the queue every
/// callback runs on.
private final nonisolated class RootStream {
    let root: LibraryRootPath
    unowned let state: WatcherState
    var stream: FSEventStreamRef?

    init(root: LibraryRootPath, state: WatcherState) {
        self.root = root
        self.state = state
    }
}

private nonisolated struct WatcherStorage {
    var handler: (@Sendable (FilesystemWatcherDelivery) -> Void)?
    var streams: [LibraryRootPath: RootStream] = [:]
}

private final nonisolated class WatcherState: Sendable {
    private let queue = DispatchQueue(label: "net.melisma.Otos.filesystem-events")
    private let storage = Mutex(WatcherStorage())

    func start(handler: @escaping @Sendable (FilesystemWatcherDelivery) -> Void) {
        queue.sync {
            storage.withLock { $0.handler = handler }
        }
    }

    func watch(_ root: LibraryRootPath, since: UInt64?) {
        queue.sync {
            storage.withLock { storage in
                guard storage.streams[root] == nil else {
                    return
                }
                let rootStream = RootStream(root: root, state: self)
                guard createStream(rootStream, since: since) else {
                    return
                }
                storage.streams[root] = rootStream
            }
        }
    }

    func unwatch(_ root: LibraryRootPath) {
        queue.sync {
            storage.withLock { storage in
                if let rootStream = storage.streams.removeValue(forKey: root) {
                    invalidate(rootStream)
                }
            }
        }
    }

    func stop() {
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync {
            storage.withLock { storage in
                for rootStream in storage.streams.values {
                    invalidate(rootStream)
                }
                storage.streams = [:]
                storage.handler = nil
            }
        }
    }

    private func createStream(_ rootStream: RootStream, since: UInt64?) -> Bool {
        let signpost = OtosSignpost.fileAccess.beginInterval("FilesystemWatcherStart")
        defer { OtosSignpost.fileAccess.endInterval("FilesystemWatcherStart", signpost) }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(rootStream).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        // `FullHistory`: a replay delivers every event of the history chunk holding `since`,
        // even ones just before it, so none near an unclean exit is skipped; an event
        // delivered twice is reconciled twice, which changes nothing.
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagIgnoreSelf
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagFullHistory
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            filesystemEventStreamCallback,
            &context,
            [rootStream.root.rawValue] as CFArray,
            since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            flags
        ) else {
            OtosLog.fileAccess.errorOperation("filesystem.watch", phase: "createFailed", fields: [
                "rootPath": rootStream.root.rawValue,
            ])
            return false
        }
        rootStream.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            OtosLog.fileAccess.errorOperation("filesystem.watch", phase: "startFailed", fields: [
                "rootPath": rootStream.root.rawValue,
            ])
            invalidate(rootStream)
            return false
        }
        OtosLog.fileAccess.noticeOperation("filesystem.watch", phase: "start", fields: [
            "rootPath": rootStream.root.rawValue,
            "since": since.map { "\($0)" } ?? "now",
        ])
        return true
    }

    private func invalidate(_ rootStream: RootStream) {
        guard let stream = rootStream.stream else {
            return
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        rootStream.stream = nil
        OtosLog.fileAccess.info("Filesystem watcher stopped root=\(rootStream.root.rawValue, privacy: .public)")
    }

    fileprivate func deliver(_ deliveries: [FilesystemWatcherDelivery]) {
        let handler = storage.withLock { $0.handler }
        guard let handler else {
            return
        }
        for delivery in deliveries {
            handler(delivery)
        }
    }
}

/// The parameter list is `FSEventStreamCallback`'s, fixed by CoreServices.
private nonisolated func filesystemEventStreamCallback(
    _: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIDs: UnsafePointer<FSEventStreamEventId>
) {
    guard let clientCallBackInfo, numEvents > 0 else {
        return
    }
    let rootStream = Unmanaged<RootStream>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
    let pathsArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
    var deliveries: [FilesystemWatcherDelivery] = []
    deliveries.reserveCapacity(numEvents)
    for index in 0 ..< numEvents {
        // The sentinel ending a replay carries no path to act on (FSEvents.h).
        if eventFlags[index] & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 {
            deliveries.append(.historyDone(rootStream.root))
            continue
        }
        guard let path = pathsArray[index] as? String else {
            continue
        }
        deliveries.append(.event(FilesystemEvent(
            path: CatalogPath.catalogSpelling(ofEventPath: path),
            flags: eventFlags[index],
            id: eventIDs[index]
        )))
    }
    rootStream.state.deliver(deliveries)
}
