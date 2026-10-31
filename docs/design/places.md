# Places — Spec

The Places scope: a sidebar row whose detail is a map of thumbnail stacks, and the
grid of one place under it. Cites `docs/design/design-system.md` by ID; rules are not
restated. Decision record: `docs/adr/0040-places-scope-and-map-clustering.md`.

Owner: `Otos/Views/PlacesMapView.swift`. Content: `CatalogMapState`
(`Otos/Models/MapModels.swift`), clusters from `MapClusterPolicy` through
`CatalogWindowViewModelMap.swift`.

## Reference

Photos' Places (macOS): a `Places` row, thumbnail stacks with a count on the map, a
Map / Satellite / Grid toggle, double-click to zoom, `Nearby Photos` on a photo. Otos
takes the row, the stacks, the double-click and the names; it drops Satellite and
Grid as toggles (a stack opens its place as the ordinary grid instead) and adds
nothing of its own. Terms are Apple's: *location*, never *GPS* or *geotag*.

## Terminology

| Term | Means | Not |
| --- | --- | --- |
| **Places** | The sidebar row and its scope: every located item in the fixed libraries. | "Map" (a presentation, not a place to go) |
| **Place** | The items at exactly one coordinate, opened from a stack. | a region, a city, a pin |
| **Stack** | One thumbnail on the map standing for the items in one cluster cell. | "pin", "marker", "annotation" |
| **Located** | Has a stored primary location. | "geotagged" |

## Sidebar

`Places`, SF Symbol `map`, directly under `All Media` and above the Libraries section,
as a top-level row like All Media. Present whenever one fixed library exists. No
trailing count, because library rows carry none. While a place is open the row stays
highlighted: the place has no row of its own.

## Toolbar while the map shows

The view-mode picker is disabled (DES-053: disabled, never removed); the filter, sort
and zoom controls keep working — filter narrows the map, sort decides which photo
fronts a stack, zoom steps the camera. The trailing per-item controls act on the
selection a stack click made.

While a place is open, a `Back to Map` item (`chevron.left`) sits at the leading edge
of the toolbar and the picker is enabled again: the place is the ordinary grid.

## The bar — L1 and L3

The surface's single fact (DES-010), in the day bar's position above the map, 52 pt in
every state (DES-053):

| Level | Text | Rule |
| --- | --- | --- |
| L1 | `1,204 items on the map` / `1 item on the map` | `.title3` semibold, tabular digits (DES-005) |
| L3 | `7,696 items have no location` / `1 item has no location` / `Every item has a location` | `.subheadline`, L3 color |

Both counts move while enrichment finds locations; nothing else on the bar does.

## Map

Standard style, following light and dark; points of interest excluded **[deviation
DES-104]**; pan and zoom only; `MapZoomStepper` and `MapScaleView` as the only chrome.
No user-location control and no permission prompt.

Camera: on entering Places, fit every located item with a margin (a single point gets
a town-sized span); on a filter change, re-fit; on return from a place, the viewport
the user left; ⌘= / ⌘− halve or double the span about the center. A flight is 0.25 s
ease-out (DES-070), a snap under Reduce Motion (DES-075).

## Stacks (DES-103)

A 48 pt square: the representative's thumbnail aspect-filled, radius 4 (DES-060), a
2 pt white edge so it separates from any map; selection is the 3 pt accent border of
a tile (DES-061). The member count sits at the lower right in `.footnote` tabular
digits on the DES-062 badge well, and appears only once the thumbnail has painted and
only for two or more members. Before the thumbnail has ever decoded, the kind glyph at
tertiary strength (DES-063). Once painted, the thumbnail stays as long as the stack's
representative is the same item.

Cells are 64 pt on a side in screen points at the current zoom, so two stacks never
touch (48 pt plus a 16 pt gutter). Only cells touching the viewport, padded by one
cell, are drawn.

| Act | Result |
| --- | --- |
| Click | The stack's members become the selection. |
| Double-click, members at several coordinates | The camera zooms into the stack: its extent, never wider than a quarter of the viewport. |
| Double-click, members at one coordinate | The place opens as the grid. |

VoiceOver names a stack by what distinguishes it (DES-082): `12 items, 60.17 north,
24.94 east`; a single item `1 item, …`. A stack is a button; a selected stack carries
the selected trait.

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

Tab reaches the toolbar and the zoom stepper; ⌘= / ⌘− zoom; ⌘1 / ⌘2 / ⌘3 are disabled.
Stacks are not keyboard-focusable; the keyboard path to the photos is a grid (a place,
or any other scope). This is a stated limit, not an oversight.

## Not in this spec

Place names (reverse geocoding), assigning or moving a location, a filmstrip under the
map, a map of a card or an import batch, Satellite imagery. Each is on the roadmap.
