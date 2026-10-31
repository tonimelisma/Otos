# Map views in photo managers, and MapKit on macOS 27

Date: 2026-10-31. Research for the Places scope (ADR 0040). Online sources read
through the fetch tool; the Photos strings were read from the installed app's
`IPXPlace.loctable`; the SDK facts from the macOS 27.0 SDK's `_MapKit_SwiftUI`
swiftinterface. No code or behavior changed in this pass.

## How the field does it

| App | Where the map lives | Stacks | Drill-in | Notes |
| --- | --- | --- | --- | --- |
| **Photos (macOS)** | A `Places` row in the sidebar; the map is the row's detail | Thumbnail stacks with a count | Double-click zooms; click shows the stack's photos; a `Grid` toggle lists by location | Map / Satellite toggle; `Nearby Photos` on one photo. Strings verified: `Places`, `Map`, `Satellite`, `Grid`, `Nearby Photos`. |
| **Lightroom Classic** | A module over the current filmstrip | Pins with counts; selected pin orange | Click selects in the filmstrip | Six map styles, search, saved locations, reverse geocoding, GPX track log, drag-to-geotag. |
| **darktable** | A view over the current collection | Thumbnail groups; white count = exact same spot, yellow = nearby | Scroll wheel over a group cycles it | Drag to geotag with undo; map settings for grouping and size. |
| **digiKam** | An inspector tab for the selection | Marker or thumbnail | None (informative only) | Editing in a separate geolocation editor. |
| **Mylio** | A top-level view | Thumbnail pins | Click opens a grid of that location | Standard, satellite hybrid, topographic. |
| **Capture One** | None | — | — | `Show on map` opens Google Maps in the browser; users ask for a map in the community. |

Pattern: catalog-centric managers make the map a view over the current collection;
the consumer app makes it a destination. Otos took the destination (ADR 0040) because
the question is library-wide, a row is discoverable on first launch, and a scope owns
its own presentation with no disabled sort, zoom or day bar.

## MapKit in the macOS 27 SDK

From `_MapKit_SwiftUI.framework/Modules/_MapKit_SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface`:

- Present, `macOS 14.0+`: `Map`, `Annotation`, `Marker`, `MapCompass`, `MapScaleView`,
  `MapZoomStepper`, `MapPitchToggle`, `MapUserLocationButton`, `MapCameraPosition`,
  `MapCameraBounds`, `MapSelection`, `MapReader`, `MapCircle`, `MapPolyline`,
  `MapPolygon`, `onMapCameraChange(frequency:)`, `mapStyle` with
  `.standard(elevation:emphasis:pointsOfInterest:)`, `.imagery`, `.hybrid`.
- Absent: any clustering. `clusteringIdentifier` exists only on AppKit's
  `MKAnnotationView` (`MKAnnotationView.h`, `macos(10.13)`).
- `MKMapPoint` is Web Mercator, so a map-point rect from `MapCameraUpdateContext.rect`
  divided by the view's size gives map points per screen point directly; the cluster
  cell is that times 64 pt.

Conclusion: SwiftUI `Map` with Otos-owned clustering, AppKit only if measurement says
so.

## What Otos already had

`asset_metadata.primary_latitude/longitude/altitude_meters`, promoted by
`MediaEnricher.mapLocations` from MediaMetadata's `exifGPS`, `quickTime` and `sonyNRTM`
sources; the first location is primary. No index on the columns; none added (Pike).

## Sources

- Apple Support, Find photos and videos by location on Mac:
  <https://support.apple.com/guide/photos/find-photos-and-videos-by-location-pht4c00b8ddc/mac>
- Adobe, Work with the Map module in Lightroom Classic:
  <https://helpx.adobe.com/lightroom-classic/help/maps-module.html>
- Julieanne Kost, GPS, Location Information, and the Map Module:
  <https://jkost.com/blog/2024/09/gps-location-information-and-the-map-module-in-lightroom-classic.html>
- darktable 4.6 user manual, map overview:
  <https://docs.darktable.org/usermanual/4.6/en/map/overview/>
- digiKam manual, Maps View: <https://docs.digikam.org/en/right_sidebar/maps_view.html>
- Mylio Photos manual, Browse the Map View:
  <https://manual.mylio.com/24.3/en/topic/browse-the-map-view>
- Capture One support, GPS location data:
  <https://support.captureone.com/hc/en-us/articles/5333146130845-GPS-location-data>
- Apple, Decluttering a Map with MapKit Annotation Clustering:
  <https://developer.apple.com/documentation/MapKit/decluttering-a-map-with-mapkit-annotation-clustering>
- Apple Developer Forums, SwiftUI Map Annotation Clustering:
  <https://developer.apple.com/forums/thread/684811>
