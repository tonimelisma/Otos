import CoreGraphics
import Foundation

/// The byte form of a face's vectors in the catalog's `face` table (ADR 0047): little-endian
/// Float32, so a catalog reads the same on any machine. An embedding is
/// `FaceEmbeddingModel.dimensions` values; the landmarks are five (x, y) pairs.
nonisolated enum FaceStorage {
    static func embeddingData(_ embedding: [Float]) -> Data {
        floatData(embedding)
    }

    /// Nil unless `data` holds exactly one embedding.
    static func embedding(from data: Data) -> [Float]? {
        guard data.count == FaceEmbeddingModel.dimensions * 4 else { return nil }
        return floats(from: data)
    }

    static func landmarksData(_ points: [CGPoint]) -> Data {
        floatData(points.flatMap { [Float($0.x), Float($0.y)] })
    }

    /// Nil unless `data` holds exactly five points.
    static func landmarks(from data: Data) -> [CGPoint]? {
        guard data.count == 5 * 2 * 4 else { return nil }
        let values = floats(from: data)
        return stride(from: 0, to: values.count, by: 2).map { CGPoint(x: Double(values[$0]), y: Double(values[$0 + 1])) }
    }

    private static func floatData(_ values: [Float]) -> Data {
        var data = Data(capacity: values.count * 4)
        for value in values {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func floats(from data: Data) -> [Float] {
        stride(from: 0, to: data.count, by: 4).map { offset in
            let bits = data[data.startIndex + offset ..< data.startIndex + offset + 4]
                .enumerated()
                .reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
            return Float(bitPattern: bits)
        }
    }
}
