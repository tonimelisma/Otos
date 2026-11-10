import Foundation

/// Search glossary guide (ADR 0048)
///
/// The English reading of a query in a language Apple Translation does not offer (Estonian):
/// the words a glossary written for Otos holds become English, and every other word stays as
/// typed for SigLIP 2's multilingual tower. On the owner's library, Estonian picture queries
/// scored recall@10 80 read this way, 49 as typed, against 85 for the same queries in English
/// (`docs/research/2026-11-09-keyword-search.md` §9).
///
/// `SearchGlossary-<language>.tsv` holds the language's case endings and, per English reading,
/// the forms that mean it: the nominative, then the genitive stem that compounds and the other
/// cases build on ("rand", beach; "ranna"). A typed word is read when glossary forms cover it
/// end to end, the last one followed by nothing or one case ending: "metsas" is "metsa" + "s",
/// "sünnipäevatort" is one form, "kõrvitsapõllul" would need "põld" in the glossary. A
/// compound's parts keep their order, modifier before head as in English: "rannapall" →
/// "beach ball". A whole form wins over a shorter one and an ending. A form shorter than three letters is never matched: it would read too many
/// words ("oa", a bean, inside "koa…").
nonisolated struct SearchGlossary: Sendable {
    let language: String
    private let readings: [String: String]
    private let endings: [String]
    private let longestForm: Int
    private static let shortestForm = 3

    enum GlossaryError: Error, Equatable {
        case malformed(line: Int)
    }

    /// The glossary for `language`, nil when Otos has none for it.
    init?(language: String, bundle: Bundle) throws {
        guard let url = bundle.url(forResource: "SearchGlossary-\(language)", withExtension: "tsv") else {
            return nil
        }
        try self.init(language: language, contents: String(contentsOf: url, encoding: .utf8))
    }

    init(language: String, contents: String) throws {
        var readings: [String: (reading: String, rank: Int)] = [:]
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
            for (rank, form) in values.enumerated() where form.count >= Self.shortestForm {
                if let known = readings[form], known.rank <= rank {
                    continue
                }
                readings[form] = (String(fields[0]), rank)
            }
        }
        self.language = language
        self.readings = readings.mapValues(\.reading)
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

    /// The fewest forms that cover `word` end to end, the last followed by a case ending, in
    /// English.
    private func reading(ofWord word: String) -> String? {
        let letters = Array(word)
        // fewest[i]: the shortest run of readings covering letters[..<i].
        var fewest: [[String]?] = Array(repeating: nil, count: letters.count + 1)
        fewest[0] = []
        for start in 0 ..< letters.count {
            guard let before = fewest[start] else { continue }
            let last = min(letters.count, start + longestForm)
            guard start + Self.shortestForm <= last else { continue }
            for end in start + Self.shortestForm ... last {
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
