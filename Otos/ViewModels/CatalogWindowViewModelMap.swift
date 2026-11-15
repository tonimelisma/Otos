import Foundation
import OSLog

// Places map intents and the cluster lane (ADR 0040)
//
// The `.places` scope is published like every other scope — Projection delivers the
// located items in display order on `CatalogWindowState.map` — and this file owns what
// is specific to drawing them as a map: the viewport the map reports, the camera the
// map is asked to adopt, the stacks for that viewport, and the navigation intents
// (into an area of the map in a view mode, back to the map).
//
// Clustering runs on its own lane, not in Projection, because its second input is the
// viewport, which changes with every pan and zoom and is window state rather than
// catalog state. The lane follows ADR 0032: `mapClusterRequested` counts requests,
// `mapClusterCovered` what the newest finished pass started from, and one loop runs
// passes until they meet; the pass reads its inputs as values, leaves the actor for
// the arithmetic, and assigns the result synchronously. A newer request never cancels
// a pass; the loop simply runs again. Cancellation is for teardown only.

extension CatalogWindowViewModel {
    /// Whether the detail pane draws the Places map, with its state applied, rather than a
    /// view mode of the grid.
    ///
    /// The pane follows the intent (`detailPane`, DES-118) but draws a surface's content only
    /// with that scope's state: mounting the grid or the map over the previous scope's items
    /// drew them under the new scope's name — entering a place from the map drew all of
    /// Places, scrolled to the focus inside them, then diffed down to the place. Until the
    /// state arrives the pane draws the selected surface waiting, with nothing of either.
    var showsPlacesMap: Bool {
        detailPane.shows(.placesMap)
    }

    /// The Places row, while a fixed library exists, once the catalog has loaded (APP-044).
    var showsPlacesRow: Bool {
        state.isCatalogLoaded && SidebarSelectionPolicy.showsPlaces(libraries: state.libraries)
    }

    /// Whether the picker shows the view mode selected: the map and On This Day are not view
    /// modes, so no segment is, from the click that selects them on (DES-118).
    var showsViewModeSegment: Bool {
        detailPane.surface != .placesMap && detailPane.surface != .onThisDay
    }

    /// Whether the picker and ⌘1/2/3 act. The duplicates list has one presentation, so
    /// they are disabled there (DES-053: disabled, never removed). On the map they open the
    /// area it shows (`openVisibleMapArea`), so they wait for the map to be on screen and
    /// to have reported where it is; a viewport kept from an earlier visit is not one.
    /// Read from the intent, unlike `showsPlacesMap`: opening a group or an area in Compare
    /// or Loupe changes the scope and then the mode, before Projection publishes the scope.
    /// On This Day's years and its story are that scope's one presentation (ADR 0049).
    var canChangeViewMode: Bool {
        switch sidebarSelection {
        case .duplicates, .onThisDay, .people: false
        case .places: showsPlacesMap && mapViewport != nil
        default: true
        }
    }

    /// Whether Back to Map applies: the browser shows an area or a stack under the map.
    var showsMapAreaLeaf: Bool {
        switch sidebarSelection {
        case .mapArea, .mapStack: true
        default: false
        }
    }

    // MARK: - Lane

    func startMapClustering() {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        mapClusterContinuation = continuation
        mapClusterTask = Task { [weak self] in
            for await _ in stream {
                guard let self else {
                    return
                }
                await runMapClusterPasses()
            }
        }
    }

    private func requestMapClusters() {
        mapClusterRequested &+= 1
        mapClusterContinuation?.yield()
    }

    /// Runs passes until the newest request is covered. Each pass covers the value it
    /// started from; a request that arrives mid-pass makes the loop go again.
    private func runMapClusterPasses() async {
        while mapClusterRequested != mapClusterCovered {
            let startedFrom = mapClusterRequested
            guard let viewport = mapViewport, let map = state.map else {
                mapClusterCovered = startedFrom
                mapClusters = []
                continue
            }
            let started = ContinuousClock.now
            let clusters = await MapClusterLane.clusters(located: map.located, viewport: viewport)
            guard !Task.isCancelled else {
                return
            }
            mapClusterCovered = startedFrom
            mapClusters = clusters
            let region = MapClusterPolicy.region(of: viewport)
            OtosLog.ui.noticeOperation("map.cluster", phase: "finish", fields: [
                "located": "\(map.located.count)",
                "clusters": "\(clusters.count)",
                "exact": "\(clusters.filter(\.isExactPlace).count)",
                "ms": "\(DiagnosticsTiming.milliseconds(since: started))",
                "center": String(format: "%.2f,%.2f", region.centerLatitude, region.centerLongitude),
                "span": String(format: "%.2fx%.2f", region.latitudeDelta, region.longitudeDelta),
                "view": String(format: "%.0fx%.0f", viewport.viewWidth, viewport.viewHeight),
                "stacks": clusters.prefix(8).map { cluster in
                    let point = MapClusterPolicy.viewPoint(of: cluster.coordinate, in: viewport)
                    return String(format: "%d@%.0f,%.0f", cluster.count, point.x, point.y)
                }.joined(separator: " "),
            ])
        }
    }

    // MARK: - State apply

    /// Called from `applyState` after `state` is assigned. Decides what the arrival of
    /// a new state means for the map: a mode the map cannot show, a camera to adopt,
    /// stacks to recompute.
    func applyMapState(previous: CatalogWindowState, next: CatalogWindowState) {
        guard next.resolvedSidebarSelection == .places, let map = next.map else {
            if !mapClusters.isEmpty {
                mapClusters = []
            }
            return
        }
        // The map is the scope's one presentation: a loupe or compare left open in
        // another scope has nothing to show here. Not while an area is already chosen: a
        // mode just entered for it waits for that area to publish, and this state is the
        // map it was chosen from.
        if viewMode != .grid, queryDescriptor.scope == .places {
            exitToGrid()
        }
        let entered = previous.resolvedSidebarSelection != .places || previous.map == nil
        let filterChanged = previous.mediaGrid.descriptor.filter != next.mediaGrid.descriptor.filter
        let firstLocated = (previous.map?.located.isEmpty ?? true) && !map.located.isEmpty
        let leftViewport = entered ? mapLeftViewport : nil
        if entered {
            mapLeftViewport = nil
            // A click made before the map was left belongs to no gesture on this one.
            mapStackClick = nil
        }
        if entered, previous.resolvedSidebarSelection.sidebarRow == .places, let viewport = leftViewport ?? mapViewport {
            // Back from a place: the map the user left, not one a flight reported after.
            requestMapCamera(MapClusterPolicy.bounds(of: viewport), reason: "return")
        } else if entered || filterChanged || firstLocated {
            let reason = entered ? "enter" : (filterChanged ? "filter" : "firstLocated")
            requestCenteredFit(map.located, reason: reason, padded: true)
        }
        if previous.map != next.map || entered {
            requestMapClusters()
        }
    }

    /// Asks for the camera centered on the located items' average location and reaching
    /// all of them (`MapClusterPolicy.centeredBounds`), and remembers the ask so the
    /// viewport that follows it can be checked (`mapViewportChanged`).
    private func requestCenteredFit(_ located: [LocatedAsset], reason: String, padded: Bool, atLeast: MapBounds? = nil) {
        guard var bounds = MapClusterPolicy.centeredBounds(located.map(\.coordinate), padded: padded) else {
            return
        }
        if let atLeast {
            bounds = MapClusterPolicy.expanded(bounds, toAtLeast: atLeast)
        }
        requestMapCamera(bounds, reason: reason)
        mapPendingFit = (mapCameraRevision, padded)
    }

    private func requestMapCamera(_ bounds: MapBounds, reason: String) {
        mapCameraRevision &+= 1
        mapCameraRequest = MapCameraRequest(revision: mapCameraRevision, bounds: bounds)
        let region = MapClusterPolicy.region(of: bounds)
        OtosLog.ui.noticeOperation("map.camera", phase: "request", fields: [
            "reason": reason,
            "revision": "\(mapCameraRevision)",
            "center": String(format: "%.2f,%.2f", region.centerLatitude, region.centerLongitude),
            "span": String(format: "%.2fx%.2f", region.latitudeDelta, region.longitudeDelta),
        ])
    }

    // MARK: - Intents

    /// The map reports where it settled (pan or zoom end, and its first layout). Only
    /// the newest viewport matters, so this is a plain assignment plus one request.
    func mapViewportChanged(_ viewport: MapViewport) {
        guard viewport != mapViewport else {
            return
        }
        mapViewport = viewport
        requestMapClusters()
        checkPendingFit(against: viewport)
    }

    /// A fit is a promise the map may not keep: MapKit clamps a camera past its zoom-out
    /// (measured 2026-10-31: about 153° of longitude at a 1232 pt map, where a
    /// two-continent library with its margin asks for 209°). The viewport that followed
    /// the fit's own request says whether it held; if not, the fit is asked once more
    /// without its margin but grown to the camera the map just proved it can show, so
    /// whatever margin fits is kept. A miss after that is logged and left: the camera
    /// stays centered on the items' average location and shows what it can.
    private func checkPendingFit(against viewport: MapViewport) {
        guard let pending = mapPendingFit, viewport.cameraRevision == pending.revision, let map = state.map else {
            return
        }
        let shown = MapClusterPolicy.bounds(of: viewport)
        let onePoint = viewport.width / viewport.viewWidth
        let outside = map.located.filter {
            !MapClusterPolicy.contains($0.coordinate, in: shown, tolerance: onePoint)
        }.count
        if outside == 0 {
            mapPendingFit = nil
            return
        }
        OtosLog.ui.noticeOperation("map.camera", phase: pending.padded ? "refit" : "unfit", fields: [
            "revision": "\(pending.revision)",
            "outside": "\(outside)",
        ])
        if pending.padded {
            requestCenteredFit(map.located, reason: "refit", padded: false, atLeast: shown)
        } else {
            mapPendingFit = nil
        }
    }

    /// A click on a stack drills in, as a click on a cluster does on every map: a stack that
    /// can still be split zooms the map into it; one whose members share a coordinate, which
    /// no zoom can split, opens (`openMapCluster`). The map has no selection. The click is
    /// remembered as the gesture a second click of a double-click continues
    /// (`mapMouseDown(clickCount:)`).
    func clickMapCluster(_ cluster: MapPlaceCluster) {
        if cluster.isExactPlace {
            openMapCluster(cluster, leaving: mapViewport)
            mapStackClick = .opened
            return
        }
        guard let viewport = mapViewport, let map = state.map else {
            mapStackClick = nil
            return
        }
        OtosLog.ui.noticeOperation("map.stack", phase: "zoom", fields: ["count": "\(cluster.count)"])
        let members = Set(cluster.memberIDs)
        let coordinates = map.located.filter { members.contains($0.id) }.map(\.coordinate)
        requestMapCamera(
            MapClusterPolicy.zoomBounds(into: cluster, members: coordinates, viewport: viewport),
            reason: "cluster"
        )
        mapStackClick = .zoomed(cluster, from: viewport)
    }

    /// A mouse-down anywhere in the map, seen before MapKit or any stack hit-tests it, with
    /// AppKit's click count. A double-click is one gesture, so its second click belongs to
    /// the stack its first click acted on, wherever the first click's flight has since moved
    /// that stack: it opens that stack — exactly the items it counted, leaving the map that
    /// click zoomed from — or, when the first click already opened it, does nothing more.
    /// Returns true when the click is that gesture's, which then reaches nothing under the
    /// pointer: not another stack the flight slid there, not MapKit's own double-click zoom.
    /// A click with a count of one starts a new gesture.
    func mapMouseDown(clickCount: Int) -> Bool {
        guard clickCount > 1 else {
            mapStackClick = nil
            return false
        }
        guard let click = mapStackClick else {
            return false
        }
        switch click {
        case let .zoomed(cluster, from):
            OtosLog.ui.noticeOperation("map.stack", phase: "doubleClick", fields: [
                "count": "\(cluster.count)", "clickCount": "\(clickCount)",
            ])
            openMapCluster(cluster, leaving: from)
        case .opened:
            break
        }
        mapStackClick = .opened
        return true
    }

    /// VoiceOver's `Show Photos` on a stack: exactly the items it counted, as the grid. Back
    /// returns to the map as it is now.
    func openMapCluster(_ cluster: MapPlaceCluster) {
        mapStackClick = nil
        openMapCluster(cluster, leaving: mapViewport)
    }

    private func openMapCluster(_ cluster: MapPlaceCluster, leaving viewport: MapViewport?) {
        // A stack on a map the user has already left belongs to no scope they chose.
        guard showsSelectedScope else {
            return
        }
        mapLeftViewport = viewport
        userHasChosenSource = true
        OtosLog.ui.noticeOperation("map.stack", phase: "open", fields: ["count": "\(cluster.count)"])
        setQueryDescriptor(CatalogQueryDescriptor(
            scope: .mapStack(MapStack(members: cluster.memberIDs)),
            filter: queryDescriptor.filter,
            sort: queryDescriptor.sort,
            search: queryDescriptor.search
        ))
        enterModeForOpeningScope(.grid)
    }

    /// View ▸ Zoom In / Zoom Out on the map: one step about the center.
    func zoomMap(by factor: Double) {
        guard let viewport = mapViewport else {
            return
        }
        requestMapCamera(MapClusterPolicy.scaledBounds(of: viewport, by: factor), reason: "step")
    }

    /// Grid, Loupe or Compare on the map — the picker, ⌘1/2/3 and the View menu alike: the
    /// area the map shows, in that mode. Not a sidebar row: the sidebar keeps Places
    /// highlighted (`SidebarSelection.sidebarRow`). Loupe and Compare start on the area's
    /// first items. The mode is set now and its focus settles when the area publishes,
    /// because the pane keeps showing the map until then (`showsPlacesMap`).
    func openVisibleMapArea(mode: BrowserViewMode) {
        guard showsPlacesMap, showsSelectedScope, let viewport = mapViewport else {
            return
        }
        let area = MapClusterPolicy.area(of: viewport)
        mapStackClick = nil
        mapLeftViewport = viewport
        userHasChosenSource = true
        OtosLog.ui.noticeOperation("map.area", phase: "enter", fields: [
            "area": area.diagnosticDescription,
            "mode": mode.rawValue,
        ])
        setQueryDescriptor(CatalogQueryDescriptor(
            scope: .mapArea(area),
            filter: queryDescriptor.filter,
            sort: queryDescriptor.sort,
            search: queryDescriptor.search
        ))
        enterModeForOpeningScope(mode)
    }

    /// Back to Map from an area or a stack; the map returns to the viewport it was left at.
    func returnToPlaces() {
        guard showsMapAreaLeaf else {
            return
        }
        OtosLog.ui.noticeOperation("map.area", phase: "return")
        setQueryDescriptor(CatalogQueryDescriptor(
            scope: .places,
            filter: queryDescriptor.filter,
            sort: queryDescriptor.sort,
            search: queryDescriptor.search
        ))
    }
}

/// What the newest click on a stack did (`CatalogWindowViewModel.mapStackClick`).
nonisolated enum MapStackClick {
    /// It zoomed the map into this stack from `from`, the map Back returns to once a second
    /// click opens it.
    case zoomed(MapPlaceCluster, from: MapViewport)
    /// It opened its stack, or a second click already has: the gesture has nothing left to do.
    case opened
}

/// The off-MainActor step of the cluster lane: pure arithmetic over values, run away
/// from the actor so a large library's pass never lands on the main thread.
nonisolated enum MapClusterLane {
    @concurrent
    static func clusters(located: [LocatedAsset], viewport: MapViewport) async -> [MapPlaceCluster] {
        MapClusterPolicy.clusters(located: located, viewport: viewport)
    }
}
