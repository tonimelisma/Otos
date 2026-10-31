import Foundation
import OSLog

// Places map intents and the cluster lane (ADR 0040)
//
// The `.places` scope is published like every other scope — Projection delivers the
// located items in display order on `CatalogWindowState.map` — and this file owns what
// is specific to drawing them as a map: the viewport the map reports, the camera the
// map is asked to adopt, the stacks for that viewport, and the two navigation intents
// (into a place, back to the map).
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
    var showsPlacesMap: Bool {
        sidebarSelection == .places
    }

    /// The map has one presentation, so the view-mode picker and ⌘1/2/3 are disabled
    /// while it shows (DES-053: disabled, never removed).
    var canChangeViewMode: Bool {
        !showsPlacesMap
    }

    /// Whether Back to Map applies: the grid shows one place under the map.
    var showsPlaceLeaf: Bool {
        if case .place = sidebarSelection {
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
            OtosLog.ui.noticeOperation("map.cluster", phase: "finish", fields: [
                "located": "\(map.located.count)",
                "clusters": "\(clusters.count)",
                "ms": "\(DiagnosticsTiming.milliseconds(since: started))",
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
        // another scope has nothing to show here.
        if viewMode != .grid {
            exitToGrid()
        }
        let entered = previous.resolvedSidebarSelection != .places || previous.map == nil
        let filterChanged = previous.mediaGrid.descriptor.filter != next.mediaGrid.descriptor.filter
        let firstLocated = (previous.map?.located.isEmpty ?? true) && !map.located.isEmpty
        if entered, previous.resolvedSidebarSelection.sidebarRow == .places, let viewport = mapViewport {
            // Back from a place: the map the user left.
            requestMapCamera(MapClusterPolicy.region(of: viewport), reason: "return")
        } else if entered || filterChanged || firstLocated {
            if let region = MapClusterPolicy.fittingRegion(map.located.map(\.coordinate)) {
                requestMapCamera(region, reason: entered ? "enter" : (filterChanged ? "filter" : "firstLocated"))
            }
        }
        if previous.map != next.map || entered {
            requestMapClusters()
        }
    }

    private func requestMapCamera(_ region: MapRegion, reason: String) {
        mapCameraRevision &+= 1
        mapCameraRequest = MapCameraRequest(revision: mapCameraRevision, region: region)
        OtosLog.ui.noticeOperation("map.camera", phase: "request", fields: [
            "reason": reason,
            "revision": "\(mapCameraRevision)",
            "latitudeDelta": String(format: "%.4f", region.latitudeDelta),
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
    }

    /// Single click: the stack's members become the selection, as a click on a tile
    /// would, so Info, Share and the Photo menu act on them.
    func selectMapCluster(_ cluster: MapPlaceCluster) {
        selectAssets(cluster.memberIDs)
    }

    /// Double-click: a stack that can still be split zooms the map into it; a stack
    /// whose members share one coordinate opens that place as a grid.
    func activateMapCluster(_ cluster: MapPlaceCluster) {
        if cluster.isExactPlace {
            enterPlace(cluster.coordinate)
            return
        }
        guard let viewport = mapViewport, let map = state.map else {
            return
        }
        let members = Set(cluster.memberIDs)
        let coordinates = map.located.filter { members.contains($0.id) }.map(\.coordinate)
        requestMapCamera(
            MapClusterPolicy.zoomRegion(into: cluster, members: coordinates, viewport: viewport),
            reason: "cluster"
        )
    }

    /// View ▸ Zoom In / Zoom Out on the map: one step about the center.
    func zoomMap(by factor: Double) {
        guard let viewport = mapViewport else {
            return
        }
        requestMapCamera(MapClusterPolicy.scaledRegion(of: viewport, by: factor), reason: "step")
    }

    /// The items at exactly one coordinate, as the ordinary grid. Not a sidebar row:
    /// the sidebar keeps Places highlighted (`SidebarSelection.sidebarRow`).
    func enterPlace(_ coordinate: PlaceCoordinate) {
        userHasChosenSource = true
        OtosLog.ui.noticeOperation("map.place", phase: "enter", fields: [
            "coordinate": coordinate.diagnosticDescription,
        ])
        setQueryDescriptor(CatalogQueryDescriptor(
            scope: .place(coordinate),
            filter: queryDescriptor.filter,
            sort: queryDescriptor.sort
        ))
    }

    /// Back to Map from a place; the map returns to the viewport it was left at.
    func returnToPlaces() {
        guard showsPlaceLeaf else {
            return
        }
        OtosLog.ui.noticeOperation("map.place", phase: "return")
        setQueryDescriptor(CatalogQueryDescriptor(
            scope: .places,
            filter: queryDescriptor.filter,
            sort: queryDescriptor.sort
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
