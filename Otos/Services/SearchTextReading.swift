import CoreGraphics
import CoreML
import Foundation
import ImageIO
import OSLog
import Synchronization
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
nonisolated struct SearchTextQuery: Sendable, Equatable {
    private let words: [(word: String, unspaced: Bool)]

    /// The same words match the same texts.
    static func == (lhs: SearchTextQuery, rhs: SearchTextQuery) -> Bool {
        lhs.words.map(\.word) == rhs.words.map(\.word)
    }

    init(_ query: String) {
        words = SearchTextReading.folded(query).split(whereSeparator: { !SearchTextWords.isWordCharacter($0) })
            .map(String.init)
            .filter { $0.count >= 2 }
            .map { ($0, $0.unicodeScalars.contains(where: Self.isUnspacedScript)) }
    }

    /// The query's words as the catalog's text index is asked for them (`SearchTextWords`):
    /// each word's first `SearchTextWords.prefixLength` characters as a prefix, all of them.
    /// Every text this query matches holds an indexed word each of them begins, so the rows the
    /// index returns are a superset of the matches, which `matches(folded:)` then decides. Nil
    /// for a query with no word, which matches nothing.
    var indexExpression: String? {
        guard !words.isEmpty else { return nil }
        return words.map { "\"\(SearchTextWords.indexed($0.word))\"*" }.joined(separator: " AND ")
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

    /// A scalar of a script written without spaces between words (Chinese, Japanese).
    static func isUnspacedScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040 ... 0x30FF, 0x3400 ... 0x9FFF, 0xF900 ... 0xFAFF:
            true
        default:
            false
        }
    }
}

/// Search text words guide (ADR 0048, "Text in the photo")
///
/// The words the catalog's text index (`search_text_word`, an FTS5 table) holds for one
/// reading, so a query finds the photos whose text it matches with one keyed read instead of
/// comparing every reading. `SearchTextQuery.matches(folded:)` is what a match is: a query word
/// at the start of a word of the text — after a character that is not a letter — or, for a word
/// of a script written without spaces, anywhere. The index holds exactly the places such a word
/// can start, so a prefix query over it misses no match:
///
/// - In each run of letters and numbers, the run from every position a word can start at: the
///   run's first character and each one after a number ("1abc" holds `1abc` and `abc`, since
///   "abc" matches it). A run holding a character of a script written without spaces holds the
///   run from every position, since such a word matches anywhere.
/// - Each is cut to `prefixLength` characters (a query word longer than that is asked for by
///   its first `prefixLength`), and one shorter than two characters is dropped (no query word
///   is). A word is in canonical composed form, so equivalent spellings are the same bytes.
///
/// The index is a candidate filter, never the answer: the rows it returns carry the reading
/// folded as `SearchTextReading.folded` gives it, and `SearchTextQuery.matches(folded:)` decides
/// each, so matching is exactly what it is over every reading. The table tokenises with
/// SQLite's `ascii` tokenizer, which splits only at ASCII characters that are not letters or
/// numbers — none of which a word holds — and folds only ASCII case, which folding already did.
/// SQLite's own `unicode61` and `trigram` tokenizers were measured against these matches and
/// differ (`docs/research/2026-11-16-search-text-index.md`). Changing what a word is changes
/// what the table must hold, so it ships with a migration that rebuilds the table.
nonisolated enum SearchTextWords {
    /// The longest word the index holds, in characters.
    static let prefixLength = 8

    /// A character a word is made of: a letter or a number, as the query splits its words.
    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// The index's words of `folded`, a text already folded (`SearchTextReading.folded`), each
    /// once, separated by spaces; empty when it holds none.
    static func of(folded: String) -> String {
        let characters = Array(folded)
        var words: [String] = []
        var seen: Set<String> = []
        var start = 0
        while start < characters.count {
            guard isWordCharacter(characters[start]) else {
                start += 1
                continue
            }
            var end = start
            while end < characters.count, isWordCharacter(characters[end]) {
                end += 1
            }
            let unspaced = characters[start ..< end].contains { $0.unicodeScalars.contains(where: SearchTextQuery.isUnspacedScript) }
            for position in start ..< end where unspaced || position == start || !characters[position - 1].isLetter {
                guard end - position >= 2 else { continue }
                let word = indexed(characters[position ..< min(end, position + prefixLength)])
                if seen.insert(word).inserted {
                    words.append(word)
                }
            }
            start = end
        }
        return words.joined(separator: " ")
    }

    /// `characters` as the index holds a word: at most `prefixLength` of them, composed.
    static func indexed(_ characters: some Collection<Character>) -> String {
        String(characters.prefix(prefixLength)).precomposedStringWithCanonicalMapping
    }
}

/// What reading one preview came to, in a session (`SearchTextSession`).
nonisolated enum SearchTextPreviewReading: Codable, Equatable, Sendable {
    /// The recognised lines; empty when the picture holds no text.
    case lines([RecognizedTextLine])
    /// The preview did not decode: no reading, so the still stays owed.
    case undecodable
    /// The recognition failed about this picture: no reading, so the still stays owed.
    case failed(String)
    /// The session cannot read again — Vision lost its reader for the session's process
    /// (`SearchTextReading.losesTheProcess`), or the process ended — and nothing more is
    /// asked of it; a new session reads the rest.
    case ended(String)
    /// The session's process ended while reading this picture, without answering — it
    /// crashed, or gave no answer by its deadline and was ended (`SearchTextChild`): the
    /// picture may be what ended it (a decoder or recognizer crash or hang), so it is no
    /// reading and stays owed, and the rest of the page is read by a new session. Never sent
    /// by the process itself.
    case exited(String)

    /// The case's name, for a log line.
    var outcomeName: String {
        switch self {
        case .lines: "lines"
        case .undecodable: "undecodable"
        case .failed: "failed"
        case .ended: "ended"
        case .exited: "exited"
        }
    }
}

nonisolated extension SearchTextReading {
    /// Reads the preview at `url` as a session does: decoded without caching, then
    /// recognised by `recognize`, Vision's reading unless a test gives its own.
    static func readPreview(
        at url: URL,
        recognize: (CGImage) throws -> [RecognizedTextLine] = read
    ) -> SearchTextPreviewReading {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return .undecodable
        }
        do {
            return try .lines(recognize(image))
        } catch where losesTheProcess(error) {
            return .ended(String(describing: error))
        } catch {
            return .failed(String(describing: error))
        }
    }
}

/// One process reading previews for text, one at a time: Otos's own reading process
/// (`SearchTextChild`) or, in a test, a reading in the test's process. A session that answers
/// `.ended` is never asked again.
nonisolated protocol SearchTextSession: AnyObject {
    func read(_ url: URL) -> SearchTextPreviewReading
    /// Ends the session from any thread, a reading in it or not, and returns once its process
    /// is gone: a reading in it then comes back without an answer (`.exited`).
    var end: @Sendable () async -> Void { get }
}

/// What reading a page of previews came to.
nonisolated enum SearchTextPageReading: Equatable, Sendable {
    /// One result per candidate read; a candidate with none stays owed.
    case read([SearchTextResult])
    /// The session reading the page ended: `before`, what the page read before it; nothing
    /// after it was attempted, and the next page is read by a new session.
    case sessionEnded(before: [SearchTextResult])
}

/// Reads stored previews for text, on its own serial queue: each reading waits on its session,
/// which blocks (ADR 0032 rule 6).
///
/// Vision's text reader can be lost for the rest of its process: a failure that says so
/// (`SearchTextReading.losesTheProcess`) comes back on every later reading in that process,
/// and nothing in it recovers, while a new process does
/// (`docs/research/2026-11-15-text-reading-lost-to-a-cache-purge.md`). So the reading runs in
/// a session of its own — in the app, a child process (`SearchTextChild`) — and a session
/// that ends ends the page: what it read is kept, the rest stays owed, and the next page
/// starts a new session. `op=search.text phase=sessionEnded` says so each time. The index's
/// own backoff paces the next page (`PhotoSearchIndex`), so a disk whose purges empty the
/// cache every few minutes starts a session at most once a backoff.
///
/// `shutdown` ends the reader from outside its queue, which a reading holds for as long as it
/// takes: it ends the live session, so the reading in it comes back unanswered and its still
/// stays owed, and no session starts after it. The session is started and recorded under one
/// lock with the shutdown's mark, so a session is either never started or ended by it.
actor SearchTextReader {
    typealias StartSession = @Sendable () throws -> any SearchTextSession

    private let queue = DispatchSerialQueue(label: "net.melisma.Otos.search.text", qos: .utility)
    /// Starts a session: Otos's reading process, unless a test gives its own.
    private let startSession: StartSession
    private var session: (any SearchTextSession)?
    /// What `shutdown` reads beside a reading in progress: whether it came, and how to end
    /// the live session.
    private let lifetime = Mutex(Lifetime())
    /// How many sessions this reader has started.
    private(set) var sessionsStarted = 0

    private struct Lifetime {
        var shutDown = false
        var endSession: (@Sendable () async -> Void)?
    }

    private enum Start {
        case started(any SearchTextSession)
        case failed(any Error)
        case shutDown
    }

    init(startSession: @escaping StartSession) {
        self.startSession = startSession
    }

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// Ends the live session and every later one, and returns once its process is gone. Not
    /// isolated to the reader: a reading holds the reader's queue until its session answers or
    /// ends, and ending it is what makes the reading return.
    nonisolated func shutdown() async {
        let endSession = lifetime.withLock { lifetime in
            lifetime.shutDown = true
            defer { lifetime.endSession = nil }
            return lifetime.endSession
        }
        await endSession?()
    }

    /// Starts a session unless the reader was shut down, recording how to end it under the
    /// same lock.
    private func start() -> Start {
        lifetime.withLock { lifetime in
            guard !lifetime.shutDown else { return .shutDown }
            do {
                let session = try startSession()
                lifetime.endSession = session.end
                return .started(session)
            } catch {
                return .failed(error)
            }
        }
    }

    /// The live session ended by itself: nothing is left for `shutdown` to end.
    private func sessionGone() {
        session = nil
        lifetime.withLock { $0.endSession = nil }
    }

    /// Reads `page` in order. A preview that does not decode, or a recognition that fails
    /// about one picture, is no reading: it has no result, so the still stays owed and is read
    /// again after the index's backoff (ADR 0032 rule 4), and the rest of the page is read. A
    /// session that ends, or cannot start, ends the page there, and so does the reader's
    /// shutdown. A failure is never a still with no text: it stamps nothing.
    func read(_ page: [SearchTextCandidate], directory: URL?) -> SearchTextPageReading {
        guard let directory else { return .read([]) }
        var results: [SearchTextResult] = []
        for candidate in page {
            let session: any SearchTextSession
            if let current = self.session {
                session = current
            } else {
                switch start() {
                case let .started(started):
                    session = started
                case let .failed(error):
                    OtosLog.thumbnails.errorOperation("search.text", phase: "sessionFailedToStart", fields: [
                        "error": String(describing: error),
                    ])
                    return .sessionEnded(before: results)
                case .shutDown:
                    OtosLog.thumbnails.noticeOperation("search.text", phase: "readerShutDown", fields: [
                        "read": "\(results.count)", "unread": "\(page.count - results.count)",
                    ])
                    return .sessionEnded(before: results)
                }
                self.session = session
                sessionsStarted += 1
            }
            switch session.read(directory.appending(path: candidate.previewPath)) {
            case let .lines(lines):
                results.append(SearchTextResult(id: candidate.id, source: candidate.source, lines: lines))
            case .undecodable:
                OtosLog.thumbnails.errorOperation("search.text", phase: "undecodable", fields: [
                    "id": candidate.id.relativePath.rawValue,
                ])
            case let .failed(error):
                OtosLog.thumbnails.errorOperation("search.text", phase: "failed", fields: ["error": error])
            case let .exited(reason):
                // Paged past, not the page's end: a picture that ends every process it is
                // asked of would otherwise come first in every page and stop every other
                // still from being read.
                sessionGone()
                OtosLog.thumbnails.errorOperation("search.text", phase: "sessionExited", fields: [
                    "id": candidate.id.relativePath.rawValue, "reason": reason,
                    "sessionsStarted": "\(sessionsStarted)",
                ])
            case let .ended(reason):
                sessionGone()
                OtosLog.thumbnails.errorOperation("search.text", phase: "sessionEnded", fields: [
                    "reason": reason, "sessionsStarted": "\(sessionsStarted)",
                ])
                return .sessionEnded(before: results)
            }
        }
        return .read(results)
    }
}
