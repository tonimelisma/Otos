import CoreGraphics
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
/// Recognition runs at Vision's fast level on the 2,560 px preview, with language correction
/// and automatic languages: 0.07 s a preview, and on the owner's screenshots it read menus,
/// settings and forecasts cleanly. The accurate level failed on macOS 27 for every image after
/// a process's first (`e5rt` error 13, research §9), with or without a pinned device; at
/// 512 px the fast level read noise, so it reads the full preview. A line below 0.3 confidence
/// is dropped.
nonisolated enum SearchTextReading {
    /// The recognition settings; stored with every reading, so a change makes them stale.
    static let revision = 1
    static let minimumConfidence: Float = 0.3

    /// The recognised lines of `image`, joined by newlines; empty when it holds no text.
    static func read(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first }
            .filter { $0.confidence >= minimumConfidence }
            .map(\.string)
            .joined(separator: "\n")
    }

    /// Whether every word of `query` appears in `text` at the start of a word, ignoring case
    /// and diacritics. A word in a script written without spaces (Chinese, Japanese) matches
    /// anywhere. A query with no word of two or more characters matches nothing.
    static func matches(query: String, in text: String) -> Bool {
        let words: [String] = folded(query).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 2 }
        guard !words.isEmpty else { return false }
        let haystack = folded(text)
        return words.allSatisfy { word in
            var searchRange = haystack.startIndex ..< haystack.endIndex
            while let found = haystack.range(of: word, range: searchRange) {
                if found.lowerBound == haystack.startIndex || !haystack[haystack.index(before: found.lowerBound)].isLetter
                    || word.unicodeScalars.contains(where: isUnspacedScript)
                {
                    return true
                }
                searchRange = found.upperBound ..< haystack.endIndex
            }
            return false
        }
    }

    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
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

    /// One result per candidate. A preview that does not decode is recorded as holding no
    /// text; a recognition that fails records nothing, so the still stays owed.
    func read(_ page: [SearchTextCandidate], directory: URL?) -> [SearchTextResult] {
        guard let directory else { return [] }
        return page.compactMap { candidate in
            let url = directory.appending(path: candidate.previewPath)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                return SearchTextResult(id: candidate.id, source: candidate.source, text: "")
            }
            do {
                return try SearchTextResult(id: candidate.id, source: candidate.source, text: SearchTextReading.read(image))
            } catch {
                OtosLog.thumbnails.errorOperation("search.text", phase: "failed", fields: ["error": String(describing: error)])
                return nil
            }
        }
    }
}
