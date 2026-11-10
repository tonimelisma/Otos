import Foundation
import NaturalLanguage
@testable import OtosKit
import Testing
import Translation

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
    @Test func choosingALanguageAddsOrRemovesItButNeverTheLast() {
        #expect(SearchLanguages.choosing("sv", isOn: true, in: ["fi", "en"]) == ["fi", "en", "sv"])
        #expect(SearchLanguages.choosing("fi", isOn: false, in: ["fi", "en"]) == ["en"])
        #expect(SearchLanguages.choosing("en", isOn: true, in: ["fi", "en"]) == ["fi", "en"])
        #expect(SearchLanguages.choosing("en", isOn: false, in: ["en"]) == nil)
    }

    @Test func theTitleNamesTheChosenLanguagesInOrder() {
        let choices = [SearchLanguageChoice(code: "en", name: "English"), SearchLanguageChoice(code: "fi", name: "Finnish")]
        let english = Locale(identifier: "en_US")
        #expect(SearchLanguages.title(of: ["fi", "en"], among: choices, locale: english) == "Finnish and English")
        #expect(SearchLanguages.title(of: ["en"], among: choices, locale: english) == "English")
    }

    @Test func backgroundReadingIsExemptFromAppNapButNotFromSleep() {
        #expect(BackgroundReading.options.contains(.userInitiatedAllowingIdleSystemSleep))
        #expect(!BackgroundReading.options.contains(.idleSystemSleepDisabled))
    }

    /// A query is translated as a photo's caption, and the caption's word is taken off.
    @Test func aQueryIsTranslatedAsAPhotosCaption() {
        #expect(SearchQueryEncoder.caption("호수", in: Locale.Language(identifier: "ko")) == "사진: 호수")
        #expect(SearchQueryEncoder.caption("馬", in: Locale.Language(identifier: "ja")) == "写真：馬")
        #expect(SearchQueryEncoder.caption("lake", in: Locale.Language(identifier: "en")) == nil)
        #expect(SearchQueryEncoder.uncaptioned("Photo: Lake") == "Lake")
        #expect(SearchQueryEncoder.uncaptioned("Image: dog") == "dog")
        #expect(SearchQueryEncoder.uncaptioned("picture: beach in September") == "beach in September")
        // A translation that dropped the caption's word is kept whole.
        #expect(SearchQueryEncoder.uncaptioned("Photography exhibition") == "Photography exhibition")
        #expect(SearchQueryEncoder.uncaptioned("dog on the beach") == "dog on the beach")
    }

    /// Every language Translation offers has its word for a photo.
    @Test func everyTranslatableLanguageHasAPhotoWord() async {
        for code in await Self.translatableCodes() {
            #expect(SearchQueryEncoder.photoWords[code] != nil, "no photo word for \(code)")
        }
    }

    /// `LanguageAvailability` is not `Sendable`, so it is asked entirely off the test's actor.
    @concurrent
    private static func translatableCodes() async -> Set<String> {
        var codes = Set<String>()
        for language in await LanguageAvailability().supportedLanguages {
            if let code = language.languageCode?.identifier, code != "en" {
                codes.insert(code)
            }
        }
        return codes
    }
}
