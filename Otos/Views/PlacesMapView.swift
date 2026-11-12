import AppKit
import MapKit
import SwiftUI

// Places map guide (ADR 0040, `docs/design/places.md`)
//
// The detail pane for the `.places` scope: a bar stating what is on the map, then the
// map itself with one thumbnail stack per cluster. The view is passive — it renders
// `CatalogMapState` and the ViewModel's clusters and camera request, holds only the
// map's own camera as control state, and reports where the camera settled. MapKit
// types stop at this file: the model speaks in `MapViewport` and `MapBounds`.
//
// No Location Services: the map never asks where the user is, so there is no user
// location control and no permission prompt. The map's tile requests are the one
// network use, as in Photos.

struct PlacesMapView: View {
    let map: CatalogMapState
    let clusters: [MapPlaceCluster]
    let cameraRequest: MapCameraRequest?
    let emptyState: CatalogMediaEmptyState
    var tileContentStore: TileContentStore?
    var thumbnailDirectory: URL?
    var detailReader: MediaTileDetailReader?
    let onViewportChanged: (MapViewport) -> Void
    let onClusterClick: (MapPlaceCluster) -> Void
    let onClusterDoubleClick: (MapPlaceCluster) -> Void
    var clearFilters: () -> Void = {}
    @State private var camera: MapCameraPosition = .automatic
    @State private var appliedCameraRevision: UInt64 = 0
    @State private var viewSize: CGSize = .zero
    @State private var settledRect: MKMapRect?
    /// Where the camera's center may go: follows the visible height while the camera
    /// moves, so the map stops at the poles at every zoom (`cameraCenterBounds`).
    @State private var centerBounds = MapClusterPolicy.cameraCenterBounds(visibleHeight: 0)
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            PlacesMapBar(locatedCount: map.located.count)
            if map.located.isEmpty {
                CatalogMediaEmptyStateView(emptyState: emptyState, clearFilters: clearFilters)
                    .background(DesignPalette.content(for: colorScheme))
            } else {
                mapContent
            }
        }
        .navigationTitle("Places")
    }

    private var mapContent: some View {
        Map(position: $camera, bounds: cameraBounds, interactionModes: [.pan, .zoom]) {
            ForEach(clusters) { cluster in
                Annotation("", coordinate: cluster.clCoordinate, anchor: .center) {
                    MapClusterStackView(
                        cluster: cluster,
                        tileContentStore: tileContentStore,
                        thumbnailDirectory: thumbnailDirectory,
                        detailReader: detailReader
                    )
                    // One gesture, AppKit's click count deciding: a click zooms at once, and
                    // the second click of a double-click opens. A SwiftUI double-tap beside a
                    // single tap would hold every click back until no second one came.
                    .onTapGesture {
                        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                            onClusterDoubleClick(cluster)
                        } else {
                            onClusterClick(cluster)
                        }
                    }
                    .accessibilityAction(named: "Show Photos") {
                        onClusterDoubleClick(cluster)
                    }
                }
                .annotationTitles(.hidden)
            }
        }
        // Standard style follows the appearance; points of interest are excluded so the
        // photographs, not shops, carry the map (DES-104 [deviation]).
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls {
            MapZoomStepper()
            MapScaleView()
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            viewSize = size
            reportViewport()
        }
        // MapKit bounds only the camera's center, and how far the center may go depends
        // on how tall the view is in map points, so the bound follows every frame of a
        // zoom; a pan leaves the height, and so the bound, unchanged.
        .onMapCameraChange(frequency: .continuous) { context in
            centerBounds = MapClusterPolicy.cameraCenterBounds(visibleHeight: context.rect.size.height)
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            settledRect = context.rect
            reportViewport()
        }
        .onChange(of: cameraRequest?.revision, initial: true) { _, _ in
            applyCameraRequest()
        }
        .accessibilityLabel("Map")
    }

    private var cameraBounds: MapCameraBounds {
        MapCameraBounds(centerCoordinateBounds: MKMapRect(
            x: centerBounds.originX,
            y: centerBounds.originY,
            width: centerBounds.width,
            height: centerBounds.height
        ))
    }

    private func reportViewport() {
        guard let rect = settledRect, viewSize.width > 0, viewSize.height > 0 else {
            return
        }
        onViewportChanged(MapViewport(
            originX: rect.origin.x,
            originY: rect.origin.y,
            width: rect.size.width,
            height: rect.size.height,
            viewWidth: viewSize.width,
            viewHeight: viewSize.height,
            cameraRevision: appliedCameraRevision
        ))
    }

    /// Adopts a camera the ViewModel asked for, once per request. A flight is content
    /// moving into place (DES-070: 0.25 s ease-out); under Reduce Motion it snaps
    /// (DES-075).
    private func applyCameraRequest() {
        guard let request = cameraRequest, request.revision != appliedCameraRevision else {
            return
        }
        appliedCameraRevision = request.revision
        let rect = MKMapRect(
            x: request.bounds.originX,
            y: request.bounds.originY,
            width: request.bounds.width,
            height: request.bounds.height
        )
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
            camera = .rect(rect)
        }
    }
}

/// The surface's one fact (DES-010): how much of the collection is on the map. Fixed
/// height in every state (DES-053); digits are monospaced because enrichment moves the
/// number while the user watches (DES-005).
private struct PlacesMapBar: View {
    let locatedCount: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            Text(primary)
                .font(.title3.weight(.semibold))
                .foregroundStyle(DesignPalette.label(for: colorScheme))
                .monospacedDigit()
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(DesignPalette.bar(for: colorScheme))
        .overlay(alignment: .bottom) {
            DesignPalette.hairline(for: colorScheme).frame(height: 1)
        }
    }

    private var primary: String {
        let count = locatedCount.formatted()
        return locatedCount == 1 ? "1 item on the map" : "\(count) items on the map"
    }
}

/// One stack on the map: a 48 pt thumbnail of the representative, the member count at
/// the lower right (DES-062), and a white edge. The map has no selection. The thumbnail follows the grid's rule: a placeholder only
/// before it has ever decoded, and once painted it stays for as long as the stack's
/// representative is the same item — which is what the stack's identity is.
private struct MapClusterStackView: View {
    let cluster: MapPlaceCluster
    let tileContentStore: TileContentStore?
    let thumbnailDirectory: URL?
    let detailReader: MediaTileDetailReader?
    @State private var image: CGImage?
    @Environment(\.colorScheme) private var colorScheme

    private static let edge: CGFloat = 48

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Rectangle()
                .fill(DesignPalette.bar(for: colorScheme))
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.edge, height: Self.edge)
            } else {
                // DES-063: the kind glyph at tertiary strength, no spinner.
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            }
            if cluster.count > 1, image != nil {
                Text("\(cluster.count)")
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(DesignPalette.badgeLabel)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(DesignPalette.badge, in: RoundedRectangle(cornerRadius: 3))
                    .padding(2)
            }
        }
        .frame(width: Self.edge, height: Self.edge)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(DesignPalette.mapStackEdge, lineWidth: 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MapClusterPolicy.accessibilityLabel(for: cluster))
        .accessibilityAddTraits(.isButton)
        .task(id: cluster.id) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        // The placeholder stays when nothing decodes; the next stack with this
        // representative reads again.
        guard let decoded = await ThumbnailLoad.image(
            for: cluster.id,
            tileContentStore: tileContentStore,
            thumbnailDirectory: thumbnailDirectory,
            detailReader: detailReader,
            operation: "map.thumbnail"
        ) else {
            return
        }
        image = decoded
    }
}

private extension MapPlaceCluster {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}
