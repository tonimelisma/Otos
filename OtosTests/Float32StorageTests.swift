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

    /// A face embedding reads back bit for bit only while it is unit length: a stored vector
    /// of any other length is no embedding, and so are values with no length to scale.
    @Test func aFaceEmbeddingIsUnitLength() throws {
        let values = (0 ..< FaceEmbeddingModel.dimensions).map { Float($0 % 5) - 2 }
        let embedding = try #require(FaceEmbedding(normalizing: values))
        #expect(abs(embedding.cosine(with: embedding) - 1) < 1e-5)
        #expect(FaceStorage.embedding(from: FaceStorage.embeddingData(embedding)) == embedding)
        let doubled = embedding.values.map { $0 * 2 }
        #expect(FaceStorage.embedding(from: Float32Storage.data(doubled)) == nil)
        let rescaled = try #require(FaceEmbedding(normalizing: doubled))
        #expect(abs(rescaled.cosine(with: embedding) - 1) < 1e-5)
        #expect(FaceEmbedding(normalizing: [Float](repeating: 0, count: FaceEmbeddingModel.dimensions)) == nil)
        #expect(FaceEmbedding(normalizing: [1]) == nil)
    }

    /// Five landmarks round-trip through their stored form.
    @Test func landmarksRoundTrip() throws {
        let landmarks = try #require(FaceAlignment.Landmarks(points: (0 ..< 5).map { CGPoint(x: Double($0) / 8, y: 0.25) }))
        #expect(FaceStorage.landmarks(from: FaceStorage.landmarksData(landmarks)) == landmarks)
    }
}
