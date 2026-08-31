import Foundation
import MediaMetadata
import Synchronization

/// Reads byte ranges from a camera file over ImageCaptureCore, for `MediaMetadata`.
///
/// The package's parsers are directed: they read a container's own index, then read exactly
/// the regions that index points at. A capture date costs 1–12 KB that way, against the
/// tens of megabytes a file transfer costs. This is the transport that makes that possible
/// for a camera reachable only over MTP.
///
/// ## Why this can be synchronous without blocking the main actor
///
/// `MediaByteSource.data` is synchronous and `ICCameraFile.requestReadDataAtOffset` is
/// completion-based, so something has to wait. Two facts make the waiting safe:
///
/// - `DeviceCameraSession.beginRangedRead` **returns immediately** — it queues the request
///   and does not wait for the answer, so the main actor's share of a read is microseconds.
/// - The waiting happens **here**, on whatever thread the parse runs on, which
///   `CameraMetadataReader` guarantees is a dedicated one and never the cooperative pool.
///
/// So the main actor is never blocked by a read, and the blocked thread never holds
/// anything the main actor needs. Nothing non-`Sendable` crosses either: `ICCameraFile`
/// stays inside the session, and only a relative path, an offset, a length and the result
/// travel.
///
/// ## Failure is never absence
///
/// A transport failure throws rather than returning nil, so the package reports
/// `.readFailure` instead of a definitive "this file has no capture date". Otos treats a
/// definitive outcome as proof and names the file from its filesystem mtime — and that name
/// is also the dedupe key, so misreading a detached camera as absence produces duplicate
/// imports. This is why `beginRangedRead` distinguishes "no data and no error" (a shape
/// ImageCaptureCore is documented to produce, FB7663947) from a delivered range.
/// `nonisolated` deliberately, and the compiler is right to insist. Under
/// `SWIFT_APPROACHABLE_CONCURRENCY` app types are main-actor isolated by default, which
/// would make the conformance main-actor isolated too — and a source that can only be read
/// from the main actor is precisely the thing this must not be.
final nonisolated class CameraByteSource: MediaByteSource {
    let size: UInt64

    /// Issues one ranged read and calls back when it settles.
    ///
    /// A closure rather than the session itself, so the bounds and short-read rules below —
    /// which are the load-bearing part of this type — can be tested without an attached
    /// camera. `DeviceCameraSession` cannot be constructed without a real `ICCameraDevice`,
    /// so a source coupled to it would have had its contract verified only on hardware.
    typealias RangeReader = @Sendable (
        _ offset: UInt64,
        _ length: Int,
        _ completion: @escaping @Sendable (Result<Data, DeviceCameraSessionError>) -> Void
    ) -> Void

    private let read: RangeReader

    /// - Parameter size: from `ICCameraFile.fileSize`. A camera item has no filesystem
    ///   entry to stat, which is why the protocol takes size from the source.
    init(size: UInt64, read: @escaping RangeReader) {
        self.size = size
        self.read = read
    }

    /// The production source: every read goes back through the session, so the
    /// non-`Sendable` `ICCameraFile` never leaves the main actor.
    convenience init(session: DeviceCameraSession, relativePath: MediaRelativePath, size: UInt64) {
        self.init(size: size) { offset, length, completion in
            session.beginRangedRead(
                relativePath: relativePath,
                offset: offset,
                length: length,
                completion: completion
            )
        }
    }

    func data(offset: UInt64, length: Int) throws -> Data? {
        // Structural facts first, and answered locally: a range past the end is `nil` by
        // the protocol's contract, and asking the camera about it would spend a round trip
        // to be told what the size already says.
        guard length >= 0, offset <= size, UInt64(length) <= size - offset else {
            return nil
        }
        guard length > 0 else {
            return Data()
        }

        let outcome = Mutex<Result<Data, DeviceCameraSessionError>?>(nil)
        let finished = DispatchSemaphore(value: 0)
        read(offset, length) { result in
            outcome.withLock { $0 = result }
            finished.signal()
        }
        finished.wait()

        guard let result = outcome.withLock({ $0 }) else {
            throw DeviceCameraSessionError.rangedReadFailed("completed without an outcome")
        }
        switch result {
        case let .success(data):
            // An in-bounds range that under-delivers is a transport fault, not the end of
            // the file. Reporting it as `nil` would let a truncated answer masquerade as
            // "there is nothing there" — which is exactly the failure this whole path is
            // built to avoid.
            guard data.count == length else {
                throw DeviceCameraSessionError.rangedReadFailed(
                    "short read: asked \(length) at \(offset), got \(data.count)"
                )
            }
            return data
        case let .failure(error):
            throw error
        }
    }

    func close() {}
}
