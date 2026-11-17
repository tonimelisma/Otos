import Foundation
@testable import OtosKit
import Testing

/// The tokenizer's file (`SigLIP2Tokenizer.bin`, `OTBPE2`) is checked once at load: a file
/// whose tables are not what the searches assume is `malformed`, never a trap in a search or
/// a merged id the text tower cannot read. Each fixture is a tiny file built here, then cut
/// or corrupted one field at a time.
struct SearchTextTokenizerFileTests {
    struct Merge {
        var left: UInt32
        var right: UInt32
        var rank: UInt32
        var merged: UInt32
    }

    /// The parts of a tokenizer file, written in the reader's layout.
    struct File {
        var vocabularyCount: UInt32 = 8
        /// Each distinct string and its id, in ascending byte order.
        var entries: [(string: [UInt8], id: UInt32)] = [
            (Array("a".utf8), 4), (Array("ab".utf8), 6), (Array("b".utf8), 5), (Array("▁".utf8), 7),
        ]
        /// Each merge, in ascending pair order.
        var merges = [Merge(left: 4, right: 5, rank: 0, merged: 6)]
        /// Replaces the start offset of one string, when set.
        var start: (index: Int, value: UInt32)?

        var bytes: Data {
            var data = Data("OTBPE2\0\0".utf8)
            func append(_ value: some FixedWidthInteger) {
                withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
            }
            let strings = entries.flatMap(\.string)
            append(vocabularyCount)
            append(UInt32(entries.count))
            append(UInt32(merges.count))
            append(UInt32(strings.count))
            for merge in merges {
                append(UInt64(merge.left) << 32 | UInt64(merge.right))
            }
            for merge in merges {
                append(UInt64(merge.rank) << 32 | UInt64(merge.merged))
            }
            var starts: [UInt32] = [0]
            for entry in entries {
                starts.append(starts.last! + UInt32(entry.string.count))
            }
            if let start {
                starts[start.index] = start.value
            }
            starts.forEach(append)
            for entry in entries {
                append(entry.id)
            }
            data.append(contentsOf: strings)
            return data
        }
    }

    @Test func aWellFormedFileTokenizes() throws {
        let tokenizer = try SearchTextTokenizer(data: File().bytes)
        let ids = tokenizer.tokenIDs(for: "ab b")
        #expect(Array(ids.prefix(4)) == [6, 7, 5, SearchTextTokenizer.endID])
        #expect(ids.count == SearchTextTokenizer.contextLength)
    }

    @Test(arguments: [1, 9, 40])
    func aTruncatedFileIsMalformed(cut: Int) {
        let data = File().bytes
        #expect(throws: SearchTextTokenizer.LoadError.malformed) {
            try SearchTextTokenizer(data: data.prefix(data.count - cut))
        }
    }

    /// Each corruption, one field at a time.
    @Test(arguments: [
        "startPastStrings", "startBackwards", "firstStartNotZero", "stringsOutOfOrder", "idPastVocabulary",
        "mergedIDPastVocabulary", "pairPastVocabulary", "mergesOutOfOrder", "vocabularySmallerThanEntries",
    ])
    func aCorruptFileIsMalformed(corruption: String) {
        var file = File()
        switch corruption {
        case "startPastStrings": file.start = (2, 400)
        case "startBackwards": file.start = (2, 0)
        case "firstStartNotZero": file.start = (0, 1)
        case "stringsOutOfOrder": file.entries.swapAt(0, 2)
        case "idPastVocabulary": file.entries[1].id = 8
        case "mergedIDPastVocabulary": file.merges[0].merged = 8
        case "pairPastVocabulary": file.merges[0].right = 9
        case "mergesOutOfOrder": file.merges.append(Merge(left: 4, right: 4, rank: 1, merged: 6))
        case "vocabularySmallerThanEntries": file.vocabularyCount = 3
        default: Issue.record("unknown corruption \(corruption)")
        }
        let data = file.bytes
        #expect(throws: SearchTextTokenizer.LoadError.malformed) {
            try SearchTextTokenizer(data: data)
        }
    }
}
