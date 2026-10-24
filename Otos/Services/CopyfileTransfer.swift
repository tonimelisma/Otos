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
            try? FileManager.default.removeItem(at: destination)
            return .cancelled
        }
        if result != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: destination)
            return .failed(errno: code)
        }
        // The last progress callback can precede the final block; report the count
        // copyfile ends on, so a completed copy's progress is its full length.
        onProgress(Progress(completedBytes: copiedBytes(state)))
        return .completed
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
            if !context.shouldContinue() {
                context.cancelled = true
                return COPYFILE_QUIT
            }
            if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS {
                context.onProgress(Progress(completedBytes: copiedBytes(state)))
            }
            return COPYFILE_CONTINUE
        }

        _ = copyfile_state_set(
            state,
            UInt32(COPYFILE_STATE_STATUS_CB),
            unsafeBitCast(callback, to: UnsafeMutableRawPointer.self)
        )
        _ = copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), contextPtr)
    }

    private final class CallbackContext {
        let onProgress: @Sendable (Progress) -> Void
        let shouldContinue: @Sendable () -> Bool
        private let cancelledFlag = Mutex(false)
        var cancelled: Bool {
            get { cancelledFlag.withLock { $0 } }
            set { cancelledFlag.withLock { $0 = newValue } }
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
