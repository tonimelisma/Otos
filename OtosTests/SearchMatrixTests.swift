import Foundation
@testable import OtosKit
import Testing

/// Plan 0116 stage 4: the search index's memory, filled from stored rows a page at a time with
/// compact labels, answers exactly as one filled from decoded vectors and label dictionaries:
/// the same ids in the same rows, scores equal to the bit, and the label gate deciding alike.
struct SearchMatrixTests {
    @Test func aMatrixFromStoredRowsAnswersExactlyAsOneFromDecodedVectors() {
        var generator = SeededFloats(seed: 42)
        let root = LibraryRootPath(rawValue: "/library/")
        let names = ["dog", "cat", "horse", "lake", "beach", "screenshot", "document", "tree"]
        var rows: [StoredSearchEmbeddingRow] = []
        var reference: [(id: MediaAssetID, vector: [Float], labels: [String: Float])] = []
        for index in 0 ..< 300 {
            let vector = (0 ..< SearchEmbedding.dimensions).map { _ in Float(generator.unit() * 2 - 1) }
            var labels: [String: Float] = [:]
            for name in names where generator.unit() < 0.3 {
                labels[name] = Float(generator.unit())
            }
            let id = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "\(index).jpg"))
            let text = SearchEmbeddingStorage.labelsText(labels)
            rows.append(StoredSearchEmbeddingRow(id: id, vector: SearchEmbeddingStorage.data(vector), labels: text))
            reference.append((id, vector, SearchEmbeddingStorage.labels(from: text)))
        }
        var matrix = SearchMatrix()
        // Pages of 64 into a matrix sized for all, as a load fills it.
        matrix.reserve(rows.count)
        for page in stride(from: 0, to: rows.count, by: 64) {
            for row in rows[page ..< min(page + 64, rows.count)] {
                matrix.append(row)
            }
        }
        let referenceIDs: [MediaAssetID] = reference.map(\.id)
        #expect(matrix.ids == referenceIDs)
        let flat: [Float] = reference.flatMap(\.vector)
        #expect(matrix.vectors == flat)
        for _ in 0 ..< 5 {
            let query = (0 ..< SearchEmbedding.dimensions).map { _ in Float(generator.unit() * 2 - 1) }
            let got = PhotoSearchIndex.scores(matrix.vectors, count: matrix.ids.count, query: query)
            let want = PhotoSearchIndex.scores(flat, count: reference.count, query: query)
            let gotBits: [UInt32] = got.map(\.bitPattern)
            let wantBits: [UInt32] = want.map(\.bitPattern)
            #expect(gotBits == wantBits)
            let best = want.max() ?? 0
            for named: [String] in [["horse"], ["cat", "lake"], ["unknown"], []] {
                for row in reference.indices {
                    let compact = SearchLabelGate.keeps(score: got[row], best: best, named: named) {
                        matrix.confidence(row: row, of: $0)
                    }
                    let dictionary = SearchLabelGate.keeps(score: want[row], best: best, named: named) {
                        reference[row].labels[$0]
                    }
                    #expect(compact == dictionary)
                }
            }
        }
        // A removal moves the last row into the gap, and its labels with it.
        let gone = reference[10].id
        matrix.remove([gone])
        #expect(matrix.rowOf[gone] == nil)
        #expect(matrix.ids[10] == reference.last?.id)
        #expect(matrix.confidence(row: 10, of: "dog") == reference.last?.labels["dog"])
    }
}

/// A seeded generator, so the vectors are the same on every run.
private struct SeededFloats {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func unit() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return Double(value >> 11) / Double(1 << 53)
    }
}
