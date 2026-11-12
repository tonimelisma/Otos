# MapKit's zoom-out limit, the globe, and panning past the poles

Date: 2026-11-13. Research for the Places map (ADR 0040, `docs/design/places.md`), done
after the owner asked why the map stops zooming out at about the size of North America
while it lets the view pan past the poles into a gray grid. Measured on macOS 27 with
the dev build at a 1232 × 845 pt map, by reading the `op=map.camera` and
`op=map.cluster` lines (`span=` is latitude × longitude degrees) and screenshots, plus
one standalone `MKMapView` probe.

## Findings

| Configuration | Widest view | Globe |
| --- | --- | --- |
| SwiftUI `Map`, `.standard(pointsOfInterest:)` (what shipped) | 152.73° of longitude | No |
| Same, plus `MapCameraBounds(maximumDistance: 100_000_000)` | 152.73° | No |
| `.standard(elevation: .realistic, …)`, with or without that bound | 152.73° | No |
| `.hybrid(elevation: .realistic, …)` | The whole Earth | Yes: satellite imagery with labels |
| AppKit `MKMapView`, `setVisibleMapRect(.world)`, any zoom range, flat configuration, 1232 pt or 600 pt wide | 180° (half the world) | No |

- A flat MapKit map cannot show the whole world. The limit comes from MapKit; no
  camera bound lifts it.
- Only satellite imagery with realistic elevation turns into a globe when zoomed out.
  The standard style stays flat even with realistic elevation. A developer forum report
  says the same: <https://developer.apple.com/forums/thread/823043>, and
  <https://developer.apple.com/forums/thread/760542>.
- `MapCameraBounds` and `MKMapView.CameraBoundary` bound only the camera's **center**
  (Apple: "a boundary of an area within which the map's center needs to remain").
  With no bound, the flat map pans past 85° north and south into MapKit's gray grid.
  A fixed bound cannot stop that at every zoom, because the half-height of the view in
  map points changes with zoom.
- A center bound wider than the world east–west (origin −1 world, three worlds wide)
  does not stop a pan across the antimeridian: the logged center went −122.67 →
  106.04 → −25.25 → −156.54 over three drags.
- A bound that follows the visible height (`onMapCameraChange(frequency:
  .continuous)`) holds the view at the edge: a drag north stopped with the center at
  77.63° and a 25.10° latitude span (top edge at the world's edge), and a zoom out
  that asked for a center at 82.15° settled at 77.60°.

## Decision taken

The owner chose the flat standard map over the satellite globe (2026-11-13), knowing
the zoom-out stays at MapKit's limit. Panning to the map's own edge (85°) still showed
Web Mercator's polar stretch, so the owner then chose to stop panning at 75° north and
south, widened for any located item farther out. Measured with the dev build: a drag
north stopped with the view's top at 75.00°N (center 53.64°, span 63.65°), a drag
south at 75°S (center −53.64°).
