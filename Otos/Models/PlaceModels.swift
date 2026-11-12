import Foundation

// Place names (ADR 0040, `docs/design/places.md`)
//
// The map is cut into cells (`PlaceCell`); Apple Maps names each cell a located photo falls
// in once (`PlaceNames`), and the Places filter (`MediaFilter.places`) narrows by those names.
// Values only: `PlaceNameReader` reads the names, the store keeps them, the filter reads them.

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

    /// The cell `coordinate` falls in.
    init(_ coordinate: PlaceCoordinate) {
        latitude = Int((coordinate.latitude * Self.perDegree).rounded(.down))
        longitude = Int((coordinate.longitude * Self.perDegree).rounded(.down))
    }

    /// The cell's center, which names it.
    var center: PlaceCoordinate {
        PlaceCoordinate(latitude: (Double(latitude) + 0.5) * Self.degrees, longitude: (Double(longitude) + 0.5) * Self.degrees)
    }

    /// `column`'s cell index in SQL: its floor after scaling, written without SQLite's math
    /// functions, which a build may lack.
    static func sql(_ column: String) -> String {
        let scaled = "(\(column) * \(perDegree))"
        return "(CAST(\(scaled) AS INTEGER) - (\(scaled) < CAST(\(scaled) AS INTEGER)))"
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

/// A country the Places filter offers, with its towns, in the locale's order.
nonisolated struct PlaceFilterCountry: Hashable, Sendable, Identifiable {
    let name: String
    let towns: [String]

    var id: String {
        name
    }
}
