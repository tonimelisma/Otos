import AppKit
import CoreGraphics
import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// What search reads besides the picture's embedding (ADR 0048): the text in a photo, and the
/// scene labels that gate a query naming a thing.
/// A session that reads in the test's own process with the test's recognition, as Otos's
/// reading process reads with Vision's (`SearchTextReading.readPreview`).
final class RecognizingSession: SearchTextSession {
    private let recognize: (CGImage) throws -> [RecognizedTextLine]

    init(_ recognize: @escaping (CGImage) throws -> [RecognizedTextLine]) {
        self.recognize = recognize
    }

    func read(_ url: URL) -> SearchTextPreviewReading {
        SearchTextReading.readPreview(at: url, recognize: recognize)
    }
}

@Suite(.testDirectory)
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
        #expect(SearchLabelGate.keeps(score: 0.10, best: 0.15, labels: [:], named: []))
        #expect(!SearchLabelGate.keeps(score: 0.10, best: 0.15, labels: ["dog": 0.9], named: ["horse"]))
        #expect(SearchLabelGate.keeps(score: 0.10, best: 0.15, labels: ["horse": 0.2], named: ["horse"]))
        #expect(SearchLabelGate.keeps(score: 0.14, best: 0.15, labels: [:], named: ["horse"]))
    }

    /// Text drawn into a picture is read back, certain enough for the Info pane to show it.
    ///
    /// When macOS purges Vision's compiled model under disk pressure while this process holds
    /// it, no reading in the process can succeed again
    /// (`docs/research/2026-11-15-text-reading-lost-to-a-cache-purge.md`). This test then has
    /// nothing to read, and records that one error as a known issue: the product's handling of
    /// it is `aReaderLostForTheProcessAttemptsNothingMore`. Any other failure fails the test.
    @Test func textInAPictureIsRead() throws {
        try withKnownIssue("Vision's text reader was lost for this process to a cache purge", isIntermittent: true) {
            let image = try #require(Self.picture(saying: "OTOS SEARCH 2026"))
            let read = try Self.readAsTheIndexDoes(image)
            #expect(Self.matches("otos search", in: SearchTextReading.searchable(read)))
            #expect(SearchTextReading.certain(read) == ["OTOS SEARCH 2026"])
            let blank = SearchModelTests.solid(red: 0.4, green: 0.5, blue: 0.6, width: 1200, height: 800)
            #expect(try Self.readAsTheIndexDoes(blank).isEmpty)
        } matching: { issue in
            issue.error.map(SearchTextReading.losesTheProcess) ?? false
        }
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
                return []
            }
        }
        #expect(await once.read(page, directory: directory) == .read([
            SearchTextResult(id: page[1].id, source: "rendered", lines: []),
        ]))
        #expect(await once.read([page[0]], directory: directory) == .read([
            SearchTextResult(id: page[0].id, source: "rendered", lines: []),
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
                return [RecognizedTextLine(text: "OPEN", confidence: 1)]
            }
        }
        let open = [RecognizedTextLine(text: "OPEN", confidence: 1)]
        #expect(await reader.read(page, directory: directory) == .sessionEnded(before: [
            SearchTextResult(id: page[0].id, source: "rendered", lines: open),
        ]))
        #expect(await reader.read(Array(page.dropFirst()), directory: directory) == .read([
            SearchTextResult(id: page[1].id, source: "rendered", lines: open),
            SearchTextResult(id: page[2].id, source: "rendered", lines: open),
        ]))
        #expect(await reader.sessionsStarted == 2)
        #expect(attempts.withLock { $0 } == 4)
    }

    /// Otos's own reading process reads a preview's text as the app read it in its own
    /// process, and a child that is gone ends its session. A child whose reader a cache purge
    /// lost is the case a new child exists for, so the reading is asked of a second one then.
    @Test func theReadingProcessReadsAPreviewAndEndsWhenItIsGone() throws {
        let directory = try makeTestDirectory()
        let sign = directory.appending(path: "sign.jpg")
        try PhotoSearchIndexTests.writeJPEG(#require(Self.picture(saying: "OTOS SEARCH 2026")), to: sign)
        let executable = try SearchTextChild.executable()
        var child = try SearchTextChild(executable: executable)
        var reading = child.read(sign)
        if case .ended = reading {
            child = try SearchTextChild(executable: executable)
            reading = child.read(sign)
        }
        guard case let .lines(lines) = reading else {
            Issue.record("the reading process answered \(reading)")
            return
        }
        #expect(SearchTextReading.certain(lines) == ["OTOS SEARCH 2026"])
        #expect(child.read(directory.appending(path: "missing.jpg")) == .undecodable)

        #expect(kill(child.processIdentifier, SIGKILL) == 0)
        guard case .ended = child.read(sign) else {
            Issue.record("a killed reading process still answered")
            return
        }
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
        let lines = [
            RecognizedTextLine(text: "BRIDGE CLOSED AHEAD", confidence: 1),
            RecognizedTextLine(text: "S6H3", confidence: 0.3),
        ]
        #expect(SearchTextReading.searchable(lines) == "BRIDGE CLOSED AHEAD\nS6H3")
        #expect(SearchTextReading.certain(lines) == ["BRIDGE CLOSED AHEAD"])
    }

    /// Vision's classification keeps the gate's loose labels and the confident ones apart:
    /// every confident label is one the gate holds, most confident first.
    @Test func sceneLabelsHoldTheConfidentOnesMostConfidentFirst() throws {
        let image = try #require(Self.picture(saying: "INVOICE 2026"))
        let reading = try SearchSceneLabels.classify(image)
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
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: library)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        let asset = try #require(scanned.testAssets.first)
        _ = await store.applyEnrichmentBatch([EnrichmentResult(
            id: asset.id, metadata: AssetMetadata(), enrichedKind: .image, thumbnailPath: "sign-thumb.jpg",
            sourceSize: asset.byteSize ?? 0, sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt), contentHash: nil,
            previewPath: "sign-preview.heic"
        )])
        let candidate = try #require(try await store.searchTextCandidates(limit: 10).first)
        #expect(candidate.previewPath == "sign-preview.heic")
        let open = [RecognizedTextLine(text: "OPEN", confidence: 1), RecognizedTextLine(text: "0p3n", confidence: 0.3)]
        #expect(try await store.applySearchTexts([SearchTextResult(id: asset.id, source: "stale", lines: open)]).isEmpty)
        #expect(try await store.applySearchTexts([SearchTextResult(id: asset.id, source: candidate.source, lines: open)]).count == 1)
        #expect(try await store.searchTextCandidates(limit: 10).isEmpty)
        #expect(try await store.currentSearchTextIDs() == [asset.id])
        #expect(try await store.currentSearchTexts(for: [asset.id]) == [asset.id: "OPEN\n0p3n"])
        #expect(try await store.photoInfoOverlay(for: asset.id)?.textLines == ["OPEN"])
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
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
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
        #expect(try await store.photoInfoOverlay(for: asset.id)?.sceneLabels == nil)
        let candidate = try #require(try await store.searchEmbeddingCandidates(limit: 10).first)
        _ = try await store.applySearchEmbeddings([SearchEmbeddingResult(
            id: asset.id, source: candidate.source, embedding: [Float](repeating: 1, count: SearchEmbedding.dimensions),
            labels: ["water": 0.88, "pool": 0.88, "horse": 0.07], confidentLabels: ["pool", "water"]
        )])
        #expect(try await store.photoInfoOverlay(for: asset.id)?.sceneLabels == ["pool", "water"])
        #expect(try await store.currentSearchEmbeddings().first?.labels["horse"] == 0.07)
        await enrich(thumbnail: "pool-thumb-2.jpg")
        #expect(try await store.photoInfoOverlay(for: asset.id)?.sceneLabels == nil)
        await store.shutdown()
    }

    /// Reads `image` as the product does: a reading that fails is read again (ADR 0048, the
    /// index retries an owed still). Under a loaded machine Vision's runtime can give up on a
    /// cold reading on its own: it cancels an operation that overran its internal deadline
    /// (`e5rt` "has timed out", error 10) while it compiles the text models, which takes
    /// minutes under parallel checks. The attempts are counted, not timed, and a reading that
    /// fails every attempt throws the last error, so a Vision that cannot read still fails. An
    /// error that loses the reader for the process is thrown at once, as the product stops at
    /// it (`SearchTextReading.losesTheProcess`): no later attempt in the process can read.
    static func readAsTheIndexDoes(_ image: CGImage) throws -> [RecognizedTextLine] {
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
