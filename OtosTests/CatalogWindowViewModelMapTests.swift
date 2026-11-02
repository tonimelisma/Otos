import Foundation
import MapKit
@testable import OtosKit
import Testing

/// The ViewModel's half of the Places map (ADR 0040): the map is the scope's one
/// presentation, the camera is asked for on entry and on return, stacks follow the
/// viewport through the cluster lane, and a place under the map is a scope reached
/// and left by two intents.
@Suite(.testDirectory)
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
            map: CatalogMapState(located: [LocatedAsset(id: id("a.jpg"), coordinate: Self.helsinki)], unlocatedCount: 1)
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

    @MainActor
    @Test func aViewportReportProducesStacksAndAStackClickSelectsItsMembers() async throws {
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
            map: CatalogMapState(located: located, unlocatedCount: 0)
        ))

        model.mapViewportChanged(cityViewport())
        let clusters = try await waitForValue { model.mapClusters.isEmpty ? nil : model.mapClusters }

        #expect(clusters.count == 1)
        #expect(clusters[0].id == id("new.jpg"))
        #expect(clusters[0].isExactPlace)
        #expect(model.canZoomIn)
        #expect(model.canZoomOut)

        model.selectMapCluster(clusters[0])
        #expect(model.gridSelection.selection == Set(located.map(\.id)))

        // ⌘= on the map asks for a camera half the viewport's span, about the same center.
        let before = try #require(model.mapCameraRequest)
        model.zoomIn()
        let after = try #require(model.mapCameraRequest)
        let shown = cityViewport()
        #expect(after.revision == before.revision + 1)
        #expect(abs(after.bounds.width - shown.width / 2) < 1)
        #expect(abs(after.bounds.centerX - (shown.originX + shown.width / 2)) < 1)
    }

    @MainActor
    @Test func activatingAnExactStackOpensItsCoordinateAndBackReturnsToTheSameMap() async throws {
        let model = makeViewModel()
        model.startMapClustering()
        model.selectSidebar(.places)
        let located = [LocatedAsset(id: id("a.jpg"), coordinate: Self.helsinki)]
        model.applyState(windowState(model, scope: .places, ids: [id("a.jpg")], map: CatalogMapState(located: located, unlocatedCount: 0)))
        model.mapViewportChanged(cityViewport())
        let clusters = try await waitForValue { model.mapClusters.isEmpty ? nil : model.mapClusters }

        model.activateMapCluster(clusters[0])

        #expect(model.queryDescriptor.scope == .mapArea(.point(Self.helsinki)))
        #expect(model.sidebarSelection.sidebarRow == .places)
        #expect(model.showsMapAreaLeaf)
        #expect(model.viewMode == .grid)
        // Until the area is published the pane still holds Places' items, so it stays
        // the map; a grid mounted now would draw all of Places and diff down to the area.
        #expect(model.showsPlacesMap)
        model.applyState(windowState(model, scope: .mapArea(.point(Self.helsinki)), ids: [id("a.jpg")]))
        #expect(!model.showsPlacesMap)
        #expect(model.canChangeViewMode)
        #expect(model.mapClusters.isEmpty)

        let revisionBeforeReturn = model.mapCameraRequest?.revision ?? 0
        model.returnToPlaces()
        #expect(model.queryDescriptor.scope == .places)
        model.applyState(windowState(model, scope: .places, ids: [id("a.jpg")], map: CatalogMapState(located: located, unlocatedCount: 0)))

        // Back lands on the viewport the user left, not on a re-fit.
        let request = try #require(model.mapCameraRequest)
        #expect(request.revision == revisionBeforeReturn + 1)
        #expect(request.bounds == MapClusterPolicy.bounds(of: cityViewport()))
    }

    @MainActor
    @Test func aStackThatCanSplitZoomsInsteadOfOpening() async throws {
        let model = makeViewModel()
        model.startMapClustering()
        model.selectSidebar(.places)
        let located = [
            LocatedAsset(id: id("a.jpg"), coordinate: PlaceCoordinate(latitude: 60.170, longitude: 24.94)),
            LocatedAsset(id: id("b.jpg"), coordinate: PlaceCoordinate(latitude: 60.180, longitude: 24.94)),
        ]
        model.applyState(windowState(model, scope: .places, ids: located.map(\.id), map: CatalogMapState(located: located, unlocatedCount: 0)))
        model.mapViewportChanged(viewport(latitudinalMeters: 400_000))
        let clusters = try await waitForValue { model.mapClusters.isEmpty ? nil : model.mapClusters }
        #expect(clusters.count == 1)
        #expect(!clusters[0].isExactPlace)
        let before = try #require(model.mapCameraRequest)

        model.activateMapCluster(clusters[0])

        #expect(model.queryDescriptor.scope == .places)
        let after = try #require(model.mapCameraRequest)
        let shown = viewport(latitudinalMeters: 400_000)
        #expect(after.revision == before.revision + 1)
        #expect(after.bounds.width <= shown.width / 4)
        #expect(abs(MapClusterPolicy.region(of: after.bounds).centerLatitude - 60.175) < 0.001)
    }

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
        model.applyState(windowState(model, scope: .places, ids: located.map(\.id), map: CatalogMapState(located: located, unlocatedCount: 0)))
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

    /// Loupe on the map (⌘2, the picker, the View menu): the area the map shows, starting
    /// on the stack the user clicked, not on the area's first item.
    @MainActor
    @Test func loupeOnTheMapOpensTheVisibleAreaOnTheClickedStack() {
        let model = makeViewModel()
        model.startMapClustering()
        model.selectSidebar(.places)
        let tallinn = PlaceCoordinate(latitude: 59.44, longitude: 24.75)
        let located = [
            LocatedAsset(id: id("near.jpg"), coordinate: PlaceCoordinate(latitude: 60.171, longitude: 24.941)),
            LocatedAsset(id: id("stack.jpg"), coordinate: Self.helsinki),
            LocatedAsset(id: id("tallinn.jpg"), coordinate: tallinn),
        ]
        model.applyState(windowState(
            model,
            scope: .places,
            ids: located.map(\.id),
            map: CatalogMapState(located: located, unlocatedCount: 0)
        ))
        #expect(!model.canChangeViewMode)
        model.mapViewportChanged(cityViewport())
        #expect(model.canChangeViewMode)
        // A stack click selected these: one in view, one across the gulf.
        model.selectAssets([id("stack.jpg"), id("tallinn.jpg")])

        model.setViewMode(.loupe)

        let area = MapClusterPolicy.area(of: cityViewport())
        #expect(model.queryDescriptor.scope == .mapArea(area))
        #expect(area.contains(Self.helsinki))
        #expect(!area.contains(tallinn))
        #expect(model.sidebarSelection.sidebarRow == .places)
        #expect(model.viewMode == .loupe)
        // The map stays until the area publishes, and a late Places state — the answer to
        // the query before this one — does not undo the chosen mode.
        #expect(model.showsPlacesMap)
        model.applyState(windowState(
            model,
            scope: .places,
            ids: located.map(\.id),
            map: CatalogMapState(located: located, unlocatedCount: 0),
            generation: model.queryGeneration - 1
        ))
        #expect(model.viewMode == .loupe)

        model.applyState(windowState(model, scope: .mapArea(area), ids: [id("near.jpg"), id("stack.jpg")]))

        #expect(!model.showsPlacesMap)
        #expect(model.showsMapAreaLeaf)
        #expect(model.viewMode == .loupe)
        #expect(model.focusedAssetID == id("stack.jpg"))
        #expect(model.gridSelection.selection == [id("stack.jpg")])
    }

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
            map: CatalogMapState(located: located, unlocatedCount: 0)
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
            map: CatalogMapState(located: located, unlocatedCount: 0)
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
            catalogStore: CatalogStore(location: .inMemory, scanCadence: .milliseconds(10)),
            catalogProjection: CatalogProjection(cadence: .milliseconds(10)),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: .suite(UUID().uuidString),
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
            mediaEmptyState: ids.isEmpty ? .noLocatedMedia : .noMedia,
            deviceConnectionBanner: nil,
            map: map,
            queryGeneration: generation ?? model.queryGeneration
        )
    }

    private func cityViewport() -> MapViewport {
        viewport(latitudinalMeters: 20000)
    }

    private func viewport(latitudinalMeters: Double) -> MapViewport {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: Self.helsinki.latitude, longitude: Self.helsinki.longitude),
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
