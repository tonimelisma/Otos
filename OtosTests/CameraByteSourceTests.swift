import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// The byte source's contract, which decides whether a camera import names files correctly.
///
/// Testable at all only because the source takes a range reader rather than a
/// `DeviceCameraSession`: the session cannot be constructed without a real `ICCameraDevice`,
/// so a coupled source would have had these rules verified on hardware or not at all.
struct CameraByteSourceTests {
    private func source(
        size: UInt64,
        answering: @escaping @Sendable (UInt64, Int) -> Result<Data, DeviceCameraSessionError>
    ) -> CameraByteSource {
        CameraByteSource(size: size) { offset, length, completion in
            completion(answering(offset, length))
        }
    }

    /// A range past the end is a structural fact about the file, and the protocol says nil.
    /// Answered locally rather than asked of the camera: the size already knows, and a round
    /// trip to be told so costs ~40 ms per read.
    @Test func aRangePastTheEndIsNilWithoutAskingTheCamera() throws {
        let asked = Mutex(0)
        let subject = source(size: 32) { _, _ in
            asked.withLock { $0 += 1 }
            return .success(Data(repeating: 0xAB, count: 8))
        }

        #expect(try subject.data(offset: 30, length: 8) == nil)
        #expect(try subject.data(offset: 32, length: 1) == nil)
        #expect(try subject.data(offset: 99, length: 1) == nil)
        #expect(asked.withLock { $0 } == 0, "the size already answers this; a round trip would be wasted")
    }

    /// The rule the whole path depends on. An in-bounds range that under-delivers is a
    /// transport fault, not the end of the file — and reporting it as absence would let the
    /// package return a definitive "no capture date", which ARC-057 treats as proof and
    /// turns into a filename derived from mtime. That name is the dedupe key, so the next
    /// plan computes a different one and copies the file again.
    @Test func anInBoundsShortReadThrowsRatherThanReportingEndOfFile() {
        let subject = source(size: 64) { _, _ in .success(Data(repeating: 1, count: 3)) }
        #expect(throws: DeviceCameraSessionError.self) {
            _ = try subject.data(offset: 0, length: 12)
        }
    }

    /// E2, at the point D1 makes hot. A read that never answers must not park a dedicated
    /// thread for the life of the process — libmtp#8 documents a shipping device that fails
    /// `GetPartialObject` by timeout at particular offsets.
    @Test func aReadThatNeverAnswersTimesOutInsteadOfHangingTheThread() {
        let subject = CameraByteSource(size: 64, readDeadline: 0.2) { _, _, _ in
            // Never calls back, which is exactly the shipping-device failure mode.
        }

        #expect(throws: DeviceCameraSessionError.self) {
            _ = try subject.data(offset: 0, length: 12)
        }
    }

    /// Timing out is safe by construction, which is why the bridge is a semaphore rather
    /// than a `CheckedContinuation`: a completion that arrives after the deadline writes
    /// into the mutex and signals a semaphore nobody is waiting on. Resuming a continuation
    /// twice would crash the process; this simply drops the answer.
    @Test func aCompletionArrivingAfterTheDeadlineIsHarmless() throws {
        let stash = Mutex<(@Sendable (Result<Data, DeviceCameraSessionError>) -> Void)?>(nil)
        let subject = CameraByteSource(size: 64, readDeadline: 0.2) { _, _, completion in
            stash.withLock { $0 = completion }
        }

        #expect(throws: DeviceCameraSessionError.self) {
            _ = try subject.data(offset: 0, length: 12)
        }

        // The device answers late. Nothing is waiting; this must not trap.
        stash.withLock { $0 }?(.success(Data(repeating: 0, count: 12)))

        // And the source is still usable afterwards, so one timed-out read does not poison
        // the item — the next read of the same file gets a fresh wait.
        let recovered = CameraByteSource(size: 64, readDeadline: 0.2) { _, length, completion in
            completion(.success(Data(repeating: 9, count: length)))
        }
        #expect(try recovered.data(offset: 0, length: 12)?.count == 12)
    }

    /// The read is asked for exactly what the caller wanted, at the offset it wanted.
    /// An off-by-one here is a wrong preview or a misparsed header, not a crash.
    @Test func theCameraIsAskedForTheRangeThatWasRequested() throws {
        let seen = Mutex<(offset: UInt64, length: Int)?>(nil)
        // Sized past the requested range on purpose: an offset beyond `size` is answered
        // locally as nil, so a too-small fixture would exercise the bounds rule instead of
        // the one this test is about. The values are a real Sony ARW preview descriptor.
        let subject = CameraByteSource(size: 40_000_000) { offset, length, completion in
            seen.withLock { $0 = (offset, length) }
            completion(.success(Data(repeating: 0, count: length)))
        }

        _ = try subject.data(offset: 196_770, length: 292)

        let asked = try #require(seen.withLock { $0 })
        #expect(asked.offset == 196_770)
        #expect(asked.length == 292)
    }
}
