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
    }

    let text: String
    /// The recognised language's identifier, nil when none was recognised.
    let language: String?
    let reading: Reading
    /// The English the model read; the typed text when `reading` is `.asTyped`.
    let modelText: String
    let embedding: [Float]
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
/// 3. **Embedding:** `SearchTextTokenizer` and `SearchTextModel`. A language Translation does
///    not offer (Estonian in the test) is read as typed by the model's multilingual tower.
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

    func encode(_ text: String) async throws -> SearchQueryEncoding {
        if let known = recent[text] {
            return known
        }
        let start = ContinuousClock.now
        if supported == nil {
            supported = await Self.supportedLanguages()
        }
        let candidates = supported ?? [:]
        let language = Self.recognize(text, among: candidates)
        let reading: SearchQueryEncoding.Reading
        let modelText: String
        if language == .english {
            reading = .english
            modelText = text
        } else if let language, let source = candidates[language], await isInstalled(language, source) {
            modelText = try await Self.translate(text, from: source)
            reading = .translated
        } else {
            reading = .asTyped
            modelText = text
        }
        let embedding = try embed(modelText)
        let encoding = SearchQueryEncoding(
            text: text, language: language?.rawValue, reading: reading, modelText: modelText, embedding: embedding
        )
        remember(encoding)
        OtosLog.catalog.noticeOperation("search.encode", phase: "done", fields: [
            "language": language?.rawValue ?? "none",
            "reading": reading.rawValue,
            "ms": "\(DiagnosticsTiming.milliseconds(since: start))",
        ])
        return encoding
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

    private func remember(_ encoding: SearchQueryEncoding) {
        recent[encoding.text] = encoding
        recentOrder.append(encoding.text)
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

    static func recognize(_ text: String, among candidates: [NLLanguage: Locale.Language]) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english] + Array(candidates.keys)
        recognizer.processString(text)
        return recognizer.dominantLanguage
    }
}
