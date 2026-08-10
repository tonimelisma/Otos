import Darwin
import Foundation
import Synchronization

/// `copyfile(3)` transfer with byte progress and mid-file cancellation.
nonisolated enum CopyfileTransfer {
    enum Outcome: Equatable, Sendable {
        case completed
        case cancelled
        case failed(String)
    }

    struct Progress: Equatable, Sendable {
        let completedBytes: Int64
        let totalBytes: Int64
    }

    static func copy(
        from source: URL,
        to destination: URL,
        onProgress: @escaping @Sendable (Progress) -> Void,
        shouldContinue: @escaping @Sendable () -> Bool
    ) -> Outcome {
        let state = copyfile_state_alloc()
        guard let state else {
            return .failed("copyfile_state_alloc failed")
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
            try? FileManager.default.removeItem(at: destination)
            return .failed("copyfile errno=\(errno)")
        }
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        onProgress(Progress(completedBytes: size, totalBytes: size))
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
                var copied: off_t = 0
                _ = withUnsafeMutablePointer(to: &copied) { ptr in
                    copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), UnsafeMutableRawPointer(ptr))
                }
                context.onProgress(Progress(completedBytes: Int64(copied), totalBytes: Int64(copied)))
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
