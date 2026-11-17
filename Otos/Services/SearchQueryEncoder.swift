import AppKit
import Foundation
import NaturalLanguage
import OSLog
import Translation

/// What a typed query became before it was compared with the photos.
nonisolated struct SearchQueryEncoding: Sendable, Equatable {
    enum Reading: String, Sendable {
        /// Read as English.
        case english
        /// Translated to English on the device from the language it was recognised as.
        case translated
        /// Recognised as a language with no installed translation, or not recognised: read
        /// by the model's own multilingual text tower as typed.
        case asTyped
        /// Not translated, from a user whose language Translation does not offer and Otos has a
        /// glossary for (`SearchGlossary`): the picture's words the glossary holds are read in
        /// English, the rest as typed. `language` is the glossary's.
        case glossed
    }

    let text: String
    /// The recognised language's identifier, nil when none was recognised.
    let language: String?
    let reading: Reading
    /// The English reading of the query, without the people it named; the typed text when
    /// `reading` is `.asTyped` or `.glossed`, whose facts are read from what was typed.
    let modelText: String
    /// What the query asks for besides the picture.
    let facts: SearchFacts
    /// What the picture is searched for: the reading without its facts, through the glossary
    /// when `reading` is `.glossed`.
    let pictureText: String
    /// `pictureText` as the photos are compared with it.
    let picture: SearchQueryPicture

    /// `pictureText`'s embedding, once made.
    var embedding: [Float]? {
        if case let .embedded(embedding) = picture {
            return embedding
        }
        return nil
    }
}

/// What a query's picture words are compared with the photos as (ADR 0048).
nonisolated enum SearchQueryPicture: Sendable, Equatable {
    /// The query names no picture ("in September"): the picture does not narrow it.
    case none
    /// The words reading (`SearchQueryEncoder.wordsReading`): the picture words are not
    /// embedded yet, so only the photos showing them as words match them.
    case unread
    /// `pictureText`'s embedding.
    case embedded([Float])
}

/// What a query asks to be read (ADR 0048): the text, the user's search languages, the people
/// they have named, and, for a search a scene-label chip started, the label it searches for.
nonisolated struct SearchQueryRequest: Hashable, Sendable {
    let text: String
    let languages: [String]
    let people: [SearchPerson]
    /// The Vision identifier a chip searches for (`baseball_hat`): read as its English name, with
    /// no language to recognise and no facts, so a chip always finds its own label.
    let label: String?

    init(text: String, languages: [String] = [], people: [SearchPerson] = [], label: String? = nil) {
        self.text = text
        self.languages = languages
        self.people = people
        self.label = label
    }
}

/// The facts a query names (ADR 0048): when, where, and who.
nonisolated struct SearchFacts: Hashable, Sendable {
    var date: SearchDate?
    var place: SearchPlace?
    var people: [PersonID] = []

    var isEmpty: Bool {
        date == nil && place == nil && people.isEmpty
    }

    /// What the Store is asked when the query is answered: the date as a span of `now`'s
    /// calendar. Nil when the query names no fact, so nothing narrows it.
    func filter(at now: Date, in calendar: Calendar) -> SearchFactFilter? {
        isEmpty ? nil : SearchFactFilter(dateSpan: date?.span(at: now, in: calendar), place: place, people: people)
    }
}

/// The facts as the Store answers them (`searchFactMatches`).
nonisolated struct SearchFactFilter: Hashable, Sendable {
    var dateSpan: SearchDateSpan?
    var place: SearchPlace?
    var people: [PersonID] = []
}

/// A person the user named, as search matches them in a query.
nonisolated struct SearchPerson: Hashable, Sendable {
    let id: PersonID
    let name: String
}

/// Search query encoder guide (ADR 0048)
///
/// Turns what the user typed into a text embedding, in the order the owner's library proved
/// best (`docs/research/2026-11-09-keyword-search.md`):
///
/// 1. **Language:** `NLLanguageRecognizer`, constrained to English and the languages Apple
///    Translation offers. The query never says its language; constrained recognition
///    measured within about two points of being told it (research §8).
/// 2. **English:** a recognised non-English language whose pack is installed is translated on the device
///    (`TranslationSession(installedSource:target:)`, no network, no UI), as a photo's caption
///    so a lone word has context (`photoWords`). SigLIP 2 reads
///    English best: translated queries scored 77 across 16 languages, the same queries as
///    typed 65.
/// 3. **Glossary:** a query not translated, from a user with a language Translation does not
///    offer (Estonian), has its picture words read through Otos's glossary of that language
///    (`SearchGlossary`): recall@10 80 instead of 49 as typed. Facts are read first, from what
///    was typed, so a place's name is never read as a word ("Kassel" is not a cat).
/// 4. **Embedding:** `SearchTextTokenizer` and `SearchTextModel`. A word no glossary holds is
///    read as typed by the model's multilingual tower.
///
/// A failed translation is an error, not a fallback: the query is not answered with a
/// reading the user did not get. The embedding is made by `SearchTextTower`, which owns the
/// tokenizer and the model on its own serial queue, because its load and its predictions block
/// (ADR 0032 rule 6) and a load can take seconds (Core ML compiling the model afresh after an
/// install, `docs/research/2026-11-16-first-search-while-the-encoder-loads.md`): this actor
/// only awaits it, so a words reading runs while the tower loads. Only what does not change
/// with time or with the Mac is kept between calls: a text's translation from a language, a
/// text's embedding, and Maps' answer for a name (found, or no place; a failed lookup is not
/// kept). Recognition, which packs are installed, the facts and the glossary are read on each
/// call, and a date is kept as the rule the query names (`SearchDate`), so a pack the user
/// installs counts on the next reading and "today" is the day the query is answered.
/// `SearchQueryReader` calls it, one query at a time.
///
/// **Load and release.** Nothing loads before the window's first grid. Then, as the last
/// background load, or at once when the user's intent to search or a query asks first
/// (`SearchQueryReader`, `LoadWaiter.user`), `prepare` loads the list of Translation's
/// languages and readies the tower (tokenizer, model, one prediction), so the first picture
/// reading pays none of it. Under memory pressure an idle tower lets the tokenizer and the
/// model go (`releaseIfIdle`); the next reading loads them again.
actor SearchQueryEncoder {
    private let queue = DispatchSerialQueue(label: "net.melisma.Otos.search.query", qos: .userInitiated)
    private let bundle: Bundle
    /// The text tower: tokenizer and model, on their own queue.
    private let tower: SearchTextTower
    private var supported: [NLLanguage: Locale.Language]?
    private var places: [String: SearchPlace?] = [:]
    private var glossaries: [String: SearchGlossary?] = [:]
    private var installed: Set<NLLanguage> = []
    private var translations = RecentValues<TranslationKey, String>(limit: 64)
    private var embeddings = RecentValues<String, [Float]>(limit: 64)

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    init(bundle: Bundle) {
        self.bundle = bundle
        tower = SearchTextTower(bundle: bundle)
    }

    /// How far a reading goes.
    private enum Depth {
        /// Neither the tower, nor Translation, nor a place Maps has not answered before: the
        /// picture words stay unread (`SearchQueryPicture.unread`).
        case words
        /// The tower, but neither Translation nor a new place.
        case asTyped
        case full

        var embeds: Bool {
            self != .words
        }
    }

    /// `request.languages`: the languages the user searches in (`NLLanguage` raw values), which
    /// recognition favours. `request.people`: the people the user has named, matched in the
    /// typed text before anything translates it, because translation mangles names.
    func encode(_ request: SearchQueryRequest) async throws -> SearchQueryEncoding {
        try await read(request, depth: .full).encoding
    }

    /// The query read as typed with no embedding made: its facts (dates, the people it names,
    /// a place Maps has answered before) and its picture words, which only the words read in
    /// photos match until a reading that embeds them replaces it. It never waits on the tower,
    /// Translation or a new Maps lookup, so it is what the window shows first while the tower
    /// loads (`SearchQueryReader`). Nil for a scene-label chip, whose label is a picture word
    /// only the tower reads.
    func wordsReading(_ request: SearchQueryRequest) async throws -> SearchQueryEncoding? {
        guard request.label == nil else { return nil }
        return try await read(request, depth: .words).encoding
    }

    /// The query read as typed, with neither Translation nor Maps asked: what the window shows
    /// while the full reading (`encode`) waits on them. Nil when the full reading asks neither,
    /// so it is as quick and there is nothing to show first. Measured on the judged queries in
    /// 17 languages (`docs/research/2026-11-16-search-vector-file.md`): as typed, recall@10 85
    /// in English and 65.4 in the other languages, against 85 and 74.9 for the full reading, and
    /// the two share 39% of their top 10 for a translated query.
    func firstReading(_ request: SearchQueryRequest) async throws -> SearchQueryEncoding? {
        guard request.label == nil else { return nil }
        let first = try await read(request, depth: .asTyped)
        return first.skipped ? first.encoding : nil
    }

    /// One reading of `request` to `depth`; `skipped` says whether a step the full reading
    /// takes (Translation, a new place) was skipped. A reading that embeds holds the tower for
    /// as long as it runs, so memory pressure does not take the model from a reading suspended
    /// on Translation or Maps; a words reading never asks the tower anything.
    private func read(_ request: SearchQueryRequest, depth: Depth) async throws -> (encoding: SearchQueryEncoding, skipped: Bool) {
        guard depth.embeds else {
            return try await unheldRead(request, depth: depth)
        }
        await tower.hold()
        do {
            let read = try await unheldRead(request, depth: depth)
            await tower.letGo()
            return read
        } catch {
            await tower.letGo()
            throw error
        }
    }

    private func unheldRead(_ request: SearchQueryRequest, depth: Depth) async throws -> (encoding: SearchQueryEncoding, skipped: Bool) {
        let asTyped = depth != .full
        if let label = request.label {
            return try await (englishEncoding(of: SceneLabelNames.englishName(label), shown: request.text), false)
        }
        var skipped = false
        let text = request.text, preferred = request.languages
        let start = ContinuousClock.now
        let (named, typedRest) = Self.takePeople(request.people, from: text)
        var rest = typedRest
        if supported == nil {
            supported = await Self.supportedLanguages()
        }
        let candidates = supported ?? [:]
        var language: NLLanguage?
        var reading = SearchQueryEncoding.Reading.english
        var modelText = ""
        var writer = SearchQueryParser.Writer.user
        // A language the user searches in that Translation cannot read (Estonian) is not even
        // recognised: the recogniser takes it for a neighbour and translation garbles it. Its
        // month names, from Foundation, say the query is in it; the rest is then read as typed.
        var untranslatable: [String] = []
        // The two steps of a reading that wait on other owners or load a model on first use:
        // English spelling, on the main actor, and the tagger that finds a place's name.
        var spellMs = 0
        for code in preferred where code != NLLanguage.english.rawValue {
            let language = NLLanguage(rawValue: code)
            if let source = candidates[language], await isInstalled(language, source) {
                continue
            }
            untranslatable.append(code)
        }
        var nativeMonth: SearchDate?
        if let native = SearchQueryParser.takeNativeMonth(rest, languages: untranslatable) {
            nativeMonth = native.month
            rest = native.rest
            reading = .asTyped
            modelText = rest
        } else if !rest.isEmpty {
            language = Self.trusted(
                Self.recognize(rest, among: candidates, preferring: preferred.map(NLLanguage.init(rawValue:))),
                preferring: preferred, untranslatable: untranslatable
            )
            // A word or two is weak evidence of a language ("sky" was recognised as Italian):
            // Latin-script text English spelling accepts is read as English, not translated.
            // On the judged queries English rose from 83 to 85 and the other languages moved
            // from 75.0 to 74.9.
            let spelling = ContinuousClock.now
            if let recognised = language, recognised != .english, candidates[recognised] != nil,
               await Self.readsAsEnglish(rest)
            {
                language = .english
            }
            spellMs = DiagnosticsTiming.milliseconds(since: spelling)
            if language == .english, try await mayBeGlossed(rest, in: untranslatable) {
                // The recogniser chooses only among languages Translation offers, so a word
                // nothing recognises ("lennuk", airplane) is often called English.
                language = nil
                reading = .asTyped
                modelText = rest
            } else if language == .english {
                modelText = rest
            } else if let language, let source = candidates[language], await isInstalled(language, source) {
                if asTyped {
                    skipped = true
                    reading = .asTyped
                    modelText = rest
                } else {
                    modelText = try await translation(of: rest, from: source)
                    reading = .translated
                    writer = .translation(source: rest, language: source.minimalIdentifier)
                }
            } else {
                reading = .asTyped
                modelText = rest
            }
        }
        // A query not translated, from a user with a language nothing recognises, may be in
        // that language, where the English tagger finds no whole name.
        let mayBeUnrecognised = reading != .translated && !untranslatable.isEmpty
        let parsing = ContinuousClock.now
        var parse = SearchQueryParser.parse(modelText, places: mayBeUnrecognised ? .capitalised : .tagged, writtenBy: writer)
        let parseMs = DiagnosticsTiming.milliseconds(since: parsing)
        var place: SearchPlace?
        if let name = parse.placeName, asTyped, places[name] == nil {
            skipped = true
            parse = SearchQueryParser.parse(modelText, places: .notRead, writtenBy: writer)
        } else if let name = parse.placeName {
            place = await locate(name)
            if place == nil {
                parse = SearchQueryParser.parse(modelText, places: .notRead, writtenBy: writer)
            }
        }
        if let native = nativeMonth {
            parse.date = native
        }
        let facts = SearchFacts(date: parse.date, place: place, people: named)
        var pictureText = parse.pictureText
        if reading == .asTyped {
            for code in untranslatable {
                guard let glossary = try glossary(code), let read = glossary.reading(of: pictureText) else { continue }
                pictureText = read
                reading = .glossed
                language = NLLanguage(rawValue: code)
                break
            }
        }
        let picture: SearchQueryPicture = if pictureText.isEmpty {
            .none
        } else if depth.embeds {
            try await .embedded(embed(pictureText))
        } else {
            .unread
        }
        let encoding = SearchQueryEncoding(
            text: text, language: language?.rawValue, reading: reading, modelText: modelText,
            facts: facts, pictureText: pictureText, picture: picture
        )
        OtosLog.catalog.noticeOperation("search.encode", phase: "done", fields: [
            "language": language?.rawValue ?? "none",
            "reading": reading.rawValue,
            "date": "\(facts.date != nil)",
            "place": "\(facts.place != nil)",
            "people": "\(facts.people.count)",
            "picture": "\(picture.diagnosticName)",
            "depth": "\(depth)",
            "first": "\(asTyped)",
            "spellMs": "\(spellMs)",
            "parseMs": "\(parseMs)",
            "ms": "\(DiagnosticsTiming.milliseconds(since: start))",
        ])
        return (encoding, skipped)
    }

    /// `english` read as English, with no facts: what a scene-label chip searches for (its
    /// label's English name), and what a test of the index compares. `shown` is the text the
    /// search field holds.
    func englishEncoding(of english: String, shown: String? = nil) async throws -> SearchQueryEncoding {
        try await SearchQueryEncoding(
            text: shown ?? english, language: NLLanguage.english.rawValue, reading: .english, modelText: english,
            facts: SearchFacts(), pictureText: english, picture: .embedded(embed(english))
        )
    }

    /// The recognised language, unless it is outside the user's languages while one of theirs
    /// cannot be translated: nothing recognises that one, so the query is most likely in it
    /// ("jäätis", Estonian ice cream, recognised as Finnish and translated "I froze"). Nil
    /// reads the query as typed.
    static func trusted(_ recognised: NLLanguage?, preferring preferred: [String], untranslatable: [String]) -> NLLanguage? {
        guard let recognised, untranslatable.isEmpty || preferred.contains(recognised.rawValue) else { return nil }
        return recognised
    }

    /// A place is asked of Maps once per name; Maps' answer that a name is nowhere is
    /// remembered too. A lookup that failed is not: the name searches the picture this time and
    /// is asked again the next time it is read.
    private func locate(_ name: String) async -> SearchPlace? {
        if let known = places[name] {
            return known
        }
        do {
            let found = try await SearchPlaces.locate(name)
            places[name] = .some(found)
            return found
        } catch {
            OtosLog.catalog.errorOperation("search.place", phase: "lookupFailed", fields: [
                "error": String(describing: error),
            ])
            return nil
        }
    }

    /// The people whose names `text` holds as whole words, ignoring case and diacritics, and
    /// the text without them. Longer names first, so "Abby Rose" is not read as "Abby".
    static func takePeople(_ people: [SearchPerson], from text: String) -> (people: [PersonID], rest: String) {
        var rest = text
        var found: [PersonID] = []
        for person in people.sorted(by: { $0.name.count > $1.name.count }) where !person.name.isEmpty {
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            var searchRange = rest.startIndex ..< rest.endIndex
            while let range = rest.range(of: person.name, options: options, range: searchRange) {
                let startsWord = range.lowerBound == rest.startIndex || !rest[rest.index(before: range.lowerBound)].isLetter
                let endsWord = range.upperBound == rest.endIndex || !rest[range.upperBound].isLetter
                if startsWord, endsWord {
                    rest.removeSubrange(range)
                    if !found.contains(person.id) {
                        found.append(person.id)
                    }
                    searchRange = rest.startIndex ..< rest.endIndex
                } else {
                    searchRange = range.upperBound ..< rest.endIndex
                }
            }
        }
        let words = rest.split(whereSeparator: \.isWhitespace).map(String.init)
        return (found, words.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)))
    }

    /// Whether a query recognised as English is in one of the user's untranslatable languages
    /// instead: a glossary of one reads a word of it, and English spelling rejects a word of
    /// it. Of the 52 test queries in English the glossary reads none; spelling keeps an
    /// English word the glossary also holds ("tool", Estonian chair; "seas") English.
    private func mayBeGlossed(_ text: String, in languages: [String]) async throws -> Bool {
        for code in languages {
            if try glossary(code)?.reading(of: text) != nil {
                return await Self.misspellsEnglish(text)
            }
        }
        return false
    }

    /// Whether `text` is in the Latin script and English spelling accepts every word of it.
    static func readsAsEnglish(_ text: String) async -> Bool {
        let letters = text.unicodeScalars.filter(\.properties.isAlphabetic)
        guard !letters.isEmpty, letters.allSatisfy({ $0.value < 0x250 }) else { return false }
        return await !misspellsEnglish(text)
    }

    /// English spelling alone: unified checking (`requestCheckingOfString`) identifies the
    /// language itself and, on a Mac with several spelling languages, passed "koer" and
    /// "bassein". AppKit's spell checker is asked on the main actor, a few words, well under
    /// a millisecond.
    @MainActor
    private static func misspellsEnglish(_ text: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(
            of: text, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
        ).location != NSNotFound
    }

    /// Otos's glossary of `language`, read from the bundle once; nil when there is none.
    private func glossary(_ language: String) throws -> SearchGlossary? {
        if let known = glossaries[language] {
            return known
        }
        let glossary = try SearchGlossary(language: language, bundle: bundle)
        glossaries[language] = .some(glossary)
        return glossary
    }

    /// `text`'s embedding: the one kept, or the tower's.
    private func embed(_ text: String) async throws -> [Float] {
        if let known = embeddings[text] {
            return known
        }
        let embedding = try await tower.embedding(of: text)
        embeddings[text] = embedding
        return embedding
    }

    /// Loads what every reading needs — Translation's languages, then the tower's tokenizer and
    /// model and one prediction, which Core ML makes slower the first time: what the user's
    /// intent to search asks for (`SearchQueryReader.prepare`), so the first picture reading
    /// pays none of it. Does nothing for what is ready.
    func prepare() async throws {
        if supported == nil {
            supported = await Self.supportedLanguages()
        }
        try await tower.prepare()
    }

    /// The tower's predictions so far, its warm-up included: what a test counts.
    var towerPredictions: Int {
        get async {
            await tower.predictions
        }
    }

    /// Whether the tower's tokenizer and model are loaded: what a test asks.
    var isLoaded: Bool {
        get async {
            await tower.isLoaded
        }
    }

    /// Whether a reading would wait on nothing `prepare` does: Translation's languages are
    /// known and the tower is prepared. Asked of the tower, so it waits for a load in flight.
    var isPrepared: Bool {
        get async {
            guard supported != nil else { return false }
            return await tower.isPrepared
        }
    }

    /// Memory pressure's answer, asked directly: what a test does.
    func releaseIfIdle() async {
        await tower.releaseIfIdle()
    }

    /// `text` in English, translated from `source` once and kept; a failed translation keeps
    /// nothing.
    private func translation(of text: String, from source: Locale.Language) async throws -> String {
        let key = TranslationKey(source: source.minimalIdentifier, text: text)
        if let known = translations[key] {
            return known
        }
        let english = try await Self.translate(text, from: source)
        translations[key] = english
        return english
    }

    private struct TranslationKey: Hashable {
        let source: String
        let text: String
    }

    /// A session per query: `TranslationSession` is not `Sendable`, so it is made, used and
    /// released off this actor. The query is translated as a photo's caption ("사진: 호수"),
    /// and the caption's word is taken off the English.
    @concurrent
    private static func translate(_ text: String, from source: Locale.Language) async throws -> String {
        let session = TranslationSession(installedSource: source, target: english)
        guard let caption = caption(text, in: source) else {
            return try await session.translate(text).targetText
        }
        return try await uncaptioned(session.translate(caption).targetText)
    }

    /// The word for a photo in each language Translation offers. A query is a word or two, and
    /// Translation reads a lone word without context, often wrongly: Korean "호수" (lake) → "the
    /// number of houses", Swedish "tåg" (train) → "march", Finnish "kurpitsat" (pumpkins) →
    /// "zucchini". As a caption it reads them right ("사진: 호수" → "Photo: Lake"). Over 15
    /// languages, recall@10 rose from 78.3 to 80.5 (Korean 72 → 78, Finnish 74 → 81, Swedish 75
    /// → 82), facts from 0.847 to 0.855 (research §9).
    static let photoWords: [String: String] = [
        "ar": "صورة", "da": "foto", "de": "Foto", "es": "foto", "fi": "kuva", "fr": "photo", "he": "תמונה",
        "hi": "फ़ोटो", "id": "foto", "it": "foto", "ja": "写真", "ko": "사진", "ms": "foto", "nb": "foto",
        "nl": "foto", "pl": "zdjęcie", "pt": "foto", "ru": "фото", "sv": "foto", "th": "รูปภาพ", "tr": "fotoğraf",
        "uk": "фото", "vi": "ảnh", "zh": "照片",
    ]

    /// `text` as a photo's caption in `language`; nil for a language with no word for a photo here.
    static func caption(_ text: String, in language: Locale.Language) -> String? {
        guard let code = language.languageCode?.identifier, let photo = photoWords[code] else { return nil }
        return photo + (["ja", "zh"].contains(code) ? "：" : ": ") + text
    }

    /// The English caption without its photo word: "Photo: Lake", "Image: dog", "picture:
    /// pumpkins". A translation that dropped the word is kept whole.
    static func uncaptioned(_ english: String) -> String {
        guard let range = english.range(
            of: #"^\s*(a\s+)?(photo|picture|image|photograph|pic|snapshot)s?\s*[:：]\s*"#,
            options: [.regularExpression, .caseInsensitive]
        ) else { return english }
        return String(english[range.upperBound...])
    }

    private static let english = Locale.Language(identifier: "en")

    /// Whether `language` can be translated to English now. An installed pack is remembered:
    /// asking for every language on every query cost 0.67 s, one language 16 ms. One not yet
    /// installed is asked again each time it is recognised, so a pack the user installs
    /// counts at once.
    private func isInstalled(_ language: NLLanguage, _ source: Locale.Language) async -> Bool {
        if installed.contains(language) {
            return true
        }
        guard await Self.status(of: source) == .installed else {
            return false
        }
        installed.insert(language)
        return true
    }

    /// Every language Translation offers to English, keyed by the recogniser's name for it:
    /// what a query's language is recognised among. Read once; the list is the system's.
    /// `@concurrent`: `LanguageAvailability` is not `Sendable`, so it lives and is asked
    /// entirely off this actor.
    @concurrent
    private static func supportedLanguages() async -> [NLLanguage: Locale.Language] {
        var languages: [NLLanguage: Locale.Language] = [:]
        for language in await LanguageAvailability().supportedLanguages {
            guard let recognised = recognizerLanguage(language), recognised != .english else { continue }
            languages[recognised] = language
        }
        return languages
    }

    @concurrent
    private static func status(of source: Locale.Language) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: source, to: english)
    }

    /// The recogniser names Chinese by script (`zh-Hans`, `zh-Hant`) and every other
    /// language by its code.
    static func recognizerLanguage(_ language: Locale.Language) -> NLLanguage? {
        guard let code = language.languageCode?.identifier else { return nil }
        if code == "zh" {
            return language.script?.identifier == "Hant" ? .traditionalChinese : .simplifiedChinese
        }
        return NLLanguage(rawValue: code)
    }

    /// The prior a preferred language gets against every other candidate: ten to one.
    /// Measured over 17 languages (research §9): a user's own languages were recognised
    /// 95% of the time instead of 80%, and a third language 83% instead of 85%.
    static let preferredPrior = 0.2
    static let otherPrior = 0.02

    static func recognize(
        _ text: String,
        among candidates: [NLLanguage: Locale.Language],
        preferring preferred: [NLLanguage] = []
    ) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        let constraints = [NLLanguage.english] + Array(candidates.keys)
        recognizer.languageConstraints = constraints
        if !preferred.isEmpty {
            var hints = Dictionary(uniqueKeysWithValues: constraints.map { ($0, otherPrior) })
            for language in preferred where hints[language] != nil {
                hints[language] = preferredPrior
            }
            recognizer.languageHints = hints
        }
        recognizer.processString(text)
        return recognizer.dominantLanguage
    }
}

/// The most recent `limit` values by key: a cache of what does not change, bounded so a long
/// session's queries do not accumulate.
nonisolated struct RecentValues<Key: Hashable, Value> {
    private var values: [Key: Value] = [:]
    private var order: [Key] = []
    let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    subscript(key: Key) -> Value? {
        get { values[key] }
        set {
            guard let newValue else {
                values.removeValue(forKey: key)
                order.removeAll { $0 == key }
                return
            }
            if values.updateValue(newValue, forKey: key) == nil {
                order.append(key)
                if order.count > limit {
                    values.removeValue(forKey: order.removeFirst())
                }
            }
        }
    }
}

nonisolated extension SearchQueryPicture {
    /// The case's name, for a log line.
    var diagnosticName: String {
        switch self {
        case .none: "none"
        case .unread: "unread"
        case .embedded: "embedded"
        }
    }
}

/// Search text tower guide (ADR 0048)
///
/// The one owner of the query side of SigLIP 2: the tokenizer (a mapped file) and the text
/// model (CPU only, `SearchEmbedding.load`), loaded on first use and kept on this actor's own
/// serial queue, because the load and every prediction block (ADR 0032 rule 6). It is apart
/// from `SearchQueryEncoder` so that a load, which Core ML can stretch to seconds when it
/// compiles the model afresh, holds only the readings that need an embedding: the encoder's
/// words reading never asks this actor anything.
///
/// - **Prepared** is loaded and predicted once, the first prediction being the slow one.
/// - **Holds.** A reading that will embed holds the tower while it runs (`hold`, `letGo`), so
///   memory pressure does not take the model from a reading suspended on Translation or Maps.
/// - **Release.** Under memory pressure an unheld tower lets the tokenizer and the model go
///   (`releaseIfIdle`); the handler runs on this queue between jobs, so it never interrupts a
///   prediction. The next reading or preparation loads them again.
actor SearchTextTower {
    private let queue = DispatchSerialQueue(label: "net.melisma.Otos.search.textTower", qos: .userInitiated)
    private let bundle: Bundle
    private var tokenizer: SearchTextTokenizer?
    private var model: SearchTextModel?
    /// Whether the loaded model has made its first prediction, which Core ML makes slower.
    private var warmed = false
    private var holds = 0
    private var pressure: DispatchSourceMemoryPressure?

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    init(bundle: Bundle) {
        self.bundle = bundle
    }

    /// `text`'s embedding, loading the tokenizer and the model first when they are not loaded.
    func embedding(of text: String) throws -> [Float] {
        let (tokenizer, model) = try loaded()
        let embedding = try predict(text, tokenizer: tokenizer, model: model)
        warmed = true
        return embedding
    }

    /// Predictions made since the tower was made, the warm-up included: what a test counts.
    private(set) var predictions = 0

    /// Loads the tokenizer and the model and runs one warm-up prediction, the slow first one,
    /// so the first query pays neither; nothing when prepared. `op=search.encoder
    /// phase=prepared` reports the load and the warm-up apart (`loadMs`, `warmUpMs`).
    func prepare() throws {
        guard !isPrepared else { return }
        let start = ContinuousClock.now
        let before = ProcessResourceSample.current().footprintBytes
        let (tokenizer, model) = try loaded()
        let warmUpStart = ContinuousClock.now
        _ = try predict("a photo", tokenizer: tokenizer, model: model)
        warmed = true
        OtosLog.catalog.noticeOperation("search.encoder", phase: "prepared", fields: [
            "footprintDeltaMB": "\((Int64(ProcessResourceSample.current().footprintBytes) - Int64(before)) / 1_048_576)",
            "loadMs": "\(DiagnosticsTiming.milliseconds(start.duration(to: warmUpStart)))",
            "warmUpMs": "\(DiagnosticsTiming.milliseconds(since: warmUpStart))",
            "ms": "\(DiagnosticsTiming.milliseconds(since: start))",
        ])
    }

    private func predict(_ text: String, tokenizer: SearchTextTokenizer, model: SearchTextModel) throws -> [Float] {
        predictions += 1
        return try model.embedding(of: tokenizer.tokenIDs(for: text))
    }

    var isLoaded: Bool {
        tokenizer != nil && model != nil
    }

    var isPrepared: Bool {
        isLoaded && warmed
    }

    func hold() {
        holds += 1
    }

    func letGo() {
        holds -= 1
    }

    /// Lets the tokenizer and the model go when no reading holds them: memory pressure's
    /// answer.
    func releaseIfIdle() {
        guard holds == 0, tokenizer != nil || model != nil else { return }
        tokenizer = nil
        model = nil
        warmed = false
        OtosLog.catalog.noticeOperation("search.encoder", phase: "released", fields: [:])
        ResourceCheckpoint.record("searchEncoderReleased")
    }

    /// The tokenizer and the model, loaded on first use.
    private func loaded() throws -> (SearchTextTokenizer, SearchTextModel) {
        if let tokenizer, let model {
            return (tokenizer, model)
        }
        let start = ContinuousClock.now
        let before = ProcessResourceSample.current().footprintBytes
        let tokenizer = try tokenizer ?? SearchTextTokenizer(bundle: bundle)
        let model = try model ?? SearchTextModel(bundle: bundle)
        self.tokenizer = tokenizer
        self.model = model
        watchMemoryPressure()
        OtosLog.catalog.noticeOperation("search.encoder", phase: "loaded", fields: [
            "footprintDeltaMB": "\((Int64(ProcessResourceSample.current().footprintBytes) - Int64(before)) / 1_048_576)",
            "ms": "\(DiagnosticsTiming.milliseconds(since: start))",
        ])
        return (tokenizer, model)
    }

    /// The system's memory-pressure warnings, heard on this actor's own queue.
    private func watchMemoryPressure() {
        guard pressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        source.setEventHandler { [weak self] in
            self?.assumeIsolated { $0.releaseIfIdle() }
        }
        source.activate()
        pressure = source
    }
}
