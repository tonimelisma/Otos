import CoreServices
import Foundation
import OSLog
import Synchronization

/// Original path watch guide
///
/// Tells its consumer that something changed at one original's path, so an owner waiting
/// for an original it could not read (`EditSession`, while its target's open has failed)
/// waits on the filesystem's own report rather than on time (ADR 0033).
///
/// One FSEvents stream watches the path itself with `kFSEventStreamCreateFlagWatchRoot`:
/// FSEvents reports the file created, written, renamed or removed, and, through the root
/// flag, any folder along the path created, moved or mounted over — so a volume that comes
/// back, or a folder a sync client puts back, is reported even when the catalog sees no row
/// change. The path need not exist when the watch starts.
///
/// The stream is armed when `changes(of:)` returns, and stops when its consumer stops
/// listening. Each delivery yields once (newest-wins): the consumer looks at the file
/// itself, so how many events there were is never a fact it reads.
nonisolated enum OriginalPathWatch {
    static func changes(of url: URL) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let path = url.path(percentEncoded: false)
        guard let watch = PathEventStream(path: path, continuation: continuation) else {
            // No stream: the consumer falls back to the signals it has besides this one.
            continuation.finish()
            return stream
        }
        continuation.onTermination = { _ in watch.stop() }
        return stream
    }
}

/// One path's FSEvents stream. Its callback and its stop run on its own serial queue, so no
/// callback runs after `stop()`; the termination handler holds the object until then.
private final nonisolated class PathEventStream: Sendable {
    private let queue = DispatchQueue(label: "net.melisma.Otos.original-path-watch")
    private let path: String
    private let running = Mutex<RunningPathStream?>(nil)

    init?(path: String, continuation: AsyncStream<Void>.Continuation) {
        self.path = path
        let queue = queue
        // The stream, and the target its callback reads, are made, started and stored inside
        // the lock, so nothing they reference leaves the region the lock guards.
        let failure: String? = running.withLock { slot in
            let target = PathEventTarget(continuation: continuation)
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(target).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagWatchRoot
            )
            // Latency 0.1 s: FSEvents' own coalescing of a burst into one delivery, as the
            // library roots' streams use; it delays a report, it never stands in for one.
            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                originalPathEventCallback,
                &context,
                [path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.1,
                flags
            ) else {
                return "createFailed"
            }
            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                return "startFailed"
            }
            slot = RunningPathStream(stream: stream, target: target)
            return nil
        }
        if let failure {
            OtosLog.fileAccess.errorOperation("original.watch", phase: failure, fields: ["path": path])
            return nil
        }
        OtosLog.fileAccess.debugOperation("original.watch", phase: "start", fields: ["path": path])
    }

    func stop() {
        queue.sync {
            running.withLock { slot in
                guard let current = slot else { return }
                FSEventStreamStop(current.stream)
                FSEventStreamInvalidate(current.stream)
                FSEventStreamRelease(current.stream)
                slot = nil
            }
            OtosLog.fileAccess.debugOperation("original.watch", phase: "stop", fields: ["path": path])
        }
    }
}

/// A started stream and the target its callback reads; the target lives as long as the
/// stream, which is invalidated before either is released.
private nonisolated struct RunningPathStream {
    let stream: FSEventStreamRef
    let target: PathEventTarget
}

/// What the callback reaches through the stream's context: where a delivery is reported.
private final nonisolated class PathEventTarget {
    let continuation: AsyncStream<Void>.Continuation

    init(continuation: AsyncStream<Void>.Continuation) {
        self.continuation = continuation
    }
}

/// The parameter list is `FSEventStreamCallback`'s, fixed by CoreServices.
private nonisolated func originalPathEventCallback(
    _: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths _: UnsafeMutableRawPointer,
    eventFlags _: UnsafePointer<FSEventStreamEventFlags>,
    eventIDs _: UnsafePointer<FSEventStreamEventId>
) {
    guard let clientCallBackInfo, numEvents > 0 else {
        return
    }
    let target = Unmanaged<PathEventTarget>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
    target.continuation.yield()
}
