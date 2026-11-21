import Foundation

/// Search text tokenizer guide
///
/// SigLIP 2's text tower reads Gemma's byte-pair-encoding vocabulary: 256,000 tokens and
/// 580,604 ranked merges (`SigLIP2Tokenizer.bin`, exported from the tokenizer the model was
/// trained with; ADR 0048). A query becomes exactly the ids open_clip's tokenizer gives it,
/// which `SearchModelTests` checks against 2,682 reference strings in 17 languages:
///
/// 1. **Canonical text**, as open_clip cleans SigLIP queries: NFC, the typographic
///    substitutions ftfy makes (curly quotes, Latin ligatures, full-width forms), `_` read as
///    a space, ASCII punctuation removed, lower case, runs of white space collapsed.
/// 2. **Pieces:** every space becomes `▁`, and each Unicode scalar is its own token, or its
///    UTF-8 bytes as `<0xNN>` tokens when the vocabulary lacks it.
/// 3. **Merges:** the adjacent pair with the lowest rank merges first, leftmost on a tie,
///    until no ranked pair is left.
/// 4. **Frame:** at most 63 tokens, then `<eos>`, padded with `<pad>` to 64.
///
/// **The file is the lookup.** `SigLIP2Tokenizer.bin` holds the tables already sorted, and the
/// tokenizer maps it and searches it in place: loading builds nothing, so it costs a mapping
/// and no heap (building hash tables of the vocabulary and merges took about 400 ms and 37 MB
/// at every encoder load; `docs/research/2026-11-16-first-search-after-launch.md`). Loading
/// reads every table once to check it (`tablesAreWellFormed`): a file whose offsets, order or
/// ids are not what the searches assume is `LoadError.malformed`, never a trap or an id the
/// text tower cannot read. Little endian, each table 8-byte aligned:
///
/// | Bytes | Holds |
/// | --- | --- |
/// | 8 | `OTBPE2\0\0` |
/// | 4 × 4 | the vocabulary's size, its distinct byte strings (E), the merges (M), the string bytes |
/// | 8 × M | each merge's pair, `left << 32 \| right`, ascending |
/// | 8 × M | the same merge's `rank << 32 \| merged id` |
/// | 4 × (E + 1) | where each string starts in the string bytes, the strings in ascending byte order |
/// | 4 × E | each string's id: the first id the trained vocabulary gives it |
/// | the string bytes | the strings, in that order |
///
/// Strings compare as UTF-8 bytes, not as `String`: Swift compares strings by canonical
/// equivalence, and 77 of the vocabulary's tokens are decomposed forms of others.
///
/// A value: mapped once off the main actor and read concurrently.
nonisolated struct SearchTextTokenizer: Sendable {
    /// The text tower's fixed sequence length.
    static let contextLength = 64
    static let padID: Int32 = 0
    static let endID: Int32 = 1
    static let unknownID: Int32 = 3

    enum LoadError: Error {
        case missingResource
        case malformed
    }

    private static let magic = Array("OTBPE2\0\0".utf8)
    private static let headerLength = 24

    /// The mapped file.
    private let file: Data
    private let entryCount: Int
    private let mergeCount: Int
    private let mergeKeysOffset: Int
    private let mergeValuesOffset: Int
    private let startsOffset: Int
    private let idsOffset: Int
    private let stringsOffset: Int

    init(bundle: Bundle) throws {
        guard let url = bundle.url(forResource: "SigLIP2Tokenizer", withExtension: "bin") else {
            throw LoadError.missingResource
        }
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    init(data: Data) throws {
        guard data.count >= Self.headerLength, data.prefix(8).elementsEqual(Self.magic) else {
            throw LoadError.malformed
        }
        let header = data.withUnsafeBytes { raw in
            (1 ... 4).map { Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4 + 4 * $0, as: UInt32.self))) }
        }
        let (vocabularyCount, entryCount, mergeCount, stringsLength) = (header[0], header[1], header[2], header[3])
        file = data
        self.entryCount = entryCount
        self.mergeCount = mergeCount
        mergeKeysOffset = Self.headerLength
        mergeValuesOffset = mergeKeysOffset + 8 * mergeCount
        startsOffset = mergeValuesOffset + 8 * mergeCount
        idsOffset = startsOffset + 4 * (entryCount + 1)
        stringsOffset = idsOffset + 4 * entryCount
        guard vocabularyCount <= Int(Int32.max), entryCount <= vocabularyCount,
              stringsOffset + stringsLength == data.count, tablesAreWellFormed(vocabularyCount: vocabularyCount)
        else {
            throw LoadError.malformed
        }
    }

    /// Whether every table holds what the searches assume, checked once at load so no
    /// corrupt file can trap a search or answer with an id the text tower cannot read:
    /// - each string starts where the one before it ended, the first at 0 and the last
    ///   ending at the strings' length, and the strings ascend strictly by bytes;
    /// - every string's id is below the vocabulary's size;
    /// - the merge pairs ascend strictly, and both halves of each pair and its merged id
    ///   are below the vocabulary's size.
    /// One pass over the tables reads every page of the mapping once; nothing is built.
    private func tablesAreWellFormed(vocabularyCount: Int) -> Bool {
        let vocabulary = UInt64(vocabularyCount)
        return file.withUnsafeBytes { raw in
            var previous: UnsafeRawBufferPointer?
            var end = 0
            guard Self.load(UInt32.self, at: startsOffset, in: raw) == 0 else { return false }
            for entry in 0 ..< entryCount {
                let start = end
                end = Int(Self.load(UInt32.self, at: startsOffset + 4 * (entry + 1), in: raw))
                guard start <= end, stringsOffset + end <= raw.count,
                      UInt64(Self.load(UInt32.self, at: idsOffset + 4 * entry, in: raw)) < vocabulary
                else {
                    return false
                }
                let string = UnsafeRawBufferPointer(rebasing: raw[stringsOffset + start ..< stringsOffset + end])
                if let previous, !previous.lexicographicallyPrecedes(string) {
                    return false
                }
                previous = string
            }
            guard stringsOffset + end == raw.count else { return false }
            var previousKey: UInt64?
            for merge in 0 ..< mergeCount {
                let key = Self.load(UInt64.self, at: mergeKeysOffset + 8 * merge, in: raw)
                let merged = Self.load(UInt64.self, at: mergeValuesOffset + 8 * merge, in: raw) & 0xFFFF_FFFF
                guard key >> 32 < vocabulary, key & 0xFFFF_FFFF < vocabulary, merged < vocabulary,
                      previousKey.map({ $0 < key }) ?? true
                else {
                    return false
                }
                previousKey = key
            }
            return true
        }
    }

    /// The 64 token ids the text tower reads for `text`.
    func tokenIDs(for text: String) -> [Int32] {
        var ids = pieces(of: Self.canonical(text))
        merge(&ids)
        ids = Array(ids.prefix(Self.contextLength - 1))
        ids.append(Self.endID)
        ids.append(contentsOf: repeatElement(Self.padID, count: Self.contextLength - ids.count))
        return ids
    }

    private func pieces(of text: String) -> [Int32] {
        var ids: [Int32] = []
        for scalar in text.unicodeScalars {
            let piece = Array((scalar == " " ? "▁" : String(scalar)).utf8)
            if let id = id(of: piece) {
                ids.append(id)
            } else {
                ids.append(contentsOf: piece.map(byteID))
            }
        }
        return ids
    }

    private func merge(_ ids: inout [Int32]) {
        while ids.count > 1 {
            var best: (index: Int, rank: UInt64, merged: Int32)?
            for index in 0 ..< ids.count - 1 {
                let key = UInt64(UInt32(bitPattern: ids[index])) << 32 | UInt64(UInt32(bitPattern: ids[index + 1]))
                guard let entry = mergeEntry(key) else { continue }
                let rank = entry >> 32
                if best == nil || rank < best!.rank {
                    best = (index, rank, Int32(bitPattern: UInt32(truncatingIfNeeded: entry)))
                }
            }
            guard let best else { return }
            ids[best.index] = best.merged
            ids.remove(at: best.index + 1)
        }
    }

    /// A byte's own token, `<0xNN>`. The vocabulary has no `<0x09>`: a tab is its own token,
    /// and canonical text has none.
    private func byteID(_ byte: UInt8) -> Int32 {
        id(of: Array(String(format: "<0x%02X>", byte).utf8)) ?? Self.unknownID
    }

    /// The id the vocabulary gives `piece`'s bytes, by binary search of the sorted strings.
    private func id(of piece: [UInt8]) -> Int32? {
        file.withUnsafeBytes { raw in
            var low = 0, high = entryCount
            while low < high {
                let middle = (low + high) / 2
                let start = Int(Self.load(UInt32.self, at: startsOffset + 4 * middle, in: raw))
                let end = Int(Self.load(UInt32.self, at: startsOffset + 4 * middle + 4, in: raw))
                let string = UnsafeRawBufferPointer(rebasing: raw[stringsOffset + start ..< stringsOffset + end])
                if string.lexicographicallyPrecedes(piece) {
                    low = middle + 1
                } else if piece.lexicographicallyPrecedes(string) {
                    high = middle
                } else {
                    return Int32(bitPattern: Self.load(UInt32.self, at: idsOffset + 4 * middle, in: raw))
                }
            }
            return nil
        }
    }

    /// The merge of the pair `key`, `rank << 32 | merged id`, by binary search of the sorted pairs.
    private func mergeEntry(_ key: UInt64) -> UInt64? {
        file.withUnsafeBytes { raw in
            var low = 0, high = mergeCount
            while low < high {
                let middle = (low + high) / 2
                let candidate = Self.load(UInt64.self, at: mergeKeysOffset + 8 * middle, in: raw)
                if candidate < key {
                    low = middle + 1
                } else if candidate > key {
                    high = middle
                } else {
                    return Self.load(UInt64.self, at: mergeValuesOffset + 8 * middle, in: raw)
                }
            }
            return nil
        }
    }

    private static func load<T: FixedWidthInteger>(_: T.Type, at offset: Int, in data: Data) -> T {
        data.withUnsafeBytes { load(T.self, at: offset, in: $0) }
    }

    private static func load<T: FixedWidthInteger>(_: T.Type, at offset: Int, in raw: UnsafeRawBufferPointer) -> T {
        T(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: T.self))
    }

    /// open_clip's SigLIP cleaning: ftfy's default fixes that apply to typed text, then
    /// big_vision's canonicalisation.
    static func canonical(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            if let replacement = typographic[scalar] {
                scalars.append(contentsOf: replacement.unicodeScalars)
            } else if (0xFF01 ... 0xFF5E).contains(scalar.value), let narrow = Unicode.Scalar(scalar.value - 0xFEE0) {
                scalars.append(narrow)
            } else if scalar.value == 0x3000 {
                scalars.append(" ")
            } else {
                scalars.append(scalar)
            }
        }
        let cleaned = String(scalars)
            .replacingOccurrences(of: "_", with: " ")
            .filter { !asciiPunctuation.contains($0) }
            .lowercased()
        return cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// ftfy's `uncurl_quotes` and `fix_latin_ligatures`.
    private static let typographic: [Unicode.Scalar: String] = [
        "\u{2018}": "'", "\u{2019}": "'", "\u{201A}": "'", "\u{201B}": "'",
        "\u{201C}": "\"", "\u{201D}": "\"", "\u{201E}": "\"", "\u{201F}": "\"",
        "\u{FB00}": "ff", "\u{FB01}": "fi", "\u{FB02}": "fl", "\u{FB03}": "ffi", "\u{FB04}": "ffl",
        "\u{FB05}": "st", "\u{FB06}": "st", "\u{0132}": "IJ", "\u{0133}": "ij", "\u{0149}": "\u{02BC}n",
        "\u{01C4}": "D\u{017D}", "\u{01C5}": "D\u{017E}", "\u{01C6}": "d\u{017E}",
        "\u{01F1}": "DZ", "\u{01F2}": "Dz", "\u{01F3}": "dz",
        "\u{01C7}": "LJ", "\u{01C8}": "Lj", "\u{01C9}": "lj", "\u{01CA}": "NJ", "\u{01CB}": "Nj", "\u{01CC}": "nj",
    ]

    /// Python's `string.punctuation`.
    private static let asciiPunctuation = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")
}
