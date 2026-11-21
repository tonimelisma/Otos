import Foundation

/// Browser place guide
///
/// Where the user was in the browser when Otos last quit: the query (sidebar scope,
/// filter, sort), the view mode, the item to bring back into view, and the selection
/// (APP-043, ADR 0031). `CatalogWindowViewModel` is the only owner: it loads this once at
/// init, writes it once at quit, and restores it once when the first non-empty result for
/// the restored query arrives.
///
/// This is UI preference state, not catalog truth. Every identity in it is a hint that the
/// restore checks against the live catalog: a scope or item that no longer exists is
/// dropped, never trusted.
///
/// Persisted as one JSON string under `defaultsKey`, through a private `Record` with an
/// explicit `version`. A missing key, a record that fails to decode, a different version,
/// or a value outside today's vocabulary (an unknown sort field, view mode, …) all load as
/// `nil`, which means "start from the defaults" — an unreadable place costs the user their
/// position, never their launch.
nonisolated struct BrowserPlace: Equatable {
    static let defaultsKey = "browserPlace"
    static let currentVersion = 6

    var descriptor: CatalogQueryDescriptor
    var viewMode: BrowserViewMode
    /// The item to bring back into view: the loupe's focused item, or the grid's middle
    /// visible item, which the grid centers on — so centering reproduces the viewport.
    var focus: MediaAssetID?
    /// The selection in display order. In compare mode this is the pair.
    var selection: [MediaAssetID]

    /// `today` is the day an On This Day scope reopens on: the scope is saved without its
    /// day, because the question it asks is always about today (ADR 0049).
    static func load(from preferences: any PreferenceStore, today: CalendarDay) -> BrowserPlace? {
        guard let json = preferences.string(forKey: defaultsKey),
              let data = json.data(using: .utf8),
              let record = try? JSONDecoder().decode(Record.self, from: data)
        else {
            return nil
        }
        return BrowserPlace(record: record, today: today)
    }

    func save(to preferences: any PreferenceStore) {
        guard let data = try? JSONEncoder().encode(Record(self)),
              let json = String(data: data, encoding: .utf8)
        else {
            return
        }
        preferences.set(json, forKey: Self.defaultsKey)
    }
}

// MARK: - Wire format

private nonisolated extension BrowserPlace {
    /// Version 6 of the stored shape: a filter's file types carry their kind, and the filter
    /// holds People and Places, its places with the language they are named in. Plain values,
    /// so the domain types stay free of persistence conformances and this file is the whole
    /// schema.
    nonisolated struct Record: Codable {
        nonisolated struct Scope: Codable {
            /// `allMedia`, `places`, `mapArea`, `onThisDay`, `duplicates`, `people`,
            /// `library`, `importBatch`, or `allImports`.
            var kind: String
            var path: String?
            var batchUnixMilliseconds: Int64?
            /// A `mapArea`'s box, in degrees.
            var south: Double?
            var north: Double?
            var west: Double?
            var east: Double?
        }

        nonisolated struct Asset: Codable {
            var root: String
            var path: String
        }

        nonisolated struct Place: Codable {
            var country: String
            var town: String?
        }

        nonisolated struct FileType: Codable {
            var kind: String
            var format: String
        }

        var version: Int
        var scope: Scope
        var kinds: [String]
        var fileTypes: [FileType]
        var choices: [String]
        /// The People filter's people, by row id; a person no longer in the catalog shows
        /// nothing and is dropped when People is next published.
        var people: [Int64]
        var unassignedFaces: Bool
        /// The Places filter's rows: a country, or a town in it.
        var places: [Place]
        /// The language `places` are named in (`PlaceNameLanguage`); nil exactly when there
        /// are none. A place the catalog no longer names in it leaves the filter when the
        /// window is first published (ADR 0051).
        var placeLanguage: String?
        var sortField: String
        var sortDirection: String
        var viewMode: String
        var focus: Asset?
        var selection: [Asset]
    }

    init?(record: Record, today: CalendarDay) {
        guard record.version == Self.currentVersion,
              let scope = Self.scope(record.scope, today: today),
              let field = MediaSortField(rawValue: record.sortField),
              let direction = MediaSortDirection(rawValue: record.sortDirection),
              let viewMode = BrowserViewMode(rawValue: record.viewMode)
        else {
            return nil
        }
        let kinds = record.kinds.compactMap(MediaKind.init(rawValue:))
        let choices = record.choices.compactMap(MediaChoice.init(rawValue:))
        let fileTypes = record.fileTypes.compactMap { fileType in
            // Restored through the library's naming, so a type saved as `HEIC` by an older
            // build selects the `HEIF` the catalog now stores (ADR 0039).
            MediaKind(rawValue: fileType.kind).flatMap { kind in
                MediaFormatToken.normalize(extension: fileType.format).map { FilterFileType(kind: kind, format: $0) }
            }
        }
        let places = record.placeLanguage.flatMap { language in
            PlaceFilter(
                language: PlaceNameLanguage(identifier: language),
                keys: Set(record.places.map { PlaceFilterKey(country: $0.country, town: $0.town) })
            )
        }
        guard kinds.count == record.kinds.count,
              choices.count == record.choices.count,
              fileTypes.count == record.fileTypes.count,
              (places == nil) == record.places.isEmpty
        else {
            return nil
        }
        let filter = MediaFilter(
            kinds: Set(kinds),
            fileTypes: Set(fileTypes),
            choices: Set(choices),
            people: Set(record.people.map(PersonID.init(rawValue:))),
            unassignedFaces: record.unassignedFaces,
            places: places
        )
        self.init(
            descriptor: CatalogQueryDescriptor(
                scope: scope,
                filter: filter,
                sort: MediaSortOrder(field: field, direction: direction)
            ),
            viewMode: viewMode,
            focus: record.focus.map(Self.assetID),
            selection: record.selection.map(Self.assetID)
        )
    }

    static func scope(_ scope: Record.Scope, today: CalendarDay) -> SidebarSelection? {
        switch scope.kind {
        case "allMedia":
            .allMedia
        case "places":
            .places
        case "onThisDay":
            .onThisDay(today)
        case "duplicates":
            .duplicates
        case "people":
            .people
        case "mapArea":
            if let south = scope.south, let north = scope.north, let west = scope.west, let east = scope.east {
                .mapArea(MapArea(south: south, north: north, west: west, east: east))
            } else {
                nil
            }
        case "allImports":
            .allImports
        case "library":
            scope.path.map { .library(LibraryRootPath(rawValue: $0)) }
        case "importBatch":
            scope.batchUnixMilliseconds.map { .importBatch(ImportBatchID(unixMilliseconds: $0)) }
        default:
            nil
        }
    }

    static func assetID(_ asset: Record.Asset) -> MediaAssetID {
        MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: asset.root),
            relativePath: MediaRelativePath(rawValue: asset.path)
        )
    }
}

private nonisolated extension BrowserPlace.Record {
    init(_ place: BrowserPlace) {
        let descriptor = place.descriptor
        self.init(
            version: BrowserPlace.currentVersion,
            scope: Self.scope(descriptor.scope),
            kinds: descriptor.filter.kinds.map(\.rawValue).sorted(),
            fileTypes: descriptor.filter.fileTypes
                .map { FileType(kind: $0.kind.rawValue, format: $0.format.rawValue) }
                .sorted { ($0.kind, $0.format) < ($1.kind, $1.format) },
            choices: descriptor.filter.choices.map(\.rawValue).sorted(),
            people: descriptor.filter.people.map(\.rawValue).sorted(),
            unassignedFaces: descriptor.filter.unassignedFaces,
            places: descriptor.filter.heldPlaces.sorted().map { Place(country: $0.country, town: $0.town) },
            placeLanguage: descriptor.filter.places?.language.identifier,
            sortField: descriptor.sort.field.rawValue,
            sortDirection: descriptor.sort.direction.rawValue,
            viewMode: place.viewMode.rawValue,
            focus: place.focus.map(Self.asset),
            selection: place.selection.map(Self.asset)
        )
    }

    static func scope(_ selection: SidebarSelection) -> Scope {
        switch selection {
        case .allMedia:
            Scope(kind: "allMedia")
        case .places, .mapStack:
            // A stack is named by its members, which are not written out: the window reopens
            // on the map it was opened from.
            Scope(kind: "places")
        case let .mapArea(area):
            Scope(kind: "mapArea", south: area.south, north: area.north, west: area.west, east: area.east)
        case .onThisDay:
            // The day is not written: the scope always asks about today, so a window
            // reopened tomorrow shows tomorrow's (ADR 0049).
            Scope(kind: "onThisDay")
        case .duplicates, .duplicateGroup:
            // A group is named by its digest, which is never written out (ADR 0018); the
            // window reopens on the list it was reached from.
            Scope(kind: "duplicates")
        case .people, .person:
            // The window reopens on the gallery, as a duplicate group reopens on its list.
            Scope(kind: "people")
        case .allImports:
            Scope(kind: "allImports")
        case let .library(path):
            Scope(kind: "library", path: path.rawValue)
        case let .importBatch(batchID):
            Scope(kind: "importBatch", batchUnixMilliseconds: batchID.unixMilliseconds)
        }
    }

    static func asset(_ id: MediaAssetID) -> Asset {
        Asset(root: id.libraryRootPath.rawValue, path: id.relativePath.rawValue)
    }
}
