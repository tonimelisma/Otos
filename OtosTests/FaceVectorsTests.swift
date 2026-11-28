import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// The face vectors People holds (ADR 0047): every vector in a mapped file of its own, never on
/// the heap, read back exactly as rounded, through appends and compactions, and assigned to the
/// same people as vectors held in bytes of their own.
struct FaceVectorsTests {
    /// `count` reads numbered from `first`, each a random unit embedding.
    static func reads(_ count: Int, from first: Int64, generator: inout SplitMix64) -> [FaceVectorStore.Read] {
        (0 ..< count).map { offset in
            let values = (0 ..< FaceEmbeddingModel.dimensions).map { _ in Float(generator.next() % 2001) / 1000 - 1 }
            return FaceVectorStore.Read(vector: first + Int64(offset), embedding: FaceEmbedding(normalizing: values))
        }
    }

    // Validates: ENR-025
    /// The guard: what the vectors hold on the heap is each slot's number and state, a few bytes
    /// a face, whatever the faces; the vectors are the file's.
    @Test func theVectorsAreTheFilesAndTheHeapHoldsAFewBytesAFace() throws {
        var generator = SplitMix64(seed: 3)
        var store = FaceVectorStore(space: .ample)
        var start: Int64 = 1
        for _ in 0 ..< 10 {
            try store.add(Self.reads(FaceVectorStore.pageSize, from: start, generator: &generator))
            start += Int64(FaceVectorStore.pageSize)
        }
        let vectors = store.vectors
        #expect(vectors.count == 10 * FaceVectorStore.pageSize)
        #expect(vectors.heapBytes / vectors.count <= Self.heapBytesPerVector, "\(vectors.heapBytes / vectors.count) bytes a vector")
    }

    /// The heap a held vector may cost: its number (8 bytes) and its state (1), and the arrays'
    /// spare capacity. Held as Float16 on the heap, a vector cost 1,024 bytes and more.
    static let heapBytesPerVector = 24

    // Validates: ENR-025
    /// A vector reads back as its embedding rounded to half precision, bit for bit, wherever it
    /// was written; a malformed row is held as such; a row at or below `owed` is passed over.
    @Test func aVectorReadsBackAsItsRoundedEmbedding() throws {
        var generator = SplitMix64(seed: 5)
        let page = Self.reads(300, from: 1, generator: &generator)
            + [FaceVectorStore.Read(vector: 301, embedding: nil)]
            + Self.reads(50, from: 302, generator: &generator)
        var store = FaceVectorStore(space: .ample)
        try store.add(Array(page.prefix(200)))
        try store.add(Array(page.dropFirst(150)))
        let vectors = store.vectors
        #expect(vectors.count == 350)
        #expect(vectors.owed == 351)
        #expect(vectors.malformed == [301])
        for read in page {
            #expect(vectors.vector(read.vector) == read.embedding.map(FaceVector.init))
        }
        #expect(vectors.vector(0) == nil && vectors.vector(352) == nil)
    }

    // Validates: ENR-025
    /// Forgetting drops the vectors no face names; a compaction writes the kept ones into a new
    /// file, and a copy made before it, as a pass running meanwhile holds, still reads its own.
    @Test func aCompactionKeepsWhatIsNamedAndACopyKeepsItsMapping() throws {
        var generator = SplitMix64(seed: 7)
        let page = Self.reads(400, from: 1, generator: &generator)
        var store = FaceVectorStore(space: .ample)
        try store.add(page)
        let before = store.vectors
        let named = Set(page.map(\.vector).filter { $0 % 3 != 0 })
        try store.keep(named, through: 400)
        #expect(store.vectors.slots == named.count, "a third dropped compacts")
        try store.add(Self.reads(10, from: 401, generator: &generator))
        let vectors = store.vectors
        for read in page {
            #expect(vectors.vector(read.vector) == (named.contains(read.vector) ? read.embedding.map(FaceVector.init) : nil))
            #expect(before.vector(read.vector) == read.embedding.map(FaceVector.init))
        }
        // Fewer than a quarter dropped: no compaction, the dropped ones are gone all the same.
        let slots = store.vectors.slots
        try store.keep(named.subtracting([1, 2]).union(401 ... 410), through: 410)
        #expect(store.vectors.slots == slots)
        #expect(store.vectors.vector(1) == nil && store.vectors.vector(4) != nil)
    }

    // Validates: ENR-025
    /// A reader's copy is made after a page and the owner appends past it: the copy reads
    /// exactly what it was made with, and the owner every vector, so a copy never sees a slot
    /// rewritten. Only the owner writes; a copy holds no file to write with.
    @Test func aCopyReadsWhatItWasMadeWithWhileTheOwnerAppends() throws {
        var generator = SplitMix64(seed: 9)
        let first = Self.reads(64, from: 1, generator: &generator)
        let second = Self.reads(64, from: 65, generator: &generator)
        var store = FaceVectorStore(space: .ample)
        try store.add(first)
        let copy = store.vectors
        try store.add(second)
        #expect(copy.count == 64 && store.vectors.count == 128)
        for read in first {
            #expect(copy.vector(read.vector) == read.embedding.map(FaceVector.init))
            #expect(store.vectors.vector(read.vector) == read.embedding.map(FaceVector.init))
        }
        for read in second {
            #expect(copy.vector(read.vector) == nil)
            #expect(store.vectors.vector(read.vector) == read.embedding.map(FaceVector.init))
        }
    }

    // Validates: ENR-025
    /// At the free-space floor a page is refused before anything is written, and what is held
    /// stays as it was; a compaction the floor refuses is not run, and the vectors kept still
    /// read back. With room again the same page is written.
    @Test func atTheFloorAPageIsRefusedAndWhatIsHeldStays() throws {
        var generator = SplitMix64(seed: 11)
        let room = ReportedCapacity(1 << 40)
        let space = FaceVectorFile.Space(directory: FileManager.default.temporaryDirectory, availableBytes: room.read)
        var store = FaceVectorStore(space: space)
        let held = Self.reads(100, from: 1, generator: &generator)
        try store.add(held)
        room.set(FreeSpaceFloor.bytes)
        let refused = Self.reads(10, from: 101, generator: &generator)
        #expect(throws: FaceVectorFile.Failure.floorReached) { try store.add(refused) }
        #expect(store.vectors.count == 100 && store.vectors.owed == 100)
        // Half dropped would compact; at the floor the slots stay where they are.
        let named = Set(held.map(\.vector).filter { $0 % 2 == 0 })
        try store.keep(named, through: 100)
        #expect(store.vectors.slots == 100 && store.vectors.count == 50)
        #expect(held.allSatisfy { store.vectors.vector($0.vector) == (named.contains($0.vector) ? $0.embedding.map(FaceVector.init) : nil) })
        room.set(1 << 40)
        try store.add(refused)
        #expect(store.vectors.count == 60 && store.vectors.owed == 110)
        #expect(FaceVectorFile.Failure.floorReached.isNoSpace && FaceVectorFile.Failure.write(errno: ENOSPC).isNoSpace)
        #expect(!FaceVectorFile.Failure.write(errno: EIO).isNoSpace)
    }

    // Validates: ENR-025
    /// The differential: assignment over vectors read back from the file gives exactly what it
    /// gives over the same vectors held in bytes of their own.
    @Test func theFilesVectorsAssignAsVectorsOfTheirOwn() throws {
        var generator = SplitMix64(seed: 13)
        let faces = FaceAssignmentPolicyTests.randomFaces(count: 2500, people: 12, generator: &generator)
        let people = (1 ... 12).map { PersonFact(id: PersonID(rawValue: Int64($0)), birthdaySeconds: nil, isBare: $0 % 4 == 0) }
        let vectors = try FaceVectors.held(facts: faces)
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

/// The free space a test's volume reports, changed by the test at a chosen step.
final nonisolated class ReportedCapacity: Sendable {
    private let bytes: Mutex<Int64?>

    init(_ bytes: Int64?) {
        self.bytes = Mutex(bytes)
    }

    func set(_ value: Int64?) {
        bytes.withLock { $0 = value }
    }

    var read: VolumeCapacityReader {
        { [self] _ in bytes.withLock { $0 } }
    }
}
