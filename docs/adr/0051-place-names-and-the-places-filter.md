# ADR 0051: Place names, named once per map cell, and the Places filter

- Status: Accepted
- Date: 2026-11-12

## Context

The owner asked why the browser's filter offers people and places nowhere (2026-11-12), and
accepted a Places filter of country and town in the same filter popover as the file types
and People. The catalog holds each item's primary location as coordinates (ADR 0039,
ADR 0040) and no place names: the Info pane looks one item's name up when it shows it
(ADR 0050), and nothing else in Otos names a place.

A filter needs every located item's country and town at once, before the user asks. A
family library holds tens of thousands of located photos, but far fewer places: photos
cluster where people live and travel.

MapKit (macOS 26 and later) names a coordinate through `MKReverseGeocodingRequest`, whose
`MKAddressRepresentations` give the country (`regionName`), the town (`cityName`) and the
town with the context that tells it from another of the same name (`cityWithContext`,
`Springfield, IL`). It names no state or province on its own, and it throttles an app that
asks too often (`MKError.loadingThrottled`). `CLGeocoder`, which named the administrative
area, is deprecated.

## MECE Decision Scope

This ADR owns: how place names are read, stored and kept current, and what the Places filter
narrows by. It references but does not own: the primary location (ADR 0039); Places and the
map (ADR 0040); the Info pane's one-item lookup (ADR 0050); the filter popover and the query
descriptor (APP-013, ADR 0011); the owner-state rules the reader follows (ADR 0032).

## Decision

- **A cell of the map is named once.** The map is cut into cells 0.02° on a side, about
  2.2 km north to south (`PlaceCell`). Every located item's cell is computed from its stored
  coordinate, in SQL without SQLite's math functions, and every item in a cell shares its
  names. A cell is a town's scale: a photo near a town's edge may be named by the neighbour.
- **Maps is sent the cell, never the photo.** `PlaceNameReader` asks Apple Maps for the
  cell's center, so no photo's own coordinate leaves the Mac for the filter.
- **Country and town.** The names stored are the country (`regionName`) and the town with
  its context (`cityWithContext(.short)`, else `cityName`). The filter is two levels,
  country ▸ town; MapKit names no region on its own, and the deprecated `CLGeocoder` is not
  used.
- **Stored per language.** A cell's names carry the locale they are in; a cell named in a
  language other than the Mac's is asked again. A cell Maps names nothing for (open sea) is
  stored with no names, so it is not asked again.
- **One owner, one loop.** `PlaceNameReader` (an actor) drains unnamed cells in pages,
  woken by the Store's change notifications (ADR 0032 rule 3). When Maps throttles or cannot
  be reached, it waits and asks again (`time: backoff`, 2 s doubling to 5 min); an error that
  is neither is logged and the cell stored unnamed.
- **The filter.** `MediaFilter.places` holds countries and towns. A photo matches when its
  cell is named one of them. Checking a country includes all of it; unchecking one town of a
  checked country narrows it to the rest. The popover offers the countries and towns named
  for the located items in every available source, as it offers file types (APP-042).
- **Not in the catalog of media.** Place names are derived, rebuildable overlay in
  Application Support (ADR 0008): nothing is written to media files.

## Alternatives Considered

- **Naming each photo:** one request per located photo, tens of thousands for a library,
  throttled for hours, and every photo's exact coordinate sent to Apple. Cells ask a few
  thousand times at most and send no photo's coordinate.
- **Smaller cells (0.01°):** four times the requests for names that differ only at town
  edges.
- **`CLGeocoder` for a region level:** deprecated in macOS 26.
- **An offline gazetteer bundled with Otos:** a dependency of hundreds of megabytes and its
  own staleness, for names Maps already gives in the user's language (CLAUDE.md requires an
  ADR for any third-party dependency; none is justified here).
- **Filtering on the map's area instead of names:** that is what Places' map already does;
  the filter answers "photos from Finland" in every scope, which an area cannot.

## Consequences

- **Network:** naming a library sends Apple Maps one request per cell, in the background,
  from when the reader starts; a library's first naming may take minutes while Maps
  throttles. Until a cell is named, its photos match no place.
- **Language:** changing the Mac's language names every cell again.
- **Precision:** a photo within about a kilometre of a town's edge may carry the
  neighbouring town's name.
