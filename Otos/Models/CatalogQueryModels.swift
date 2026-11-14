import Foundation
import MediaMetadata
import UniformTypeIdentifiers

// Query model guide
//
// These values describe how the single media browser asks Store for visible
// identities. The ViewModel saves the current descriptor at quit and restores it at
// launch as part of `BrowserPlace` (APP-043); nothing else persists it. Keeping
// scope, filter, and sort in one descriptor gives toolbar buttons, menu commands,
// Projection, Store SQL, and the AppKit scroll-reset gate one shared contract.

nonisolated enum MediaKind: String, CaseIterable, Hashable {
    case image
    case raw
    case video

    static let displayOrder: [MediaKind] = [.image, .raw, .video]

    static func classify(_ contentType: UTType?) -> MediaKind? {
        guard let contentType else { return nil }
        if contentType.conforms(to: .rawImage) {
            return .raw
        }
        if contentType.conforms(to: .image) {
            return .image
        }
        if contentType.conforms(to: .movie) {
            return .video
        }
        return nil
    }

    var label: String {
        switch self {
        case .image:
            "Images"
        case .raw:
            "RAW"
        case .video:
            "Videos"
        }
    }
}

nonisolated struct MediaFormatToken: Hashable, Codable, RawRepresentable, Comparable, CustomStringConvertible {
    let rawValue: String

    var description: String {
        rawValue
    }

    static func < (left: MediaFormatToken, right: MediaFormatToken) -> Bool {
        left.rawValue.localizedStandardCompare(right.rawValue) == .orderedAscending
    }

    static func normalize(contentType: UTType?) -> MediaFormatToken? {
        guard let contentType else { return nil }
        return normalize(extension: contentType.preferredFilenameExtension)
            ?? normalize(extension: contentType.tags[.filenameExtension]?.first)
    }

    /// The file-type name for an extension, as MediaMetadata names it (ADR 0039): `JPEG`
    /// for jpg/jpe, `HEIF` for heic/heif/hif, `TIFF` for tif. An extension the library does
    /// not know keeps its own name, upper-cased.
    static func normalize(extension rawExtension: String?) -> MediaFormatToken? {
        guard let rawExtension else { return nil }
        let trimmed = rawExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return MediaFileType(fileExtension: trimmed).map(MediaFormatToken.init)
            ?? MediaFormatToken(rawValue: trimmed.uppercased())
    }

    /// The file-type name for a read file: the type its bytes settled, else its extension's.
    static func normalize(_ format: MediaFormat) -> MediaFormatToken? {
        format.fileType.map(MediaFormatToken.init) ?? normalize(extension: format.fileExtension)
    }
}

extension MediaFormatToken {
    /// MediaMetadata's name for a file type: `JPEG`, `HEIF`, `ARW`.
    nonisolated init(_ fileType: MediaFileType) {
        self.init(rawValue: fileType.displayName)
    }
}

/// One file type the filter holds, under the kind its catalog rows carry. The kind is part
/// of the value so the popover can always draw a row for it, even where nothing in the
/// catalog has that type any more — a filter never holds a value the user cannot see.
nonisolated struct FilterFileType: Hashable {
    let kind: MediaKind
    let format: MediaFormatToken
}

nonisolated struct MediaFilter: Hashable {
    var kinds: Set<MediaKind> = []
    var fileTypes: Set<FilterFileType> = []
    var choices: Set<MediaChoice> = []
    /// The People filter (ADR 0047): photos holding a face of every one of these people.
    var people: Set<PersonID> = []
    /// The People filter's `Unidentified Faces` row: photos holding, as well, a face with no
    /// person.
    var unassignedFaces = false
    /// The Places filter (ADR 0051): photos taken in any of these countries or towns.
    var places: Set<PlaceFilterKey> = []

    static let all = MediaFilter()

    var isActive: Bool {
        !kinds.isEmpty || !fileTypes.isEmpty || !choices.isEmpty || filtersPeople || !places.isEmpty
    }

    var filtersPeople: Bool {
        !people.isEmpty || unassignedFaces
    }

    func settingPerson(_ person: PersonID, included: Bool) -> MediaFilter {
        var updated = self
        if included {
            updated.people.insert(person)
        } else {
            updated.people.remove(person)
        }
        return updated
    }

    /// Checking a country includes all of it, so its towns leave the filter; checking a town
    /// of a checked country narrows the country to the towns checked.
    func settingPlace(_ place: PlaceFilterKey, included: Bool, towns: [String]) -> MediaFilter {
        var updated = self
        let country = PlaceFilterKey(country: place.country, town: nil)
        if place.town == nil {
            updated.places = updated.places.filter { $0.country != place.country }
            if included {
                updated.places.insert(country)
            }
            return updated
        }
        if updated.places.contains(country) {
            // Narrowing a whole country: every other town stays.
            updated.places.remove(country)
            for town in towns where town != place.town {
                updated.places.insert(PlaceFilterKey(country: place.country, town: town))
            }
            if included {
                updated.places.insert(place)
            }
            return updated
        }
        if included {
            updated.places.insert(place)
        } else {
            updated.places.remove(place)
        }
        return updated
    }

    func includes(kind: MediaKind?, format: MediaFormatToken?, choice: MediaChoice) -> Bool {
        let includesMedia = (kinds.isEmpty && fileTypes.isEmpty)
            || (kind.map(kinds.contains) ?? false)
            || (kind.flatMap { kind in format.map { fileTypes.contains(FilterFileType(kind: kind, format: $0)) } } ?? false)
        let includesChoice = choices.isEmpty || choices.contains(choice)
        return includesMedia && includesChoice
    }

    /// The file types of `kind` this filter holds by name (a whole kind holds none by name).
    func fileTypes(of kind: MediaKind) -> Set<MediaFormatToken> {
        Set(fileTypes.filter { $0.kind == kind }.map(\.format))
    }

    func settingChoice(_ choice: MediaChoice, included: Bool) -> MediaFilter {
        var updated = self
        if included {
            updated.choices.insert(choice)
        } else {
            updated.choices.remove(choice)
        }
        if updated.choices == Set(MediaChoice.allCases) {
            updated.choices = []
        }
        return updated
    }

    func settingKind(_ kind: MediaKind, included: Bool) -> MediaFilter {
        var updated = self
        updated.kinds.remove(kind)
        updated.fileTypes = updated.fileTypes.filter { $0.kind != kind }
        if included {
            updated.kinds.insert(kind)
        }
        return updated.canonicalized()
    }

    /// Selecting every file type `options` offers under `kind` selects the kind itself, so
    /// a type that arrives in that kind later is included too.
    func settingFileType(
        _ format: MediaFormatToken,
        kind: MediaKind,
        included: Bool,
        options: CatalogFilterOptions
    ) -> MediaFilter {
        var updated = self
        let offered = Set(options.formats(for: kind, holding: self))
        var selected = kinds.contains(kind) ? offered : fileTypes(of: kind)
        if included {
            selected.insert(format)
        } else {
            selected.remove(format)
        }

        updated.kinds.remove(kind)
        updated.fileTypes = updated.fileTypes.filter { $0.kind != kind }
        if !offered.isEmpty, selected == offered {
            updated.kinds.insert(kind)
        } else {
            updated.fileTypes.formUnion(selected.map { FilterFileType(kind: kind, format: $0) })
        }
        return updated.canonicalized()
    }

    /// Every kind selected is no media restriction at all.
    private func canonicalized() -> MediaFilter {
        guard kinds == Set(MediaKind.allCases), fileTypes.isEmpty else {
            return self
        }
        var result = self
        result.kinds = []
        return result
    }
}

nonisolated enum MediaSortField: String, Hashable {
    case bestDate
    case name
    case size
    /// How like the filtered person each photo's face of theirs is (ADR 0047): only with a
    /// People filter of one person.
    case likeness
}

nonisolated enum MediaSortDirection: String, Hashable {
    case ascending
    case descending
}

nonisolated struct MediaSortOrder: Hashable, CaseIterable {
    var field: MediaSortField
    var direction: MediaSortDirection

    static let dateNewest = MediaSortOrder(field: .bestDate, direction: .descending)
    static let dateOldest = MediaSortOrder(field: .bestDate, direction: .ascending)
    static let filenameAscending = MediaSortOrder(field: .name, direction: .ascending)
    static let filenameDescending = MediaSortOrder(field: .name, direction: .descending)
    static let sizeLargest = MediaSortOrder(field: .size, direction: .descending)
    static let sizeSmallest = MediaSortOrder(field: .size, direction: .ascending)
    static let likenessLeast = MediaSortOrder(field: .likeness, direction: .ascending)
    static let likenessMost = MediaSortOrder(field: .likeness, direction: .descending)

    static let allCases: [MediaSortOrder] = [
        .dateNewest,
        .dateOldest,
        .filenameAscending,
        .filenameDescending,
        .sizeLargest,
        .sizeSmallest,
        .likenessLeast,
        .likenessMost,
    ]

    static let defaultOrder = dateNewest

    var label: String {
        switch (field, direction) {
        case (.bestDate, .descending):
            "Date — Newest First"
        case (.bestDate, .ascending):
            "Date — Oldest First"
        case (.name, .ascending):
            "Filename — A to Z"
        case (.name, .descending):
            "Filename — Z to A"
        case (.size, .descending):
            "Size — Largest First"
        case (.size, .ascending):
            "Size — Smallest First"
        case (.likeness, .ascending):
            "Likeness — Least Alike First"
        case (.likeness, .descending):
            "Likeness — Most Alike First"
        }
    }

    /// The menu's title for this order when the filter shows `person`'s photos: the
    /// likeness orders name the person (`Likeness — Least Like Sam First`).
    func label(person name: String?) -> String {
        switch (field, direction, name) {
        case let (.likeness, .ascending, name?):
            "Likeness — Least Like \(name) First"
        case let (.likeness, .descending, name?):
            "Likeness — Most Like \(name) First"
        default:
            label
        }
    }
}

/// A keyword search narrowing what the scope shows to the photos and videos the text
/// describes (ADR 0048). Never persisted: a relaunch opens without one, as Photos does.
nonisolated struct CatalogSearch: Hashable, Sendable {
    /// How the results are ordered: best match first, Lightroom's default for a search, or
    /// by the scope's own sort.
    enum Order: Hashable, Sendable {
        case relevance
        case sort
    }

    /// What the search field shows, trimmed; never empty.
    let text: String
    var order: Order
    /// The languages the user searches in (`SearchLanguages`), which recognising the text's
    /// language favours; part of the search, so changing them searches again.
    var languages: [String]
    /// The Vision scene label a chip in the Info pane searches for (`baseball_hat`); `text` is
    /// then its name as the chip shows it. Nil for typed text.
    let label: String?

    /// Nil for text that is only white space: an empty field is no search.
    init?(text: String, order: Order = .relevance, languages: [String] = [], label: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.text = trimmed
        self.order = order
        self.languages = languages
        self.label = label
    }
}

nonisolated struct CatalogQueryDescriptor: Hashable {
    var scope: SidebarSelection
    var filter: MediaFilter
    var sort: MediaSortOrder
    var search: CatalogSearch?

    static let `default` = CatalogQueryDescriptor(scope: .allMedia)

    init(
        scope: SidebarSelection,
        filter: MediaFilter = .all,
        sort: MediaSortOrder = .defaultOrder,
        search: CatalogSearch? = nil
    ) {
        self.scope = scope
        self.filter = filter
        self.sort = sort
        self.search = search
    }

    /// Whether the grid groups by day (DES-069): under Date sort, unless a search orders it
    /// by relevance.
    var groupsByDay: Bool {
        effectiveSort.field == .bestDate && effectiveSearch?.order != .relevance
    }

    /// The search the scope's reads apply. A scope that fixes its order keeps it under a
    /// search, which then only narrows: On This Day's anniversaries stay contiguous runs
    /// (ADR 0049). The user's `search.order` is kept as chosen for when they leave.
    var effectiveSearch: CatalogSearch? {
        guard var search else { return nil }
        if scope.fixedSort != nil {
            search.order = .sort
        }
        return search
    }

    /// The order the scope's reads use: the scope's own when it fixes one, else the user's
    /// `sort`, which is kept as chosen so leaving such a scope restores it. Likeness needs one
    /// person's photos (`.person`); elsewhere the reads use the default order.
    var effectiveSort: MediaSortOrder {
        if let fixed = scope.fixedSort {
            return fixed
        }
        if sort.field == .likeness, scope.person == nil {
            return .defaultOrder
        }
        return sort
    }

    var diagnosticDescription: String {
        let kindList = filter.kinds.map(\.rawValue).sorted().joined(separator: ",")
        let formatList = filter.fileTypes.map { "\($0.kind.rawValue)/\($0.format.rawValue)" }.sorted().joined(separator: ",")
        let choiceList = filter.choices.map(\.rawValue).sorted().joined(separator: ",")
        return """
        scope=\(scope.diagnosticDescription) \
        sort=\(sort.field.rawValue):\(sort.direction.rawValue) \
        kinds=\(kindList.isEmpty ? "all" : kindList) \
        formats=\(formatList.isEmpty ? "all" : formatList) \
        choices=\(choiceList.isEmpty ? "all" : choiceList) \
        places=\(filter.places.count) \
        people=\(filter.people.count)\(filter.unassignedFaces ? "+unassigned" : "") \
        search=\(search.map { "\($0.text.count)chars:\($0.order)" } ?? "none")
        """
    }
}

nonisolated struct CatalogQueryRequest: Hashable {
    var descriptor: CatalogQueryDescriptor
    var generation: UInt64
    /// The stacks the user expanded (ADR 0052). Not part of the descriptor: expanding one
    /// changes no scope, so it never clears the selection or resets the browser place.
    var expandedStacks: Set<PhotoStackID> = []

    static let initial = CatalogQueryRequest(descriptor: .default, generation: 0)
}

/// The choices the filter popover offers: the file types and places present in every
/// available source, whatever the sidebar shows, so the choices are the same under every
/// row and a row's leaves (an area or stack under Places, a person under People), which keep
/// the row's filter (APP-013), never lose a choice it holds. Every held value also has a row
/// (`formats(for:holding:)`, `countries(holding:)`), so it can always be seen and cleared.
nonisolated struct CatalogFilterOptions: Equatable {
    var formatsByKind: [MediaKind: [MediaFormatToken]] = [:]
    /// The countries and towns Maps named for the located items, most items first (ADR 0051).
    var countries: [PlaceFilterCountry] = []

    static let empty = CatalogFilterOptions()

    /// The rows under `kind`, in name order: the file types present, plus any `filter`
    /// holds that nothing present has, so every held value can be seen and cleared.
    /// Every token is one file type (MediaMetadata's name), so a type is one row.
    func formats(for kind: MediaKind, holding filter: MediaFilter) -> [MediaFormatToken] {
        Set(formatsByKind[kind] ?? []).union(filter.fileTypes(of: kind)).sorted()
    }

    /// The countries, each with its towns, most items first: those named, plus every place
    /// `filter` holds that nothing named has — a held town under its country, after the towns
    /// named, and a held country with no named items after the countries named — so every
    /// held place can be seen and cleared (a place held in a language no longer the Mac's,
    /// or whose photos left the catalog).
    func countries(holding filter: MediaFilter) -> [PlaceFilterCountry] {
        var heldTowns: [String: Set<String>] = [:]
        var heldCountries: Set<String> = []
        for place in filter.places {
            heldCountries.insert(place.country)
            if let town = place.town {
                heldTowns[place.country, default: []].insert(town)
            }
        }
        func withHeldTowns(_ country: String, towns: [String]) -> PlaceFilterCountry {
            let named = Set(towns)
            let held = (heldTowns[country] ?? []).subtracting(named).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            return PlaceFilterCountry(name: country, towns: towns + held)
        }
        let named = countries.map { withHeldTowns($0.name, towns: $0.towns) }
        let namedNames = Set(countries.map(\.name))
        let held = heldCountries.subtracting(namedNames)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { withHeldTowns($0, towns: []) }
        return named + held
    }
}

/// Where a library moves in the user's order (APP-003), stated against libraries rather
/// than positions so the Store can apply it to the order it holds when the move arrives.
nonisolated enum LibraryOrderMove: Equatable, Sendable {
    /// One place earlier.
    case up
    /// One place later.
    case down
    /// Directly before this library, or last when nil.
    case before(LibraryRootPath?)

    /// The order after this move, or nil when `moving` (or the library it is placed
    /// before) is not in `order`.
    func reordering(_ order: [LibraryRootPath], moving: LibraryRootPath) -> [LibraryRootPath]? {
        guard let index = order.firstIndex(of: moving) else { return nil }
        var result = order
        switch self {
        case .up:
            guard index > 0 else { return order }
            result.swapAt(index, index - 1)
        case .down:
            guard index < order.count - 1 else { return order }
            result.swapAt(index, index + 1)
        case let .before(anchor):
            result.remove(at: index)
            if let anchor {
                guard anchor != moving else { return order }
                guard let anchorIndex = result.firstIndex(of: anchor) else { return nil }
                result.insert(moving, at: anchorIndex)
            } else {
                result.append(moving)
            }
        }
        return result
    }
}

/// One ordered-ID read of the catalog: the identities in display order, their day
/// buckets when sorted by date, and the identity remaps not yet acknowledged by the
/// window — all from one read transaction (ARC-052).
nonisolated struct CatalogOrderedAssets: Equatable, Sendable {
    let ids: [MediaAssetID]
    let dayBuckets: [Date?]
    /// Each row's primary location, index-paired with `ids`; empty unless the scope
    /// requires a location (`.places`, `.place`), where every row has one (ADR 0040).
    let coordinates: [PlaceCoordinate]
    let pendingIdentityRemaps: [CatalogIdentityRemapBatch]
    /// Every stack in the scope's roots, read in the same transaction as the IDs (ADR
    /// 0052). The IDs are the full order: collapsing is the projection's.
    let stacks: CatalogStacks

    init(
        ids: [MediaAssetID],
        dayBuckets: [Date?],
        coordinates: [PlaceCoordinate] = [],
        pendingIdentityRemaps: [CatalogIdentityRemapBatch],
        stacks: CatalogStacks = .empty
    ) {
        self.ids = ids
        self.dayBuckets = dayBuckets
        self.coordinates = coordinates
        self.pendingIdentityRemaps = pendingIdentityRemaps
        self.stacks = stacks
    }
}
