import CoreGraphics
import CoreML
import Foundation
import ImageIO
import OSLog
import Vision

/// Search text reading guide (ADR 0048)
///
/// Text in a photo — a sign, a menu, a screenshot's message — is what an image embedding reads
/// worst: searched for a word Vision reads in the owner's photos, SigLIP put a photo holding it
/// in its top 10 for 21% of them (`docs/research/2026-11-09-keyword-search.md` §9). So the
/// stored preview of each still is read for text, and a query whose words appear in it
/// matches.
///
/// Recognition runs at Vision's accurate level on the 2,560 px preview, with language
/// correction and automatic languages, pinned to the CPU as every Otos model is (ADR 0045): on
/// the default device a reading stalled for 32 s under load, on the CPU it takes a median
/// 0.15 s. The fast level, which search read with before, reports only two confidences and
/// misreads texture as text at both (`*•9>•'•` at 0.5, beside real menu lines); the accurate
/// level reports 1.0 for the lines it is sure of, and on the owner's previews those read
/// cleanly (`docs/research/2026-11-12-text-and-labels-in-the-info-pane.md`). Every line from
/// 0.3 is kept with its confidence: search matches them all, and the Info pane shows the
/// certain ones (`certainConfidence`).
nonisolated enum SearchTextReading {
    /// The recognition settings; stored with every reading, so a change makes them stale.
    static let revision = 2
    static let minimumConfidence: Float = 0.3
    /// A line the Info pane shows: what the accurate level reports for the lines it is sure of.
    static let certainConfidence: Float = 1

    /// The recognised lines of `image`, in reading order; empty when it holds no text.
    static func read(_ image: CGImage) throws -> [RecognizedTextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        if let cpu = try request.supportedComputeStageDevices[.main]?.first(where: Self.isCPU) {
            request.setComputeDevice(cpu, for: .main)
        }
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first }
            .filter { $0.confidence >= minimumConfidence }
            .map { RecognizedTextLine(text: $0.string, confidence: $0.confidence) }
    }

    /// What search matches a query against: every kept line.
    static func searchable(_ lines: [RecognizedTextLine]) -> String {
        lines.map(\.text).joined(separator: "\n")
    }

    /// The lines the Info pane shows.
    static func certain(_ lines: [RecognizedTextLine]) -> [String] {
        lines.filter { $0.confidence >= certainConfidence }.map(\.text)
    }

    private static func isCPU(_ device: MLComputeDevice) -> Bool {
        if case .cpu = device {
            return true
        }
        return false
    }

    /// Whether every word of `query` appears in `text` at the start of a word, ignoring case
    /// and diacritics (`SearchTextQuery`).
    static func matches(query: String, in text: String) -> Bool {
        SearchTextQuery(query).matches(folded: folded(text))
    }

    /// A text as matching compares it: case, diacritics and width folded. The index keeps each
    /// reading folded, so a query folds only itself.
    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

/// A query's words as text matching reads them: folded, each of two or more characters. A
/// word matches at the start of a word of the text; a word in a script written without spaces
/// (Chinese, Japanese) matches anywhere. A query with no such word matches nothing.
nonisolated struct SearchTextQuery: Sendable {
    private let words: [(word: String, unspaced: Bool)]

    init(_ query: String) {
        words = SearchTextReading.folded(query).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 2 }
            .map { ($0, $0.unicodeScalars.contains(where: Self.isUnspacedScript)) }
    }

    /// Whether every word appears in `folded`, a text already folded (`SearchTextReading.folded`).
    func matches(folded haystack: String) -> Bool {
        guard !words.isEmpty else { return false }
        return words.allSatisfy { word, unspaced in
            var searchRange = haystack.startIndex ..< haystack.endIndex
            while let found = haystack.range(of: word, range: searchRange) {
                if unspaced || found.lowerBound == haystack.startIndex || !haystack[haystack.index(before: found.lowerBound)].isLetter {
                    return true
                }
                searchRange = found.upperBound ..< haystack.endIndex
            }
            return false
        }
    }

    private static func isUnspacedScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040 ... 0x30FF, 0x3400 ... 0x9FFF, 0xF900 ... 0xFAFF:
            true
        default:
            false
        }
    }
}

/// Reads stored previews for text, on its own serial queue: decoding a 2,560 px preview and
/// recognising text both block (ADR 0032 rule 6).
actor SearchTextReader {
    private let queue = DispatchSerialQueue(label: "net.melisma.Otos.search.text", qos: .utility)

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// One result per candidate read. A preview that does not decode, or a recognition that
    /// fails, is no reading: it has no result, so the still stays owed and is read again after
    /// the index's backoff.
    func read(_ page: [SearchTextCandidate], directory: URL?) -> [SearchTextResult] {
        guard let directory else { return [] }
        return page.compactMap { candidate in
            let url = directory.appending(path: candidate.previewPath)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                OtosLog.thumbnails.errorOperation("search.text", phase: "undecodable", fields: [
                    "id": candidate.id.relativePath.rawValue,
                ])
                return nil
            }
            do {
                return try SearchTextResult(id: candidate.id, source: candidate.source, lines: SearchTextReading.read(image))
            } catch {
                OtosLog.thumbnails.errorOperation("search.text", phase: "failed", fields: ["error": String(describing: error)])
                return nil
            }
        }
    }
}
