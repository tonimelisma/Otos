# Places — Spec

The Places scope: a sidebar row whose detail is a map of thumbnail stacks, and an
area of the map under it in the ordinary view modes. Cites `docs/design/design-system.md` by ID; rules are not
restated. Decision record: `docs/adr/0040-places-scope-and-map-clustering.md`.

Owner: `Otos/Views/PlacesMapView.swift`. Content: `CatalogMapState`
(`Otos/Models/MapModels.swift`), clusters from `MapClusterPolicy` through
`CatalogWindowViewModelMap.swift`.

## Reference

Photos' Places (macOS 27, observed 2026-11-01): a `Places` row, thumbnail stacks with a
count on the map, double-click to zoom, and a Map / Satellite / Grid toggle whose Grid
shows the photos in the area the map shows, in sections by place name and date
(`docs/research/2026-10-31-map-views-in-photo-managers.md`). Otos takes the row, the
stacks and Grid's meaning, but not its control or its clicks (below): Otos's own view-mode
picker plays Grid's part (and Loupe and Compare with it) and `Back to Map` plays Map's,
so the toolbar gains nothing. It drops Satellite, keeps its day sections (place-name
sections need reverse geocoding, which Otos does not do) and adds nothing of its own.
Terms are Apple's: *location*, never *GPS* or *geotag*.

## Terminology

| Term | Means | Not |
| --- | --- | --- |
| **Places** | The sidebar row and its scope: every located item in the fixed libraries. | "Map" (a presentation, not a place to go) |
| **Area** | The items in one box of the map: the area the map showed. Not named in the UI. | a region, a city, a pin |
| **Stack** | One thumbnail on the map standing for the items in one cluster cell; opened, exactly those items. | "pin", "marker", "annotation" |
| **Located** | Has a stored primary location. | "geotagged" |

## Sidebar

`Places`, SF Symbol `map`, a top-level row after `On This Day` and `People` (owner
decision, 2026-11-12): browsing by place sits with the other ways to browse the whole
library. Present whenever one fixed library exists. No
trailing count, because library rows carry none. While an area is open the row stays
highlighted: the area has no row of its own.

## Toolbar while the map shows

The view-mode picker shows no segment selected, because the map is not one of the modes.
Choosing one (or ⌘1 / ⌘2 / ⌘3, or the View menu) opens the area the map shows in that
mode: Grid, Loupe or Compare over the photos located inside it. Loupe and Compare start
on the area's first photos. The map stays on screen until the area is ready. The picker
is disabled (DES-053) only before the map has first reported where it is. The filter,
sort and zoom controls keep working: filter narrows the map, sort decides which photo
fronts a stack, zoom steps the camera. The map has no selection, so the trailing
per-item controls are disabled (DES-053).

While an area is open, a `Back to Map` item (`chevron.left`) sits at the leading edge
of the toolbar and returns to the map as it was left; the browser there is the
ordinary one.

## The bar — L1

The surface's single fact (DES-010), in the day bar's position above the map, 52 pt in
every state (DES-053):

| Level | Text | Rule |
| --- | --- | --- |
| L1 | `1,204 items on the map` / `1 item on the map` | `.title3` semibold, tabular digits (DES-005) |

The bar carries no count of the items left off the map (owner decision, 2026-11-12). The
count moves while enrichment finds locations; nothing else on the bar does.

## Map

Standard style, following light and dark; points of interest excluded **[deviation
DES-104]**; pan and zoom only; `MapZoomStepper` and `MapScaleView` as the only chrome.
No user-location control and no permission prompt. The map pans north and south only
to 75°, or to the farthest located item plus 2° when one lies beyond, never past the
map's own edge: Web Mercator stretches the polar regions many times over, so they stay
off screen, and no item is ever out of reach (owner decision, 2026-11-13). A pan or zoom
that settles past the band eases back to its edge at the same zoom (0.25 s ease-out,
DES-070; a snap under Reduce Motion, DES-075), as a scroll view springs back from its
end; east–west it wraps freely. MapKit's own camera bounds are not used: with any bound,
its pan stops at the antimeridian going east. Zoom-out stops where MapKit's flat map does; only its satellite globe shows the
whole world undistorted, and the owner chose the standard map
(`docs/research/2026-11-13-mapkit-zoom-out-and-poles.md`).

Camera: on entering Places, center on the located items' average location (the circular
mean of longitude, so items either side of the antimeridian average to it) and reach the
farthest item on each axis with a margin, in map points so a library shot on two
continents (more than 180° of longitude) does not wrap (a single point gets a 2 km
square). Zoomed far out is fine; a view of no items is not: MapKit clamps a camera wider
than it can show about its center, so a library mostly in one place opens on that place
(owner decision, 2026-11-12, after a California library with a few Sydney and Helsinki
photos opened on an empty Africa). The map wraps at the antimeridian, and stacks and the
fit check take each item's copy in the viewport. MapKit refuses a camera past its zoom-out (about 153° of
longitude at a 1232 pt map), so when the viewport that follows a fit leaves an item
outside, the fit is asked once more without margin but grown to the camera the map
just showed, and left there if it still misses. On a filter change, re-fit; on return from an area, the viewport
the user left; ⌘= / ⌘− halve or double the span about the center. A flight is 0.25 s
ease-out (DES-070), a snap under Reduce Motion (DES-075).

## Stacks (DES-103)

A 48 pt square: the representative's thumbnail aspect-filled, radius 4 (DES-060), a
2 pt white edge so it separates from any map. A stack is never selected: a click
drills in. The member count sits at the lower right in `.footnote` tabular
digits on the DES-062 badge well, and appears only once the thumbnail has painted and
only for two or more members. Before the thumbnail has ever decoded, the kind glyph at
tertiary strength (DES-063). Once painted, the thumbnail stays as long as the stack's
representative is the same item.

Cells are 64 pt on a side in screen points at the current zoom, and a stack whose
center would fall within a cell of an earlier stack's center merges into it, so two
stacks never touch whatever the cell boundaries happen to be (48 pt plus a 16 pt
gutter). Only cells touching the viewport, padded by one cell, are drawn.

| Act | Result |
| --- | --- |
| Click, members at several coordinates | The camera zooms into the stack: its extent, never wider than a quarter of the viewport. |
| Click, members at one coordinate | The stack opens, since no zoom can split it. |
| Double-click | The stack opens: exactly the items it counted, as the grid. |

**[deviation]** from Photos, whose click does nothing and whose double-click zooms. A
click drills in, as a click on a cluster does on nearly every map, and the double-click
that ends the drilling opens the photos (owner decision, 2026-11-12). A double-click's
first click has already started the zoom, which moves an off-centre stack out from under
the pointer, so a double-click is one gesture, decided by AppKit's click count and not by
what lies under the pointer: its second click is taken before MapKit or any stack sees it
and opens the stack the first click landed on — never a neighbouring stack the flight slid
there, never MapKit's own double-click zoom on the bare map — a third click does nothing
more, and on a stack the first click already opened the second opens nothing again. A
click counted as a second click whose first did not land on a stack acts on nothing it
lands on. Back to Map returns to the map that first click zoomed from. An opened stack is its items
by identity, not a box: neighbouring stacks' boxes overlap, and a box would take in
another stack's items.

VoiceOver names a stack by what distinguishes it (DES-082): `12 items, 60.17 north,
24.94 east`; a single item `1 item, …`. A stack is a button; pressing it zooms, and its
`Show Photos` action opens it.

## Empty states

| State | Title | L3 |
| --- | --- | --- |
| No located item, libraries reachable | `No Located Media` | `Photos and videos with location information appear here as they are cataloged.` |
| Filter leaves nothing | `No Matching Media` | the shared filter message, with `Clear Filters` |
| Libraries still being checked | `Checking Libraries` | shared |
| Libraries offline | `No Available Media` | shared |

The bar is drawn above every one of them, so the surface's height does not change
when the first item is located.

## Keyboard

Tab reaches the toolbar and the zoom stepper; ⌘= / ⌘− zoom; ⌘1 / ⌘2 / ⌘3 open the
area the map shows. Stacks are not keyboard-focusable; the keyboard path to the photos
is ⌘1, which puts them in a grid. This is a stated limit, not an oversight.

## Verification

`script/smoke-run.sh --verify places` with `OTOS_SMOKE_CAPTURE_PATH`,
`OTOS_SMOKE_APPEARANCE` and `OTOS_SMOKE_CAPTURE_SETTLE_SECONDS` launches the dev build
on the real library, selects Places and writes the window's own rendering to a PNG
(ADR 0020). The bar and the map tiles come through; the sidebar's material and the
stacks (SwiftUI annotations inside the map) do not, so the stacks are verified from
the `op=map.cluster` log line, which carries each stack's count and position in view
points.

## The Places filter

A section of the filter popover, under People (ADR 0051): every country Apple Maps named for
the located items in the shown sidebar row's scope — a library's own, a card's own, Places'
— most items first, so every place offered matches something there (an area or a stack
under the map is offered what Places is), each a checkbox opening onto its towns (`Springfield,
IL`), most items first, a country with some towns checked shown mixed. The first five
countries show, and within a country the first five towns; `Show All 14 Countries` /
`Show All 9 Towns` lists the rest in place and `Show Less` folds it back, and the whole
list of countries gains `Search Places` once there are more than eight. `No places named
yet` before any cell is named. Checking a country includes all of it; unchecking one town
of a checked country narrows it to the rest. A checked place always shows, even one
nothing in the scope is named any more (a town whose photos left): a held town after its
country's named towns, a held country after the named countries, so it can be seen and
cleared. Names are in the Mac's language; after a language change, the list fills again
as the cells are named anew, and every checked place leaves the filter as soon as the old
names are forgotten: the catalog holds nothing that names a place apart from its name in
one language, so a checked `Finland` cannot become `Suomi`, and is cleared — the boxes
uncheck and the grid widens — rather than left checked matching nothing. It narrows the
map and every scope, within the sidebar row it was set in (`docs/design/people.md`, The
filter's reach).

## Not in this spec

Place names on the map (the Info pane names one item's place, ADR 0050), assigning or moving a location, a filmstrip under the
map, a map of a card or an import batch, Satellite imagery. Each is on the roadmap.
