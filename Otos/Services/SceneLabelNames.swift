import Foundation

/// Scene label names guide (ADR 0050)
///
/// The Info pane's In This Photo section names Vision's scene labels in the Mac's language.
/// Vision's identifiers are English (`baseball_hat`), and it offers no localized names, so
/// Otos ships them: `SceneLabelNames.tsv` holds every identifier's name in each language Apple
/// Translation offers, made once ahead of time by Translation itself.
///
/// - **Made as a caption, kept only when it reads back.** Each name was translated as a photo's
///   caption ("Photo: pool"), as search translates queries (ADR 0048): a bare word has no
///   context, and Translation read "pool" as a puddle in Norwegian. Even so it got some wrong
///   (Finnish "omena", apple, for pear), so each translation was read back into English the
///   same way, and kept only when the reading names the same label by search's own test
///   (`SearchLabelVocabulary`, cosine 0.95: "clothes" names clothing, "apple" does not name
///   pear). A name that fails is left empty, and that label reads in English.
/// - **Shipped, not translated at run time:** Translation took seconds for a photo's few
///   labels under load, and a Mac without the language's pack could not translate at all.
///
/// An actor, so the table is read from the bundle once, off the main actor, when the pane
/// first needs it. A table that cannot be read throws, and the pane's refresh fails rather
/// than showing English as if no name existed.
actor SceneLabelNames {
    private let bundle: Bundle
    private var table: Table?

    init(bundle: Bundle) {
        self.bundle = bundle
    }

    /// The names of `identifiers` in `language`, in order: the shipped name where one passed
    /// the read-back, else the English name.
    func names(of identifiers: [String], in language: Locale.Language) throws -> [String] {
        let table = try loaded()
        let column = Self.column(for: language).flatMap { table.columns[$0] }
        return identifiers.map { identifier in
            if let column, let name = table.names[identifier]?[column], !name.isEmpty {
                return name
            }
            return Self.englishName(identifier)
        }
    }

    /// `identifiers` as the Info pane's chips, named in `language`, in order, each name once:
    /// every language names some pairs of Vision's labels alike (Finnish "koira" for canine and
    /// dog), and the chip keeps the first, most confident one's identifier.
    func labels(of identifiers: [String], in language: Locale.Language) throws -> [PhotoInfo.Recognized.Label] {
        var seen: Set<String> = []
        return try zip(identifiers, names(of: identifiers, in: language)).compactMap { identifier, name in
            seen.insert(name).inserted ? PhotoInfo.Recognized.Label(identifier: identifier, name: name) : nil
        }
    }

    /// Vision's identifier as English words: `baseball_hat` → `baseball hat`.
    static func englishName(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: " ")
    }

    /// The table's column for `language`: its language code, and Chinese by script, as
    /// Translation offers it. English and a language without a column have none.
    static func column(for language: Locale.Language) -> String? {
        guard let code = language.languageCode?.identifier, code != "en" else { return nil }
        if code == "zh" {
            return language.script?.identifier == "Hant" ? "zh-Hant" : "zh-Hans"
        }
        return code
    }

    private func loaded() throws -> Table {
        if let table {
            return table
        }
        let read = try Table(bundle: bundle)
        table = read
        return read
    }

    /// `SceneLabelNames.tsv`: `#` comment lines, a header (`identifier`, then each column's
    /// language), then one identifier a line with its name in each column, empty where none
    /// read back; empty names at the end of a line are left off.
    struct Table {
        let columns: [String: Int]
        let names: [String: [String]]

        enum ReadError: Error {
            case missingResource
            case missingHeader
            case malformedRow(String)
        }

        init(bundle: Bundle) throws {
            guard let url = bundle.url(forResource: "SceneLabelNames", withExtension: "tsv") else {
                throw ReadError.missingResource
            }
            try self.init(text: String(contentsOf: url, encoding: .utf8))
        }

        init(text: String) throws {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).filter { !$0.hasPrefix("#") }
            guard let header = lines.first?.split(separator: "\t", omittingEmptySubsequences: false),
                  header.first == "identifier"
            else {
                throw ReadError.missingHeader
            }
            var columns: [String: Int] = [:]
            for (index, language) in header.dropFirst().enumerated() {
                columns[String(language)] = index
            }
            var names: [String: [String]] = [:]
            for line in lines.dropFirst() {
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard fields.count <= header.count, !fields[0].isEmpty else {
                    throw ReadError.malformedRow(String(line))
                }
                // Trailing empty names are left off the line, so it ends in no whitespace.
                names[fields[0]] = Array(fields.dropFirst()) + Array(repeating: "", count: header.count - fields.count)
            }
            self.columns = columns
            self.names = names
        }
    }
}
