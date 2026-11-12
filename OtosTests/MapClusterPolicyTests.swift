import Foundation
import MapKit
@testable import OtosKit
import Testing

/// The Places map's stacks are a pure function of the located items and the viewport
/// (ADR 0040): one cell per `MapClusterPolicy.cellPoints` screen points, members in
/// display order, only cells touching the viewport.
struct MapClusterPolicyTests {
    private let root = LibraryRootPath(rawValue: "/Users/example/Pictures")

    private func id(_ name: String) -> MediaAssetID {
        MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: name))
    }

    private func located(_ name: String, _ latitude: Double, _ longitude: Double) -> LocatedAsset {
        LocatedAsset(id: id(name), coordinate: PlaceCoordinate(latitude: latitude, longitude: longitude))
    }

    /// A viewport that shows `region` in a view of `size` points.
    private func viewport(_ region: MKCoordinateRegion, size: CGSize = CGSize(width: 800, height: 600)) -> MapViewport {
        let rect = mapRect(region)
        return MapViewport(
            originX: rect.origin.x,
            originY: rect.origin.y,
            width: rect.size.width,
            height: rect.size.height,
            viewWidth: size.width,
            viewHeight: size.height
        )
    }

    private func mapRect(_ region: MKCoordinateRegion) -> MKMapRect {
        let topLeft = MKMapPoint(CLLocationCoordinate2D(
            latitude: region.center.latitude + region.span.latitudeDelta / 2,
            longitude: region.center.longitude - region.span.longitudeDelta / 2
        ))
        let bottomRight = MKMapPoint(CLLocationCoordinate2D(
            latitude: region.center.latitude - region.span.latitudeDelta / 2,
            longitude: region.center.longitude + region.span.longitudeDelta / 2
        ))
        return MKMapRect(
            x: topLeft.x,
            y: topLeft.y,
            width: bottomRight.x - topLeft.x,
            height: bottomRight.y - topLeft.y
        )
    }

    private let helsinki = CLLocationCoordinate2D(latitude: 60.17, longitude: 24.94)

    @Test func itemsAtOneCoordinateFormOneExactStackFrontedByTheFirstInOrder() {
        let items = [
            located("newest.jpg", 60.17, 24.94),
            located("older.jpg", 60.17, 24.94),
            located("oldest.jpg", 60.17, 24.94),
        ]
        let city = viewport(MKCoordinateRegion(center: helsinki, latitudinalMeters: 20000, longitudinalMeters: 20000))

        let clusters = MapClusterPolicy.clusters(located: items, viewport: city)

        #expect(clusters.count == 1)
        #expect(clusters.first?.id == id("newest.jpg"))
        #expect(clusters.first?.memberIDs == items.map(\.id))
        #expect(clusters.first?.isExactPlace == true)
        #expect(clusters.first?.coordinate == PlaceCoordinate(latitude: 60.17, longitude: 24.94))
    }

    @Test func nearbyItemsMergeWhenZoomedOutAndSplitWhenZoomedIn() {
        // Two spots about 1.1 km apart in Helsinki.
        let items = [
            located("a.jpg", 60.170, 24.940),
            located("b.jpg", 60.180, 24.940),
        ]
        let country = viewport(MKCoordinateRegion(center: helsinki, latitudinalMeters: 400_000, longitudinalMeters: 400_000))
        let street = viewport(MKCoordinateRegion(center: helsinki, latitudinalMeters: 3000, longitudinalMeters: 3000))

        let merged = MapClusterPolicy.clusters(located: items, viewport: country)
        let split = MapClusterPolicy.clusters(located: items, viewport: street)

        #expect(merged.count == 1)
        #expect(merged.first?.isExactPlace == false)
        #expect(merged.first?.count == 2)
        // A merged stack sits at the mean of its members.
        #expect(abs((merged.first?.coordinate.latitude ?? 0) - 60.175) < 0.0001)
        #expect(split.count == 2)
        for stack in split {
            #expect(stack.isExactPlace)
        }
    }

    @Test func stacksOutsideTheViewportAreNotEmitted() {
        let items = [
            located("helsinki.jpg", 60.17, 24.94),
            located("sydney.jpg", -33.87, 151.21),
        ]
        let overHelsinki = viewport(MKCoordinateRegion(center: helsinki, latitudinalMeters: 50000, longitudinalMeters: 50000))
        let world = viewport(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 170, longitudeDelta: 350)
        ))

        let local = MapClusterPolicy.clusters(located: items, viewport: overHelsinki)
        let global = MapClusterPolicy.clusters(located: items, viewport: world)

        #expect(local.map(\.id) == [id("helsinki.jpg")])
        #expect(global.count == 2)
    }

    @Test func fittingBoundsHoldEveryCoordinateWithAMarginAndNeverCollapse() throws {
        let helsinkiPoint = PlaceCoordinate(latitude: 60.17, longitude: 24.94)
        let losAngeles = PlaceCoordinate(latitude: 34.05, longitude: -118.24)
        let spread = try #require(MapClusterPolicy.fittingBounds([helsinkiPoint, losAngeles]))
        #expect(MapClusterPolicy.contains(helsinkiPoint, in: spread))
        #expect(MapClusterPolicy.contains(losAngeles, in: spread))
        // The margin: a fifth of the extent on each side.
        let extent = try #require(MapClusterPolicy.fittingBounds([helsinkiPoint, losAngeles]))
        let region = MapClusterPolicy.region(of: extent)
        #expect(region.longitudeDelta > 143 * 1.3)

        let single = try #require(MapClusterPolicy.fittingBounds([helsinkiPoint]))
        let singleRegion = MapClusterPolicy.region(of: single)
        // About 2 km at Helsinki: roughly 0.018° of latitude.
        #expect(singleRegion.latitudeDelta > 0.015 && singleRegion.latitudeDelta < 0.025)
        #expect(MapClusterPolicy.contains(helsinkiPoint, in: single))

        #expect(MapClusterPolicy.fittingBounds([]) == nil)
    }

    /// A library shot on two continents spans more than 180° of longitude. A camera in
    /// degrees wrapped that and left a stack past the edge (2026-10-31); map-point
    /// bounds cannot wrap.
    @Test func aFitAcrossMoreThanHalfTheWorldStillHoldsBothEnds() throws {
        let tokyo = PlaceCoordinate(latitude: 35.68, longitude: 139.69)
        let lima = PlaceCoordinate(latitude: -12.05, longitude: -77.04)
        let bounds = try #require(MapClusterPolicy.fittingBounds([tokyo, lima]))
        #expect(MapClusterPolicy.contains(tokyo, in: bounds))
        #expect(MapClusterPolicy.contains(lima, in: bounds))
        #expect(bounds.width <= MapClusterPolicy.worldMapPoints)
    }

    /// Two cells next to each other can hold items whose centers are closer than a
    /// stack is wide (measured 2026-10-31: 33 pt apart). They become one stack.
    @Test func stacksWhoseFacesWouldOverlapMerge() {
        let city = viewport(MKCoordinateRegion(center: helsinki, latitudinalMeters: 20000, longitudinalMeters: 20000))
        // Two points a few screen points apart, placed to straddle a cell boundary.
        let base = PlaceCoordinate(latitude: 60.17, longitude: 24.94)
        let basePoint = MapClusterPolicy.viewPoint(of: base, in: city)
        let perPoint = city.width / city.viewWidth
        let cell = MapClusterPolicy.cellPoints * perPoint
        let baseMap = MKMapPoint(CLLocationCoordinate2D(latitude: base.latitude, longitude: base.longitude))
        let boundaryX = (floor(baseMap.x / cell) + 1) * cell
        let left = MKMapPoint(x: boundaryX - 2 * perPoint, y: baseMap.y).coordinate
        let right = MKMapPoint(x: boundaryX + 2 * perPoint, y: baseMap.y).coordinate
        let items = [
            located("a.jpg", left.latitude, left.longitude),
            located("b.jpg", right.latitude, right.longitude),
        ]
        _ = basePoint

        let clusters = MapClusterPolicy.clusters(located: items, viewport: city)

        #expect(clusters.count == 1)
        #expect(clusters.first?.memberIDs == [id("a.jpg"), id("b.jpg")])
        #expect(clusters.first?.isExactPlace == false)
    }

    @Test func zoomIntoAStackAlwaysNarrowsTheViewport() {
        let country = viewport(MKCoordinateRegion(center: helsinki, latitudinalMeters: 400_000, longitudinalMeters: 400_000))
        let cluster = MapPlaceCluster(
            id: id("a.jpg"),
            coordinate: PlaceCoordinate(latitude: 60.175, longitude: 24.94),
            memberIDs: [id("a.jpg"), id("b.jpg")],
            isExactPlace: false
        )

        let zoomed = MapClusterPolicy.zoomBounds(
            into: cluster,
            members: [PlaceCoordinate(latitude: 60.170, longitude: 24.94), PlaceCoordinate(latitude: 60.180, longitude: 24.94)],
            viewport: country
        )

        #expect(zoomed.width <= country.width / 4)
        #expect(zoomed.height <= country.height / 4)
        #expect(abs(MapClusterPolicy.region(of: zoomed).centerLatitude - 60.175) < 0.001)
    }

    @Test func zoomStepsScaleAboutTheCenter() {
        let city = viewport(MKCoordinateRegion(center: helsinki, latitudinalMeters: 20000, longitudinalMeters: 20000))

        let zoomedIn = MapClusterPolicy.scaledBounds(of: city, by: 0.5)
        let zoomedOut = MapClusterPolicy.scaledBounds(of: city, by: 2)

        #expect(abs(zoomedIn.width - city.width / 2) < 1)
        #expect(abs(zoomedOut.width - city.width * 2) < 1)
        #expect(abs(zoomedIn.centerX - (city.originX + city.width / 2)) < 1)
        #expect(abs(zoomedOut.centerY - (city.originY + city.height / 2)) < 1)
    }

    @Test func accessibilityLabelLeadsWithTheCountThenThePlace() {
        let stack = MapPlaceCluster(
            id: id("a.jpg"),
            coordinate: PlaceCoordinate(latitude: 60.17, longitude: 24.94),
            memberIDs: [id("a.jpg"), id("b.jpg")],
            isExactPlace: true
        )
        let single = MapPlaceCluster(
            id: id("c.jpg"),
            coordinate: PlaceCoordinate(latitude: -33.87, longitude: -70.65),
            memberIDs: [id("c.jpg")],
            isExactPlace: true
        )
        #expect(MapClusterPolicy.accessibilityLabel(for: stack) == "2 items, 60.17 north, 24.94 east")
        #expect(MapClusterPolicy.accessibilityLabel(for: single) == "1 item, 33.87 south, 70.65 west")
    }

    // MARK: - The area a viewport shows

    /// Web Mercator keeps longitude in x and latitude in y, so the box is the viewport's
    /// own edges: the city in it, the next city out.
    @Test func aViewportsAreaIsTheBoxItShows() {
        let helsinki = PlaceCoordinate(latitude: 60.17, longitude: 24.94)
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: helsinki.latitude, longitude: helsinki.longitude),
            latitudinalMeters: 20000,
            longitudinalMeters: 20000
        )
        let area = MapClusterPolicy.area(of: viewport(region))

        #expect(area.contains(helsinki))
        #expect(!area.contains(PlaceCoordinate(latitude: 59.44, longitude: 24.75)))
        #expect(abs(area.north - (helsinki.latitude + region.span.latitudeDelta / 2)) < 0.001)
        #expect(abs(area.west - (helsinki.longitude - region.span.longitudeDelta / 2)) < 0.001)
        #expect(!area.crossesAntimeridian)
    }

    /// MapKit reports a view of the Pacific with x past one world width: the box crosses
    /// the antimeridian and holds both sides of it.
    @Test func aViewportAcrossTheAntimeridianHoldsBothSides() {
        let world = MapClusterPolicy.worldMapPoints
        let fiji = MKMapPoint(CLLocationCoordinate2D(latitude: -17.7, longitude: 178.0))
        let viewport = MapViewport(
            originX: fiji.x,
            originY: fiji.y - world / 64,
            width: world / 32,
            height: world / 32,
            viewWidth: 800,
            viewHeight: 800
        )
        let area = MapClusterPolicy.area(of: viewport)

        #expect(area.crossesAntimeridian)
        #expect(area.contains(PlaceCoordinate(latitude: -17.7, longitude: 179.9)))
        #expect(area.contains(PlaceCoordinate(latitude: -17.7, longitude: -179.9)))
        #expect(!area.contains(PlaceCoordinate(latitude: -17.7, longitude: 170)))
    }

    /// A viewport a world wide or wider shows every longitude.
    @Test func aWorldWideViewportHoldsEveryLongitude() {
        let world = MapClusterPolicy.worldMapPoints
        let viewport = MapViewport(
            originX: -world / 4, originY: 0, width: world * 1.5, height: world,
            viewWidth: 1200, viewHeight: 800
        )
        let area = MapClusterPolicy.area(of: viewport)

        #expect(area.west == -180)
        #expect(area.east == 180)
        #expect(area.contains(PlaceCoordinate(latitude: 0, longitude: 179.9)))
        #expect(area.contains(PlaceCoordinate(latitude: 60, longitude: -120)))
    }
}
