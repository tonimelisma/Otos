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

    /// Whether `error` loses Vision's text reader for the rest of its process.
    ///
    /// Vision's text reader keeps its compiled model in memory for the process and reloads
    /// parts of it from the runtime's compiled-model cache in `~/Library/Caches` at every
    /// reading. When macOS purges those files under disk pressure, every later reading in the
    /// process throws `CRImageReaderError.e5rtError(_, 13)` — the runtime could not create the
    /// precompiled operation — and nothing in the process recovers it: not a new request or
    /// handler, the default device, the Swift `RecognizeTextRequest`, nor removing the cache.
    /// A new process recompiles and reads
    /// (`docs/research/2026-11-15-text-reading-lost-to-a-cache-purge.md`).
    ///
    /// It is told by the error's domain and code (`CRImageReaderError` code 1, its `e5rtError`
    /// case) and that case's own `e5rt` status, 13, read from the typed value, never from its
    /// text. Status 10, the runtime's deadline overrun on a cold reading under load, is not
    /// it: that is a failure of one reading. An error this cannot read is not it either, and
    /// is a failure of one reading.
    static func losesTheProcess(_ error: any Error) -> Bool {
        let bridged = error as NSError
        guard bridged.domain == "TextRecognition.CRImageReaderError", bridged.code == 1,
              let payload = Mirror(reflecting: error).children.first?.value
        else { return false }
        return Mirror(reflecting: payload).children.contains { field in
            (field.value as? any BinaryInteger).flatMap { Int(exactly: $0) } == lostE5RTStatus
        }
    }

    /// The `e5rt` status (a `UInt32` in the case) whose operation could not be created from the
    /// compiled-model cache.
    private static let lostE5RTStatus = 13

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

/// What reading a page of previews came to.
nonisolated enum SearchTextPageReading: Equatable, Sendable {
    /// One result per candidate read; a candidate with none stays owed.
    case read([SearchTextResult])
    /// Vision's reader is lost for the rest of this process: `before`, what the page read
    /// before it was lost; nothing after it is attempted.
    case readerLost(before: [SearchTextResult])
}

/// Reads stored previews for text, on its own serial queue: decoding a 2,560 px preview and
/// recognising text both block (ADR 0032 rule 6).
///
/// Vision's text reader can be lost for the rest of its process: a failure that says so
/// (`SearchTextReading.losesTheProcess`) comes back on every later reading until Otos
/// relaunches, and a new request or handler does not recover it
/// (`docs/research/2026-11-15-text-reading-lost-to-a-cache-purge.md`). From that failure on,
/// this reader attempts nothing — no preview is decoded, no recognition made — and says so,
/// once, as `op=search.text phase=readerLost`. Every still it did not read stays owed and is
/// read in the next process.
actor SearchTextReader {
    typealias Recognize = @Sendable (CGImage) throws -> [RecognizedTextLine]

    private let queue = DispatchSerialQueue(label: "net.melisma.Otos.search.text", qos: .utility)
    /// Vision's reading (`SearchTextReading.read`); tests replace it to deliver its failure.
    private let recognize: Recognize
    /// Whether the reader is lost for this process. Set once, never cleared: only a new process
    /// recovers it.
    private(set) var isLost = false

    init(recognize: @escaping Recognize = SearchTextReading.read) {
        self.recognize = recognize
    }

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// Reads `page` in order. A preview that does not decode, or a recognition that fails
    /// about one picture, is no reading: it has no result, so the still stays owed and is read
    /// again after the index's backoff (ADR 0032 rule 4), and the rest of the page is read. A
    /// failure that loses the reader for the process ends the page there and every page after
    /// it. A failure is never a still with no text: it stamps nothing.
    func read(_ page: [SearchTextCandidate], directory: URL?) -> SearchTextPageReading {
        guard !isLost else { return .readerLost(before: []) }
        guard let directory else { return .read([]) }
        var results: [SearchTextResult] = []
        for candidate in page {
            let url = directory.appending(path: candidate.previewPath)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                OtosLog.thumbnails.errorOperation("search.text", phase: "undecodable", fields: [
                    "id": candidate.id.relativePath.rawValue,
                ])
                continue
            }
            do {
                try results.append(SearchTextResult(id: candidate.id, source: candidate.source, lines: recognize(image)))
            } catch where SearchTextReading.losesTheProcess(error) {
                isLost = true
                OtosLog.thumbnails.errorOperation("search.text", phase: "readerLost", fields: [
                    "error": String(describing: error),
                    "domain": (error as NSError).domain,
                    "code": "\((error as NSError).code)",
                ])
                return .readerLost(before: results)
            } catch {
                OtosLog.thumbnails.errorOperation("search.text", phase: "failed", fields: ["error": String(describing: error)])
            }
        }
        return .read(results)
    }
}
