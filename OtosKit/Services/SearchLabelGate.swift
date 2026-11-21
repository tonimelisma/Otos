import Accelerate
import CoreGraphics
import Foundation
import Vision

/// Search label gate guide (ADR 0048)
///
/// A second, independent reading of each picture: Vision's scene classifier (1,303 labels,
/// built into macOS) run on the same stored thumbnail as the embedding. A query that names a
/// thing the classifier knows — "horse", "cat", "Christmas tree" — keeps only the photos where
/// the classifier saw it too, or where SigLIP is nearly as sure as of its best match.
///
/// Measured on the owner's judged queries (`docs/research/2026-11-09-keyword-search.md` §9):
/// precision inside the cutoff rose from 0.65 to 0.70, with 81% of the relevant photos kept
/// against 87%. A query for a thing the library barely holds no longer floods the grid: horse
/// showed 150 photos, two of them right; gated, 27. Lowering the cutoff instead bought less
/// precision for the same loss.
///
/// - **Which labels a query names:** those whose name SigLIP's text tower places at cosine
///   0.95 or more from the query's English (`SearchLabelVocabulary`, the label names embedded
///   ahead of time). Synonyms come with it ("cat" names cat, kitten and feline); a phrase
///   names none, so "child on a slide" is never gated.
/// - **Kept:** confidence 0.05 or more for one of them, or a cosine within 0.02 of the best.
nonisolated enum SearchLabelGate {
    static let namingSimilarity: Float = 0.95
    static let minimumConfidence: Float = 0.05
    static let nearBest: Float = 0.02

    /// `confidence`: the photo's confidence in a label by its identifier, nil when absent.
    static func keeps(score: Float, best: Float, named: [String], confidence: (String) -> Float?) -> Bool {
        guard !named.isEmpty else { return true }
        if score >= best - nearBest {
            return true
        }
        return named.contains { (confidence($0) ?? 0) >= minimumConfidence }
    }
}

/// Vision's scene classification of one picture, read twice over:
/// - **For the gate:** every label at or above `SearchLabelGate.minimumConfidence`, with its
///   confidence — a loose reading on purpose, about 18 labels a photo on the owner's library,
///   with echoes like a horse beside a wagon at 0.08.
/// - **For the Info pane:** the labels that pass Vision's own high-precision test
///   (`hasMinimumRecall(0.01, forPrecision: 0.9)`, Apple's recommended filter: each label's
///   threshold comes from its precision-recall curve, not one cut for all). About five a photo,
///   most confident first (`docs/research/2026-11-12-text-and-labels-in-the-info-pane.md`).
nonisolated enum SearchSceneLabels {
    /// The classifier revision measured; part of `SearchEmbedding.revision`.
    static let revision = VNClassifyImageRequestRevision2
    static let shownPrecision: Float = 0.9
    static let shownRecall: Float = 0.01

    static func classify(_ image: CGImage) throws -> SceneLabelReading {
        let request = VNClassifyImageRequest()
        request.revision = revision
        try VNImageRequestHandler(cgImage: image).perform([request])
        let observations = request.results ?? []
        var labels: [String: Float] = [:]
        for observation in observations where observation.confidence >= SearchLabelGate.minimumConfidence {
            labels[observation.identifier] = observation.confidence
        }
        let confident = observations
            .filter { $0.hasMinimumRecall(shownRecall, forPrecision: shownPrecision) }
            .sorted { ($0.confidence, $1.identifier) > ($1.confidence, $0.identifier) }
            .map(\.identifier)
        return SceneLabelReading(labels: labels, confident: confident)
    }
}

/// One picture's scene labels: the gate's loose reading and the confident ones the Info pane
/// shows, most confident first.
nonisolated struct SceneLabelReading: Equatable, Sendable {
    var labels: [String: Float] = [:]
    var confident: [String] = []
}

/// The classifier's label names embedded by the shipped text path (`SearchLabelEmbeddings.bin`:
/// "OTLBL1\0\0", UInt32 count, UInt32 dimensions, then each identifier as UInt16 length + UTF-8,
/// then count × dimensions little-endian Float16), so naming a query's labels is one product.
nonisolated struct SearchLabelVocabulary: Sendable {
    let identifiers: [String]
    private let matrix: [Float]

    enum LoadError: Error {
        case missingResource
        case malformed
    }

    init(bundle: Bundle) throws {
        guard let url = bundle.url(forResource: "SearchLabelEmbeddings", withExtension: "bin") else {
            throw LoadError.missingResource
        }
        let data = try Data(contentsOf: url)
        try self.init(data: data)
    }

    init(data: Data) throws {
        guard data.count > 16, data.prefix(8) == Data("OTLBL1\0\0".utf8) else { throw LoadError.malformed }
        func uint(_ offset: Int, _ width: Int) -> Int {
            (0 ..< width).reduce(0) { $0 | Int(data[data.startIndex + offset + $1]) << (8 * $1) }
        }
        let count = uint(8, 4), dimensions = uint(12, 4)
        guard dimensions == SearchEmbedding.dimensions else { throw LoadError.malformed }
        var offset = 16
        var identifiers: [String] = []
        for _ in 0 ..< count {
            guard offset + 2 <= data.count else { throw LoadError.malformed }
            let length = uint(offset, 2)
            offset += 2
            guard offset + length <= data.count,
                  let identifier = String(data: data[data.startIndex + offset ..< data.startIndex + offset + length], encoding: .utf8)
            else {
                throw LoadError.malformed
            }
            identifiers.append(identifier)
            offset += length
        }
        guard data.count - offset == count * dimensions * 2 else { throw LoadError.malformed }
        var halves = [UInt16](repeating: 0, count: count * dimensions)
        _ = halves.withUnsafeMutableBytes { data.copyBytes(to: $0, from: data.startIndex + offset ..< data.endIndex) }
        self.identifiers = identifiers
        matrix = halves.map { Float(Float16(bitPattern: UInt16(littleEndian: $0))) }
    }

    /// The labels `query` (an English text embedding) names.
    func labels(namedBy query: [Float]) -> [String] {
        let similarities = PhotoSearchIndex.scores(matrix, count: identifiers.count, query: query)
        return similarities.enumerated().compactMap { $0.element >= SearchLabelGate.namingSimilarity ? identifiers[$0.offset] : nil }
    }
}
