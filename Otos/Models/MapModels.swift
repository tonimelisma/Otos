import Foundation

// Map model guide
//
// Value types for the Places map (ADR 0040). `PlaceCoordinate` is the stored primary
// location of an asset, exactly as `asset_metadata.primary_latitude/longitude` hold it;
// equality is exact, which is what makes "the items at this location" a precise scope
// (`SidebarSelection.place`). `CatalogMapState` is Projection's answer for the `.places`
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
}

/// A geographic region in degrees, for camera requests. The view converts to
/// `MKCoordinateRegion` at its edge.
nonisolated struct MapRegion: Equatable, Sendable {
    var centerLatitude: Double
    var centerLongitude: Double
    var latitudeDelta: Double
    var longitudeDelta: Double
}

/// A stack on the map: the located items that fall in one cluster cell at the current
/// viewport. `id` is the representative — the first member in display order — so a
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
    let region: MapRegion
}
