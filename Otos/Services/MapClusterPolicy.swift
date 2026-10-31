import Foundation
import MapKit

/// Map cluster policy guide
///
/// Pure rules for turning the `.places` scope's located items into the stacks drawn
/// on the map (ADR 0040). No actor, no I/O, no SwiftUI; `CatalogWindowViewModel` runs
/// `clusters` off the main actor and assigns the result.
///
/// The rule is a grid in Web Mercator map points: at the current viewport, one cell is
/// `cellPoints` screen points on a side. Items in one cell form one stack, so stacks
/// never overlap and their count is bounded by the viewport's area. Only cells that
/// touch the viewport (padded by one cell) are emitted, so a street-level camera over
/// one city never materializes every other city's stack. The representative is the
/// first member in display order — the user's sort decides which photo fronts a stack.
nonisolated enum MapClusterPolicy {
    /// The width of the world in `MKMapPoint` units.
    static let worldMapPoints = MKMapSize.world.width
    /// Cluster cell edge in screen points: the 48 pt stack plus the gutter that keeps two
    /// stacks from touching (DES-103).
    static let cellPoints: Double = 64

    static func clusters(
        located: [LocatedAsset],
        viewport: MapViewport
    ) -> [MapPlaceCluster] {
        guard viewport.viewWidth > 0, viewport.viewHeight > 0, viewport.width > 0 else {
            return []
        }
        let pointsPerScreenPoint = viewport.width / viewport.viewWidth
        let cell = cellPoints * pointsPerScreenPoint
        // One cell of padding on every side, so a stack whose cell straddles the edge is
        // drawn rather than clipped at its center.
        let minCellX = Int(floor(viewport.originX / cell)) - 1
        let maxCellX = Int(floor((viewport.originX + viewport.width) / cell)) + 1
        let minCellY = Int(floor(viewport.originY / cell)) - 1
        let maxCellY = Int(floor((viewport.originY + viewport.height) / cell)) + 1

        struct Cell: Hashable {
            let column: Int
            let row: Int
        }
        var membersByCell: [Cell: [LocatedAsset]] = [:]
        var cellOrder: [Cell] = []
        for asset in located {
            let point = MKMapPoint(
                CLLocationCoordinate2D(latitude: asset.coordinate.latitude, longitude: asset.coordinate.longitude)
            )
            let cellX = Int(floor(point.x / cell))
            let cellY = Int(floor(point.y / cell))
            guard cellX >= minCellX, cellX <= maxCellX, cellY >= minCellY, cellY <= maxCellY else {
                continue
            }
            let key = Cell(column: cellX, row: cellY)
            if membersByCell[key] == nil {
                cellOrder.append(key)
            }
            membersByCell[key, default: []].append(asset)
        }
        return cellOrder.map { key in
            let members = membersByCell[key] ?? []
            let first = members[0].coordinate
            let isExact = members.allSatisfy { $0.coordinate == first }
            let coordinate: PlaceCoordinate = if isExact {
                first
            } else {
                PlaceCoordinate(
                    latitude: members.reduce(0) { $0 + $1.coordinate.latitude } / Double(members.count),
                    longitude: members.reduce(0) { $0 + $1.coordinate.longitude } / Double(members.count)
                )
            }
            return MapPlaceCluster(
                id: members[0].id,
                coordinate: coordinate,
                memberIDs: members.map(\.id),
                isExactPlace: isExact
            )
        }
    }

    /// The region that shows every coordinate with a margin, or nil when there is
    /// nothing to show. A single point, or points that coincide, get a town-sized span
    /// rather than a zero one.
    static func fittingRegion(_ coordinates: [PlaceCoordinate]) -> MapRegion? {
        guard let first = coordinates.first else {
            return nil
        }
        var minLatitude = first.latitude
        var maxLatitude = first.latitude
        var minLongitude = first.longitude
        var maxLongitude = first.longitude
        for coordinate in coordinates.dropFirst() {
            minLatitude = min(minLatitude, coordinate.latitude)
            maxLatitude = max(maxLatitude, coordinate.latitude)
            minLongitude = min(minLongitude, coordinate.longitude)
            maxLongitude = max(maxLongitude, coordinate.longitude)
        }
        let margin = 1.4
        let minimumSpan = 0.02
        return MapRegion(
            centerLatitude: (minLatitude + maxLatitude) / 2,
            centerLongitude: (minLongitude + maxLongitude) / 2,
            latitudeDelta: min(180, max(minimumSpan, (maxLatitude - minLatitude) * margin)),
            longitudeDelta: min(360, max(minimumSpan, (maxLongitude - minLongitude) * margin))
        )
    }

    /// The region a double-click on a stack that can still be split zooms to: the
    /// stack's own extent with the same margin, never wider than a quarter of the
    /// current viewport — so a zoom always visibly zooms.
    static func zoomRegion(
        into cluster: MapPlaceCluster,
        members: [PlaceCoordinate],
        viewport: MapViewport
    ) -> MapRegion {
        let fitted = fittingRegion(members) ?? MapRegion(
            centerLatitude: cluster.coordinate.latitude,
            centerLongitude: cluster.coordinate.longitude,
            latitudeDelta: 0.02,
            longitudeDelta: 0.02
        )
        let current = region(of: viewport)
        return MapRegion(
            centerLatitude: fitted.centerLatitude,
            centerLongitude: fitted.centerLongitude,
            latitudeDelta: min(fitted.latitudeDelta, current.latitudeDelta / 4),
            longitudeDelta: min(fitted.longitudeDelta, current.longitudeDelta / 4)
        )
    }

    /// The viewport's region scaled about its center: `factor` 0.5 zooms in one step,
    /// 2 zooms out one step (View ▸ Zoom In / Zoom Out on the map).
    static func scaledRegion(of viewport: MapViewport, by factor: Double) -> MapRegion {
        let current = region(of: viewport)
        return MapRegion(
            centerLatitude: current.centerLatitude,
            centerLongitude: current.centerLongitude,
            latitudeDelta: min(180, current.latitudeDelta * factor),
            longitudeDelta: min(360, current.longitudeDelta * factor)
        )
    }

    static func region(of viewport: MapViewport) -> MapRegion {
        let rect = MKMapRect(x: viewport.originX, y: viewport.originY, width: viewport.width, height: viewport.height)
        let region = MKCoordinateRegion(rect)
        return MapRegion(
            centerLatitude: region.center.latitude,
            centerLongitude: region.center.longitude,
            latitudeDelta: region.span.latitudeDelta,
            longitudeDelta: region.span.longitudeDelta
        )
    }

    /// VoiceOver's name for a stack (DES-082): what distinguishes it first — the count,
    /// then where it is.
    static func accessibilityLabel(for cluster: MapPlaceCluster) -> String {
        let latitude = cluster.coordinate.latitude
        let longitude = cluster.coordinate.longitude
        let position = String(
            format: "%.2f %@, %.2f %@",
            abs(latitude), latitude >= 0 ? "north" : "south",
            abs(longitude), longitude >= 0 ? "east" : "west"
        )
        return cluster.count == 1 ? "1 item, \(position)" : "\(cluster.count) items, \(position)"
    }
}
