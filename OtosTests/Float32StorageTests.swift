import Foundation
@testable import OtosKit
import Testing

/// The catalog's byte form for stored vectors (face and search embeddings, face landmarks):
/// little-endian Float32, the same on every machine.
struct Float32StorageTests {
    @Test func valuesAreLittleEndianFloat32() {
        let data = Float32Storage.data([1, -2.5])
        #expect(data == Data([0x00, 0x00, 0x80, 0x3F, 0x00, 0x00, 0x20, 0xC0]))
        #expect(Float32Storage.floats(from: data, count: 2) == [1, -2.5])
        // A blob read from a row's middle starts past index 0.
        let slice = (Data([0xFF]) + data).dropFirst()
        #expect(Float32Storage.floats(from: slice, count: 2) == [1, -2.5])
    }

    @Test func aBlobOfAnotherLengthIsNoVector() {
        #expect(Float32Storage.floats(from: Data([0, 0, 0x80]), count: 1) == nil)
        #expect(Float32Storage.floats(from: Float32Storage.data([1, 2]), count: 1) == nil)
        #expect(FaceStorage.embedding(from: Float32Storage.data([1])) == nil)
    }

    /// Five landmarks round-trip through their stored form.
    @Test func landmarksRoundTrip() throws {
        let points = (0 ..< 5).map { CGPoint(x: Double($0) / 8, y: 0.25) }
        #expect(try #require(FaceStorage.landmarks(from: FaceStorage.landmarksData(points))) == points)
    }
}
