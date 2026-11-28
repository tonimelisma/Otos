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
/// A chip that only repeats a more specific one is left out. Vision names every ancestor with a
/// label (people with adult, machine and vehicle with automobile, liquid, water and water body
/// with ocean) and publishes no taxonomy; its scores show one, derived once from the stored
/// scene readings of a reference library and shipped as `SceneLabelHierarchy.tsv`. An ancestor inherited from its
/// descendant scores what the descendant does: 70% of shown ancestor–descendant pairs on the
/// reference library were within 0.02, and the gaps tail off past 0.04. One that scores well above
/// every shown descendant was seen in its own right — an automobile at 0.52 beside its licence
/// plate at 0.34 — and stays. So an ancestor is left out when a shown descendant scores within
/// `inheritedConfidence` of it (`docs/research/2026-11-19-info-labels-and-text.md`). Search
/// keeps every label.
///
/// An actor, so the tables are read from the bundle once, off the main actor, when the pane
/// first needs them. A table that cannot be read throws, and the pane's refresh fails rather
/// than showing English as if no name existed.
actor SceneLabelNames {
    private let bundle: Bundle
    private var table: Table?
    private var hierarchy: Hierarchy?

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

    /// `labels` as the Info pane's chips, named in `language`, in order, each name once: a label
    /// another of them only inherits from is left out (`Hierarchy.shown`). Every language names
    /// some pairs of Vision's labels alike (Finnish "koira" for canine and dog), and the chip
    /// keeps the first, most confident one's identifier.
    func labels(of labels: [SceneLabel], in language: Locale.Language) throws -> [PhotoInfo.Recognized.Label] {
        let specific = try loadedHierarchy().shown(labels)
        var seen: Set<String> = []
        return try zip(specific, names(of: specific, in: language)).compactMap { identifier, name in
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

    /// How far below its ancestor a descendant may score for the ancestor to add nothing.
    static let inheritedConfidence: Float = 0.05

    private func loadedHierarchy() throws -> Hierarchy {
        if let hierarchy {
            return hierarchy
        }
        let read = try Hierarchy(bundle: bundle)
        hierarchy = read
        return read
    }

    /// `SceneLabelHierarchy.tsv`: `#` comment lines, a header (`identifier`, `ancestors`,
    /// `readings`), then one label a line with its ancestors, comma-separated, and the number of
    /// readings they were measured on. A label not in it has no known ancestor.
    struct Hierarchy {
        let ancestors: [String: Set<String>]

        init(bundle: Bundle) throws {
            guard let url = bundle.url(forResource: "SceneLabelHierarchy", withExtension: "tsv") else {
                throw Table.ReadError.missingResource
            }
            try self.init(text: String(contentsOf: url, encoding: .utf8))
        }

        init(text: String) throws {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).filter { !$0.hasPrefix("#") }
            guard lines.first?.split(separator: "\t").first == "identifier" else {
                throw Table.ReadError.missingHeader
            }
            var ancestors: [String: Set<String>] = [:]
            for line in lines.dropFirst() {
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard fields.count == 3, !fields[0].isEmpty, !fields[1].isEmpty else {
                    throw Table.ReadError.malformedRow(String(line))
                }
                ancestors[String(fields[0])] = Set(fields[1].split(separator: ",").map(String.init))
            }
            self.ancestors = ancestors
        }

        /// The identifiers of `labels` in order, without each one a descendant among them scores
        /// within `inheritedConfidence` of. A label whose confidence is unknown is kept, and
        /// leaves out no ancestor.
        func shown(_ labels: [SceneLabel]) -> [String] {
            labels.filter { label in
                guard let confidence = label.confidence else { return true }
                return !labels.contains { other in
                    guard let descendant = other.confidence, ancestors[other.identifier]?.contains(label.identifier) == true else {
                        return false
                    }
                    return confidence - descendant <= SceneLabelNames.inheritedConfidence
                }
            }.map(\.identifier)
        }
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
