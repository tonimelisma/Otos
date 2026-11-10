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
    /// `pictureText`'s embedding; nil when the query is only facts ("in September").
    let embedding: [Float]?
}

/// The facts a query names (ADR 0048): when, where, and who.
nonisolated struct SearchFacts: Hashable, Sendable {
    var date: SearchDateSpan?
    var place: SearchPlace?
    var people: [PersonID] = []

    var isEmpty: Bool {
        date == nil && place == nil && people.isEmpty
    }
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
///    (`TranslationSession(installedSource:target:)`, no network, no UI). SigLIP 2 reads
///    English best: translated queries scored 77 across 16 languages, the same queries as
///    typed 65.
/// 3. **Glossary:** a query not translated, from a user with a language Translation does not
///    offer (Estonian), has its picture words read through Otos's glossary of that language
///    (`SearchGlossary`): recall@10 77 instead of 49 as typed. Facts are read first, from what
///    was typed, so a place's name is never read as a word ("Kassel" is not a cat).
/// 4. **Embedding:** `SearchTextTokenizer` and `SearchTextModel`. A word no glossary holds is
///    read as typed by the model's multilingual tower.
///
/// A failed translation is an error, not a fallback: the query is not answered with a
/// reading the user did not get. The tokenizer, the model (87 MB, memory-mapped token table)
/// load on first use and stay on this actor's serial queue,
/// because every step blocks (ADR 0032 rule 6). Recent encodings are kept, so a projection
/// pass that asks again for the same text costs a lookup.
actor SearchQueryEncoder {
    private let queue = DispatchSerialQueue(label: "net.melisma.Otos.search.query", qos: .userInitiated)
    private let bundle: Bundle
    private var tokenizer: SearchTextTokenizer?
    private var model: SearchTextModel?
    private var supported: [NLLanguage: Locale.Language]?
    private var places: [String: SearchPlace?] = [:]
    private var glossaries: [String: SearchGlossary?] = [:]
    private var installed: Set<NLLanguage> = []
    private var recent: [String: SearchQueryEncoding] = [:]
    private var recentOrder: [String] = []
    private static let recentLimit = 32

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    init(bundle: Bundle) {
        self.bundle = bundle
    }

    /// `preferred`: the languages the user searches in (`NLLanguage` raw values), which
    /// recognition favours. `people`: the people the user has named, matched in the typed
    /// text before anything translates it, because translation mangles names.
    func encode(
        _ text: String,
        preferring preferred: [String] = [],
        people: [SearchPerson] = []
    ) async throws -> SearchQueryEncoding {
        let key = ([text] + preferred + people.map { "\($0.id.rawValue)=\($0.name)" }).joined(separator: "\u{0}")
        if let known = recent[key] {
            return known
        }
        let start = ContinuousClock.now
        let (named, typedRest) = Self.takePeople(people, from: text)
        var rest = typedRest
        if supported == nil {
            supported = await Self.supportedLanguages()
        }
        let candidates = supported ?? [:]
        var language: NLLanguage?
        var reading = SearchQueryEncoding.Reading.english
        var modelText = ""
        // A language the user searches in that Translation cannot read (Estonian) is not even
        // recognised: the recogniser takes it for a neighbour and translation garbles it. Its
        // month names, from Foundation, say the query is in it; the rest is then read as typed.
        var untranslatable: [String] = []
        for code in preferred where code != NLLanguage.english.rawValue {
            let language = NLLanguage(rawValue: code)
            if let source = candidates[language], await isInstalled(language, source) {
                continue
            }
            untranslatable.append(code)
        }
        var nativeMonth: SearchDateSpan?
        if let native = SearchQueryParser.takeNativeMonth(rest, languages: untranslatable) {
            nativeMonth = native.span
            rest = native.rest
            reading = .asTyped
            modelText = rest
        } else if !rest.isEmpty {
            language = Self.trusted(
                Self.recognize(rest, among: candidates, preferring: preferred.map(NLLanguage.init(rawValue:))),
                preferring: preferred, untranslatable: untranslatable
            )
            if language == .english, try await mayBeGlossed(rest, in: untranslatable) {
                // The recogniser chooses only among languages Translation offers, so a word
                // nothing recognises ("lennuk", airplane) is often called English.
                language = nil
                reading = .asTyped
                modelText = rest
            } else if language == .english {
                modelText = rest
            } else if let language, let source = candidates[language], await isInstalled(language, source) {
                modelText = try await Self.translate(rest, from: source)
                reading = .translated
            } else {
                reading = .asTyped
                modelText = rest
            }
        }
        // A query not translated, from a user with a language nothing recognises, may be in
        // that language, where the English tagger finds no whole name.
        let mayBeUnrecognised = reading != .translated && !untranslatable.isEmpty
        var parse = SearchQueryParser.parse(modelText, places: mayBeUnrecognised ? .capitalised : .tagged)
        var place: SearchPlace?
        if let name = parse.placeName {
            place = await locate(name)
            if place == nil {
                parse = SearchQueryParser.parse(modelText, places: .notRead)
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
        let embedding = pictureText.isEmpty ? nil : try embed(pictureText)
        let encoding = SearchQueryEncoding(
            text: text, language: language?.rawValue, reading: reading, modelText: modelText,
            facts: facts, pictureText: pictureText, embedding: embedding
        )
        remember(encoding, as: key)
        OtosLog.catalog.noticeOperation("search.encode", phase: "done", fields: [
            "language": language?.rawValue ?? "none",
            "reading": reading.rawValue,
            "date": "\(facts.date != nil)",
            "place": "\(facts.place != nil)",
            "people": "\(facts.people.count)",
            "picture": "\(embedding != nil)",
            "ms": "\(DiagnosticsTiming.milliseconds(since: start))",
        ])
        return encoding
    }

    /// A place is asked of Maps once per name; a name that is nowhere is remembered too.
    /// The recognised language, unless it is outside the user's languages while one of theirs
    /// cannot be translated: nothing recognises that one, so the query is most likely in it
    /// ("jäätis", Estonian ice cream, recognised as Finnish and translated "I froze"). Nil
    /// reads the query as typed.
    static func trusted(_ recognised: NLLanguage?, preferring preferred: [String], untranslatable: [String]) -> NLLanguage? {
        guard let recognised, untranslatable.isEmpty || preferred.contains(recognised.rawValue) else { return nil }
        return recognised
    }

    private func locate(_ name: String) async -> SearchPlace? {
        if let known = places[name] {
            return known
        }
        let found = await SearchPlaces.locate(name)
        places[name] = .some(found)
        return found
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

    private func embed(_ text: String) throws -> [Float] {
        if tokenizer == nil {
            tokenizer = try SearchTextTokenizer(bundle: bundle)
        }
        if model == nil {
            model = try SearchTextModel(bundle: bundle)
        }
        return try model!.embedding(of: tokenizer!.tokenIDs(for: text))
    }

    /// A session per query: `TranslationSession` is not `Sendable`, so it is made, used and
    /// released off this actor.
    @concurrent
    private static func translate(_ text: String, from source: Locale.Language) async throws -> String {
        try await TranslationSession(installedSource: source, target: english).translate(text).targetText
    }

    private func remember(_ encoding: SearchQueryEncoding, as key: String) {
        recent[key] = encoding
        recentOrder.append(key)
        if recentOrder.count > Self.recentLimit {
            recent.removeValue(forKey: recentOrder.removeFirst())
        }
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
