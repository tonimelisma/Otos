import Foundation
import MapKit
@testable import OtosKit
import Testing

/// The ViewModel's half of the Places map (ADR 0040): the map is the scope's one
/// presentation, the camera is asked for on entry and on return, stacks follow the
/// viewport through the cluster lane, and a place under the map is a scope reached
/// and left by two intents.
@Suite(.testScope)
struct CatalogWindowViewModelMapTests {
    private static let helsinki = PlaceCoordinate(latitude: 60.17, longitude: 24.94)
    private let pictures = CatalogLibraryState(
        root: LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures")),
        availability: .available,
        activity: .idle
    )

    private func id(_ name: String) -> MediaAssetID {
        MediaAssetID(libraryRootPath: pictures.path, relativePath: MediaRelativePath(rawValue: name))
    }

    // Validates: APP-057
    @MainActor
    @Test func enteringPlacesLeavesTheLoupeAndAsksForAFittingCamera() throws {
        let model = makeViewModel()
        model.startMapClustering()
        let gridState = windowState(
            model,
            scope: .library(pictures.path),
            ids: [id("a.jpg"), id("b.jpg")]
        )
        model.applyState(gridState)
        model.openLoupe(id: id("a.jpg"))
        #expect(model.viewMode == .loupe)

        model.selectSidebar(.places)
        let placesState = windowState(
            model,
            scope: .places,
            ids: [id("a.jpg")],
            map: CatalogMapState(located: [LocatedAsset(id: id("a.jpg"), coordinate: Self.helsinki)])
        )
        model.applyState(placesState)

        #expect(model.viewMode == .grid)
        #expect(model.showsPlacesMap)
        #expect(!model.canChangeViewMode)
        let request = try #require(model.mapCameraRequest)
        let region = MapClusterPolicy.region(of: request.bounds)
        #expect(abs(region.centerLatitude - Self.helsinki.latitude) < 0.001)
        #expect(MapClusterPolicy.contains(Self.helsinki, in: request.bounds))
        // Before the map reports where it is there is no area to open: a mode change is
        // refused rather than acted on.
        model.setViewMode(.loupe)
        #expect(model.viewMode == .grid)
    }

    // Validates: APP-057, APP-058
    @MainActor
    @Test func aViewportReportProducesStacksAndZoomStepsTheCamera() async throws {
        let model = makeViewModel()
        model.startMapClustering()
        model.selectSidebar(.places)
        let located = [
            LocatedAsset(id: id("new.jpg"), coordinate: Self.helsinki),
            LocatedAsset(id: id("old.jpg"), coordinate: Self.helsinki),
        ]
        model.applyState(windowState(
            model,
            scope: .places,
            ids: located.map(\.id),
            map: CatalogMapState(located: located)
        ))

        model.mapViewportChanged(cityViewport())
        let clusters = try await waitForValue { model.mapClusters.isEmpty ? nil : model.mapClusters }

        #expect(clusters.count == 1)
        #expect(clusters[0].id == id("new.jpg"))
        #expect(clusters[0].isExactPlace)
        #expect(model.canZoomIn)
        #expect(model.canZoomOut)

        // ⌘= on the map asks for a camera half the viewport's span, about the same center.
        let before = try #require(model.mapCameraRequest)
        model.zoomIn()
        let after = try #require(model.mapCameraRequest)
        let shown = cityViewport()
        #expect(after.revision == before.revision + 1)
        #expect(abs(after.bounds.width - shown.width / 2) < 1)
        #expect(abs(after.bounds.centerX - (shown.originX + shown.width / 2)) < 1)
    }

    // Validates: APP-058
    /// A click on a stack no zoom can split opens exactly its items, as a double-click on any
    /// stack does; Back to Map returns to the map as it was left.
    @MainActor
    @Test func clickingAnExactStackOpensItsItemsAndBackReturnsToTheSameMap() async throws {
        let model = makeViewModel()
        model.startMapClustering()
        model.selectSidebar(.places)
        let located = [LocatedAsset(id: id("a.jpg"), coordinate: Self.helsinki)]
        model.applyState(windowState(model, scope: .places, ids: [id("a.jpg")], map: CatalogMapState(located: located)))
        model.mapViewportChanged(cityViewport())
        let clusters = try await waitForValue { model.mapClusters.isEmpty ? nil : model.mapClusters }

        model.clickMapCluster(clusters[0])

        let stack = SidebarSelection.mapStack(MapStack(members: [id("a.jpg")]))
        #expect(model.queryDescriptor.scope == stack)
        #expect(model.sidebarSelection.sidebarRow == .places)
        #expect(model.showsMapAreaLeaf)
        #expect(model.viewMode == .grid)
        // Until the area is published the pane is the area's, waiting (DES-118): neither the
        // map nor a grid of all of Places that would diff down to the area.
        #expect(!model.showsPlacesMap)
        #expect(model.detailPane == CatalogDetailPane(surface: nil, content: .waiting(showsIndicator: false)))
        model.applyState(windowState(model, scope: stack, ids: [id("a.jpg")]))
        #expect(!model.showsPlacesMap)
        #expect(model.canChangeViewMode)
        #expect(model.mapClusters.isEmpty)

        let revisionBeforeReturn = model.mapCameraRequest?.revision ?? 0
        model.returnToPlaces()
        #expect(model.queryDescriptor.scope == .places)
        model.applyState(windowState(model, scope: .places, ids: [id("a.jpg")], map: CatalogMapState(located: located)))

        // Back lands on the viewport the user left, not on a re-fit.
        let request = try #require(model.mapCameraRequest)
        #expect(request.revision == revisionBeforeReturn + 1)
        #expect(request.bounds == MapClusterPolicy.bounds(of: cityViewport()))
    }

    // Validates: APP-058
    /// A click on a stack that can split zooms into it; a double-click opens exactly its
    /// items, whatever the camera did after the first click: the second click belongs to the
    /// gesture its first click began, not to what the flight moved under the pointer.
    @MainActor
    @Test func aClickZoomsIntoAStackAndADoubleClickOpensIt() async throws {
        let model = makeViewModel()
        model.startMapClustering()
        model.selectSidebar(.places)
        let located = [
            LocatedAsset(id: id("a.jpg"), coordinate: PlaceCoordinate(latitude: 60.170, longitude: 24.94)),
            LocatedAsset(id: id("b.jpg"), coordinate: PlaceCoordinate(latitude: 60.180, longitude: 24.94)),
        ]
        model.applyState(windowState(model, scope: .places, ids: located.map(\.id), map: CatalogMapState(located: located)))
        model.mapViewportChanged(viewport(latitudinalMeters: 400_000))
        let clusters = try await waitForValue { model.mapClusters.isEmpty ? nil : model.mapClusters }
        #expect(clusters.count == 1)
        #expect(!clusters[0].isExactPlace)
        let before = try #require(model.mapCameraRequest)

        #expect(!model.mapMouseDown(clickCount: 1))
        model.clickMapCluster(clusters[0])

        #expect(model.queryDescriptor.scope == .places)
        let after = try #require(model.mapCameraRequest)
        let shown = viewport(latitudinalMeters: 400_000)
        #expect(after.revision == before.revision + 1)
        #expect(after.bounds.width <= shown.width / 4)
        #expect(abs(MapClusterPolicy.region(of: after.bounds).centerLatitude - 60.175) < 0.001)

        // The flight is under way when the second click lands; the click is taken before
        // anything under the pointer sees it.
        model.mapViewportChanged(viewport(latitudinalMeters: 100_000))
        #expect(model.mapMouseDown(clickCount: 2))
        let stack = SidebarSelection.mapStack(MapStack(members: located.map(\.id)))
        #expect(model.queryDescriptor.scope == stack)
        #expect(model.showsMapAreaLeaf)
        #expect(model.viewMode == .grid)

        // The first click's flight settles after the stack opened; Back still returns to the
        // map the double-click left, not to the zoom its first click started.
        model.mapViewportChanged(viewport(latitudinalMeters: 50000))
        model.applyState(windowState(model, scope: stack, ids: located.map(\.id)))
        model.returnToPlaces()
        model.applyState(windowState(model, scope: .places, ids: located.map(\.id), map: CatalogMapState(located: located)))
        let back = try #require(model.mapCameraRequest)
        #expect(back.revision == after.revision + 1)
        #expect(back.bounds == MapClusterPolicy.bounds(of: shown))
    }

    // Validates: APP-058
    /// The reported case: a stack off the map's centre, double-clicked. Its first click flies
    /// the camera to it, so whatever the second click would land on — bare map, which MapKit
    /// would zoom again, or a neighbouring stack — has moved under the pointer. The second click
    /// is the gesture's: it opens the stack the first click acted on, a third does nothing more,
    /// and a click AppKit counts as one begins a new gesture whose own second click is left to
    /// what lies under it. A double-click on a stack no zoom can split opens it once.
    @MainActor
    @Test func aDoubleClicksSecondClickNeverActsOnWhatTheFirstMovedUnderThePointer() async throws {
        let model = makeViewModel()
        model.startMapClustering()
        model.selectSidebar(.places)
        let located = [
            LocatedAsset(id: id("centre-a.jpg"), coordinate: PlaceCoordinate(latitude: 60.170, longitude: 24.94)),
            LocatedAsset(id: id("centre-b.jpg"), coordinate: PlaceCoordinate(latitude: 60.180, longitude: 24.94)),
            LocatedAsset(id: id("east-a.jpg"), coordinate: PlaceCoordinate(latitude: 60.170, longitude: 27.0)),
            LocatedAsset(id: id("east-b.jpg"), coordinate: PlaceCoordinate(latitude: 60.180, longitude: 27.0)),
        ]
        model.applyState(windowState(model, scope: .places, ids: located.map(\.id), map: CatalogMapState(located: located)))
        let shown = viewport(latitudinalMeters: 400_000)
        model.mapViewportChanged(shown)
        let clusters = try await waitForValue { model.mapClusters.count == 2 ? model.mapClusters : nil }
        let east = try #require(clusters.first { $0.memberIDs.contains(id("east-a.jpg")) })
        #expect(!east.isExactPlace)

        // A click begins a gesture; a second click begun on bare map is not one of a stack's.
        #expect(!model.mapMouseDown(clickCount: 1))
        #expect(!model.mapMouseDown(clickCount: 2))
        #expect(model.queryDescriptor.scope == .places)

        #expect(!model.mapMouseDown(clickCount: 1))
        model.clickMapCluster(east)
        let zoom = try #require(model.mapCameraRequest)
        #expect(MapClusterPolicy.region(of: zoom.bounds).centerLongitude > 26)
        // The flight brings the east stack to the centre, where the centre stack was.
        model.mapViewportChanged(viewport(latitudinalMeters: 60000, longitude: 27.0))
        #expect(model.mapMouseDown(clickCount: 2))
        let stack = SidebarSelection.mapStack(MapStack(members: east.memberIDs))
        #expect(model.queryDescriptor.scope == stack)
        let generation = model.queryGeneration
        #expect(model.mapMouseDown(clickCount: 3))
        #expect(model.queryGeneration == generation)
        #expect(model.mapLeftViewport == shown)

        // A click AppKit counts as one, after the gesture: the next second click is not taken.
        #expect(!model.mapMouseDown(clickCount: 1))
        #expect(!model.mapMouseDown(clickCount: 2))
        #expect(model.queryGeneration == generation)
    }

    // Validates: APP-058
    /// A stack no zoom can split opens on its first click; the second click of the double-click
    /// is that gesture's and opens nothing again.
    @MainActor
    @Test func aDoubleClickOnAnExactStackOpensItOnce() async throws {
        let model = makeViewModel()
        model.startMapClustering()
        model.selectSidebar(.places)
        let located = [LocatedAsset(id: id("a.jpg"), coordinate: Self.helsinki)]
        model.applyState(windowState(model, scope: .places, ids: [id("a.jpg")], map: CatalogMapState(located: located)))
        model.mapViewportChanged(cityViewport())
        let clusters = try await waitForValue { model.mapClusters.isEmpty ? nil : model.mapClusters }

        #expect(!model.mapMouseDown(clickCount: 1))
        model.clickMapCluster(clusters[0])
        let generation = model.queryGeneration
        #expect(model.queryDescriptor.scope == .mapStack(MapStack(members: [id("a.jpg")])))
        #expect(model.mapMouseDown(clickCount: 2))
        #expect(model.queryGeneration == generation)
    }

    // Validates: APP-057
    /// MapKit clamps a camera past its zoom-out. The viewport that follows a fit's own
    /// request says whether every item is shown; a miss gets one unpadded re-ask, and a
    /// miss after that is left alone.
    @MainActor
    @Test func aFitTheMapCouldNotKeepIsAskedOnceMoreWithoutMargin() throws {
        let model = makeViewModel()
        model.startMapClustering()
        model.selectSidebar(.places)
        let located = [
            LocatedAsset(id: id("helsinki.jpg"), coordinate: Self.helsinki),
            LocatedAsset(id: id("la.jpg"), coordinate: PlaceCoordinate(latitude: 34.05, longitude: -118.24)),
        ]
        model.applyState(windowState(model, scope: .places, ids: located.map(\.id), map: CatalogMapState(located: located)))
        let fit = try #require(model.mapCameraRequest)
        let fitRegion = MapClusterPolicy.region(of: fit.bounds)
        #expect(fitRegion.longitudeDelta > 143 * 1.3)

        // The map settles on a camera that shows only Helsinki, as the fit's own follow-up.
        var narrow = cityViewport()
        narrow.cameraRevision = fit.revision
        model.mapViewportChanged(narrow)

        let refit = try #require(model.mapCameraRequest)
        #expect(refit.revision == fit.revision + 1)
        let refitRegion = MapClusterPolicy.region(of: refit.bounds)
        #expect(refitRegion.longitudeDelta < fitRegion.longitudeDelta)
        #expect(MapClusterPolicy.contains(Self.helsinki, in: refit.bounds))

        // Still short after the unpadded ask: no further request.
        var stillNarrow = viewport(latitudinalMeters: 30000)
        stillNarrow.cameraRevision = refit.revision
        model.mapViewportChanged(stillNarrow)
        #expect(model.mapCameraRequest?.revision == refit.revision)

        // A pan the user makes afterwards never re-fits.
        var pan = viewport(latitudinalMeters: 40000)
        pan.cameraRevision = refit.revision
        model.mapViewportChanged(pan)
        #expect(model.mapCameraRequest?.revision == refit.revision)
    }

    // Validates: APP-058
    /// Loupe on the map (⌘2, the picker, the View menu): the area the map shows, starting
    /// on the area's first item; the map has no selection to carry in.
    @MainActor
    @Test func loupeOnTheMapOpensTheVisibleAreaOnItsFirstItem() {
        let model = makeViewModel()
        model.startMapClustering()
        model.selectSidebar(.places)
        let tallinn = PlaceCoordinate(latitude: 59.44, longitude: 24.75)
        let located = [
            LocatedAsset(id: id("near.jpg"), coordinate: PlaceCoordinate(latitude: 60.171, longitude: 24.941)),
            LocatedAsset(id: id("helsinki.jpg"), coordinate: Self.helsinki),
            LocatedAsset(id: id("tallinn.jpg"), coordinate: tallinn),
        ]
        model.applyState(windowState(
            model,
            scope: .places,
            ids: located.map(\.id),
            map: CatalogMapState(located: located)
        ))
        #expect(!model.canChangeViewMode)
        model.mapViewportChanged(cityViewport())
        #expect(model.canChangeViewMode)

        model.setViewMode(.loupe)

        let area = MapClusterPolicy.area(of: cityViewport())
        #expect(model.queryDescriptor.scope == .mapArea(area))
        #expect(area.contains(Self.helsinki))
        #expect(!area.contains(tallinn))
        #expect(model.sidebarSelection.sidebarRow == .places)
        #expect(model.viewMode == .loupe)
        // The area waits until it publishes (DES-118), and a late Places state — the answer
        // to the query before this one — neither draws the map again nor undoes the mode.
        #expect(!model.showsPlacesMap)
        #expect(model.detailPane.content != .shown)
        model.applyState(windowState(
            model,
            scope: .places,
            ids: located.map(\.id),
            map: CatalogMapState(located: located),
            generation: model.queryGeneration - 1
        ))
        #expect(model.viewMode == .loupe)

        model.applyState(windowState(model, scope: .mapArea(area), ids: [id("near.jpg"), id("helsinki.jpg")]))

        #expect(!model.showsPlacesMap)
        #expect(model.showsMapAreaLeaf)
        #expect(model.viewMode == .loupe)
        #expect(model.focusedAssetID == id("near.jpg"))
    }

    // Validates: APP-058
    /// Grid on the map with nothing selected: the visible area as the grid, nothing
    /// selected; Back returns to the map, which resets the mode to the map's own.
    @MainActor
    @Test func gridOnTheMapOpensTheVisibleAreaAndBackReturnsToTheMap() {
        let model = makeViewModel()
        model.startMapClustering()
        model.selectSidebar(.places)
        let located = [LocatedAsset(id: id("a.jpg"), coordinate: Self.helsinki)]
        let placesState = windowState(
            model,
            scope: .places,
            ids: [id("a.jpg")],
            map: CatalogMapState(located: located)
        )
        model.applyState(placesState)
        model.mapViewportChanged(cityViewport())

        model.setViewMode(.grid)
        let area = MapClusterPolicy.area(of: cityViewport())
        #expect(model.queryDescriptor.scope == .mapArea(area))
        model.applyState(windowState(model, scope: .mapArea(area), ids: [id("a.jpg")]))
        #expect(model.viewMode == .grid)
        #expect(model.gridSelection.selection.isEmpty)

        model.setViewMode(.compare)
        #expect(model.viewMode == .compare)
        model.returnToPlaces()
        model.applyState(windowState(
            model,
            scope: .places,
            ids: [id("a.jpg")],
            map: CatalogMapState(located: located)
        ))
        #expect(model.showsPlacesMap)
        #expect(model.viewMode == .grid)
    }

    // MARK: - Fixtures

    /// Not started: only the cluster lane runs. A started model's own projection loop
    /// would publish states for its empty catalog, resolving Places away and clearing
    /// the clusters these tests wait for. States are applied by hand instead.
    @MainActor
    private func makeViewModel() -> CatalogWindowViewModel {
        CatalogWindowViewModel(
            catalogStore: makeTestStore(location: .inMemory, scanCadence: .milliseconds(10)),
            catalogProjection: CatalogProjection(volumeCapacity: ampleVolumeCapacity, cadence: .milliseconds(10)),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: .suite(UUID().uuidString),
            volumeCapacity: ampleVolumeCapacity,
            trashFiles: .refusing
        )
    }

    /// A published state for `scope` at the model's current query generation, so
    /// `applyState` treats it as the answer to the model's own intent.
    @MainActor
    private func windowState(
        _ model: CatalogWindowViewModel,
        scope: SidebarSelection,
        ids: [MediaAssetID],
        map: CatalogMapState? = nil,
        generation: UInt64? = nil
    ) -> CatalogWindowState {
        CatalogWindowState(
            title: CatalogWindowPolicy.title(for: scope, libraries: [pictures]),
            libraries: [pictures],
            removableSources: [],
            mediaGrid: CatalogMediaGridState(
                descriptor: CatalogQueryDescriptor(
                    scope: scope,
                    filter: model.queryDescriptor.filter,
                    sort: model.queryDescriptor.sort
                ),
                orderedAssetIDs: ids
            ),
            filterOptions: .empty,
            resolvedSidebarSelection: scope,
            mediaEmptyState: ids.isEmpty ? .noLocatedMedia : nil,
            deviceConnectionBanner: nil,
            map: map,
            queryGeneration: generation ?? model.queryGeneration
        )
    }

    private func cityViewport() -> MapViewport {
        viewport(latitudinalMeters: 20000)
    }

    private func viewport(latitudinalMeters: Double, longitude: Double = Self.helsinki.longitude) -> MapViewport {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: Self.helsinki.latitude, longitude: longitude),
            latitudinalMeters: latitudinalMeters,
            longitudinalMeters: latitudinalMeters
        )
        let topLeft = MKMapPoint(CLLocationCoordinate2D(
            latitude: region.center.latitude + region.span.latitudeDelta / 2,
            longitude: region.center.longitude - region.span.longitudeDelta / 2
        ))
        let bottomRight = MKMapPoint(CLLocationCoordinate2D(
            latitude: region.center.latitude - region.span.latitudeDelta / 2,
            longitude: region.center.longitude + region.span.longitudeDelta / 2
        ))
        return MapViewport(
            originX: topLeft.x,
            originY: topLeft.y,
            width: bottomRight.x - topLeft.x,
            height: bottomRight.y - topLeft.y,
            viewWidth: 800,
            viewHeight: 600
        )
    }
}
