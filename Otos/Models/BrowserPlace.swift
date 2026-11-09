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
    static let currentVersion = 1

    var descriptor: CatalogQueryDescriptor
    var viewMode: BrowserViewMode
    /// The item to bring back into view: the loupe's focused item, or the grid's middle
    /// visible item, which the grid centers on — so centering reproduces the viewport.
    var focus: MediaAssetID?
    /// The selection in display order. In compare mode this is the pair.
    var selection: [MediaAssetID]

    static func load(from preferences: any PreferenceStore) -> BrowserPlace? {
        guard let json = preferences.string(forKey: defaultsKey),
              let data = json.data(using: .utf8),
              let record = try? JSONDecoder().decode(Record.self, from: data)
        else {
            return nil
        }
        return BrowserPlace(record: record)
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
    /// Version 1 of the stored shape. Plain strings, so the domain types stay free of
    /// persistence conformances and this file is the whole schema.
    nonisolated struct Record: Codable {
        nonisolated struct Scope: Codable {
            /// `allMedia`, `places`, `mapArea`, `duplicates`, `people`, `peopleReview`,
            /// `person`, `library`, `importBatch`, or `allImports`.
            var kind: String
            var path: String?
            var batchUnixMilliseconds: Int64?
            /// A `mapArea`'s box, in degrees.
            var south: Double?
            var north: Double?
            var west: Double?
            var east: Double?
            /// A `person`'s row id.
            var person: Int64?
        }

        nonisolated struct Asset: Codable {
            var root: String
            var path: String
        }

        var version: Int
        var scope: Scope
        var kinds: [String]
        var formats: [String]
        var choices: [String]
        var sortField: String
        var sortDirection: String
        var viewMode: String
        var focus: Asset?
        var selection: [Asset]
    }

    init?(record: Record) {
        guard record.version == Self.currentVersion,
              let scope = Self.scope(record.scope),
              let field = MediaSortField(rawValue: record.sortField),
              let direction = MediaSortDirection(rawValue: record.sortDirection),
              let viewMode = BrowserViewMode(rawValue: record.viewMode)
        else {
            return nil
        }
        let kinds = record.kinds.compactMap(MediaKind.init(rawValue:))
        let choices = record.choices.compactMap(MediaChoice.init(rawValue:))
        guard kinds.count == record.kinds.count, choices.count == record.choices.count else {
            return nil
        }
        let filter = MediaFilter(
            kinds: Set(kinds),
            // Restored through the library's naming, so a filter saved as `HEIC` by an older
            // build selects the `HEIF` the catalog now stores (ADR 0039).
            formats: Set(record.formats.compactMap { MediaFormatToken.normalize(extension: $0) }),
            choices: Set(choices)
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

    static func scope(_ scope: Record.Scope) -> SidebarSelection? {
        switch scope.kind {
        case "allMedia":
            .allMedia
        case "places":
            .places
        case "duplicates":
            .duplicates
        case "people":
            .people
        case "peopleReview":
            .peopleReview
        case "person":
            scope.person.map { .person(PersonID(rawValue: $0)) }
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
            formats: descriptor.filter.formats.map(\.rawValue).sorted(),
            choices: descriptor.filter.choices.map(\.rawValue).sorted(),
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
        case .places:
            Scope(kind: "places")
        case let .mapArea(area):
            Scope(kind: "mapArea", south: area.south, north: area.north, west: area.west, east: area.east)
        case .duplicates, .duplicateGroup:
            // A group is named by its digest, which is never written out (ADR 0018); the
            // window reopens on the list it was reached from.
            Scope(kind: "duplicates")
        case .people:
            Scope(kind: "people")
        case .peopleReview, .reviewPhotos:
            // One row's photos are named by what the review showed then; the window reopens
            // on the review.
            Scope(kind: "peopleReview")
        case let .person(person):
            Scope(kind: "person", person: person.rawValue)
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
