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
    /// Whether the detail pane is the Places map rather than a view mode of the grid.
    ///
    /// Read from the published scope, not from `sidebarSelection`: the pane's content
    /// is `state`, and the intent runs ahead of it until Projection publishes. Deciding
    /// the presentation from the intent mounted the grid over the previous scope's
    /// items — entering a place from the map drew all of Places, scrolled to the focus
    /// inside them, then diffed down to the place. The map stays until the place
    /// arrives, as every scope keeps its old content until the new one is ready.
    var showsPlacesMap: Bool {
        state.resolvedSidebarSelection == .places
    }

    /// The Places row, while a fixed library exists, once the catalog has loaded (APP-044).
    var showsPlacesRow: Bool {
        state.isCatalogLoaded && SidebarSelectionPolicy.showsPlaces(libraries: state.libraries)
    }

    /// Whether the picker and ⌘1/2/3 act. The duplicates list has one presentation, so
    /// they are disabled there (DES-053: disabled, never removed). On the map they open the
    /// area it shows (`openVisibleMapArea`), so they wait for the map to be on screen and
    /// to have reported where it is; a viewport kept from an earlier visit is not one.
    /// Read from the intent, unlike `showsPlacesMap`: opening a group or an area in Compare
    /// or Loupe changes the scope and then the mode, before Projection publishes the scope.
    var canChangeViewMode: Bool {
        switch sidebarSelection {
        case .duplicates, .people, .peopleReview: false
        case .places: showsPlacesMap && mapViewport != nil
        default: true
        }
    }

    /// Whether Back to Map applies: the browser shows an area under the map.
    var showsMapAreaLeaf: Bool {
        if case .mapArea = sidebarSelection {
            return true
        }
        return false
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
        if entered, previous.resolvedSidebarSelection.sidebarRow == .places, let viewport = mapViewport {
            // Back from a place: the map the user left.
            requestMapCamera(MapClusterPolicy.bounds(of: viewport), reason: "return")
        } else if entered || filterChanged || firstLocated {
            let reason = entered ? "enter" : (filterChanged ? "filter" : "firstLocated")
            requestFit(map.located, reason: reason, padded: true)
        }
        if previous.map != next.map || entered {
            requestMapClusters()
        }
    }

    /// Asks for the camera that shows every located item, and remembers the ask so the
    /// viewport that follows it can be checked (`mapViewportChanged`).
    private func requestFit(_ located: [LocatedAsset], reason: String, padded: Bool, atLeast: MapBounds? = nil) {
        guard var bounds = MapClusterPolicy.fittingBounds(located.map(\.coordinate), padded: padded) else {
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
    /// whatever margin fits is kept. A miss after that is logged and left — the items
    /// are where they are, and the map shows what it can.
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
            requestFit(map.located, reason: "refit", padded: false, atLeast: shown)
        } else {
            mapPendingFit = nil
        }
    }

    /// Single click: the stack's members become the selection, as a click on a tile
    /// would, so Info, Share and the Photo menu act on them.
    func selectMapCluster(_ cluster: MapPlaceCluster) {
        selectAssets(cluster.memberIDs)
    }

    /// Double-click: a stack that can still be split zooms the map into it; a stack
    /// whose members share one coordinate, which no zoom can split, opens that coordinate
    /// as the grid.
    func activateMapCluster(_ cluster: MapPlaceCluster) {
        if cluster.isExactPlace {
            openMapArea(.point(cluster.coordinate), mode: .grid, reason: "stack")
            return
        }
        guard let viewport = mapViewport, let map = state.map else {
            return
        }
        let members = Set(cluster.memberIDs)
        let coordinates = map.located.filter { members.contains($0.id) }.map(\.coordinate)
        requestMapCamera(
            MapClusterPolicy.zoomBounds(into: cluster, members: coordinates, viewport: viewport),
            reason: "cluster"
        )
    }

    /// View ▸ Zoom In / Zoom Out on the map: one step about the center.
    func zoomMap(by factor: Double) {
        guard let viewport = mapViewport else {
            return
        }
        requestMapCamera(MapClusterPolicy.scaledBounds(of: viewport, by: factor), reason: "step")
    }

    /// Grid, Loupe or Compare on the map — the picker, ⌘1/2/3 and the View menu alike:
    /// the area the map shows, in that mode.
    func openVisibleMapArea(mode: BrowserViewMode) {
        guard showsPlacesMap, let viewport = mapViewport else {
            return
        }
        openMapArea(MapClusterPolicy.area(of: viewport), mode: mode, reason: "visible")
    }

    /// The items in one box of the map, in a view mode. Not a sidebar row: the sidebar
    /// keeps Places highlighted (`SidebarSelection.sidebarRow`). The selection made on the
    /// map — a clicked stack — carries into the area as far as it lies inside it, so Loupe
    /// and Compare start on it; with none, they start on the area's first items. The mode
    /// is set now and its focus settles when the area publishes, because the pane keeps
    /// showing the map until then (`showsPlacesMap`).
    func openMapArea(_ area: MapArea, mode: BrowserViewMode, reason: String) {
        let located = state.map?.located ?? []
        let selected = gridSelection.selection
        let entry = located.filter { selected.contains($0.id) && area.contains($0.coordinate) }.map(\.id)
        userHasChosenSource = true
        OtosLog.ui.noticeOperation("map.area", phase: "enter", fields: [
            "area": area.diagnosticDescription,
            "mode": mode.rawValue,
            "reason": reason,
            "entrySelection": "\(entry.count)",
        ])
        setQueryDescriptor(CatalogQueryDescriptor(
            scope: .mapArea(area),
            filter: queryDescriptor.filter,
            sort: queryDescriptor.sort,
            search: queryDescriptor.search
        ))
        scopeEntrySelection = (queryGeneration, entry)
        enterModeForOpeningScope(mode)
    }

    /// Back to Map from an area; the map returns to the viewport it was left at.
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

/// The off-MainActor step of the cluster lane: pure arithmetic over values, run away
/// from the actor so a large library's pass never lands on the main thread.
nonisolated enum MapClusterLane {
    @concurrent
    static func clusters(located: [LocatedAsset], viewport: MapViewport) async -> [MapPlaceCluster] {
        MapClusterPolicy.clusters(located: located, viewport: viewport)
    }
}
