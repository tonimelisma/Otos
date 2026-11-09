import Foundation
import NaturalLanguage

/// When a query asks for photos taken: one span of capture time, start inclusive, end
/// exclusive, in the user's calendar.
nonisolated struct SearchDateSpan: Hashable, Sendable {
    let start: Date
    let end: Date
}

/// What the parser read in a query's English reading (ADR 0048).
nonisolated struct SearchQueryParse: Hashable, Sendable {
    /// Capture time the query names ("in September", "2025", "last week"); nil when none.
    var date: SearchDateSpan?
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
///   week, month and year. "May" counts as the month only with "in", "of" or a year beside
///   it. A month without a year is the most recent one, this year's if it has begun.
/// - **Places:** the first name `NLTagger` finds (it often tags a place as a person), with a
///   leading "Lake", "Mount" or "Mt." kept. Whether it is a place, and where, is answered by
///   `SearchPlaces`; one that is nowhere stays part of the picture's words.
/// - **The picture's words:** what is left, without the prepositions that tied the facts to
///   it.
nonisolated enum SearchQueryParser {
    private static let months = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
        "november", "december",
    ]
    private static let joiningWords: Set<String> = ["in", "on", "at", "from", "during", "of", "near", "around", "taken", "the"]

    /// `takesPlace`: false reads no place, for a query whose name turned out to be nowhere.
    static func parse(_ english: String, takesPlace: Bool = true, now: Date = Date(), calendar: Calendar = .current) -> SearchQueryParse {
        var words = english.split(whereSeparator: \.isWhitespace).map(String.init)
        let date = takeDate(&words, now: now, calendar: calendar)
        let place = takesPlace ? takePlace(&words) : nil
        trimJoiningWords(&words)
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

    private static func takeDate(_ words: inout [String], now: Date, calendar: Calendar) -> SearchDateSpan? {
        let lower = words.map(bare)
        func year(at index: Int) -> Int? {
            guard lower.indices.contains(index), lower[index].count == 4, let value = Int(lower[index]),
                  (1900 ... 2100).contains(value) else { return nil }
            return value
        }
        // Relative spans first: they are two words or one fixed word.
        let relative: [(words: [String], component: Calendar.Component, offset: Int)] = [
            (["today"], .day, 0), (["yesterday"], .day, -1),
            (["this", "week"], .weekOfYear, 0), (["last", "week"], .weekOfYear, -1),
            (["this", "month"], .month, 0), (["last", "month"], .month, -1),
            (["this", "year"], .year, 0), (["last", "year"], .year, -1),
        ]
        for entry in relative {
            let starts = 0 ... max(0, lower.count - entry.words.count)
            if let index = starts.first(where: { Array(lower[$0 ..< min(lower.count, $0 + entry.words.count)]) == entry.words }),
               let shifted = calendar.date(byAdding: entry.component, value: entry.offset, to: now),
               let interval = calendar.dateInterval(of: entry.component, for: shifted)
            {
                words.removeSubrange(index ..< index + entry.words.count)
                return SearchDateSpan(start: interval.start, end: interval.end)
            }
        }
        for (index, word) in lower.enumerated() {
            guard let month = months.firstIndex(of: word).map({ $0 + 1 }) else { continue }
            let named = year(at: index + 1) ?? (index > 0 ? year(at: index - 1) : nil)
            if word == "may", named == nil, !(index > 0 && ["in", "of", "during"].contains(lower[index - 1])) {
                continue
            }
            var components = calendar.dateComponents([.year, .month], from: now)
            if let named {
                components.year = named
            } else if month > components.month ?? 12 {
                components.year = (components.year ?? 0) - 1
            }
            components.month = month
            components.day = 1
            guard let start = calendar.date(from: components), let end = calendar.date(byAdding: .month, value: 1, to: start) else { continue }
            let yearIndex = year(at: index + 1) != nil ? index + 1 : (index > 0 && year(at: index - 1) != nil ? index - 1 : nil)
            words.removeSubrange(min(index, yearIndex ?? index) ... max(index, yearIndex ?? index))
            return SearchDateSpan(start: start, end: end)
        }
        for index in lower.indices {
            if let value = year(at: index), let start = calendar.date(from: DateComponents(year: value, month: 1, day: 1)),
               let end = calendar.date(byAdding: .year, value: 1, to: start)
            {
                words.remove(at: index)
                return SearchDateSpan(start: start, end: end)
            }
        }
        return nil
    }

    /// For a query no translation could read: a month named in one of the user's languages,
    /// by Foundation's month names in that language, matched on the stem so an inflected form
    /// counts (Estonian "septembris", from "september"). The month is the most recent one, as
    /// in English. Returns the span and the text without the month.
    static func takeNativeMonth(
        _ text: String,
        languages: [String],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (span: SearchDateSpan, rest: String)? {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        for language in languages {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: language)
            let names = [formatter.monthSymbols ?? [], formatter.standaloneMonthSymbols ?? []]
            for symbols in names where symbols.count == 12 {
                for (index, symbol) in symbols.enumerated() {
                    let name = symbol.lowercased()
                    let stem = name.count > 5 ? String(name.dropLast(2)) : name
                    guard let position = words.firstIndex(where: { bare($0).hasPrefix(stem) && bare($0).count <= name.count + 4 }) else {
                        continue
                    }
                    var components = calendar.dateComponents([.year, .month], from: now)
                    if index + 1 > components.month ?? 12 {
                        components.year = (components.year ?? 0) - 1
                    }
                    components.month = index + 1
                    components.day = 1
                    guard let start = calendar.date(from: components),
                          let end = calendar.date(byAdding: .month, value: 1, to: start) else { continue }
                    words.remove(at: position)
                    return (SearchDateSpan(start: start, end: end), words.joined(separator: " "))
                }
            }
        }
        return nil
    }

    private static func takePlace(_ words: inout [String]) -> String? {
        let text = words.joined(separator: " ")
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        tagger.setLanguage(.english, range: text.startIndex ..< text.endIndex)
        var place: Range<String.Index>?
        // The tagger often calls a place a person ("Dog in San Francisco"): any name is a
        // candidate, and `SearchPlaces` decides whether it is somewhere.
        let names: Set<NLTag> = [.placeName, .personalName, .organizationName]
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        tagger.enumerateTags(in: text.startIndex ..< text.endIndex, unit: .word, scheme: .nameType, options: options) { tag, range in
            if let tag, names.contains(tag), place == nil {
                place = range
            }
            return true
        }
        guard var range = place else { return nil }
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

    private static func trimJoiningWords(_ words: inout [String]) {
        while let last = words.last, joiningWords.contains(bare(last)) {
            words.removeLast()
        }
        while let first = words.first, joiningWords.contains(bare(first)) {
            words.removeFirst()
        }
    }
}
