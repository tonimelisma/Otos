import Foundation
@testable import OtosKit
import Testing

/// The face vectors People holds (ADR 0047): every vector in a mapped file of its own, never on
/// the heap, read back exactly as rounded, through appends and compactions, and assigned to the
/// same people as vectors held in bytes of their own.
struct FaceVectorsTests {
    /// `count` reads numbered from `first`, each a random unit embedding.
    static func reads(_ count: Int, from first: Int64, generator: inout SplitMix64) -> [FaceVectors.Read] {
        (0 ..< count).map { offset in
            let values = (0 ..< FaceEmbeddingModel.dimensions).map { _ in Float(generator.next() % 2001) / 1000 - 1 }
            return FaceVectors.Read(vector: first + Int64(offset), embedding: FaceEmbedding(normalizing: values))
        }
    }

    /// The guard: what the vectors hold on the heap is each slot's number and state, a few bytes
    /// a face, whatever the faces; the vectors are the file's.
    @Test func theVectorsAreTheFilesAndTheHeapHoldsAFewBytesAFace() throws {
        var generator = SplitMix64(seed: 3)
        var vectors = FaceVectors()
        var start: Int64 = 1
        for _ in 0 ..< 10 {
            try vectors.add(Self.reads(FaceVectors.pageSize, from: start, generator: &generator))
            start += Int64(FaceVectors.pageSize)
        }
        #expect(vectors.count == 10 * FaceVectors.pageSize)
        #expect(vectors.heapBytes / vectors.count <= Self.heapBytesPerVector, "\(vectors.heapBytes / vectors.count) bytes a vector")
    }

    /// The heap a held vector may cost: its number (8 bytes) and its state (1), and the arrays'
    /// spare capacity. Held as Float16 on the heap, a vector cost 1,024 bytes and more.
    static let heapBytesPerVector = 24

    /// A vector reads back as its embedding rounded to half precision, bit for bit, wherever it
    /// was written; a malformed row is held as such; a row at or below `owed` is passed over.
    @Test func aVectorReadsBackAsItsRoundedEmbedding() throws {
        var generator = SplitMix64(seed: 5)
        let page = Self.reads(300, from: 1, generator: &generator)
            + [FaceVectors.Read(vector: 301, embedding: nil)]
            + Self.reads(50, from: 302, generator: &generator)
        var vectors = FaceVectors()
        try vectors.add(Array(page.prefix(200)))
        try vectors.add(Array(page.dropFirst(150)))
        #expect(vectors.count == 350)
        #expect(vectors.owed == 351)
        #expect(vectors.malformed == [301])
        for read in page {
            #expect(vectors.vector(read.vector) == read.embedding.map(FaceVector.init))
        }
        #expect(vectors.vector(0) == nil && vectors.vector(352) == nil)
    }

    /// Forgetting drops the vectors no face names; a compaction writes the kept ones into a new
    /// file, and a copy made before it, as a pass running meanwhile holds, still reads its own.
    @Test func aCompactionKeepsWhatIsNamedAndACopyKeepsItsMapping() throws {
        var generator = SplitMix64(seed: 7)
        let page = Self.reads(400, from: 1, generator: &generator)
        var vectors = FaceVectors()
        try vectors.add(page)
        let before = vectors
        let named = Set(page.map(\.vector).filter { $0 % 3 != 0 })
        try vectors.keep(named, through: 400)
        #expect(vectors.slots == named.count, "a third dropped compacts")
        try vectors.add(Self.reads(10, from: 401, generator: &generator))
        for read in page {
            #expect(vectors.vector(read.vector) == (named.contains(read.vector) ? read.embedding.map(FaceVector.init) : nil))
            #expect(before.vector(read.vector) == read.embedding.map(FaceVector.init))
        }
        // Fewer than a quarter dropped: no compaction, the dropped ones are gone all the same.
        let slots = vectors.slots
        try vectors.keep(named.subtracting([1, 2]).union(401 ... 410), through: 410)
        #expect(vectors.slots == slots)
        #expect(vectors.vector(1) == nil && vectors.vector(4) != nil)
    }

    /// The differential: assignment over vectors read back from the file gives exactly what it
    /// gives over the same vectors held in bytes of their own.
    @Test func theFilesVectorsAssignAsVectorsOfTheirOwn() throws {
        var generator = SplitMix64(seed: 13)
        let faces = FaceAssignmentPolicyTests.randomFaces(count: 2500, people: 12, generator: &generator)
        let people = (1 ... 12).map { PersonFact(id: PersonID(rawValue: Int64($0)), birthdaySeconds: nil, isBare: $0 % 4 == 0) }
        let vectors = try FaceVectors(facts: faces)
        let mapped = faces.enumerated().map { index, face in
            FaceFact(
                id: face.id, captureSeconds: face.captureSeconds, vector: vectors.vector(Int64(index + 1))!,
                assignment: face.assignment, rejected: face.rejected
            )
        }
        #expect(mapped == faces)
        #expect(FaceAssignmentPolicy.assign(faces: mapped, people: people) == FaceAssignmentPolicy.assign(faces: faces, people: people))
    }
}
