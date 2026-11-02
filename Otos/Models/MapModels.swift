import Foundation

// Map model guide
//
// Value types for the Places map (ADR 0040). `PlaceCoordinate` is the stored primary
// location of an asset, exactly as `asset_metadata.primary_latitude/longitude` hold it.
// `MapArea` is a latitude/longitude box, the scope of the grid under the map
// (`SidebarSelection.mapArea`): the visible map, or one coordinate as a box of no extent,
// whose bounds compare exactly with the stored values. `CatalogMapState` is Projection's answer for the `.places`
// scope — every located item in display order plus how many items in scope have no
// location — and `MapPlaceCluster` is what the ViewModel's cluster pass turns it into
// for one viewport. None of these carry MapKit types: the view converts at its edge.

/// An asset's primary location, in degrees.
nonisolated struct PlaceCoordinate: Hashable, Sendable {
    let latitude: Double
    let longitude: Double

    var diagnosticDescription: String {
        "\(latitude),\(longitude)"
    }
}

/// A box of the map in degrees: the items whose primary location lies in it, edges
/// included. Bounds are the stored values' own doubles, so a box of no extent around a
/// stored coordinate holds exactly the items at that coordinate. `west > east` means the
/// box crosses the antimeridian.
nonisolated struct MapArea: Hashable, Sendable {
    let south: Double
    let north: Double
    let west: Double
    let east: Double

    /// The items at exactly one coordinate.
    static func point(_ coordinate: PlaceCoordinate) -> MapArea {
        MapArea(
            south: coordinate.latitude,
            north: coordinate.latitude,
            west: coordinate.longitude,
            east: coordinate.longitude
        )
    }

    var crossesAntimeridian: Bool {
        west > east
    }

    func contains(_ coordinate: PlaceCoordinate) -> Bool {
        guard coordinate.latitude >= south, coordinate.latitude <= north else {
            return false
        }
        return crossesAntimeridian
            ? coordinate.longitude >= west || coordinate.longitude <= east
            : coordinate.longitude >= west && coordinate.longitude <= east
    }

    var diagnosticDescription: String {
        "\(south),\(west)..\(north),\(east)"
    }
}

/// One item on the map, in the scope's display order.
nonisolated struct LocatedAsset: Hashable, Sendable {
    let id: MediaAssetID
    let coordinate: PlaceCoordinate
}

/// What the `.places` scope shows: the located items in display order, and the count
/// of items in the same libraries and filter that carry no location (DES-103's L3).
nonisolated struct CatalogMapState: Equatable, Sendable {
    var located: [LocatedAsset]
    var unlocatedCount: Int

    static let empty = CatalogMapState(located: [], unlocatedCount: 0)
}

/// The map the user is looking at: the visible map rect in Web Mercator map points
/// (`MKMapPoint` units, world width `MapClusterPolicy.worldMapPoints`) and the view's
/// size in points. The two together give the map points per screen point, which sets
/// the cluster cell.
nonisolated struct MapViewport: Equatable, Sendable {
    var originX: Double
    var originY: Double
    var width: Double
    var height: Double
    var viewWidth: Double
    var viewHeight: Double
    /// The camera request this viewport followed (`MapCameraRequest.revision`), 0 before
    /// any — so the model can tell a fit's own settled viewport from the one the map
    /// reported at first layout, and from a pan the user made since.
    var cameraRevision: UInt64 = 0
}

/// A geographic region in degrees, for diagnostics and tests; never a camera request.
nonisolated struct MapRegion: Equatable, Sendable {
    var centerLatitude: Double
    var centerLongitude: Double
    var latitudeDelta: Double
    var longitudeDelta: Double
}

/// A rectangle in map points, for camera requests. The view converts to `MKMapRect`
/// at its edge. Map points, not degrees: a region in degrees wider than 180° of
/// longitude wraps when MapKit fits it, and a library shot on two continents is
/// exactly that wide (measured 2026-10-31: the fit left a stack 27 pt past the edge).
nonisolated struct MapBounds: Equatable, Sendable {
    var originX: Double
    var originY: Double
    var width: Double
    var height: Double

    var centerX: Double {
        originX + width / 2
    }

    var centerY: Double {
        originY + height / 2
    }
}

/// A stack on the map: the located items that fall in one cluster cell at the current
/// viewport, merged with any neighbor whose stack would touch it. `id` is the representative — the first member in display order — so a
/// stack whose front photo is unchanged keeps its view, and with it its painted
/// thumbnail, across camera changes (the grid's no-blank rule, applied to the map).
nonisolated struct MapPlaceCluster: Identifiable, Equatable, Sendable {
    let id: MediaAssetID
    /// Mean of the members' coordinates; the members' one coordinate when exact.
    let coordinate: PlaceCoordinate
    /// Members in display order; the representative is first.
    let memberIDs: [MediaAssetID]
    /// Every member shares one coordinate: double-click opens the place rather than
    /// zooming, because zooming could never separate them.
    let isExactPlace: Bool

    var count: Int {
        memberIDs.count
    }
}

/// A camera the map should adopt, numbered so the view applies each request once.
nonisolated struct MapCameraRequest: Equatable, Sendable {
    let revision: UInt64
    let bounds: MapBounds
}
