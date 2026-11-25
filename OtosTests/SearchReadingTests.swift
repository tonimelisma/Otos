import AppKit
import CoreGraphics
import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// A session that reads in the test's own process with the test's recognition, as Otos's
/// reading process reads with Vision's (`SearchTextReading.readPreview`).
final class RecognizingSession: SearchTextSession {
    private let recognize: (CGImage) throws -> TextReading
    /// It has no process of its own to end.
    let end: @Sendable () async -> Void = {}

    init(_ recognize: @escaping (CGImage) throws -> TextReading) {
        self.recognize = recognize
    }

    func read(_ url: URL) -> SearchTextPreviewReading {
        SearchTextReading.readPreview(at: url, recognize: recognize)
    }
}

extension SearchTextReader {
    /// A reader whose sessions read in the test's own process and find no text in any
    /// picture: an index test reads its pictures' text without starting Otos's reading process
    /// or the system's text model, whose cold load can take many minutes.
    static func readingNoText() -> SearchTextReader {
        SearchTextReader { RecognizingSession { _ in TextReading([]) } }
    }
}

/// A session whose process ends, without answering, on the pictures `exitsOn` names.
final class ExitingSession: SearchTextSession {
    private let exitsOn: Set<String>
    let end: @Sendable () async -> Void = {}

    init(exitsOn: Set<String>) {
        self.exitsOn = exitsOn
    }

    func read(_ url: URL) -> SearchTextPreviewReading {
        exitsOn.contains(url.lastPathComponent)
            ? .exited("ended while reading")
            : .read(TextReading([RecognizedTextLine(text: "OPEN", confidence: 1)]))
    }
}

/// What search reads besides the picture's embedding (ADR 0048): the text in a photo, and the
/// scene labels that gate a query naming a thing.
@Suite(.testScope)
struct SearchReadingTests {
    /// Whether `query` matches `text` as a search pass matches it (`PhotoSearchIndex`): the
    /// reading kept folded, the query's words read once.
    private static func matches(_ query: String, in text: String) -> Bool {
        SearchTextQuery(query).matches(folded: SearchTextReading.folded(text))
    }

    @Test func typedWordsMatchAtTheStartOfAWord() {
        let text = "STARBUCKS Coffee\nMenu · Café crème 4,50 €"
        #expect(Self.matches("starbucks", in: text))
        #expect(Self.matches("cafe CREME", in: text))
        #expect(Self.matches("coff", in: text))
        #expect(!Self.matches("bucks", in: text))
        #expect(!Self.matches("starbucks tea", in: text))
        #expect(!Self.matches("a", in: text))
        #expect(Self.matches("咖啡", in: "星巴克咖啡"))
    }

    @Test func aQueryNamingAThingIsGatedAndAPhraseIsNot() throws {
        let vocabulary = try SearchLabelVocabulary(bundle: Bundle(for: CatalogWindowViewModel.self))
        let tokenizer = try SearchTextTokenizer(bundle: Bundle(for: CatalogWindowViewModel.self))
        let text = try SearchTextModel(bundle: Bundle(for: CatalogWindowViewModel.self))
        #expect(vocabulary.identifiers.count > 1000)
        let cat = try vocabulary.labels(namedBy: text.embedding(of: tokenizer.tokenIDs(for: "cat")))
        #expect(cat.contains("cat"))
        let phrase = try vocabulary.labels(namedBy: text.embedding(of: tokenizer.tokenIDs(for: "child on a slide")))
        #expect(phrase.isEmpty)
    }

    @Test func theGateKeepsWhatTheClassifierSawOrWhatSigLIPIsSureOf() {
        #expect(SearchLabelGate.keeps(score: 0.10, best: 0.15, named: []) { _ in nil })
        #expect(!SearchLabelGate.keeps(score: 0.10, best: 0.15, named: ["horse"]) { ["dog": Float(0.9)][$0] })
        #expect(SearchLabelGate.keeps(score: 0.10, best: 0.15, named: ["horse"]) { ["horse": Float(0.2)][$0] })
        #expect(SearchLabelGate.keeps(score: 0.14, best: 0.15, named: ["horse"]) { _ in nil })
    }

    /// The shape of Vision's `TextRecognition.CRImageReaderError`, whose `e5rtError` case is
    /// code 1 and carries the runtime's message and its `UInt32` status, as the reader receives it.
    enum VisionTextError: Error, CustomNSError {
        case other
        case e5rtError(String, UInt32)

        static var errorDomain: String {
            "TextRecognition.CRImageReaderError"
        }

        var errorCode: Int {
            switch self {
            case .other: 0
            case .e5rtError: 1
            }
        }
    }

    /// What every reading throws once the compiled-model cache was purged under the process.
    static let readerLostError = VisionTextError.e5rtError(
        "e5rt_execution_stream_operation_create_precompiled_compute_operation_with_options call failed", 13
    )

    private static func candidates(_ count: Int, in directory: URL) throws -> [SearchTextCandidate] {
        try (0 ..< count).map { index in
            try writeGradientJPEG(to: directory.appending(path: "preview-\(index).jpg"))
            return SearchTextCandidate(
                id: MediaAssetID(
                    libraryRootPath: LibraryRootPath(rawValue: "/Library"),
                    relativePath: MediaRelativePath(rawValue: "sign-\(index).jpg")
                ),
                previewPath: "preview-\(index).jpg",
                source: "rendered"
            )
        }
    }

    /// A recognition that fails about one picture is no reading (ADR 0032 rule 4): that still
    /// has no result, so it stays owed and is read again, never stamped as holding no text, and
    /// the rest of the page is read, in the same session. A reading that finds nothing is a
    /// result with no lines.
    @Test func aFailedRecognitionIsNoReadingAndAnEmptyOneIs() async throws {
        let directory = try makeTestDirectory()
        let page = try Self.candidates(2, in: directory)
        let attempts = Mutex(0)
        let once = SearchTextReader {
            RecognizingSession { _ in
                let attempt = attempts.withLock { count in
                    count += 1
                    return count
                }
                if attempt == 1 {
                    throw VisionTextError.e5rtError("e5rt_stream_completion_handler call failed", 10)
                }
                return TextReading([])
            }
        }
        #expect(await once.read(page, directory: directory) == .read([
            SearchTextResult(id: page[1].id, source: "rendered", reading: TextReading([])),
        ]))
        #expect(await once.read([page[0]], directory: directory) == .read([
            SearchTextResult(id: page[0].id, source: "rendered", reading: TextReading([])),
        ]))
        #expect(await once.sessionsStarted == 1)
    }

    /// A failure that loses Vision's reader for the session's process ends the page where it
    /// came: the stills it did not read have no result, so they stay owed, and the next page
    /// is read by a new session.
    @Test func aSessionThatEndsEndsThePageAndANewSessionReadsTheNext() async throws {
        let directory = try makeTestDirectory()
        let page = try Self.candidates(3, in: directory)
        let attempts = Mutex(0)
        let reader = SearchTextReader {
            RecognizingSession { _ in
                let attempt = attempts.withLock { count in
                    count += 1
                    return count
                }
                if attempt == 2 {
                    throw Self.readerLostError
                }
                return TextReading([RecognizedTextLine(text: "OPEN", confidence: 1)])
            }
        }
        let open = TextReading([RecognizedTextLine(text: "OPEN", confidence: 1)])
        #expect(await reader.read(page, directory: directory) == .sessionEnded(before: [
            SearchTextResult(id: page[0].id, source: "rendered", reading: open),
        ]))
        #expect(await reader.read(Array(page.dropFirst()), directory: directory) == .read([
            SearchTextResult(id: page[1].id, source: "rendered", reading: open),
            SearchTextResult(id: page[2].id, source: "rendered", reading: open),
        ]))
        #expect(await reader.sessionsStarted == 2)
        #expect(attempts.withLock { $0 } == 4)
    }

    /// Otos's own reading process answers a preview through its pipe, answers a picture that
    /// does not decode as such, and a child that is gone ends its session. The child answers
    /// with a fixed line instead of asking Vision (`SearchTextReadingProcess.answeringArgument`):
    /// this tests the process, its protocol and its end, and the system's text model, cold,
    /// can take many minutes to load. `SearchTextLiveReadingTests` reads with Vision.
    @Test func theReadingProcessReadsAPreviewAndEndsWhenItIsGone() throws {
        let directory = try makeTestDirectory()
        let sign = directory.appending(path: "sign.jpg")
        try PhotoSearchIndexTests.writeJPEG(#require(Self.picture(saying: "OTOS SEARCH 2026")), to: sign)
        let child = try SearchTextChild(
            executable: SearchTextChild.executable(),
            arguments: [SearchTextReadingProcess.argument, SearchTextReadingProcess.answeringArgument, "OTOS SEARCH 2026"]
        )
        let signImage = try #require(Self.picture(saying: "OTOS SEARCH 2026"))
        #expect(child.read(sign) == .read(TextReading(
            width: signImage.width, height: signImage.height, lines: [RecognizedTextLine(text: "OTOS SEARCH 2026", confidence: 1)]
        )))
        #expect(child.read(directory.appending(path: "missing.jpg")) == .undecodable)

        #expect(kill(child.processIdentifier, SIGKILL) == 0)
        switch child.read(sign) {
        case .ended, .exited:
            break
        case let answer:
            Issue.record("a killed reading process still answered \(answer)")
        }
    }

    /// A child started with arguments it does not know ends at once rather than reading with
    /// a reader nobody asked for: the session ends with no reading, as a crashed child's does
    /// (`.exited` when its output closes first, `.ended` when the request finds it gone).
    @Test func aReadingProcessStartedWithUnknownArgumentsReadsNothing() throws {
        let directory = try makeTestDirectory()
        let sign = directory.appending(path: "sign.jpg")
        try PhotoSearchIndexTests.writeJPEG(#require(Self.picture(saying: "OTOS")), to: sign)
        let child = try SearchTextChild(
            executable: SearchTextChild.executable(),
            arguments: [SearchTextReadingProcess.argument, "--unknown"]
        )
        switch child.read(sign) {
        case .ended, .exited:
            break
        case let answer:
            Issue.record("a reading process with unknown arguments answered \(answer)")
        }
    }

    /// A reading process that neither answers nor exits is ended at its deadline, and the
    /// picture comes back `.exited`: owed, and paged past by the reader. `/bin/sleep` stands in
    /// for a child stuck mid-reading: its output stays open and silent.
    @Test func aReadingProcessThatNeverAnswersIsEndedAtItsDeadline() throws {
        let child = try SearchTextChild(
            executable: URL(filePath: "/bin/sleep"), arguments: ["86400"], answerDeadline: .milliseconds(100)
        )
        guard case .exited = child.read(URL(filePath: "/nonexistent.jpg")) else {
            Issue.record("a silent reading process was not ended")
            return
        }
    }

    /// A picture whose reading ends its process is paged past: the rest of the page is read by
    /// a new session, so one such picture never stops every other still from being read.
    @Test func aPictureThatEndsItsSessionIsPagedPast() async throws {
        let directory = try makeTestDirectory()
        let page = try Self.candidates(3, in: directory)
        let reader = SearchTextReader {
            ExitingSession(exitsOn: [URL(filePath: page[0].previewPath).lastPathComponent])
        }
        let open = TextReading([RecognizedTextLine(text: "OPEN", confidence: 1)])
        #expect(await reader.read(page, directory: directory) == .read([
            SearchTextResult(id: page[1].id, source: "rendered", reading: open),
            SearchTextResult(id: page[2].id, source: "rendered", reading: open),
        ]))
        #expect(await reader.sessionsStarted == 2)
    }

    /// Only the `e5rtError` case with status 13 loses the process: the same case's deadline
    /// (status 10), another case of the same domain, and an error of another domain with the
    /// same code fail one reading.
    @Test func onlyTheCompiledModelsLossLosesTheProcess() {
        #expect(SearchTextReading.losesTheProcess(Self.readerLostError))
        #expect(!SearchTextReading.losesTheProcess(VisionTextError.e5rtError("e5rt_stream_completion_handler call failed", 10)))
        #expect(!SearchTextReading.losesTheProcess(VisionTextError.other))
        #expect(!SearchTextReading.losesTheProcess(NSError(domain: "TextRecognition.CRImageReaderError", code: 1)))
        #expect(!SearchTextReading.losesTheProcess(NSError(domain: NSCocoaErrorDomain, code: 1)))
    }

    /// Search matches every kept line; the Info pane shows only the certain ones.
    @Test func searchReadsEveryLineAndTheInfoPaneTheCertainOnes() {
        let reading = TextReading([
            RecognizedTextLine(text: "BRIDGE CLOSED AHEAD", confidence: 1),
            RecognizedTextLine(text: "S6H3", confidence: 0.3),
        ])
        #expect(SearchTextReading.searchable(reading) == "BRIDGE CLOSED AHEAD\nS6H3")
        #expect(SearchTextReading.shown(reading, sceneLabels: []) == ["BRIDGE CLOSED AHEAD"])
    }

    /// What a person reads as the photo's text: a phone screenshot's status bar is not shown,
    /// nor a line twice; a cropped screenshot keeps a title at its top, and a photo keeps text
    /// at its top. Search keeps every line.
    @Test func theShownTextLeavesAPhoneScreenshotsStatusBarAndRepeats() {
        func line(_ text: String, top: Double, bottom: Double) -> RecognizedTextLine {
            RecognizedTextLine(text: text, confidence: 1, box: TextBox(left: 0.1, top: top, right: 0.9, bottom: bottom))
        }
        let lines = [
            line("23:11 1", top: 0.026, bottom: 0.044),
            line("25", top: 0.029, bottom: 0.041),
            line("Send your money", top: 0.083, bottom: 0.102),
            line("dreamforce", top: 0.3, bottom: 0.32),
            line("Dreamforce", top: 0.5, bottom: 0.52),
        ]
        let phone = TextReading(width: 1179, height: 2556, lines: lines)
        #expect(SearchTextReading.shown(phone, sceneLabels: ["document", "screenshot"]) == ["Send your money", "dreamforce"])
        #expect(SearchTextReading.shown(phone, sceneLabels: ["people"]) == ["23:11 1", "25", "Send your money", "dreamforce"])
        let cropped = TextReading(width: 753, height: 1032, lines: lines)
        #expect(SearchTextReading.shown(cropped, sceneLabels: ["screenshot"]).first == "23:11 1")
        #expect(SearchTextReading.searchable(phone).hasPrefix("23:11 1\n25\n"))
    }

    /// Vision's classification keeps the gate's loose labels and the confident ones apart:
    /// every confident label is one the gate holds, most confident first.
    @Test func sceneLabelsHoldTheConfidentOnesMostConfidentFirst() async throws {
        let image = try #require(Self.picture(saying: "INVOICE 2026"))
        // Off the pool, as `SearchImageEmbedder`'s queue runs it (`offThePool`).
        let reading = try await offThePool { try SearchSceneLabels.classify(image) }
        for label in reading.confident {
            #expect(reading.labels[label] != nil)
        }
        let confidences = reading.confident.compactMap { reading.labels[$0] }
        #expect(confidences == confidences.sorted(by: >))
    }

    /// A text reading is written only for the preview it was read from, and is current after.
    @Test func aTextReadingIsWrittenOnlyForThePreviewItWasReadFrom() async throws {
        let temp = try makeTestDirectory()
        let library = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try writeCatalogStoreFile(library.appending(path: "sign.jpg"), contents: "jpeg sign")
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: library)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        let asset = try #require(scanned.testAssets.first)
        _ = await store.applyEnrichmentBatch([EnrichmentResult(
            id: asset.id, metadata: AssetMetadata(), enrichedKind: .image, thumbnailPath: "sign-thumb.jpg",
            sourceSize: asset.byteSize ?? 0, sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt), contentHash: nil,
            previewPath: "sign-preview.heic"
        )])
        let candidate = try #require(try await store.backgroundReads.searchTextCandidates(limit: 10).candidates.first)
        #expect(candidate.previewPath == "sign-preview.heic")
        let open = TextReading([RecognizedTextLine(text: "OPEN", confidence: 1), RecognizedTextLine(text: "0p3n", confidence: 0.3)])
        #expect(try await store.applySearchTexts([SearchTextResult(id: asset.id, source: "stale", reading: open)]).isEmpty)
        #expect(try await store.applySearchTexts([SearchTextResult(id: asset.id, source: candidate.source, reading: open)]).count == 1)
        #expect(try await store.backgroundReads.searchTextCandidates(limit: 10).candidates.isEmpty)
        #expect(try await store.windowReads.searchTextMatches([SearchTextQuery("open")]).ids == [asset.id])
        #expect(try await store.windowReads.searchTextMatches([SearchTextQuery("0p3n")]).ids == [asset.id], "every kept line is matched")
        #expect(try await store.windowReads.photoInfoOverlay(for: asset.id)?.textLines == ["OPEN"])
        await store.shutdown()
    }

    /// The Info pane reads a still's confident scene labels from its current embedding row
    /// only: none before it is read, the confident ones after, none again once its thumbnail
    /// changes.
    @Test func theInfoPaneReadsConfidentLabelsFromTheCurrentEmbedding() async throws {
        let temp = try makeTestDirectory()
        let library = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try writeCatalogStoreFile(library.appending(path: "pool.jpg"), contents: "jpeg pool")
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: library)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        let asset = try #require(scanned.testAssets.first)
        func enrich(thumbnail: String) async {
            _ = await store.applyEnrichmentBatch([EnrichmentResult(
                id: asset.id, metadata: AssetMetadata(), enrichedKind: .image, thumbnailPath: thumbnail,
                sourceSize: asset.byteSize ?? 0, sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt), contentHash: nil
            )])
        }
        await enrich(thumbnail: "pool-thumb.jpg")
        #expect(try await store.windowReads.photoInfoOverlay(for: asset.id)?.sceneLabels == nil)
        let candidate = try #require(try await store.backgroundReads.searchEmbeddingCandidates(limit: 10).candidates.first)
        _ = try await store.applySearchEmbeddings([SearchEmbeddingResult(
            id: asset.id, source: candidate.source, embedding: [Float](repeating: 1, count: SearchEmbedding.dimensions),
            labels: ["water": 0.88, "pool": 0.88, "horse": 0.07], confidentLabels: ["pool", "water"]
        )])
        #expect(try await store.windowReads.photoInfoOverlay(for: asset.id)?.sceneLabels == [
            SceneLabel(identifier: "pool", confidence: 0.88), SceneLabel(identifier: "water", confidence: 0.88),
        ])
        let stored = try await store.backgroundReads.currentSearchEmbeddings(for: [asset.id]).first
        #expect(SearchEmbeddingStorage.labels(from: stored?.labels)["horse"] == 0.07)
        await enrich(thumbnail: "pool-thumb-2.jpg")
        #expect(try await store.windowReads.photoInfoOverlay(for: asset.id)?.sceneLabels == nil)
        await store.shutdown()
    }

    /// Reads `image` in this process, reading again after a failure, as the index reads an owed
    /// still again (ADR 0048). Under a loaded machine Vision's runtime can give up on a cold
    /// reading on its own: it cancels an operation that overran its internal deadline (`e5rt`
    /// "has timed out", error 10) while it compiles the text models, which takes minutes under
    /// parallel checks. The attempts are counted, not timed, and a reading that fails every
    /// attempt throws the last error, so a Vision that cannot read still fails. An error that
    /// loses the reader for the process (`SearchTextReading.losesTheProcess`) is thrown at
    /// once: no later attempt in this process can read, and only a new process would.
    static func readRetryingFailures(_ image: CGImage) throws -> TextReading {
        let attempts = 3
        for attempt in 1 ... attempts {
            do {
                return try SearchTextReading.read(image)
            } catch where attempt < attempts && !SearchTextReading.losesTheProcess(error) {
                print("op=test.searchReading phase=retry attempt=\(attempt) error=\(error)")
            }
        }
        preconditionFailure("the last attempt returns or throws")
    }

    static func picture(saying text: String) -> CGImage? {
        let width = 1200, height = 800
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 90), .foregroundColor: NSColor.black]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: 80, y: 360)
        CTLineDraw(line, context)
        return context.makeImage()
    }
}

/// Readings by the system's own text model, in this process and in Otos's reading process.
/// They run only when asked (`OTOS_TEXT_READING_LIVE=1 script/check.sh --only
/// SearchTextLiveReadingTests`): the model's first load in a process is cold, 0.2 s with its
/// compiled files cached and up to 649 s measured with them purged under a loaded machine
/// (`docs/research/2026-11-14-vision-text-reading-breaks-for-its-process.md`), and a default
/// check never waits on it. Each first reading's wait is in the unified log (`op=search.text
/// phase=firstReading waitMs=` from the reading process's session, `op=test.live
/// phase=firstReading waitMs=` from this process), so a slow run reads as a cold load, not a
/// hang.
@Suite(.testScope, .enabled(if: ProcessInfo.processInfo.environment["OTOS_TEXT_READING_LIVE"] == "1"))
struct SearchTextLiveReadingTests {
    /// Text drawn into a picture is read back, certain enough for the Info pane to show it.
    ///
    /// When macOS purges Vision's compiled model under disk pressure while this process holds
    /// it, no reading in the process can succeed again
    /// (`docs/research/2026-11-15-text-reading-lost-to-a-cache-purge.md`). This test reads in
    /// its own process, so it then has nothing to read, and records that one error as a known
    /// issue: the product reads in a child process and starts a new one then
    /// (`theReadingProcessReadsWithTheSystemsTextModel`). Any other failure fails the test.
    @Test func textInAPictureIsRead() throws {
        try withKnownIssue("Vision's text reader was lost for this process to a cache purge", isIntermittent: true) {
            let image = try #require(SearchReadingTests.picture(saying: "OTOS SEARCH 2026"))
            let asked = ContinuousClock.now
            let read = try SearchReadingTests.readRetryingFailures(image)
            OtosLog.thumbnails.noticeOperation("test.live", phase: "firstReading", fields: [
                "where": "testProcess", "waitMs": "\(DiagnosticsTiming.milliseconds(since: asked))",
            ])
            let searchable = SearchTextReading.folded(SearchTextReading.searchable(read))
            #expect(SearchTextQuery("otos search").matches(folded: searchable))
            #expect(SearchTextReading.shown(read, sceneLabels: []) == ["OTOS SEARCH 2026"])
            let blank = SearchModelTests.solid(red: 0.4, green: 0.5, blue: 0.6, width: 1200, height: 800)
            #expect(try SearchReadingTests.readRetryingFailures(blank).lines.isEmpty)
        } matching: { issue in
            issue.error.map(SearchTextReading.losesTheProcess) ?? false
        }
    }

    /// Otos's own reading process reads a preview's text with Vision as the app reads it. A
    /// fresh child's first reading is a cold one, which a loaded machine can make Vision give
    /// up on, and a child whose reader a cache purge lost is the case a new child exists for,
    /// so the reading is asked again, of a new child then; the attempts are counted, not timed.
    @Test func theReadingProcessReadsWithTheSystemsTextModel() throws {
        let directory = try makeTestDirectory()
        let sign = directory.appending(path: "sign.jpg")
        try PhotoSearchIndexTests.writeJPEG(#require(SearchReadingTests.picture(saying: "OTOS SEARCH 2026")), to: sign)
        let executable = try SearchTextChild.executable()
        var child = try SearchTextChild(executable: executable)
        // Its wait is logged by the session (`op=search.text phase=firstReading waitMs=`).
        var reading = child.read(sign)
        for _ in 1 ..< 3 {
            switch reading {
            case .read, .undecodable:
                break
            case .failed:
                reading = child.read(sign)
                continue
            case .ended, .exited:
                child = try SearchTextChild(executable: executable)
                reading = child.read(sign)
                continue
            }
            break
        }
        guard case let .read(read) = reading else {
            Issue.record("the reading process answered \(reading)")
            return
        }
        #expect(SearchTextReading.shown(read, sceneLabels: []) == ["OTOS SEARCH 2026"])
    }
}
