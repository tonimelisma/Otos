# ADR 0040: Places is a scope whose presentation is a map

- Status: Accepted
- Date: 2026-10-31

## Context

Every enriched asset already carries a stored primary location
(`asset_metadata.primary_latitude/longitude/altitude_meters`), promoted by
`MediaEnricher` from the first location MediaMetadata reports (EXIF GPS, QuickTime
location, Sony NRTM). Nothing in the app showed it. The user asked for a native map of
all media by coordinate, reached from the sidebar, built the way an app shipped with
macOS would build it.

Field survey (`docs/research/2026-10-31-map-views-in-photo-managers.md`): Photos makes
Places a sidebar destination whose detail is a map of thumbnail stacks with counts;
Lightroom Classic, darktable and Mylio make the map a view *over the current
collection*; digiKam makes it an inspector; Capture One has none. Otos's own
architecture splits *scope* (`SidebarSelection`, what media) from *presentation*
(`BrowserViewMode`: grid, loupe, compare).

The first design offered both: a Map view mode over any scope, plus a Places row that
defaults into it. That is confusing from the user's side — the same map reachable two
ways with slightly different contents, and a mode that inherits sort, zoom and the day
bar, all meaningless on a map, so every one needs a disabled state.

## MECE Decision Scope

This ADR owns: what the Places and place scopes mean; where the map's content and its
clusters are computed; how the sidebar, toolbar and view modes behave while the map
shows; how a stack is reached and left; and what the map never does (location
services, reverse geocoding, editing). The Info pane's place name for one item is ADR
0050's; place names for the Places filter are ADR 0051's.

It references but does not own: scope resolution and the sidebar default policy (ADR
0014); the query descriptor and scope predicate (ADR 0011, ADR 0010); the browser
place saved at quit (ADR 0031); the owner-state rules the cluster lane follows (ADR
0032); thumbnail storage (ADR 0009); the no-blank grid rule (ADR 0006).

## Decision

**Places is a scope, and the map is simply what that scope looks like.** There is no
Map view mode.

- `SidebarSelection.places` is every asset with a stored primary location across the
  available fixed libraries — All Media's membership plus one dimension, "has a
  location". Removable sources are excluded, as in All Media. The row exists as soon as
  one fixed library exists, located items or not, so it can be found and the sidebar
  never reflows as enrichment finds coordinates.
- `SidebarSelection.mapArea(MapArea)` is one leaf: the items whose primary location
  lies in one latitude/longitude box, edges included. The view-mode picker and ⌘1 / ⌘2 /
  ⌘3 open the box the viewport shows in that mode (Web Mercator keeps longitude in x and
  latitude in y, so the viewport's rect is exactly a box; a box past the antimeridian has
  `west > east`).
- `SidebarSelection.mapStack(MapStack)` is the other: exactly the items one stack counted,
  by identity, read as `ContentConstraint.members` with the members passed as one JSON
  argument (a stack opened zoomed out holds more items than SQLite's bound-parameter
  limit). A box would not do: stacks merge neighbouring cells, so their boxes overlap
  and a stack's box takes in another stack's items. It is not written to the browser
  place; a relaunch reopens the map. Neither leaf is a sidebar row; the sidebar keeps
  Places highlighted for them (`sidebarRow`).
- **A click drills in; a double-click opens** (owner decision, 2026-11-12). A click on a
  stack zooms into it, as a click on a cluster does on nearly every map; one whose
  members share a coordinate, which no zoom can split, opens. A double-click opens the
  stack. The map has no selection. One tap gesture reads AppKit's click count, so the
  click zooms at once rather than waiting out the double-click interval, and the
  double-click's second click opens the stack its first click landed on. It is presented in the ordinary view modes, and a
  Back to Map toolbar item returns to the map at the viewport the user left. This is
  Photos' Grid, reached through Otos's own picker rather than a fourth control.
- **The scope predicate carries the location dimension.** `CatalogScopePredicate`
  gains `LocationConstraint` (`.any`, `.located`, `.within(area)`), resolved only by
  `RootRegistry.scopePredicate`, so order and counts cannot disagree
  about what Places holds — the same guarantee ADR 0010 gave the import-batch
  dimension. A scope that requires a location joins `asset_metadata` and the ordered-ID
  query reads each row's coordinate alongside its order; there is no second query for
  the map's content.
- **Filter applies; sort applies.** The descriptor is scope plus filter plus sort, and
  both other parts keep their meaning: the filter narrows what is on the map, and the
  sort decides which photo fronts a stack (the representative is the first member in
  display order). Nothing is disabled but the view-mode switcher.
- **Projection publishes the map's content; the ViewModel clusters it.** Projection
  adds `CatalogWindowState.map` (`CatalogMapState`: the located items in display order
  plus the count of items in the same libraries and filter without a location) for the
  `.places` scope only. Clustering depends on the camera, which is window state that
  changes with every pan, so it runs on a ViewModel-owned lane
  (`CatalogWindowViewModelMap.swift`) under ADR 0032: a revision pair, one doorbell
  loop, the arithmetic off the main actor through `@concurrent`, the result assigned
  synchronously. `MapClusterPolicy` is pure: a Web Mercator grid of 64 pt cells at the
  current viewport, members in display order, a stack merged into an earlier one whose
  center lies within a cell of it, only cells touching the padded viewport emitted, so
  stacks never overlap and their count is bounded by the viewport's area.
- **The map's camera is a request, not a mirror.** The map owns its camera as control
  state and reports where it settled (`MapViewport`, in map points). The ViewModel asks
  for a camera as map-point bounds (`MapBounds`, never degrees: a region wider than
  180° of longitude wraps when MapKit fits it, and a two-continent library is that
  wide — found on the real library, 2026-10-31), numbered so the view applies each
  once. A viewport report carries the request it followed, so a fit is checked: MapKit
  clamps a camera past its zoom-out, and a fit whose own viewport leaves an item
  outside is asked once more without margin, grown to the camera the map proved it can
  show, then left. Cameras requested: on entry, centered on the located items' average location (circular
  mean of longitude) and reaching every item, so a clamp keeps the average in view
  and on a filter change, the last viewport on return from an area, a quarter-span zoom
  on a stack that can still split, a step on View ▸ Zoom In / Out.
- **The map is not a view mode; the modes open its area.** While the map shows, the
  view-mode picker selects no segment, and choosing one — or ⌘1 / ⌘2 / ⌘3 — opens the
  visible area in that mode. Loupe and Compare start on the area's first items once it
  publishes; until then the pane is still the map (the pane follows the published
  scope). Before the map's first viewport there is no area, so the picker is
  disabled, never hidden (DES-053). A loupe or compare left open elsewhere exits to grid
  on entering Places. The zoom control and View ▸ Zoom In / Out drive the map.
- **Thumbnails follow the grid's rule.** A stack's identity is its representative, so a
  camera change that keeps the same front photo keeps the view and its painted
  thumbnail; decode is off the main actor through the grid's own loader, and the
  decoded image warms the shared `TileContentStore`.
- **What the map never does.** It never asks for the user's location (no
  `CLLocationManager`, no location button, no usage key); the map's tile requests are
  its one network use, as in Photos. The map never reverse-geocodes (the Places filter's
  place names are ADR 0051's), never edits a location, never infers one. Unknown stays
  unknown: an item without a stored location is left off, not placed.

## Alternatives Considered

### A fourth view mode, Map, over any scope

Pros: Lightroom's model; "where was this card shot" is answerable.

Cons: inherits sort, zoom and the day bar; needs a disabled or empty state for every
scope with nothing located; a fourth glyph in the mode picker is not discoverable.
Combined with a Places row it is two paths to one map.

Failure mode: the user cannot predict which of two maps they are looking at.

### Both a Places row and a Map mode

Rejected for the reason above; this ADR's decision replaced it before any code was
written.

### Only one coordinate opens as a grid

The first build opened a grid only from a stack whose members shared one coordinate,
and zoomed every other stack by at most a quarter of the viewport.

Cons: photos taken a few meters apart never share a coordinate, so reaching them took
one double-click per zoom step — the owner counted seventeen (2026-11-01). Photos, Mylio
and Lightroom Classic's Visible on Map filter all show an area's photos at whatever
zoom the user stopped at.

### Photos' clicks: a click does nothing, a double-click zooms

The first build took Photos' double-click to zoom and gave the click to selection.

Cons: the selection a stack click made was barely visible on the map (an accent border,
the per-item controls, where Loupe began), so the easiest gesture did the least, and
reaching an area's photos took a zoom per double-click then a mode switch. Every other
clustering map zooms on a click.

### Opening a stack as the box of its members

Pros: one leaf kind, `mapArea`, persisted like the visible area.

Cons: stacks merge neighbouring cells, so the box of one stack's members can hold another
stack's items, and the grid would not show what the count said.

### Photos' Map / Grid toggle as its own control

Pros: Photos' exact chrome.

Cons: a second segmented control beside the view-mode picker, both choosing what the
detail pane shows; Grid would be a fourth way to say what the picker's Grid says.
Otos's picker and Back to Map already carry both halves of the toggle.

### Clustering in Projection

Pros: one publication path.

Cons: couples catalog publication to the camera; every pan would be a Projection pass
against the Store's cadence rules; the Store would be asked the same located set
repeatedly.

### MapKit's own clustering (`MKAnnotationView.clusteringIdentifier`)

Pros: free, animated.

Cons: AppKit only (`MKMapView`), while the macOS 27 SDK's SwiftUI `Map` has
`Annotation`, `MapZoomStepper`, `MapScaleView`, `MapCameraPosition` and
`onMapCameraChange` but no clustering. ARC-001 prefers SwiftUI; the policy is a
hundred lines and unit-tested; AppKit remains the fallback if measurement shows
SwiftUI annotations cannot keep up.

### A partial index on `primary_latitude`

Rejected after measuring (Pike). On the real catalog (16,254 fixed-library rows, 12,834
located) the joined order query runs in about 30 ms warm against 11 ms for All Media:
the order still walks the capture index and the join is a primary-key lookup per row,
with no temporary sort (`docs/research/2026-10-31-map-views-in-photo-managers.md`;
plan pinned by `CatalogStoreQueryPlanTests`).

## Consequences

- The sidebar gains one top-level row, Places, with the other ways to browse the whole
  library: under All Media, On This Day and People (APP-002). `SidebarSelection`
  gains two cases, and every exhaustive switch over it names them; `BrowserPlace`
  persists both.
- `CatalogWindowState` grows `map`; `CatalogProjectionChangeSummary` compares it so a
  re-enriched coordinate publishes without an identity change. A detail-only pass under
  Places re-runs the order query instead of reusing it, because the coordinates travel
  with the order.
- "Show me where this card or batch was shot" is not reachable; the map always covers
  the fixed libraries. A contextual command from the grid could add it later without
  reopening this decision.
- Keyboard: the stacks are mouse-driven; the keyboard path to the photos is the grid
  (the place leaf, or any other scope). Tab reaches the zoom stepper and the toolbar.

## Retirement Proof

Nothing is replaced. The empty-state drawing moved from `MediaGridView` to the shared
`CatalogMediaEmptyStateView`; the badge color moved into `DesignPalette.badge`.

## Living Documentation Impact

- `docs/requirements.md`: APP-057, APP-058 added; APP-002, APP-013, APP-016, APP-019,
  APP-043, ARC-022 amended.
- `docs/design/design-system.md`: DES-103, DES-104, DES-105; `docs/design/places.md`.
- `docs/architecture.md`: dataflow, ViewModel row, where-to-change row.
- `docs/research/2026-10-31-map-views-in-photo-managers.md`.
- `docs/product/roadmap.md`: reverse geocoding, geotag editing, nearby, show-on-map.

## Reversal Plan

If the map must show an arbitrary scope, add the location dimension to any scope's
predicate (the plumbing is scope-agnostic) and a presentation choice on the descriptor
— not a view mode — so one owner still decides what the detail pane is. If SwiftUI
`Map` cannot carry the annotation count, swap `PlacesMapView`'s body for an
`MKMapView` representable; the policy, lane and state are unchanged.
