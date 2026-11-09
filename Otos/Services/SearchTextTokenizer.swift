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
/// A value: built once off the main actor and read concurrently.
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

    /// Keyed by UTF-8 bytes, not `String`: Swift compares strings by canonical equivalence,
    /// and 77 of the vocabulary's tokens are decomposed forms of others.
    private let vocabulary: [[UInt8]: Int32]
    private let byteIDs: [Int32]
    /// `(left << 32 | right)` → `(rank << 32 | merged id)`.
    private let merges: [UInt64: UInt64]

    init(bundle: Bundle) throws {
        guard let url = bundle.url(forResource: "SigLIP2Tokenizer", withExtension: "bin") else {
            throw LoadError.missingResource
        }
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    init(data: Data) throws {
        var reader = ByteReader(data: data)
        guard try reader.bytes(8) == Array("OTBPE1\0\0".utf8) else {
            throw LoadError.malformed
        }
        let vocabularyCount = try Int(reader.uint32())
        let mergeCount = try Int(reader.uint32())
        var tokens: [[UInt8]] = []
        tokens.reserveCapacity(vocabularyCount)
        var vocabulary: [[UInt8]: Int32] = [:]
        vocabulary.reserveCapacity(vocabularyCount)
        for id in 0 ..< vocabularyCount {
            let length = try Int(reader.uint16())
            let token = try reader.bytes(length)
            tokens.append(token)
            // The first id wins, as in the trained vocabulary's map.
            if vocabulary[token] == nil {
                vocabulary[token] = Int32(id)
            }
        }
        var merges: [UInt64: UInt64] = [:]
        merges.reserveCapacity(mergeCount)
        for rank in 0 ..< mergeCount {
            let left = try reader.uint32()
            let right = try reader.uint32()
            guard Int(left) < vocabularyCount, Int(right) < vocabularyCount,
                  let merged = vocabulary[tokens[Int(left)] + tokens[Int(right)]]
            else {
                throw LoadError.malformed
            }
            merges[UInt64(left) << 32 | UInt64(right)] = UInt64(rank) << 32 | UInt64(UInt32(merged))
        }
        // The vocabulary has no `<0x09>`: a tab is its own token, and canonical text has none.
        let byteIDs = (0 ... 255).map { byte in
            vocabulary[Array(String(format: "<0x%02X>", byte).utf8)] ?? Self.unknownID
        }
        self.vocabulary = vocabulary
        self.byteIDs = byteIDs
        self.merges = merges
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
            if let id = vocabulary[piece] {
                ids.append(id)
            } else {
                ids.append(contentsOf: piece.map { byteIDs[Int($0)] })
            }
        }
        return ids
    }

    private func merge(_ ids: inout [Int32]) {
        while ids.count > 1 {
            var best: (index: Int, rank: UInt64, merged: Int32)?
            for index in 0 ..< ids.count - 1 {
                let key = UInt64(UInt32(bitPattern: ids[index])) << 32 | UInt64(UInt32(bitPattern: ids[index + 1]))
                guard let entry = merges[key] else { continue }
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

private nonisolated struct ByteReader {
    let data: Data
    var offset = 0

    mutating func bytes(_ count: Int) throws -> [UInt8] {
        guard offset + count <= data.count else {
            throw SearchTextTokenizer.LoadError.malformed
        }
        defer { offset += count }
        return [UInt8](data[data.startIndex + offset ..< data.startIndex + offset + count])
    }

    mutating func uint16() throws -> UInt16 {
        let b = try bytes(2)
        return UInt16(b[0]) | UInt16(b[1]) << 8
    }

    mutating func uint32() throws -> UInt32 {
        let b = try bytes(4)
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }
}
