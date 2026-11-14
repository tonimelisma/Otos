import Foundation
@testable import OtosKit
import Testing

/// A query in a language Translation does not offer, read through Otos's glossary of it
/// (ADR 0048).
@Suite(.testDirectory)
struct SearchGlossaryTests {
    private static let bundle = Bundle(for: CatalogWindowViewModel.self)

    @Test func casesCompoundsAndUnknownWordsAreRead() throws {
        let glossary = try #require(try SearchGlossary(language: "et", bundle: Self.bundle))
        #expect(glossary.reading(of: "rand") == "beach")
        // The genitive stem and a case ending: "in the forest", "with a bike", plural.
        #expect(glossary.reading(of: "matk metsas") == "hiking forest")
        #expect(glossary.reading(of: "lilled") == "flower")
        // A compound keeps its order, modifier before head.
        #expect(glossary.reading(of: "rannapall") == "beach ball")
        #expect(glossary.reading(of: "sünnipäevatort") == "birthday cake")
        // A word the glossary lacks stays as typed; a foreign name keeps its name, not its ending.
        #expect(glossary.reading(of: "unistav beebi") == "unistav baby")
        // Common words beyond the labels: a participle, a colour, a compound of an adjective.
        #expect(glossary.reading(of: "magav beebi") == "sleeping baby")
        #expect(glossary.reading(of: "punase mütsiga laps") == "red hat child")
        #expect(glossary.reading(of: "laps sõidab rattaga") == "child riding bicycle")
        #expect(glossary.reading(of: "vanaauto") == "old automobile")
        #expect(glossary.reading(of: "Golden Gate'i sild") == "Golden Gate bridge")
        #expect(glossary.reading(of: "unistus") == nil)
        #expect(try SearchGlossary(language: "xx", bundle: Self.bundle) == nil)
    }

    @Test func aWrittenGlossaryIsReadAsItSays() throws {
        let glossary = try SearchGlossary(language: "et", contents: """
        # comment
        @endings\ts,st
        cat\tkass,kassi
        clock\tkell,kella
        moon\tkuu
        night\töö
        """)
        #expect(glossary.reading(of: "kassist") == "cat")
        #expect(glossary.reading(of: "kell") == "clock")
        // A short form is a whole word: "kuus" (six) is not the moon with an ending.
        #expect(glossary.reading(of: "kuu") == "moon")
        #expect(glossary.reading(of: "kuus") == nil)
        #expect(glossary.reading(of: "kuukass") == nil)
        #expect(glossary.reading(of: "öö") == "night")
        #expect(throws: SearchGlossary.GlossaryError.malformed(line: 2)) {
            try SearchGlossary(language: "et", contents: "cat\tkass\nbroken")
        }
    }

    /// A form has one sense, and the file says which: one listed for two is refused, so the
    /// order of the lines never decides it.
    @Test func aFormListedTwiceDoesNotLoad() {
        #expect(throws: SearchGlossary.GlossaryError.listedTwice(form: "kell", line: 2)) {
            try SearchGlossary(language: "et", contents: "bell\tkell,kella\nclock\tkell")
        }
        #expect(throws: SearchGlossary.GlossaryError.listedTwice(form: "kodu", line: 1)) {
            try SearchGlossary(language: "et", contents: "home\tkodu,kodu")
        }
    }

    /// The shipped glossary reads a word in the sense a photo search means by it.
    @Test func theShippedGlossaryReadsTheSenseASearchMeans() throws {
        let glossary = try #require(try SearchGlossary(language: "et", bundle: Self.bundle))
        #expect(glossary.reading(of: "aed") == "garden")
        #expect(glossary.reading(of: "kell") == "clock")
        #expect(glossary.reading(of: "kodu") == "home")
        #expect(glossary.reading(of: "päev") == "day")
        #expect(glossary.reading(of: "pidu") == "party")
        #expect(glossary.reading(of: "prillid") == "glasses")
        #expect(glossary.reading(of: "öö") == "night")
        #expect(glossary.reading(of: "või") == nil)
        #expect(glossary.reading(of: "võit") == nil)
        #expect(glossary.reading(of: "seal") == nil)
        #expect(glossary.reading(of: "kuus") == nil)
    }

    /// Estonian, which Translation does not offer, is glossed after its facts are read: the
    /// picture is searched for in English.
    @Test func anEstonianQueryIsSearchedInEnglish() async throws {
        let encoder = SearchQueryEncoder(bundle: Self.bundle)
        let encoding = try await encoder.encode(SearchQueryRequest(text: "koer rannas", languages: ["et", "en"]))
        #expect(encoding.reading == .glossed)
        #expect(encoding.language == "et")
        #expect(encoding.modelText == "koer rannas")
        #expect(encoding.pictureText == "dog beach")
        let model = try SearchTextModel(bundle: Self.bundle)
        let tokenizer = try SearchTextTokenizer(bundle: Self.bundle)
        #expect(try encoding.embedding == model.embedding(of: tokenizer.tokenIDs(for: "dog beach")))
    }

    /// The recogniser calls a word it does not know English; English spelling tells them apart.
    @Test(arguments: [
        ("lennuk", SearchQueryEncoding.Reading.glossed, "airplane"),
        ("hobune pargis", .glossed, "horse park"),
        // Estonian "tool" is a chair, but it is spelled as English.
        ("tool", .english, "tool"),
        ("garden tools", .english, "garden tools"),
    ])
    func englishSpellingDecidesAWordNothingRecognises(typed: String, reading: SearchQueryEncoding.Reading, picture: String) async throws {
        let encoding = try await SearchQueryEncoder(bundle: Self.bundle).encode(SearchQueryRequest(text: typed, languages: ["et", "en"]))
        #expect(encoding.reading == reading)
        #expect(encoding.pictureText == picture)
    }
}
