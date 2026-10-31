import MapKit
import OSLog
import SwiftUI

// Places map guide (ADR 0040, `docs/design/places.md`)
//
// The detail pane for the `.places` scope: a bar stating what is on the map, then the
// map itself with one thumbnail stack per cluster. The view is passive — it renders
// `CatalogMapState` and the ViewModel's clusters and camera request, holds only the
// map's own camera as control state, and reports where the camera settled. MapKit
// types stop at this file: the model speaks in `MapViewport` and `MapRegion`.
//
// No Location Services: the map never asks where the user is, so there is no user
// location control and no permission prompt. The map's tile requests are the one
// network use, as in Photos.

struct PlacesMapView: View {
    let map: CatalogMapState
    let clusters: [MapPlaceCluster]
    let cameraRequest: MapCameraRequest?
    let selection: Set<MediaAssetID>
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            PlacesMapBar(locatedCount: map.located.count, unlocatedCount: map.unlocatedCount)
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
        Map(position: $camera, interactionModes: [.pan, .zoom]) {
            ForEach(clusters) { cluster in
                Annotation("", coordinate: cluster.clCoordinate, anchor: .center) {
                    MapClusterStackView(
                        cluster: cluster,
                        isSelected: cluster.memberIDs.allSatisfy(selection.contains),
                        tileContentStore: tileContentStore,
                        thumbnailDirectory: thumbnailDirectory,
                        detailReader: detailReader
                    )
                    .onTapGesture(count: 2) {
                        onClusterDoubleClick(cluster)
                    }
                    .onTapGesture {
                        onClusterClick(cluster)
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
        .onMapCameraChange(frequency: .onEnd) { context in
            settledRect = context.rect
            reportViewport()
        }
        .onChange(of: cameraRequest?.revision, initial: true) { _, _ in
            applyCameraRequest()
        }
        .accessibilityLabel("Map")
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
            viewHeight: viewSize.height
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
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: request.region.centerLatitude,
                longitude: request.region.centerLongitude
            ),
            span: MKCoordinateSpan(
                latitudeDelta: request.region.latitudeDelta,
                longitudeDelta: request.region.longitudeDelta
            )
        )
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
            camera = .region(region)
        }
    }
}

/// The surface's one fact (DES-010): how much of the collection is on the map, with the
/// count it leaves off as L3. Fixed height in every state (DES-053); digits are
/// monospaced because enrichment moves both numbers while the user watches (DES-005).
private struct PlacesMapBar: View {
    let locatedCount: Int
    let unlocatedCount: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(primary)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(DesignPalette.label(for: colorScheme))
                    .monospacedDigit()
                Text(supporting)
                    .font(.subheadline)
                    .foregroundStyle(DesignPalette.l3(for: colorScheme))
                    .monospacedDigit()
            }
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

    private var supporting: String {
        switch unlocatedCount {
        case 0:
            "Every item has a location"
        case 1:
            "1 item has no location"
        default:
            "\(unlocatedCount.formatted()) items have no location"
        }
    }
}

/// One stack on the map: a 48 pt thumbnail of the representative, the member count at
/// the lower right (DES-062), the selection border of a tile when its members are the
/// selection (DES-061). The thumbnail follows the grid's rule: a placeholder only
/// before it has ever decoded, and once painted it stays for as long as the stack's
/// representative is the same item — which is what the stack's identity is.
private struct MapClusterStackView: View {
    let cluster: MapPlaceCluster
    let isSelected: Bool
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
                .strokeBorder(
                    isSelected ? Color.accentColor : DesignPalette.mapStackEdge,
                    lineWidth: isSelected ? 3 : 2
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MapClusterPolicy.accessibilityLabel(for: cluster))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .task(id: cluster.id) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        if let cached = tileContentStore?.image(for: cluster.id) {
            image = cached
            return
        }
        guard let detailReader else {
            return
        }
        let detail: MediaTileDetail?
        do {
            detail = try await detailReader.detail(for: cluster.id)
        } catch {
            // The placeholder stays; the next stack with this representative reads again.
            OtosLog.ui.errorOperation("map.thumbnail", phase: "detailFailed", fields: [
                "path": cluster.id.relativePath.rawValue,
                "error": String(describing: error),
            ])
            return
        }
        guard let detail, detail.thumbnailPath != nil, !Task.isCancelled else {
            return
        }
        guard let decoded = await MapThumbnailDecode.decode(detail: detail, thumbnailDirectory: thumbnailDirectory),
              !Task.isCancelled
        else {
            return
        }
        tileContentStore?.warm(id: cluster.id, image: decoded, detail: detail)
        image = decoded
    }
}

/// Decodes a stack's thumbnail away from the main actor (ENR-010), through the grid's
/// own loader so the two cannot disagree about where a thumbnail is.
private nonisolated enum MapThumbnailDecode {
    @concurrent
    static func decode(detail: MediaTileDetail, thumbnailDirectory: URL?) async -> CGImage? {
        MediaAssetTilePresentation.decodedThumbnailImage(detail: detail, thumbnailDirectory: thumbnailDirectory)
    }
}

private extension MapPlaceCluster {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}
