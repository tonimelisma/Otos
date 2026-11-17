import Foundation
import GRDB
@testable import OtosKit
import Testing

/// The catalog's text index (ADR 0048, "Text in the photo"; v74): a query's words are matched
/// by one keyed read of an FTS5 table, and the answer is exactly what matching every current
/// reading in memory gave (`SearchTextQuery.matches(folded:)`).
@Suite(.testScope)
struct SearchTextIndexTests {
    /// Readings in the scripts and shapes the owner's photos hold and the ways matching treats
    /// them: case and diacritics, `ß`, full-width forms, decomposed accents, numbers beside
    /// letters, apostrophes and hyphens, scripts written without spaces (Chinese, Japanese) and
    /// with (Korean, Cyrillic, Greek, Arabic, Hebrew, Devanagari, Thai), emoji, long words.
    static let corpus: [String] = [
        "OPEN 24 HOURS\nNo Parking",
        "Straße der Pariser Kommune\nAusfahrt freihalten",
        "Café de Flore — L'École des Beaux-Arts",
        "Niño, Peña y Muñoz\nAÑO 2024",
        "İstanbul Havalimanı\nÇıkış",
        "ＯＰＥＮ ２４ｈ　ＣＡＦＥ",
        "Cafe\u{0301} au lait",
        "abc123def 1abc 2024年11月16日",
        "東京タワー 営業時間 9時から",
        "北京大学 图书馆 开放时间",
        "ひらがなとカタカナ ラーメン",
        "서울 지하철 2호선 강남역",
        "Москва Красная площадь\nВыход",
        "Αθήνα Ακρόπολη\nΕΙΣΟΔΟΣ",
        "القاهرة محطة\nمخرج",
        "תל אביב יציאה",
        "नमस्ते दिल्ली मेट्रो",
        "กรุงเทพมหานคร สถานี",
        "Proof of Insurance\nPolicy #A-77812",
        "Donaudampfschifffahrtsgesellschaftskapitän",
        "e-mail: hello@example.org\nwww.example.org/path",
        "Pizza 🍕 & Beer 🍺 — 12,50 €",
        "ÉCOLE PRIMAIRE\nRue de la Gare",
        "x2 x-ray 3D 4K HDR10+",
        "Hôtel Ritz\nRéception 24/7",
        "Københavns Lufthavn\nÅbningstider",
        "Ørsted Øl Ål",
        "ﬁnance oﬃce",
        "Ⅻ ½ ²³",
        "a b c d e",
    ]

    @Test func sqliteHasFTS5() throws {
        let options = try DatabaseQueue().read { db in try String.fetchAll(db, sql: "PRAGMA compile_options") }
        #expect(options.contains("ENABLE_FTS5"))
    }

    /// The differential: every query cut from the corpus — each run of 2, 3, 5 and 9 characters
    /// at every position, as folded and as written, each word alone and with a word of another
    /// reading — is answered by the index exactly as matching every reading answers it.
    @Test func theIndexMatchesExactlyWhatEveryReadingMatches() async throws {
        let fixture = try await Fixture.make(Self.corpus)
        let store = fixture.store, ids = fixture.ids
        let folded = Dictionary(uniqueKeysWithValues: zip(ids, Self.corpus.map(SearchTextReading.folded)))
        var queries: Set<String> = []
        for text in Self.corpus {
            for written in [text, SearchTextReading.folded(text)] {
                let characters = Array(written)
                for length in [2, 3, 5, 9] {
                    for start in characters.indices where start + length <= characters.count {
                        queries.insert(String(characters[start ..< start + length]))
                    }
                }
            }
        }
        let words = Self.corpus.flatMap { $0.split(whereSeparator: { !SearchTextWords.isWordCharacter($0) }).map(String.init) }
        for (first, second) in zip(words, words.dropFirst(7) + words.prefix(7)) {
            queries.insert("\(first) \(second)")
            queries.insert("\(first) \(first.prefix(2))")
        }
        var matched = 0
        var mismatches: [String] = []
        for query in queries.sorted() {
            let text = SearchTextQuery(query)
            let expected = Set(folded.filter { text.matches(folded: $0.value) }.keys)
            let found = try await store.windowReads.searchTextMatches([text]).ids
            if found != expected {
                mismatches.append("\(query.debugDescription): expected \(expected.count) found \(found.count)")
            }
            matched += expected.isEmpty ? 0 : 1
        }
        #expect(queries.count > 2500)
        #expect(matched > 1000, "the corpus's queries mostly match something")
        #expect(mismatches.isEmpty, "\(mismatches.count) of \(queries.count): \(mismatches.prefix(20).joined(separator: "; "))")

        // Two readings of one query (as typed, and its English) match what either matches.
        let both = try await store.windowReads.searchTextMatches([SearchTextQuery("insurance"), SearchTextQuery("東京")]).ids
        #expect(both.count == 2)
        await store.shutdown()
    }

    /// A match reads the text index first, then each row it returns by key: its folded row by
    /// its integer key, its reading's source and its asset by theirs. No table is scanned.
    @Test func aMatchReadsTheIndexFirstAndEachRowByItsKey() throws {
        let queue = try DatabaseQueue()
        try CatalogStore.migrator.migrate(queue)
        let plan = try queue.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + SearchTextStorage.matchSQL, arguments: ["\"open\"*"])
                .map { ($0["detail"] as String).trimmingCharacters(in: .whitespaces) }
        }
        #expect(plan.count == 4, "\(plan)")
        #expect(plan.first?.hasPrefix("SCAN search_text_word VIRTUAL TABLE INDEX") == true, "\(plan)")
        #expect(plan.dropFirst().first?.hasPrefix("SEARCH f USING INTEGER PRIMARY KEY (rowid=?)") == true, "\(plan)")
        #expect(plan.contains { $0.hasPrefix("SEARCH t USING COVERING INDEX \(SearchTextStorage.sourceIndexName) (library_root_id=? AND relative_path=?") }, "\(plan)")
        #expect(plan.contains { $0.hasPrefix("SEARCH a USING") && $0.hasSuffix("(library_root_id=? AND relative_path=?)") }, "\(plan)")
        #expect(plan.dropFirst().allSatisfy { !$0.hasPrefix("SCAN") }, "\(plan)")
    }

    /// The index follows its readings: written with a reading, replaced when it is read again,
    /// emptied by a reading with no text, matching nothing once its preview changes, and gone
    /// with its asset when the asset is proven deleted (by cascade, through its trigger).
    @Test func theIndexFollowsItsReadings() async throws {
        var fixture = try await Fixture.make(["Proof of Insurance", "Menu"], onDisk: true)
        let ids = fixture.ids
        func found(_ word: String) async throws -> Set<MediaAssetID> {
            try await fixture.store.windowReads.searchTextMatches([SearchTextQuery(word)]).ids
        }
        #expect(try await found("insurance") == [ids[0]])

        try await fixture.read(ids[0], text: "Boarding pass")
        #expect(try await found("insurance").isEmpty)
        #expect(try await found("boarding") == [ids[0]])
        try await fixture.read(ids[0], text: "")
        #expect(try await found("boarding").isEmpty)
        #expect(try fixture.indexedRows() == 1)

        // A new preview leaves the reading stale: it matches nothing until it is read again.
        try await fixture.read(ids[1], text: "Menu du jour")
        try await fixture.givePreview(ids[1], "menu-preview-2.heic")
        #expect(try await found("menu").isEmpty)

        // The asset is proven deleted at the next launch's scan: its reading, its folded row and
        // its words go.
        await fixture.store.shutdown()
        try FileManager.default.removeItem(at: fixture.library.appending(path: ids[1].relativePath.rawValue))
        let store = makeTestStore(location: .databaseFile(fixture.databaseURL), scanCadence: .milliseconds(10))
        try await store.start()
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        #expect(try fixture.indexedRows() == 0)
        await store.shutdown()
    }

    /// A search the projection holds is asked again when a kind of fact its text match reads
    /// moved (`CatalogChangedFacts.searchTextInputs`): every kind a write to what the match's
    /// statement reads names is among them.
    @Test func aHeldSearchIsAskedAgainWhenWhatItsWordsReadMoves() async throws {
        let fixture = try await Fixture.make(["Menu"])
        let read = try await fixture.store.backgroundReads.factsRead(by: [SearchTextStorage.matchSQL])
        #expect(read.contains(.searchContent))
        #expect(read.isSubset(of: CatalogChangedFacts.searchTextInputs), "\(read.diagnosticDescription)")
        await fixture.store.shutdown()
    }

    // MARK: Fixtures

    /// One still per text, each with a current reading of it.
    struct Fixture {
        let store: CatalogStore
        let ids: [MediaAssetID]
        let library: URL
        let databaseURL: URL
        private var assets: [MediaAssetID: MediaAsset]
        private var sources: [MediaAssetID: String] = [:]

        static func make(_ texts: [String], onDisk: Bool = false) async throws -> Fixture {
            let temp = try makeTestDirectory()
            let library = temp.appending(path: "Pictures", directoryHint: .isDirectory)
            let databaseURL = temp.appending(path: "db/catalog.sqlite")
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            for index in texts.indices {
                try writeCatalogStoreFile(library.appending(path: "still-\(index).jpg"), contents: "jpeg \(index)")
            }
            let store = makeTestStore(location: onDisk ? .databaseFile(databaseURL) : .inMemory, scanCadence: .milliseconds(10))
            try await store.start(scansSavedLibraries: false)
            try await store.addLibrary(url: library)
            let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == texts.count }
            let byName = Dictionary(uniqueKeysWithValues: scanned.testAssets.map { ($0.id.relativePath.rawValue, $0) })
            let assets = try texts.indices.map { try #require(byName["still-\($0).jpg"]) }
            var fixture = Fixture(
                store: store, ids: assets.map(\.id), library: library, databaseURL: databaseURL,
                assets: Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
            )
            for (id, text) in zip(fixture.ids, texts) {
                try await fixture.givePreview(id, "\(id.relativePath.rawValue)-preview.heic")
                try await fixture.read(id, text: text)
            }
            return fixture
        }

        private init(store: CatalogStore, ids: [MediaAssetID], library: URL, databaseURL: URL, assets: [MediaAssetID: MediaAsset]) {
            self.store = store
            self.ids = ids
            self.library = library
            self.databaseURL = databaseURL
            self.assets = assets
        }

        /// Gives `id` a stored preview named `preview`, which it is then owed a reading of.
        mutating func givePreview(_ id: MediaAssetID, _ preview: String) async throws {
            let asset = try #require(assets[id])
            _ = await store.applyEnrichmentBatch([EnrichmentResult(
                id: id, metadata: AssetMetadata(), enrichedKind: .image, thumbnailPath: "\(id.relativePath.rawValue)-thumb.jpg",
                sourceSize: asset.byteSize ?? 0, sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt), contentHash: nil,
                previewPath: preview
            )])
            let owed = try await store.backgroundReads.searchTextCandidates(for: [id])
            sources[id] = try #require(owed.first).source
        }

        /// Writes a reading of `text` from its current preview, a line each, as the index writes
        /// what Vision read.
        func read(_ id: MediaAssetID, text: String) async throws {
            let source = try #require(sources[id])
            let lines = text.isEmpty ? [] : text.split(separator: "\n").map { RecognizedTextLine(text: String($0), confidence: 1) }
            #expect(try await store.applySearchTexts([SearchTextResult(id: id, source: source, lines: lines)]).count == 1)
        }

        /// The folded readings the index holds, read from the file.
        func indexedRows() throws -> Int {
            try makeTestDatabaseQueue(path: databaseURL.path(percentEncoded: false)).read { db in
                let folded = try Int.fetchOne(db, sql: "SELECT count(*) FROM search_text_folded") ?? -1
                let words = try Int.fetchOne(db, sql: "SELECT count(*) FROM search_text_word") ?? -1
                #expect(words == folded, "every folded row has its words, and no words outlive theirs")
                return folded
            }
        }
    }
}
