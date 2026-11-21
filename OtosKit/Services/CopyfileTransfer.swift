import Darwin
import Foundation
import Synchronization

/// `copyfile(3)` transfer with byte progress and mid-file cancellation.
nonisolated enum CopyfileTransfer {
    enum Outcome: Equatable, Sendable {
        case completed
        case cancelled
        /// `copyfile(3)` refused, with the `errno` it left — typed so the
        /// executor can tell a volume out of room (`ENOSPC`) from any other
        /// refusal without matching a message.
        case failed(errno: Int32)
    }

    /// The bytes `copyfile(3)` reports it has written so far — its own counter, read from
    /// `COPYFILE_STATE_COPIED`. There is no total: the copy never states one, and a size
    /// read separately can fail, so none is invented.
    struct Progress: Equatable, Sendable {
        let completedBytes: Int64
    }

    /// The queue every blocking copy runs on. A copy holds its thread for as long as the
    /// volume takes — seconds for a card's video — so it never runs on the cooperative pool:
    /// that pool is one thread per core, and an import's eight copies on it took every
    /// thread, so a visible tile's few-millisecond read waited 7–25 s for one to come free
    /// (`docs/research/2026-11-15-small-scope-reads-and-tile-waits.md`). A dispatch queue's
    /// threads are its own, and Dispatch adds one when a copy blocks.
    private static let queue = DispatchQueue(
        label: "net.melisma.Otos.copyfile",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Runs `copy`, a blocking transfer, on the copy queue and returns its outcome.
    static func offCooperativePool(_ copy: @escaping @Sendable () -> Outcome) async -> Outcome {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: copy())
            }
        }
    }

    static func copy(
        from source: URL,
        to destination: URL,
        onProgress: @escaping @Sendable (Progress) -> Void,
        shouldContinue: @escaping @Sendable () -> Bool
    ) -> Outcome {
        let state = copyfile_state_alloc()
        guard let state else {
            return .failed(errno: errno)
        }
        defer { copyfile_state_free(state) }

        let context = CallbackContext(onProgress: onProgress, shouldContinue: shouldContinue)
        let contextPtr = Unmanaged.passRetained(context).toOpaque()
        defer { Unmanaged<CallbackContext>.fromOpaque(contextPtr).release() }

        installStatusCallback(state: state, contextPtr: contextPtr)

        let flags = copyfile_flags_t(COPYFILE_ALL)
        let result = source.path.withCString { from in
            destination.path.withCString { to in
                copyfile(from, to, state, flags)
            }
        }

        if context.cancelled {
            removePartialCopy(at: destination)
            return .cancelled
        }
        if result != 0 {
            // The failed step's own errno, read in the callback where copyfile set it; a
            // quit leaves it as it was, but nothing between that callback and here owns it.
            let code = context.failedErrno ?? errno
            removePartialCopy(at: destination)
            return .failed(errno: code)
        }
        // The last progress callback can precede the final block; report the count
        // copyfile ends on, so a completed copy's progress is its full length.
        onProgress(Progress(completedBytes: copiedBytes(state)))
        return .completed
    }

    /// Removes what a stopped copy left at `destination`; a file already gone is the
    /// outcome wanted.
    private static func removePartialCopy(at destination: URL) {
        do {
            try FileManager.default.removeItem(at: destination)
        } catch where ErrorDiagnostics.isMissingFile(error) {
            // Already gone: the outcome this removal wanted.
        } catch {
            OtosLog.mediaIO.errorOperation("mediaOperation.copy", phase: "partialRemoveFailed", fields: [
                "path": destination.path(percentEncoded: false),
                "error": String(describing: error),
            ])
        }
    }

    private static func installStatusCallback(state: copyfile_state_t, contextPtr: UnsafeMutableRawPointer) {
        let callback: @convention(c) (
            Int32,
            Int32,
            copyfile_state_t?,
            UnsafePointer<CChar>?,
            UnsafePointer<CChar>?,
            UnsafeMutableRawPointer?
        ) -> Int32 = { what, stage, state, _, _, ctx in
            guard let ctx, let state else {
                return COPYFILE_CONTINUE
            }
            let context = Unmanaged<CallbackContext>.fromOpaque(ctx).takeUnretainedValue()
            switch CopyfileTransfer.statusAnswer(stage: stage, shouldContinue: context.shouldContinue()) {
            case .cancel:
                context.cancelled = true
                return COPYFILE_QUIT
            case .fail:
                context.failedErrno = errno
                return COPYFILE_QUIT
            case .proceed:
                if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS {
                    context.onProgress(Progress(completedBytes: copiedBytes(state)))
                }
                return COPYFILE_CONTINUE
            }
        }

        _ = copyfile_state_set(
            state,
            UInt32(COPYFILE_STATE_STATUS_CB),
            unsafeBitCast(callback, to: UnsafeMutableRawPointer.self)
        )
        _ = copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), contextPtr)
    }

    /// What the status callback answers copyfile at one step.
    enum StatusAnswer: Equatable {
        case proceed
        case cancel
        case fail
    }

    /// A failed step quits the copy rather than continuing: after `COPYFILE_ERR` on a data
    /// or extended-attribute write, `COPYFILE_CONTINUE` makes copyfile write it again
    /// (copyfile(3)), so a full disk retried forever — on 2026-10-31 eight import workers
    /// logged copyfile's "No space left on device" 1.26 million times in 30 s and never
    /// reached the executor's `ENOSPC` stop (ADR 0027).
    static func statusAnswer(stage: Int32, shouldContinue: Bool) -> StatusAnswer {
        guard shouldContinue else {
            return .cancel
        }
        return stage == COPYFILE_ERR ? .fail : .proceed
    }

    private final class CallbackContext {
        let onProgress: @Sendable (Progress) -> Void
        let shouldContinue: @Sendable () -> Bool
        private let cancelledFlag = Mutex(false)
        private let failedErrnoValue = Mutex<Int32?>(nil)
        var cancelled: Bool {
            get { cancelledFlag.withLock { $0 } }
            set { cancelledFlag.withLock { $0 = newValue } }
        }

        /// The errno of the step that failed, when one did.
        var failedErrno: Int32? {
            get { failedErrnoValue.withLock { $0 } }
            set { failedErrnoValue.withLock { $0 = newValue } }
        }

        init(
            onProgress: @escaping @Sendable (Progress) -> Void,
            shouldContinue: @escaping @Sendable () -> Bool
        ) {
            self.onProgress = onProgress
            self.shouldContinue = shouldContinue
        }
    }
}

/// The bytes `copyfile(3)` has written, from its own counter. File-level rather than a
/// member so the C status callback can call it without capturing context.
private nonisolated func copiedBytes(_ state: copyfile_state_t) -> Int64 {
    var copied: off_t = 0
    _ = withUnsafeMutablePointer(to: &copied) { pointer in
        copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), UnsafeMutableRawPointer(pointer))
    }
    return Int64(copied)
}
