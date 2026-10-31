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

    @Test func aDegenerateViewportYieldsNoStacks() {
        let items = [located("a.jpg", 60.17, 24.94)]
        let empty = MapViewport(originX: 0, originY: 0, width: 0, height: 0, viewWidth: 0, viewHeight: 0)
        #expect(MapClusterPolicy.clusters(located: items, viewport: empty).isEmpty)
    }

    @Test func fittingRegionCoversEveryCoordinateWithAMarginAndNeverCollapses() throws {
        let spread = try #require(MapClusterPolicy.fittingRegion([
            PlaceCoordinate(latitude: 60, longitude: 24),
            PlaceCoordinate(latitude: 50, longitude: 10),
        ]))
        #expect(abs(spread.centerLatitude - 55) < 0.0001)
        #expect(abs(spread.centerLongitude - 17) < 0.0001)
        #expect(spread.latitudeDelta > 10)
        #expect(spread.longitudeDelta > 14)

        let single = try #require(MapClusterPolicy.fittingRegion([PlaceCoordinate(latitude: 60.17, longitude: 24.94)]))
        #expect(single.latitudeDelta == 0.02)
        #expect(single.longitudeDelta == 0.02)

        #expect(MapClusterPolicy.fittingRegion([]) == nil)
    }

    @Test func zoomIntoAStackAlwaysNarrowsTheViewport() {
        let country = viewport(MKCoordinateRegion(center: helsinki, latitudinalMeters: 400_000, longitudinalMeters: 400_000))
        let cluster = MapPlaceCluster(
            id: id("a.jpg"),
            coordinate: PlaceCoordinate(latitude: 60.175, longitude: 24.94),
            memberIDs: [id("a.jpg"), id("b.jpg")],
            isExactPlace: false
        )
        let before = MapClusterPolicy.region(of: country)

        let zoomed = MapClusterPolicy.zoomRegion(
            into: cluster,
            members: [PlaceCoordinate(latitude: 60.170, longitude: 24.94), PlaceCoordinate(latitude: 60.180, longitude: 24.94)],
            viewport: country
        )

        #expect(zoomed.latitudeDelta <= before.latitudeDelta / 4)
        #expect(zoomed.longitudeDelta <= before.longitudeDelta / 4)
        #expect(abs(zoomed.centerLatitude - 60.175) < 0.0001)
    }

    @Test func zoomStepsScaleAboutTheCenter() {
        let city = viewport(MKCoordinateRegion(center: helsinki, latitudinalMeters: 20000, longitudinalMeters: 20000))
        let before = MapClusterPolicy.region(of: city)

        let zoomedIn = MapClusterPolicy.scaledRegion(of: city, by: 0.5)
        let zoomedOut = MapClusterPolicy.scaledRegion(of: city, by: 2)

        #expect(abs(zoomedIn.latitudeDelta - before.latitudeDelta / 2) < 0.0001)
        #expect(abs(zoomedOut.latitudeDelta - before.latitudeDelta * 2) < 0.0001)
        #expect(abs(zoomedIn.centerLatitude - before.centerLatitude) < 0.0001)
        #expect(abs(zoomedOut.centerLongitude - before.centerLongitude) < 0.0001)
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
}
