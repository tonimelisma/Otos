import Foundation

// Place names (ADR 0040, `docs/design/places.md`)
//
// The map is cut into cells (`PlaceCell`); Apple Maps names each cell a located photo falls
// in once (`PlaceNames`), and the Places filter (`MediaFilter.places`) narrows by those names.
// Values only: `PlaceNameReader` reads the names, the store keeps them, the filter reads them.
// The store keeps one language's names at a time (`PlaceNameLanguage`).

/// One cell of the map, `PlaceCell.degrees` on a side: every photo located in it shares its
/// names. The cell is named from its center, so Apple Maps is sent the cell, never a photo's
/// own coordinate.
nonisolated struct PlaceCell: Hashable, Sendable {
    /// 0.02°, about 2.2 km north to south: a town's scale, so a photo near a town's edge may
    /// be named by its neighbour, and a library's photos ask Maps a few thousand times at most.
    static let degrees = 0.02
    static var perDegree: Double {
        1 / degrees
    }

    let latitude: Int
    let longitude: Int

    init(latitude: Int, longitude: Int) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// The southernmost and northernmost cell rows, and the westernmost and easternmost
    /// columns. A coordinate on the north pole or on the 180th meridian falls in the cell
    /// below it, so every cell's center is a valid coordinate.
    static let latitudes = -Int(90 * perDegree) ... Int(90 * perDegree) - 1
    static let longitudes = -Int(180 * perDegree) ... Int(180 * perDegree) - 1

    /// The cell `coordinate` falls in. `asset_metadata.place_cell_latitude` and
    /// `place_cell_longitude` compute the same cell in SQL (`CatalogSchema.placeCellStatements`).
    init(_ coordinate: PlaceCoordinate) {
        latitude = Self.index(coordinate.latitude, in: Self.latitudes)
        longitude = Self.index(coordinate.longitude, in: Self.longitudes)
    }

    private static func index(_ degrees: Double, in range: ClosedRange<Int>) -> Int {
        min(max(Int((degrees * perDegree).rounded(.down)), range.lowerBound), range.upperBound)
    }

    /// The cell's center, which names it.
    var center: PlaceCoordinate {
        PlaceCoordinate(latitude: (Double(latitude) + 0.5) * Self.degrees, longitude: (Double(longitude) + 0.5) * Self.degrees)
    }
}

/// The language place names are read in: the Mac's language and its script, never its
/// region, so a change of region alone asks Maps nothing again (ADR 0051). `zh-Hans` and
/// `zh-Hant` are two languages; `en_US` and `en_GB` are one, `en-Latn`.
nonisolated struct PlaceNameLanguage: Hashable, Sendable {
    /// The value stored with a cell's names (`place_cell.language`).
    let identifier: String

    init(_ locale: Locale) {
        let language = locale.language
        identifier = [language.languageCode?.identifier, language.script?.identifier]
            .compactMap(\.self)
            .joined(separator: "-")
    }
}

/// What Apple Maps names a cell: its country and its town, the town with the context that
/// tells it from another of the same name (`Springfield, IL`). Nil where Maps names none.
nonisolated struct PlaceNames: Hashable, Sendable {
    let country: String?
    let town: String?

    static let none = PlaceNames(country: nil, town: nil)
}

/// One row of the Places filter: a whole country, or one town in it.
nonisolated struct PlaceFilterKey: Hashable, Sendable, Comparable {
    let country: String
    /// Nil for the whole country.
    let town: String?

    static func < (lhs: PlaceFilterKey, rhs: PlaceFilterKey) -> Bool {
        (lhs.country, lhs.town ?? "") < (rhs.country, rhs.town ?? "")
    }
}

/// A country the Places filter offers, with its towns, most items first.
nonisolated struct PlaceFilterCountry: Hashable, Sendable, Identifiable {
    let name: String
    let towns: [String]

    var id: String {
        name
    }

    /// Place names by the items they hold, most first; a tie in the locale's order.
    static func mostItemsFirst(_ items: [String: Int]) -> [String] {
        items.sorted { lhs, rhs in
            lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
        }.map(\.key)
    }
}
