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
    let emptyState: CatalogMediaEmptyState?
    var tileContentStore: TileContentStore?
    var thumbnailDirectory: URL?
    var detailReader: MediaTileDetailReader?
    let onViewportChanged: (MapViewport) -> Void
    let onClusterClick: (MapPlaceCluster) -> Void
    /// Every mouse-down in the map with AppKit's click count, before anything under the
    /// pointer sees it; true when the owner takes the click (`mapMouseDown(clickCount:)`).
    let onMouseDown: (Int) -> Bool
    let onClusterOpen: (MapPlaceCluster) -> Void
    var clearFilters: () -> Void = {}
    @State private var camera: MapCameraPosition = .automatic
    @State private var appliedCameraRevision: UInt64 = 0
    @State private var viewSize: CGSize = .zero
    @State private var settledRect: MKMapRect?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            PlacesMapBar(locatedCount: map.located.count)
            if map.located.isEmpty {
                if let emptyState {
                    CatalogMediaEmptyStateView(emptyState: emptyState, clearFilters: clearFilters)
                        .background(DesignPalette.content(for: colorScheme))
                }
            } else {
                mapContent
            }
        }
    }

    private var mapContent: some View {
        Map(position: $camera, interactionModes: [.pan, .zoom]) {
            ForEach(clusters) { cluster in
                Annotation("", coordinate: cluster.clCoordinate, anchor: .center) {
                    MapClusterStackView(
                        cluster: cluster,
                        tileContentStore: tileContentStore,
                        thumbnailDirectory: thumbnailDirectory,
                        detailReader: detailReader
                    )
                    // A click acts at once, on the stack under it. The second click of a
                    // double-click is not this stack's to take: the map's mouse-down monitor
                    // hands it to the stack the first click acted on (`MapMouseDownMonitor`),
                    // and a later click AppKit counts as a gesture begun elsewhere — on bare
                    // map, before this stack slid under the pointer — acts on nothing here. A
                    // SwiftUI double-tap beside a single tap would hold every click back until
                    // no second one came.
                    .onTapGesture {
                        guard Self.currentClickCount == 1 else { return }
                        onClusterClick(cluster)
                    }
                    .accessibilityAction(named: "Show Photos") {
                        onClusterOpen(cluster)
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
        // The pan band is held where a camera settles, not by `MapCameraBounds`: with any
        // bound MapKit's pan stops a center at the antimeridian going east, though it wraps
        // going west (measured 2026-11-13).
        .onMapCameraChange(frequency: .onEnd) { context in
            settledRect = context.rect
            reportViewport()
            keepInsidePanBand()
        }
        .onChange(of: map.panBand) { _, _ in
            keepInsidePanBand()
        }
        .onChange(of: cameraRequest?.revision, initial: true) { _, _ in
            applyCameraRequest()
        }
        .background(MapMouseDownMonitor(onMouseDown: onMouseDown))
        .accessibilityLabel("Map")
    }

    /// AppKit's click count for the mouse event a tap answers; 1 for a press with no mouse
    /// event behind it (VoiceOver), since `clickCount` is defined only on mouse events.
    private static var currentClickCount: Int {
        guard let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp].contains(event.type) else {
            return 1
        }
        return event.clickCount
    }

    /// Eases a camera that settled past the pan band back inside it, at the same zoom:
    /// content moving into place (DES-070: 0.25 s ease-out), a snap under Reduce Motion
    /// (DES-075). The settle that follows reports the viewport inside the band.
    private func keepInsidePanBand() {
        guard let rect = settledRect,
              let inside = MapClusterPolicy.keptInside(
                  MapBounds(
                      originX: rect.origin.x,
                      originY: rect.origin.y,
                      width: rect.size.width,
                      height: rect.size.height
                  ),
                  band: map.panBand
              )
        else {
            return
        }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
            camera = .rect(MKMapRect(x: inside.originX, y: inside.originY, width: inside.width, height: inside.height))
        }
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

/// The facts of one left mouse-down the map's monitor saw, and the decision whether the map
/// hands it to `mapMouseDown(clickCount:)`: a pure function of those facts, so the monitor
/// is only the hop from AppKit. Any other event is no mouse-down here, and its click count
/// is never read: `clickCount` raises on an event that is not a mouse event.
nonisolated struct MapMouseDown: Equatable, Sendable {
    let windowNumber: Int
    /// In the window's coordinates.
    let location: NSPoint
    let clickCount: Int

    init?(_ event: NSEvent) {
        guard event.type == .leftMouseDown else { return nil }
        windowNumber = event.windowNumber
        location = event.locationInWindow
        clickCount = event.clickCount
    }

    /// The click count to hand the map, when the press is in window `number` inside
    /// `frame` (the map's frame in that window's coordinates); nil when it is elsewhere.
    func clickCount(inWindow number: Int, frame: NSRect) -> Int? {
        guard windowNumber == number, frame.contains(location) else { return nil }
        return clickCount
    }
}

/// AppKit's click count for every mouse-down inside the map, delivered before MapKit or a
/// stack hit-tests it, so a double-click is routed as one gesture rather than by whatever the
/// first click's camera flight moved under the pointer. SwiftUI offers neither the count nor
/// a look at a click before the view under it; a local event monitor offers both. The view
/// draws nothing and takes no click itself (`hitTest` is nil); the monitor lives exactly as
/// long as the view is in a window.
private struct MapMouseDownMonitor: NSViewRepresentable {
    let onMouseDown: (Int) -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onMouseDown = onMouseDown
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onMouseDown = onMouseDown
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class MonitorView: NSView {
        var onMouseDown: ((Int) -> Bool)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            // AppKit runs a local monitor on the main thread, before the event is dispatched;
            // returning nil consumes it.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let down = MapMouseDown(event) else { return event }
                let taken = MainActor.assumeIsolated {
                    self?.takes(down) ?? false
                }
                return taken ? nil : event
            }
        }

        /// The hop: the map's window and frame, which only the view knows, decide nothing
        /// themselves; `MapMouseDown.clickCount(inWindow:frame:)` does.
        private func takes(_ down: MapMouseDown) -> Bool {
            guard let window, let clickCount = down.clickCount(inWindow: window.windowNumber, frame: convert(bounds, to: nil)) else {
                return false
            }
            return onMouseDown?(clickCount) ?? false
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}

/// The surface's one fact (DES-010): how much of the collection is on the map. Fixed
/// height in every state (DES-053); digits are monospaced because enrichment moves the
/// number while the user watches (DES-005). `nil` while the scope's state has not arrived
/// (DES-118): the count is not known, so the line holds its height and says nothing.
struct PlacesMapBar: View {
    let locatedCount: Int?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            Text(primary ?? " ")
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

    private var primary: String? {
        guard let locatedCount else {
            return nil
        }
        return locatedCount == 1 ? "1 item on the map" : "\(locatedCount.formatted()) items on the map"
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
