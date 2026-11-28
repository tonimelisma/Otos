import Foundation

/// Search glossary guide (ADR 0048)
///
/// The English reading of a query in a language Apple Translation does not offer (Estonian):
/// the words a glossary written for Otos holds become English, and every other word stays as
/// typed for SigLIP 2's multilingual tower. On the reference library, Estonian picture queries
/// scored recall@10 80 read this way, 49 as typed, against 85 for the same queries in English
/// (`docs/research/2026-11-09-keyword-search.md` §9).
///
/// `SearchGlossary-<language>.tsv` holds the language's case endings and, per English reading,
/// the forms that mean it: the nominative, then the genitive stem that compounds and the other
/// cases build on ("rand", beach; "ranna"). A typed word is read when glossary forms cover it
/// end to end, the last one followed by nothing or one case ending: "metsas" is "metsa" + "s",
/// "sünnipäevatort" is one form, "kõrvitsapõllul" would need "põld" in the glossary. A
/// compound's parts keep their order, modifier before head as in English: "rannapall" →
/// "beach ball". A whole form wins over a shorter one and an ending.
///
/// - **One sense a form.** A form is listed once, on the line of the sense a photo search means
///   by it ("kell" is a clock, not a bell); a glossary that lists a form twice does not load
///   (`GlossaryError.listedTwice`), so the file, not the order of its lines, says which.
/// - **Short forms are whole words.** A form of `wholeWordLength` letters or fewer is read only
///   as the whole typed word, never inside a compound or before an ending: it would read too
///   many words ("kuus", six, is not "kuu", moon, with an ending; "seal", there, is not "sea",
///   pig).
nonisolated struct SearchGlossary: Sendable {
    let language: String
    private let readings: [String: String]
    /// The forms read only as a whole word.
    private let wholeWords: [String: String]
    private let endings: [String]
    private let longestForm: Int
    static let wholeWordLength = 3

    enum GlossaryError: Error, Equatable {
        case malformed(line: Int)
        case listedTwice(form: String, line: Int)
    }

    /// The glossary for `language`, nil when Otos has none for it.
    init?(language: String, bundle: Bundle) throws {
        guard let url = bundle.url(forResource: "SearchGlossary-\(language)", withExtension: "tsv") else {
            return nil
        }
        try self.init(language: language, contents: String(contentsOf: url, encoding: .utf8))
    }

    init(language: String, contents: String) throws {
        var readings: [String: String] = [:]
        var wholeWords: [String: String] = [:]
        var endings: [String] = []
        for (index, line) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where !line.isEmpty && !line.hasPrefix("#")
        {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2, !fields[0].isEmpty, !fields[1].isEmpty else {
                throw GlossaryError.malformed(line: index + 1)
            }
            let values = fields[1].split(separator: ",").map { $0.lowercased() }
            if fields[0] == "@endings" {
                endings = values
                continue
            }
            for form in values {
                guard readings[form] == nil, wholeWords[form] == nil else {
                    throw GlossaryError.listedTwice(form: form, line: index + 1)
                }
                if form.count > Self.wholeWordLength {
                    readings[form] = String(fields[0])
                } else {
                    wholeWords[form] = String(fields[0])
                }
            }
        }
        self.language = language
        self.readings = readings
        self.wholeWords = wholeWords
        self.endings = [""] + endings.sorted { $0.count > $1.count }
        longestForm = readings.keys.map(\.count).max() ?? 0
    }

    /// `text` with every word the glossary covers in English, nil when it covers none. A word
    /// is a run of letters; after an apostrophe come the case endings of a foreign name
    /// ("Gate'i"), so the name before it is kept as typed. Words keep their order and case.
    func reading(of text: String) -> String? {
        var read = false
        var words: [String] = []
        for typed in text.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" }) {
            let name = typed.split(whereSeparator: { $0 == "'" || $0 == "’" }).first.map(String.init) ?? ""
            guard !name.isEmpty else { continue }
            if name.count == typed.count, let english = reading(ofWord: name.lowercased()) {
                words.append(english)
                read = true
            } else {
                words.append(name)
            }
        }
        return read ? words.joined(separator: " ") : nil
    }

    /// A short form typed whole, else the fewest longer forms that cover `word` end to end, the
    /// last followed by a case ending, in English.
    private func reading(ofWord word: String) -> String? {
        if let whole = wholeWords[word] {
            return whole
        }
        let letters = Array(word)
        let shortestForm = Self.wholeWordLength + 1
        // fewest[i]: the shortest run of readings covering letters[..<i].
        var fewest: [[String]?] = Array(repeating: nil, count: letters.count + 1)
        fewest[0] = []
        for start in 0 ..< letters.count {
            guard let before = fewest[start] else { continue }
            let last = min(letters.count, start + longestForm)
            guard start + shortestForm <= last else { continue }
            for end in start + shortestForm ... last {
                guard let english = readings[String(letters[start ..< end])] else { continue }
                if let known = fewest[end], known.count <= before.count + 1 {
                    continue
                }
                fewest[end] = before + [english]
            }
        }
        for ending in endings where word.hasSuffix(ending) {
            if let parts = fewest[letters.count - ending.count], !parts.isEmpty {
                return parts.joined(separator: " ")
            }
        }
        return nil
    }
}
