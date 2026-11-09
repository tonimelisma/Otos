import Foundation
import NaturalLanguage
import Translation

/// One language Settings offers for search: its recogniser name (`NLLanguage` raw value) and
/// its name in the user's language.
nonisolated struct SearchLanguageChoice: Hashable, Sendable, Identifiable {
    let code: String
    let name: String
    var id: String {
        code
    }
}

/// Search languages guide (ADR 0048)
///
/// The languages the user searches in. Recognising a typed query's language favours them
/// ten to one (`SearchQueryEncoder.preferredPrior`): over 17 languages, a user's own were
/// recognised 95% of the time instead of 80%, at a cost of 2 points on languages they did not
/// list (`docs/research/2026-11-09-keyword-search.md` §9). A Mac often lists one system
/// language although its owner searches in two, so it is a setting; until it is set, the
/// system's preferred languages stand in. Values are recogniser names: `fi`, `en`,
/// `zh-Hans`.
nonisolated enum SearchLanguages {
    /// The recogniser's name for a system language identifier (`en-US` → `en`,
    /// `zh-Hant-TW` → `zh-Hant`).
    static func recognizerCode(_ identifier: String) -> String? {
        let language = Locale.Language(identifier: identifier)
        guard let code = language.languageCode?.identifier else { return nil }
        if code == "zh" {
            return language.script?.identifier == "Hant" ? NLLanguage.traditionalChinese.rawValue : NLLanguage.simplifiedChinese.rawValue
        }
        return code
    }

    /// The stored choice, else the system's preferred languages, without repeats.
    static func resolved(stored: [String]?, systemPreferred: [String]) -> [String] {
        if let stored, !stored.isEmpty {
            return stored
        }
        var seen: Set<String> = []
        return systemPreferred.compactMap(recognizerCode).filter { seen.insert($0).inserted }
    }

    /// What Settings offers: every language Translation reads into English, plus English,
    /// named in the user's language, alphabetically.
    @concurrent
    static func choices(locale: Locale = .current) async -> [SearchLanguageChoice] {
        var codes: Set<String> = [NLLanguage.english.rawValue]
        for language in await LanguageAvailability().supportedLanguages {
            if let code = SearchQueryEncoder.recognizerLanguage(language)?.rawValue {
                codes.insert(code)
            }
        }
        return codes.map { SearchLanguageChoice(code: $0, name: locale.localizedString(forIdentifier: $0) ?? $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
