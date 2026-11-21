import Foundation
import NaturalLanguage

/// When a query asks for photos taken: one span of capture time, start inclusive, end
/// exclusive, in the user's calendar.
nonisolated struct SearchDateSpan: Hashable, Sendable {
    let start: Date
    let end: Date
}

/// The time a query names, as it names it ("today", "September", "July 2024", "2025"): a rule,
/// not a span, so a reading made yesterday still means today when it is answered today. It
/// becomes a span only when the Store is asked (`span(at:in:)`).
nonisolated enum SearchDate: Hashable, Sendable {
    /// Today, yesterday, this or last week, month or year: `offset` units from now's.
    case relative(Unit, offset: Int)
    /// A month; without a year, the most recent one, this year's if it has begun.
    case month(Int, year: Int?)
    case year(Int)

    enum Unit: Hashable, Sendable {
        case day, week, month, year

        var component: Calendar.Component {
            switch self {
            case .day: .day
            case .week: .weekOfYear
            case .month: .month
            case .year: .year
            }
        }
    }

    func span(at now: Date, in calendar: Calendar) -> SearchDateSpan? {
        switch self {
        case let .relative(unit, offset):
            guard let shifted = calendar.date(byAdding: unit.component, value: offset, to: now),
                  let interval = calendar.dateInterval(of: unit.component, for: shifted) else { return nil }
            return SearchDateSpan(start: interval.start, end: interval.end)
        case let .month(month, year):
            var components = calendar.dateComponents([.year, .month], from: now)
            if let year {
                components.year = year
            } else if month > components.month ?? 12 {
                components.year = (components.year ?? 0) - 1
            }
            components.month = month
            components.day = 1
            guard let start = calendar.date(from: components),
                  let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
            return SearchDateSpan(start: start, end: end)
        case let .year(year):
            guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                  let end = calendar.date(byAdding: .year, value: 1, to: start) else { return nil }
            return SearchDateSpan(start: start, end: end)
        }
    }
}

/// What the parser read in a query's English reading (ADR 0048).
nonisolated struct SearchQueryParse: Hashable, Sendable {
    /// Capture time the query names ("in September", "2025", "last week"); nil when none.
    var date: SearchDate?
    /// A name the query holds that may be a place, as in the English reading ("San Francisco").
    var placeName: String?
    /// What is left for the picture to match; empty when the query is only facts.
    var pictureText: String
}

/// Search query parser guide (ADR 0048)
///
/// Reads the facts out of a query's English reading, so "beach in September" searches the
/// picture for "beach" among the photos taken in September. It runs after translation: every
/// language Translation reads arrives as English, so one grammar serves all of them
/// ("ranta syyskuussa" → "beach in September").
///
/// - **Dates:** a month (with or without a year), a year, and today, yesterday, this or last
///   week, month and year, read as a rule (`SearchDate`) that becomes a span when it is
///   answered. In what the user typed, "may" counts as the month only with "in", "of" or a
///   year beside it; in a translation, a month counts only when the text it was translated
///   from names that month in its own language (`Writer`).
/// - **Places:** in an English reading, the first name `NLTagger` calls a place or a person (it
///   often tags a place as a person), with a leading "Lake", "Mount" or "Mt." kept, unless it
///   is one word an ordinary word follows ("Ferris wheel"). In a query read as typed (a
///   language Translation cannot read), the run of capitalised words around that name, or
///   else the first such run that is not a lone first word ("Orange cat"), under the same
///   compound rule, because the English tagger finds no whole name in "koer San Franciscos".
///   That name, and nothing else of the query, is what `SearchPlaces` asks Apple Maps; one that
///   is nowhere stays part of the picture's words.
/// - **The picture's words:** what is left, without the prepositions that tied the facts to
///   it.
nonisolated enum SearchQueryParser {
    private static let months = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
        "november", "december",
    ]
    private static let joiningWords: Set<String> = ["in", "on", "at", "from", "during", "of", "near", "around", "taken", "the"]
    /// Words that may follow a place's name in a phrase ("Lake Tahoe in July", "Paris with
    /// kids"), unlike a noun that makes the name half of a compound.
    private static let followingWords = joiningWords.union(["with", "and", "or", "by", "for", "to", "during", "this", "last"])

    /// How a query's place name is found.
    enum Places: Sendable {
        /// An English reading: the tagger's first name.
        case tagged
        /// A query that may be in a language the tagger does not know: the run of capitalised
        /// words around its first name.
        case capitalised
        /// No place, for a query whose name turned out to be nowhere.
        case notRead
    }

    /// Who wrote the English reading, which decides what a month name is.
    enum Writer: Sendable {
        /// The user: any case, and "may" is the month only with "in", "of", "during" or a year.
        case user
        /// Apple Translation, from `source` in `language` (a locale identifier): a month it
        /// wrote is a month only when `source` names that month by Foundation's month names in
        /// that language. Case says nothing here: a query is translated as a photo's caption,
        /// and Translation capitalises the caption's first word ("Photo: Lake"), while it reads
        /// Swedish "tåg" (train) as "march".
        case translation(source: String, language: String)
    }

    static func parse(
        _ english: String,
        places: Places = .tagged,
        writtenBy writer: Writer = .user
    ) -> SearchQueryParse {
        var words = english.split(whereSeparator: \.isWhitespace).map(String.init)
        let date = takeDate(&words, writtenBy: writer)
        let place: String? = switch places {
        case .tagged: takePlace(&words)
        case .capitalised: takeCapitalised(&words)
        case .notRead: nil
        }
        // A joining word is left behind by a fact taken out ("beach in" May); a query with no
        // fact keeps every word, so "at" (Turkish horse, recognised as English) is not emptied.
        if date != nil || place != nil {
            trimJoiningWords(&words)
        }
        return SearchQueryParse(date: date, placeName: place, pictureText: words.joined(separator: " "))
    }

    /// The word as the grammar reads it: lower case, no punctuation, no possessive
    /// ("October's swing", as Japanese and Korean month phrases translate).
    private static func bare(_ word: String) -> String {
        var word = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
        for suffix in ["'s", "\u{2019}s"] where word.hasSuffix(suffix) {
            word.removeLast(2)
        }
        return word
    }

    private static func takeDate(_ words: inout [String], writtenBy writer: Writer) -> SearchDate? {
        let lower = words.map(bare)
        func year(at index: Int) -> Int? {
            guard lower.indices.contains(index), lower[index].count == 4, let value = Int(lower[index]),
                  (1900 ... 2100).contains(value) else { return nil }
            return value
        }
        // Relative spans first: they are two words or one fixed word.
        let relative: [(words: [String], unit: SearchDate.Unit, offset: Int)] = [
            (["today"], .day, 0), (["yesterday"], .day, -1),
            (["this", "week"], .week, 0), (["last", "week"], .week, -1),
            (["this", "month"], .month, 0), (["last", "month"], .month, -1),
            (["this", "year"], .year, 0), (["last", "year"], .year, -1),
        ]
        for entry in relative {
            let starts = 0 ... max(0, lower.count - entry.words.count)
            if let index = starts.first(where: { Array(lower[$0 ..< min(lower.count, $0 + entry.words.count)]) == entry.words }) {
                words.removeSubrange(index ..< index + entry.words.count)
                return .relative(entry.unit, offset: entry.offset)
            }
        }
        for (index, word) in lower.enumerated() {
            guard let month = months.firstIndex(of: word).map({ $0 + 1 }) else { continue }
            let named = year(at: index + 1) ?? (index > 0 ? year(at: index - 1) : nil)
            switch writer {
            case let .translation(source, language):
                guard names(month: month, in: source, language: language) else { continue }
            case .user:
                if word == "may", named == nil, !(index > 0 && ["in", "of", "during"].contains(lower[index - 1])) {
                    continue
                }
            }
            let yearIndex = year(at: index + 1) != nil ? index + 1 : (index > 0 && year(at: index - 1) != nil ? index - 1 : nil)
            words.removeSubrange(min(index, yearIndex ?? index) ... max(index, yearIndex ?? index))
            return .month(month, year: named)
        }
        for index in lower.indices {
            if let value = year(at: index) {
                words.remove(at: index)
                return .year(value)
            }
        }
        return nil
    }

    /// Whether `source` names `month` (1–12) in `language`: it holds the month's name, ignoring
    /// case and diacritics, as far as Foundation's two forms of it agree ("syyskuu" of
    /// "syyskuuta" and "syyskuu", so "syyskuussa" counts; "сентябр" of "сентября" and
    /// "сентябрь"). Unspaced scripts write a month inside a word ("9月の海"), so the name is
    /// looked for anywhere in the text.
    static func names(month: Int, in source: String, language: String) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language)
        guard let format = formatter.monthSymbols, let standalone = formatter.standaloneMonthSymbols,
              format.count == 12, standalone.count == 12, (1 ... 12).contains(month) else { return false }
        let one = fold(format[month - 1]), other = fold(standalone[month - 1])
        let shared = String(zip(one, other).prefix { $0 == $1 }.map(\.0))
        let stems = shared.count >= 2 ? [shared] : [one, other]
        let text = fold(source)
        return stems.contains { !$0.isEmpty && text.contains($0) }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// For a query no translation could read: a month named in one of the user's languages, by
    /// Foundation's month names in that language, as a whole word: the name itself, or one of
    /// the case forms that language writes it in (`monthCaseForms`; Estonian "septembris", in
    /// September). Never a word the name only begins, so Dutch "mei" is not "meisje" (girl) and
    /// Estonian "mai" is not "main". Returns the month and the text without it.
    static func takeNativeMonth(_ text: String, languages: [String]) -> (month: SearchDate, rest: String)? {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        for language in languages {
            for (index, forms) in monthForms(language).enumerated() {
                guard let position = words.firstIndex(where: { forms.contains(bare($0)) }) else { continue }
                words.remove(at: position)
                return (.month(index + 1, year: nil), words.joined(separator: " "))
            }
        }
        return nil
    }

    /// Each month's whole-word forms in `language`, lower case: Foundation's two names for it
    /// and, where Otos knows the language's case endings, those forms.
    static func monthForms(_ language: String) -> [Set<String>] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language)
        guard let format = formatter.monthSymbols, let standalone = formatter.standaloneMonthSymbols,
              format.count == 12, standalone.count == 12 else { return [] }
        return (0 ..< 12).map { index in
            let names: Set<String> = [format[index].lowercased(), standalone[index].lowercased()]
            return names.reduce(into: names) { forms, name in
                forms.formUnion(monthCaseForms[language]?(name) ?? [])
            }
        }
    }

    /// The case forms of a month's name in the languages Otos may search untranslated, where a
    /// date is written inflected. Estonian: the genitive ("septembri", "märtsi", "mai") and the
    /// in, from, into and until cases on it ("septembris", "maist", "märtsisse", "maini").
    /// Finnish, read untranslated when its pack is not installed: the same cases on the
    /// standalone name ("syyskuussa", "syyskuun").
    private static let monthCaseForms: [String: @Sendable (String) -> [String]] = [
        "et": { name in
            guard let last = name.last else { return [] }
            let genitive = name.hasSuffix("er") ? String(name.dropLast(2)) + "ri" : ("aeiouõäöü".contains(last) ? name : name + "i")
            return [genitive] + ["s", "st", "sse", "ni"].map { genitive + $0 }
        },
        "fi": { name in
            guard name.hasSuffix("kuu") else { return [] }
            return ["n", "ssa", "sta", "lla", "lle", "hun", "ksi"].map { name + $0 }
        },
    ]

    private static func takePlace(_ words: inout [String]) -> String? {
        guard let (text, found) = taggedName(in: words.joined(separator: " ")) else { return nil }
        let following = text[found.upperBound...].split(whereSeparator: \.isWhitespace).first.map(String.init)
        if startsCompound(nameWords: text[found].split(whereSeparator: \.isWhitespace).count, next: following) {
            return nil
        }
        var range = found
        // A leading feature word belongs to the name the tagger found ("Lake Tahoe").
        let before = text[..<range.lowerBound].split(separator: " ")
        if let last = before.last, ["lake", "mount", "mt", "mt."].contains(last.lowercased()) {
            range = text.index(range.lowerBound, offsetBy: -(last.count + 1)) ..< range.upperBound
        }
        let name = String(text[range])
        let remaining = (text[..<range.lowerBound] + " " + text[range.upperBound...]).split(whereSeparator: \.isWhitespace).map(String.init)
        words = remaining
        return name
    }

    /// A one-word name an ordinary word follows is the first half of a compound, not a place:
    /// "Ferris wheel" (Japanese, Chinese and Korean "carousel", translated), which Maps places
    /// in Texas, "Christmas tree", "Teddy bear". A longer name before a noun is a place ("San
    /// Francisco skyline", "New York pizza").
    private static func startsCompound(nameWords: Int, next: String?) -> Bool {
        guard nameWords == 1, let next else { return false }
        return next.first?.isLowercase == true && !followingWords.contains(bare(next))
    }

    /// The first name the English tagger calls a place or a person in `text`, with the text it
    /// ranges over.
    private static func taggedName(in text: String) -> (text: String, range: Range<String.Index>)? {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        tagger.setLanguage(.english, range: text.startIndex ..< text.endIndex)
        var place: Range<String.Index>?
        // The tagger often calls a place a person ("Dog in San Francisco"), so a person's name
        // is a candidate too, and `SearchPlaces` decides whether it is somewhere. An
        // organisation's is not: no measured query needed it.
        let names: Set<NLTag> = [.placeName, .personalName]
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        tagger.enumerateTags(in: text.startIndex ..< text.endIndex, unit: .word, scheme: .nameType, options: options) { tag, range in
            if let tag, names.contains(tag), place == nil {
                place = range
            }
            return true
        }
        return place.map { (text, $0) }
    }

    /// The run of capitalised words around the tagger's first name, or else the first run of
    /// capitalised words that is not a lone first word (a sentence's capital: "Orange cat",
    /// "Nice sunset"), taken out of `words` unless it is a one-word name before an ordinary
    /// word. The English tagger, given "koer San Franciscos", tags only "San".
    private static func takeCapitalised(_ words: inout [String]) -> String? {
        let capitalised = { (word: String) in word.first?.isUppercase == true }
        func run(around seed: Int) -> Range<Int> {
            var start = seed
            while start > words.startIndex, capitalised(words[start - 1]) {
                start -= 1
            }
            let end = words[seed...].firstIndex { !capitalised($0) } ?? words.endIndex
            return start ..< end
        }
        let tagged = taggedName(in: words.joined(separator: " ")).map { text, range in
            text[..<range.lowerBound].split(whereSeparator: \.isWhitespace).count
        }
        var found: Range<Int>?
        if let tagged, words.indices.contains(tagged), capitalised(words[tagged]) {
            found = run(around: tagged)
        } else {
            var index = words.startIndex
            while index < words.endIndex, found == nil {
                guard capitalised(words[index]) else {
                    index += 1
                    continue
                }
                let candidate = run(around: index)
                if candidate.lowerBound > 0 || candidate.count > 1 {
                    found = candidate
                }
                index = candidate.upperBound
            }
        }
        guard let found else { return nil }
        let next = words.indices.contains(found.upperBound) ? words[found.upperBound] : nil
        guard !startsCompound(nameWords: found.count, next: next) else { return nil }
        let name = words[found].joined(separator: " ")
        words.removeSubrange(found)
        return name
    }

    private static func trimJoiningWords(_ words: inout [String]) {
        while let last = words.last, joiningWords.contains(bare(last)) {
            words.removeLast()
        }
        while let first = words.first, joiningWords.contains(bare(first)) {
            words.removeFirst()
        }
    }
}
