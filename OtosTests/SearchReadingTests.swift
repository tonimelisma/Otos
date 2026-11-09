import AppKit
import CoreGraphics
import Foundation
@testable import OtosKit
import Testing

/// What search reads besides the picture's embedding (ADR 0048): the text in a photo, and the
/// scene labels that gate a query naming a thing.
@Suite(.testDirectory)
struct SearchReadingTests {
    @Test func typedWordsMatchAtTheStartOfAWord() {
        let text = "STARBUCKS Coffee\nMenu · Café crème 4,50 €"
        #expect(SearchTextReading.matches(query: "starbucks", in: text))
        #expect(SearchTextReading.matches(query: "cafe CREME", in: text))
        #expect(SearchTextReading.matches(query: "coff", in: text))
        #expect(!SearchTextReading.matches(query: "bucks", in: text))
        #expect(!SearchTextReading.matches(query: "starbucks tea", in: text))
        #expect(!SearchTextReading.matches(query: "a", in: text))
        #expect(SearchTextReading.matches(query: "咖啡", in: "星巴克咖啡"))
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

    /// Text drawn into a picture is read back.
    @Test func textInAPictureIsRead() throws {
        let image = try #require(Self.picture(saying: "OTOS SEARCH 2026"))
        let read = try SearchTextReading.read(image)
        #expect(SearchTextReading.matches(query: "otos search", in: read))
        let blank = SearchModelTests.solid(red: 0.4, green: 0.5, blue: 0.6, width: 1200, height: 800)
        #expect(try SearchTextReading.read(blank).isEmpty)
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
        #expect(try await store.applySearchTexts([SearchTextResult(id: asset.id, source: "stale", text: "x")]).isEmpty)
        #expect(try await store.applySearchTexts([SearchTextResult(id: asset.id, source: candidate.source, text: "OPEN")]).count == 1)
        #expect(try await store.searchTextCandidates(limit: 10).isEmpty)
        #expect(try await store.currentSearchTexts() == [asset.id: "OPEN"])
        await store.shutdown()
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
