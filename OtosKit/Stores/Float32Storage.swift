import Foundation

/// The catalog's byte form for a vector of floats: little-endian Float32, so a catalog reads
/// the same on any machine. Face embeddings and landmarks (`FaceStorage`) and search
/// embeddings (`SearchEmbeddingStorage`) are all stored this way.
///
/// On a little-endian host — every Mac Otos runs on — that form is the array's own memory,
/// so both directions are one copy. People reads every face's embedding on each build,
/// millions of values at a family archive's scale (`people.snapshot.10k`), and a loop over
/// values cost about 2,000 instructions each in the Debug build Otos installs.
nonisolated enum Float32Storage {
    static func data(_ values: [Float]) -> Data {
        #if _endian(little)
            values.withUnsafeBytes { Data($0) }
        #else
            Data(values.map(\.bitPattern.littleEndian).withUnsafeBytes { Data($0) })
        #endif
    }

    /// Nil unless `data` holds exactly `count` values.
    static func floats(from data: Data, count: Int) -> [Float]? {
        guard data.count == count * 4 else { return nil }
        let values = [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
            _ = data.copyBytes(to: UnsafeMutableRawBufferPointer(buffer))
            initialized = count
        }
        #if _endian(little)
            return values
        #else
            return values.map { Float(bitPattern: UInt32(littleEndian: $0.bitPattern)) }
        #endif
    }
}
