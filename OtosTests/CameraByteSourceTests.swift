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

    @Test func aZeroLengthReadIsSatisfiedLocally() throws {
        let subject = source(size: 32) { _, _ in .failure(.rangedReadFailed("should not be asked")) }
        #expect(try subject.data(offset: 0, length: 0) == Data())
    }

    @Test func anInBoundsRangeReturnsExactlyItsBytes() throws {
        let payload = Data(repeating: 0x7F, count: 12)
        let subject = source(size: 64) { _, _ in .success(payload) }
        #expect(try subject.data(offset: 4, length: 12) == payload)
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

    @Test func aTransportFailureThrows() {
        let subject = source(size: 64) { _, _ in .failure(.rangedReadFailed("camera detached")) }
        #expect(throws: DeviceCameraSessionError.self) {
            _ = try subject.data(offset: 0, length: 12)
        }
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
