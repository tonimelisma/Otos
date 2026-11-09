import Foundation
import NaturalLanguage
@testable import OtosKit
import Testing

/// The languages the user searches in (ADR 0048): a stored choice, else the system's, and
/// recognising a query's language favours them.
struct SearchLanguagesTests {
    @Test func theStoredChoiceWinsElseTheSystemsLanguages() {
        #expect(SearchLanguages.resolved(stored: ["fi", "en"], systemPreferred: ["en-US"]) == ["fi", "en"])
        #expect(SearchLanguages.resolved(stored: nil, systemPreferred: ["en-US", "en-GB", "fi-FI"]) == ["en", "fi"])
        #expect(SearchLanguages.resolved(stored: [], systemPreferred: ["zh-Hant-TW", "zh-Hans"]) == ["zh-Hant", "zh-Hans"])
    }

    /// "kot" is Polish for cat and reads as Finnish alone; a Polish user's search reads it as
    /// Polish. A Finnish sentence reads as Finnish either way.
    @Test func recognitionFavoursTheUsersLanguages() {
        let candidates: [NLLanguage: Locale.Language] = Dictionary(uniqueKeysWithValues: ["fi", "sv", "pl", "tr", "de", "nl"].map {
            (NLLanguage(rawValue: $0), Locale.Language(identifier: $0))
        })
        #expect(SearchQueryEncoder.recognize("kot", among: candidates) == .finnish)
        #expect(SearchQueryEncoder.recognize("kot", among: candidates, preferring: [.polish, .english]) == .polish)
        #expect(SearchQueryEncoder.recognize("lapset leikkivät lumessa", among: candidates, preferring: [.polish, .english]) == .finnish)
    }
}

extension SearchLanguagesTests {
    /// ARC-061: user-initiated work is what exempts a process from App Nap; the activity must
    /// not also keep the Mac awake.
    @Test func backgroundReadingIsExemptFromAppNapButNotFromSleep() {
        #expect(BackgroundReading.options.contains(.userInitiatedAllowingIdleSystemSleep))
        #expect(!BackgroundReading.options.contains(.idleSystemSleepDisabled))
    }
}
