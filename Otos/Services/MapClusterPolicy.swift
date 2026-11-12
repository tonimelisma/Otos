import Foundation
import MapKit

/// Map cluster policy guide
///
/// Pure rules for turning the `.places` scope's located items into the stacks drawn
/// on the map, and for the cameras the map is asked to adopt (ADR 0040). No actor, no
/// I/O, no SwiftUI; `CatalogWindowViewModel` runs `clusters` off the main actor and
/// assigns the result.
///
/// Everything is in Web Mercator map points (`MKMapPoint`), never degrees: a camera
/// in degrees wraps once its longitude span passes 180°, and a cell in degrees is a
/// different size at every latitude. The map wraps at the antimeridian, and MapKit
/// reports a viewport that shows it with x past one world width, so every comparison of
/// a point with a viewport or a camera takes the point's copy at or right of the rect's
/// left edge (`wrappedX`). At the current viewport one cell is `cellPoints`
/// screen points on a side. Items in one cell form one stack; a stack whose center
/// would land within a cell of an earlier stack's center merges into it, so stacks
/// never overlap whatever the cell boundaries happen to be. Only cells that touch the
/// viewport (padded by one cell) are emitted, so a street-level camera over one city
/// never materializes every other city's stack. The representative is the first
/// member in display order — the user's sort decides which photo fronts a stack.
nonisolated enum MapClusterPolicy {
    /// The width of the world in `MKMapPoint` units.
    static let worldMapPoints = MKMapSize.world.width
    /// Cluster cell edge in screen points: the 48 pt stack plus the gutter that keeps two
    /// stacks from touching (DES-103).
    static let cellPoints: Double = 64
    /// The smallest camera: a 2 km square, so one point or coincident points get a
    /// town-sized view rather than a zero one.
    static let minimumCameraMeters: Double = 2000
    /// Margin around a fit: a fifth of the extent on every side.
    static let fitMargin: Double = 0.2

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
        struct Member {
            let index: Int
            let asset: LocatedAsset
            let point: MKMapPoint
        }
        var membersByCell: [Cell: [Member]] = [:]
        var cellOrder: [Cell] = []
        let left = Double(minCellX) * cell
        for (index, asset) in located.enumerated() {
            let raw = mapPoint(asset.coordinate)
            let point = MKMapPoint(x: wrappedX(raw.x, from: left), y: raw.y)
            let cellX = Int(floor(point.x / cell))
            let cellY = Int(floor(point.y / cell))
            guard cellX >= minCellX, cellX <= maxCellX, cellY >= minCellY, cellY <= maxCellY else {
                continue
            }
            let key = Cell(column: cellX, row: cellY)
            if membersByCell[key] == nil {
                cellOrder.append(key)
            }
            membersByCell[key, default: []].append(Member(index: index, asset: asset, point: point))
        }

        // Cells in order of their first member, so an earlier stack keeps its identity
        // when a later cell merges into it. A merge happens when two stacks' centers
        // are closer than a cell: their 48 pt faces would otherwise overlap.
        struct Stack {
            var members: [Member]
            var center: MKMapPoint
        }
        var stacks: [Stack] = []
        for key in cellOrder {
            let members = membersByCell[key] ?? []
            let center = centroid(of: members.map(\.point))
            if let index = stacks.firstIndex(where: { existing in
                abs(existing.center.x - center.x) < cell && abs(existing.center.y - center.y) < cell
            }) {
                stacks[index].members.append(contentsOf: members)
                stacks[index].members.sort { $0.index < $1.index }
                stacks[index].center = centroid(of: stacks[index].members.map(\.point))
            } else {
                stacks.append(Stack(members: members, center: center))
            }
        }
        return stacks.map { stack in
            let first = stack.members[0].asset.coordinate
            let isExact = stack.members.allSatisfy { $0.asset.coordinate == first }
            let coordinate: PlaceCoordinate = if isExact {
                first
            } else {
                coordinate(of: stack.center)
            }
            return MapPlaceCluster(
                id: stack.members[0].asset.id,
                coordinate: coordinate,
                memberIDs: stack.members.map(\.asset.id),
                isExactPlace: isExact
            )
        }
    }

    /// The camera Places opens on: centered on the average location of the coordinates,
    /// and reaching the farthest of them on each axis, with `fitMargin` around that reach
    /// when `padded`; nil when there is nothing to show. The average longitude is the
    /// circular mean, so items either side of the antimeridian average to it, not to the
    /// far side of the earth; the average latitude is the plain mean. MapKit clamps a
    /// camera wider than it can show about its center, so a library spread over more
    /// than the map's zoom-out stays centered where it is on average (owner decision,
    /// 2026-11-12). One point, or coincident points, get `minimumCameraMeters`.
    static func centeredBounds(_ coordinates: [PlaceCoordinate], padded: Bool = true) -> MapBounds? {
        guard !coordinates.isEmpty else {
            return nil
        }
        var east = 0.0
        var north = 0.0
        var latitudeSum = 0.0
        for coordinate in coordinates {
            let longitude = coordinate.longitude * .pi / 180
            east += cos(longitude)
            north += sin(longitude)
            latitudeSum += coordinate.latitude
        }
        let center = mapPoint(PlaceCoordinate(
            latitude: latitudeSum / Double(coordinates.count),
            longitude: atan2(north, east) * 180 / .pi
        ))
        var halfWidth = 0.0
        var halfHeight = 0.0
        for coordinate in coordinates {
            let point = mapPoint(coordinate)
            halfWidth = max(halfWidth, abs(wrappedX(point.x, from: center.x - worldMapPoints / 2) - center.x))
            halfHeight = max(halfHeight, abs(point.y - center.y))
        }
        let rect = MKMapRect(
            x: center.x - halfWidth,
            y: center.y - halfHeight,
            width: 2 * halfWidth,
            height: 2 * halfHeight
        )
        return normalized(bounds(rect, margin: padded ? fitMargin : 0))
    }

    /// The box around the coordinates' own extent, with `fitMargin`: what a click on a
    /// stack zooms to. Each point is taken at its copy nearest the first, so a stack
    /// straddling the antimeridian is one small box, not one around the world.
    private static func fittingBounds(_ coordinates: [PlaceCoordinate]) -> MapBounds? {
        guard let first = coordinates.first else {
            return nil
        }
        let anchor = mapPoint(first)
        var rect = MKMapRect(origin: anchor, size: MKMapSize(width: 0, height: 0))
        for coordinate in coordinates.dropFirst() {
            let point = mapPoint(coordinate)
            let near = MKMapPoint(x: wrappedX(point.x, from: anchor.x - worldMapPoints / 2), y: point.y)
            rect = rect.union(MKMapRect(origin: near, size: MKMapSize(width: 0, height: 0)))
        }
        return normalized(bounds(rect, margin: fitMargin))
    }

    /// The camera a double-click on a stack that can still be split zooms to: the
    /// stack's own extent with the margin, never wider than a quarter of the current
    /// viewport on either axis — so a zoom always visibly zooms.
    static func zoomBounds(
        into cluster: MapPlaceCluster,
        members: [PlaceCoordinate],
        viewport: MapViewport
    ) -> MapBounds {
        let fitted = fittingBounds(members.isEmpty ? [cluster.coordinate] : members)
            ?? bounds(
                MKMapRect(origin: mapPoint(cluster.coordinate), size: MKMapSize(width: 0, height: 0)),
                margin: fitMargin
            )
        let width = min(fitted.width, viewport.width / 4)
        let height = min(fitted.height, viewport.height / 4)
        return MapBounds(
            originX: fitted.centerX - width / 2,
            originY: fitted.centerY - height / 2,
            width: width,
            height: height
        )
    }

    /// The viewport scaled about its center: `factor` 0.5 zooms in one step, 2 zooms
    /// out one step (View ▸ Zoom In / Zoom Out on the map).
    static func scaledBounds(of viewport: MapViewport, by factor: Double) -> MapBounds {
        let width = min(worldMapPoints, viewport.width * factor)
        let height = min(worldMapPoints, viewport.height * factor)
        return MapBounds(
            originX: viewport.originX + viewport.width / 2 - width / 2,
            originY: viewport.originY + viewport.height / 2 - height / 2,
            width: width,
            height: height
        )
    }

    /// The viewport as a camera request: what Back to Map restores.
    static func bounds(of viewport: MapViewport) -> MapBounds {
        MapBounds(originX: viewport.originX, originY: viewport.originY, width: viewport.width, height: viewport.height)
    }

    /// How far north and south the map pans when no item lies beyond: past about 75°
    /// the Web Mercator map stretches land many times over (Greenland drawn the size of
    /// Africa), so the polar regions stay off screen (owner decision, 2026-11-13).
    static let panLatitudeLimit: Double = 75
    /// Room past the farthest item, so a stack on it is drawn whole, not on the edge.
    static let panItemMarginDegrees: Double = 2
    /// The north–south limit of Web Mercator, where the map itself ends.
    static let mercatorLatitudeLimit: Double = 85.051_128_78

    /// The latitudes the map may pan over: `panLatitudeLimit` each way, widened to reach
    /// the farthest item north and south with `panItemMarginDegrees`, so no located item
    /// is ever out of reach, and never past the map's own edge.
    static func panBand(for coordinates: [PlaceCoordinate]) -> MapLatitudeBand {
        var south = -panLatitudeLimit
        var north = panLatitudeLimit
        for coordinate in coordinates {
            south = min(south, coordinate.latitude - panItemMarginDegrees)
            north = max(north, coordinate.latitude + panItemMarginDegrees)
        }
        return MapLatitudeBand(
            south: max(south, -mercatorLatitudeLimit),
            north: min(north, mercatorLatitudeLimit)
        )
    }

    /// `bounds` moved north or south, at the same size, so it shows nothing past `band`;
    /// nil when it already does. A view taller than the band sits at its middle.
    /// East–west is never touched: the map wraps at the antimeridian.
    static func keptInside(_ bounds: MapBounds, band: MapLatitudeBand) -> MapBounds? {
        let top = mapPoint(PlaceCoordinate(latitude: band.north, longitude: 0)).y
        let bottom = mapPoint(PlaceCoordinate(latitude: band.south, longitude: 0)).y
        let originY: Double
        if bounds.height >= bottom - top {
            originY = (top + bottom - bounds.height) / 2
        } else if bounds.originY < top {
            originY = top
        } else if bounds.originY + bounds.height > bottom {
            originY = bottom - bounds.height
        } else {
            return nil
        }
        // Less than a map point is not a move: a camera already at the edge settles there.
        guard abs(originY - bounds.originY) >= 1 else {
            return nil
        }
        return MapBounds(originX: bounds.originX, originY: originY, width: bounds.width, height: bounds.height)
    }

    /// The box of the earth the viewport shows: what Grid, Loupe and Compare open on the
    /// map. Web Mercator maps longitude to x and latitude to y monotonically, so the
    /// viewport's rect is exactly a latitude/longitude box. A rect past the world's
    /// right edge (MapKit reports x beyond one world width when the map shows the
    /// antimeridian) is a box that crosses it; a rect a world wide or wider is every
    /// longitude.
    static func area(of viewport: MapViewport) -> MapArea {
        let world = worldMapPoints
        let top = min(max(viewport.originY, 0), world)
        let bottom = min(max(viewport.originY + viewport.height, 0), world)
        let north = MKMapPoint(x: 0, y: top).coordinate.latitude
        let south = MKMapPoint(x: 0, y: bottom).coordinate.latitude
        guard viewport.width < world else {
            return MapArea(south: south, north: north, west: -180, east: 180)
        }
        let left = viewport.originX - (viewport.originX / world).rounded(.down) * world
        let right = left + viewport.width
        let west = MKMapPoint(x: left, y: 0).coordinate.longitude
        let east = MKMapPoint(x: right > world ? right - world : right, y: 0).coordinate.longitude
        return MapArea(south: south, north: north, west: west, east: east)
    }

    /// Whether `bounds` holds the coordinate, within `tolerance` map points of its edges
    /// (a stack on the very edge counts as shown); what a fit promises.
    static func contains(_ coordinate: PlaceCoordinate, in bounds: MapBounds, tolerance: Double = 0) -> Bool {
        let point = mapPoint(coordinate)
        let x = wrappedX(point.x, from: bounds.originX - tolerance)
        return x <= bounds.originX + bounds.width + tolerance
            && point.y >= bounds.originY - tolerance && point.y <= bounds.originY + bounds.height + tolerance
    }

    /// `bounds` grown about its center to at least `size`'s width and height: the fit
    /// re-asked at the largest camera the map has shown it can give.
    static func expanded(_ bounds: MapBounds, toAtLeast size: MapBounds) -> MapBounds {
        let width = max(bounds.width, size.width)
        let height = max(bounds.height, size.height)
        return MapBounds(
            originX: bounds.centerX - width / 2,
            originY: bounds.centerY - height / 2,
            width: width,
            height: height
        )
    }

    /// Where a coordinate falls in the view, in points from its top-left; outside
    /// 0…viewWidth / 0…viewHeight means off screen. Diagnostics only.
    static func viewPoint(of coordinate: PlaceCoordinate, in viewport: MapViewport) -> (x: Double, y: Double) {
        let point = mapPoint(coordinate)
        let scale = viewport.viewWidth / viewport.width
        let x = wrappedX(point.x, from: viewport.originX)
        return ((x - viewport.originX) * scale, (point.y - viewport.originY) * scale)
    }

    /// The viewport in degrees, for logs and tests.
    static func region(of viewport: MapViewport) -> MapRegion {
        region(of: bounds(of: viewport))
    }

    /// Web Mercator maps x to longitude linearly, so the span is the width's share of
    /// 360°, and a rect past the world's right edge still has its center's longitude.
    static func region(of bounds: MapBounds) -> MapRegion {
        let world = worldMapPoints
        let center = coordinate(of: MKMapPoint(x: bounds.centerX, y: bounds.centerY))
        let north = MKMapPoint(x: 0, y: min(max(bounds.originY, 0), world)).coordinate.latitude
        let south = MKMapPoint(x: 0, y: min(max(bounds.originY + bounds.height, 0), world)).coordinate.latitude
        return MapRegion(
            centerLatitude: center.latitude,
            centerLongitude: center.longitude,
            latitudeDelta: north - south,
            longitudeDelta: bounds.width / world * 360
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

    // MARK: - Map-point helpers

    private static func mapPoint(_ coordinate: PlaceCoordinate) -> MKMapPoint {
        MKMapPoint(CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }

    /// `x` moved by whole worlds to the first copy at or right of `left`.
    private static func wrappedX(_ x: Double, from left: Double) -> Double {
        x + ((left - x) / worldMapPoints).rounded(.up) * worldMapPoints
    }

    /// The coordinate at a map point, whichever copy of the world its x is in.
    private static func coordinate(of point: MKMapPoint) -> PlaceCoordinate {
        let normal = MKMapPoint(x: wrappedX(point.x, from: 0), y: point.y).coordinate
        return PlaceCoordinate(latitude: normal.latitude, longitude: normal.longitude)
    }

    /// `bounds` with its left edge moved into the first world, so a camera across the
    /// antimeridian reaches past the right edge as MapKit's own viewport does.
    private static func normalized(_ bounds: MapBounds) -> MapBounds {
        MapBounds(
            originX: wrappedX(bounds.originX, from: 0),
            originY: bounds.originY,
            width: bounds.width,
            height: bounds.height
        )
    }

    private static func centroid(of points: [MKMapPoint]) -> MKMapPoint {
        MKMapPoint(
            x: points.reduce(0) { $0 + $1.x } / Double(points.count),
            y: points.reduce(0) { $0 + $1.y } / Double(points.count)
        )
    }

    /// `rect` grown by `margin` of its extent on every side, and to
    /// `minimumCameraMeters` when smaller, measured at the latitude of the extent's center.
    private static func bounds(_ rect: MKMapRect, margin: Double) -> MapBounds {
        let centerLatitude = MKMapPoint(x: rect.midX, y: rect.midY).coordinate.latitude
        let minimum = MKMapPointsPerMeterAtLatitude(centerLatitude) * minimumCameraMeters
        let width = max(minimum, rect.size.width * (1 + 2 * margin))
        let height = max(minimum, rect.size.height * (1 + 2 * margin))
        return MapBounds(
            originX: rect.midX - width / 2,
            originY: rect.midY - height / 2,
            width: width,
            height: height
        )
    }
}
