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
/// 0.3 is kept with its confidence and its box: search matches them all, and the Info pane and
/// the description's facts show the lines a person reads as the photo's text (`shown`).
nonisolated enum SearchTextReading {
    /// The recognition settings and what a reading holds; stored with every reading, so a
    /// change makes them stale. Revision 3 keeps each line's box and the picture's size.
    static let revision = 3
    static let minimumConfidence: Float = 0.3
    /// A line the Info pane shows: what the accurate level reports for the lines it is sure of.
    static let certainConfidence: Float = 1

    /// What `image` holds: its size, and its recognised lines in reading order.
    static func read(_ image: CGImage) throws -> TextReading {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        if let cpu = try request.supportedComputeStageDevices[.main]?.first(where: Self.isCPU) {
            request.setComputeDevice(cpu, for: .main)
        }
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { observation -> RecognizedTextLine? in
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= minimumConfidence else {
                return nil
            }
            // Vision's box is normalized with its origin at the bottom left.
            let box = observation.boundingBox
            return RecognizedTextLine(
                text: candidate.string,
                confidence: candidate.confidence,
                box: TextBox(left: box.minX, top: 1 - box.maxY, right: box.maxX, bottom: 1 - box.minY)
            )
        }
        return TextReading(width: image.width, height: image.height, lines: lines)
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
    static func searchable(_ reading: TextReading) -> String {
        reading.lines.map(\.text).joined(separator: "\n")
    }

    /// The lines a person reads as the photo's text, which the Info pane shows and a
    /// description is told: each line Vision is certain of, once, in reading order, without a
    /// phone screenshot's status bar. `sceneLabels` are the photo's confident scene labels.
    ///
    /// Measured on the owner's library (`docs/research/2026-11-19-info-labels-and-text.md`):
    /// 3,792 stills showed a line more than once ("dreamforce" three times, one banner per
    /// stand), and every phone screenshot began with its clock, signal and battery
    /// ("23:11 1", "25", "SOS"). Those lines end within the top `statusBarDepth` of a phone's
    /// portrait screen on every device sampled, from 640×1136 to 1179×2556, and the screen's
    /// own content starts below it; a cropped screenshot can hold a real title there, so only
    /// a picture of a phone screen's proportions loses that band. Search still matches every
    /// line.
    static func shown(_ reading: TextReading, sceneLabels: [String]) -> [String] {
        let phoneScreen = sceneLabels.contains(screenshotLabel) && reading.height > 0
            && Double(reading.width) / Double(reading.height) <= phoneScreenMaximumAspect
        var seen: Set<String> = []
        return reading.lines.compactMap { line in
            guard line.confidence >= certainConfidence,
                  !(phoneScreen && line.box.bottom <= statusBarDepth),
                  seen.insert(folded(line.text)).inserted
            else { return nil }
            return line.text
        }
    }

    /// Vision's scene label for a screenshot.
    static let screenshotLabel = "screenshot"
    /// A phone screen in portrait is at most this wide for its height: 0.46 for an iPhone with
    /// a Dynamic Island, 0.56 for one with a home button.
    static let phoneScreenMaximumAspect = 0.6
    /// The status bar's depth on a phone's portrait screen, as a fraction of its height: its
    /// lines ended at 0.031–0.048 on every device measured, the screen's content began at 0.047.
    static let statusBarDepth = 0.05

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
    /// What the picture holds; no lines when it holds no text.
    case read(TextReading)
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
        case .read: "read"
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
        recognize: (CGImage) throws -> TextReading = read
    ) -> SearchTextPreviewReading {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return .undecodable
        }
        do {
            return try .read(recognize(image))
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
    /// Lets the session's process go from any thread without waiting for it to exit: what the
    /// reader does when the background room holds text reading (ADR 0057).
    var closeNow: @Sendable () -> Void { get }
    /// Logs what the session's process cost so far: the reader asks after each page.
    func reportUsage()
}

nonisolated extension SearchTextSession {
    /// A session in the test's own process has no process to let go.
    var closeNow: @Sendable () -> Void {
        {}
    }

    /// A session in the test's own process has no process whose cost to report.
    func reportUsage() {}
}

/// What reading a page of previews came to.
nonisolated enum SearchTextPageReading: Equatable, Sendable {
    /// One result per candidate read; a candidate with none stays owed.
    case read([SearchTextResult])
    /// The session reading the page ended: `before`, what the page read before it; nothing
    /// after it was attempted, and the next page is read by a new session.
    case sessionEnded(before: [SearchTextResult])
    /// The background room held text reading before the page's `attempted`-th candidate
    /// (ADR 0057): `before`, what it read until then; the rest were not asked, and the
    /// session was let go.
    case held(before: [SearchTextResult], attempted: Int)
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
/// The background room (ADR 0057) decides whether a reading may start: before each reading
/// the reader asks it, and while it holds text reading the page stops there (`.held`) and the
/// live session is let go, its helper process exiting at its input's end. A helper idle
/// between pages is let go in the step the room's hold is delivered, and one mid-reading only
/// at `memoryCritical`, whose reading comes back unanswered and stays owed. One helper at a
/// time, never more: each holds its own copy of the system's text model.
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
    private let lifetime: LockedLifetime

    /// The lifetime behind its lock, shared with the room's observer.
    private final nonisolated class LockedLifetime: Sendable {
        private let state = Mutex(Lifetime())

        func withLock<Result>(_ body: (inout Lifetime) -> Result) -> Result {
            state.withLock { body(&$0) }
        }
    }

    /// How many sessions this reader has started.
    private(set) var sessionsStarted = 0

    private struct Lifetime {
        var shutDown = false
        var endSession: (@Sendable () async -> Void)?
        var closeNow: (@Sendable () -> Void)?
        /// A reading is in the live session now.
        var reading = false
        /// The room's observer let the live session go: the reader drops it at its next
        /// reading.
        var released = false
    }

    /// Whether text reading may start a reading now (ADR 0057).
    private let room: BackgroundRoom
    /// Lets the live session go when the room holds text reading: at once while no reading
    /// runs in it, and mid-reading at `memoryCritical`, whose reading stays owed.
    private let roomObservation: BackgroundRoomObservation

    private enum Start {
        case started(any SearchTextSession)
        case failed(any Error)
        case shutDown
    }

    init(startSession: @escaping StartSession, room: BackgroundRoom = BackgroundRoom()) {
        self.startSession = startSession
        self.room = room
        let lifetime = LockedLifetime()
        self.lifetime = lifetime
        roomObservation = room.observe { [weak room] in
            guard let hold = room?.hold(for: .textReading) else { return }
            let close = lifetime.withLock { lifetime -> (@Sendable () -> Void)? in
                guard let close = lifetime.closeNow, !lifetime.reading || hold == .memoryCritical else { return nil }
                lifetime.closeNow = nil
                lifetime.endSession = nil
                lifetime.released = true
                return close
            }
            guard let close else { return }
            close()
            OtosLog.thumbnails.noticeOperation("search.text", phase: "sessionReleased", fields: ["hold": hold.rawValue])
        }
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
                lifetime.closeNow = session.closeNow
                lifetime.released = false
                return .started(session)
            } catch {
                return .failed(error)
            }
        }
    }

    /// The live session ended by itself: nothing is left for `shutdown` to end.
    private func sessionGone() {
        session = nil
        lifetime.withLock { lifetime in
            lifetime.endSession = nil
            lifetime.closeNow = nil
        }
    }

    /// The room holds text reading before a reading: the live session is let go (its child
    /// exits at its input's end), and the page stops there.
    private func held(_ hold: BackgroundHold) {
        let close = lifetime.withLock { lifetime in
            defer {
                lifetime.closeNow = nil
                lifetime.endSession = nil
                lifetime.released = false
            }
            return lifetime.closeNow
        }
        if session != nil || close != nil {
            close?()
            OtosLog.thumbnails.noticeOperation("search.text", phase: "sessionReleased", fields: ["hold": hold.rawValue])
        }
        session = nil
    }

    /// Reads `page` in order. A preview that does not decode, or a recognition that fails
    /// about one picture, is no reading: it has no result, so the still stays owed and is read
    /// again after the index's backoff (ADR 0032 rule 4), and the rest of the page is read. A
    /// session that ends, or cannot start, ends the page there, and so does the reader's
    /// shutdown. A failure is never a still with no text: it stamps nothing.
    func read(_ page: [SearchTextCandidate], directory: URL?) -> SearchTextPageReading {
        // What the helper cost so far, whichever way the page ends.
        defer { session?.reportUsage() }
        guard let directory else { return .read([]) }
        var results: [SearchTextResult] = []
        for (attempted, candidate) in page.enumerated() {
            if let hold = room.hold(for: .textReading) {
                held(hold)
                return .held(before: results, attempted: attempted)
            }
            // The room's observer let the live session go while no reading ran.
            if lifetime.withLock({ lifetime in defer { lifetime.released = false }
                return lifetime.released })
            {
                session = nil
            }
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
            lifetime.withLock { $0.reading = true }
            let reading = session.read(directory.appending(path: candidate.previewPath))
            lifetime.withLock { $0.reading = false }
            switch reading {
            case let .read(reading):
                results.append(SearchTextResult(id: candidate.id, source: candidate.source, reading: reading))
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
