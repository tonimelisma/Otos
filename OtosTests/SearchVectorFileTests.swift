import Foundation
@testable import OtosKit
import Testing

/// ADR 0048, "The index": the search index's memory is a mapped file pair. A file appended a
/// page at a time and opened again holds the same assets in the same slots, the vectors as
/// Float16 rounded to nearest, its scores those of the widened vectors, and the label gate
/// decides over it exactly as over the parsed label text. A file is trusted only for the
/// slots the catalog commits: bytes past them are cut off, and a file short of them, torn or
/// of another file's name does not open.
@Suite(.testScope)
struct SearchVectorFileTests {
    private static let root = LibraryRootPath(rawValue: "/library/")
    private static let names = ["dog", "cat", "horse", "lake", "beach", "screenshot", "document", "tree"]

    private static func id(_ index: Int, root: LibraryRootPath = root) -> MediaAssetID {
        MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "\(index).jpg"))
    }

    private static func rows(_ count: Int, generator: inout SeededFloats, from first: Int = 0) -> [StoredSearchEmbeddingRow] {
        (first ..< first + count).map { index in
            let vector = (0 ..< SearchEmbedding.dimensions).map { _ in Float(generator.unit() * 0.2 - 0.1) }
            var labels: [String: Float] = [:]
            for name in names where generator.unit() < 0.3 {
                labels[name] = Float(generator.unit())
            }
            let root = index % 3 == 0 ? LibraryRootPath(rawValue: "/other/") : Self.root
            return StoredSearchEmbeddingRow(
                id: Self.id(index, root: root), vector: SearchEmbeddingStorage.data(vector), labels: SearchEmbeddingStorage.labelsText(labels)
            )
        }
    }

    // Validates: ENR-027
    @Test func aFileAppendedInPagesAndOpenedAgainAnswersAsItsRowsDo() async throws {
        let directory = try makeTestDirectory()
        var generator = SeededFloats(seed: 42)
        let rows = Self.rows(300, generator: &generator)
        let id = UUID()
        do {
            let file = try SearchVectorFile.create(directory: directory, id: id)
            for page in stride(from: 0, to: rows.count, by: 64) {
                try await file.append(Array(rows[page ..< min(page + 64, rows.count)]))
            }
            #expect(file.slots == 300)
        }
        let file = try SearchVectorFile.open(directory: directory, state: SearchVectorFileState(id: id, slots: 300))
        #expect(file.keys.slotIDs == rows.map(\.id))
        #expect(file.live == 300)
        let widened: [[Float]] = rows.map { row in
            (SearchEmbeddingStorage.embedding(from: row.vector) ?? []).map { Float(Float16($0)) }
        }
        for slot in [0, 1, 150, 299] {
            #expect(file.vector(slot: slot).map(\.bitPattern) == widened[slot].map(\.bitPattern))
        }
        for _ in 0 ..< 5 {
            let query = (0 ..< SearchEmbedding.dimensions).map { _ in Float(generator.unit() * 0.2 - 0.1) }
            let got = file.scores(query)
            let want = widened.map { vector in zip(vector, query).reduce(Float(0)) { $0 + $1.0 * $1.1 } }
            for slot in rows.indices {
                #expect(abs(got[slot] - want[slot]) < 1e-5)
            }
            let best = got.max() ?? 0
            for named: [String] in [["horse"], ["cat", "lake"], ["unknown"], []] {
                for slot in rows.indices {
                    let labels = SearchEmbeddingStorage.labels(from: rows[slot].labels)
                    let mapped = SearchLabelGate.keeps(score: got[slot], best: best, named: named) { file.confidence(slot: slot, of: $0) }
                    let parsed = SearchLabelGate.keeps(score: got[slot], best: best, named: named) { labels[$0] }
                    #expect(mapped == parsed)
                }
            }
        }
    }

    // Validates: ENR-027
    @Test func aLaterSlotForAnAssetSupersedesItAndCompactionKeepsOnlyTheLive() async throws {
        let directory = try makeTestDirectory()
        var generator = SeededFloats(seed: 7)
        let first = Self.rows(10, generator: &generator)
        let again = Self.rows(1, generator: &generator, from: 3)
        let file = try SearchVectorFile.create(directory: directory, id: UUID())
        try await file.append(first)
        try await file.append(again)
        #expect(file.rowOf[Self.id(3, root: LibraryRootPath(rawValue: "/other/"))] == 10)
        #expect(file.live == 10 && file.dead == 1)
        var memory = SearchIndexMemory()
        memory.replaceVectors(with: file)
        try memory.changeVectors(of: file, taking: nil, removing: [first[5].id])
        #expect(file.live == 9 && file.dead == 2)

        let compacted = try SearchVectorFile.create(directory: directory, id: UUID())
        try await compacted.appendLive(of: file, batch: 4)
        #expect(compacted.slots == 9 && compacted.dead == 0)
        #expect(Set(compacted.keys.slotIDs) == Set(file.rowOf.keys))
        for (asset, slot) in file.rowOf {
            let copied = try #require(compacted.rowOf[asset])
            #expect(compacted.vector(slot: Int(copied)).map(\.bitPattern) == file.vector(slot: Int(slot)).map(\.bitPattern))
            for name in Self.names {
                #expect(compacted.confidence(slot: Int(copied), of: name) == file.confidence(slot: Int(slot), of: name))
            }
        }
    }

    // Validates: ENR-027
    @Test func onlyCommittedSlotsOpenAndAnythingElseDoesNot() async throws {
        let directory = try makeTestDirectory()
        var generator = SeededFloats(seed: 3)
        let id = UUID()
        do {
            let file = try SearchVectorFile.create(directory: directory, id: id)
            try await file.append(Self.rows(20, generator: &generator))
        }
        // Slots past the catalog's count were never committed: cut off.
        let committed = try SearchVectorFile.open(directory: directory, state: SearchVectorFileState(id: id, slots: 12))
        #expect(committed.slots == 12)
        let urls = SearchVectorFormat.urls(directory: directory, id: id)
        let vectorsBytes = try #require(FileManager.default.attributesOfItem(atPath: urls.vectors.path)[.size] as? Int)
        #expect(vectorsBytes == SearchVectorFormat.vectorsLength(slots: 12))

        // More slots than the file holds: a commit the file never got.
        #expect(throws: SearchVectorFileInvalid.short) {
            try SearchVectorFile.open(directory: directory, state: SearchVectorFileState(id: id, slots: 13))
        }
        // Another file's name, and none at all.
        #expect(throws: SearchVectorFileInvalid.missing) {
            try SearchVectorFile.open(directory: directory, state: SearchVectorFileState(id: UUID(), slots: 12))
        }
        // A header whose bytes changed.
        let handle = try FileHandle(forWritingTo: urls.vectors)
        try handle.seek(toOffset: 21)
        try handle.write(contentsOf: Data([0xFF]))
        try handle.close()
        #expect(throws: SearchVectorFileInvalid.malformed("vectorsHeader")) {
            try SearchVectorFile.open(directory: directory, state: SearchVectorFileState(id: id, slots: 12))
        }
    }

    // Validates: ENR-027
    @Test func labelsReadAsTheStoredTextReadsThem() {
        let labels = SearchVectorKeys.labels(fromText: "dog:0.500,cat:bad,dog:0.250,lake:0.125,broken")
        #expect(labels.map(\.name) == ["dog", "lake"])
        #expect(labels.map(\.confidence) == [0.25, 0.125])
        #expect(SearchVectorKeys.labels(fromText: nil).isEmpty)
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
