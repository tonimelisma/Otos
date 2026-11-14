import AppKit
import CoreGraphics
import Foundation
@testable import OtosKit
import Testing

/// What search reads besides the picture's embedding (ADR 0048): the text in a photo, and the
/// scene labels that gate a query naming a thing.
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
    @Test func textInAPictureIsRead() throws {
        let image = try #require(Self.picture(saying: "OTOS SEARCH 2026"))
        let read = try Self.readAsTheIndexDoes(image)
        #expect(Self.matches("otos search", in: SearchTextReading.searchable(read)))
        #expect(SearchTextReading.certain(read) == ["OTOS SEARCH 2026"])
        let blank = SearchModelTests.solid(red: 0.4, green: 0.5, blue: 0.6, width: 1200, height: 800)
        #expect(try Self.readAsTheIndexDoes(blank).isEmpty)
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
    /// fails every attempt throws the last error, so a Vision that cannot read still fails.
    static func readAsTheIndexDoes(_ image: CGImage) throws -> [RecognizedTextLine] {
        let attempts = 3
        for attempt in 1 ... attempts {
            do {
                return try SearchTextReading.read(image)
            } catch where attempt < attempts {
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
