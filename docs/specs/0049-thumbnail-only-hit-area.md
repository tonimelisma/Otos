# Spec 0049: Thumbnail-Only Hit Area

## Classification

- Work type: Bug fix
- Current requirement IDs: APP-006 (grid cell face is the thumbnail's aspect-fit rect),
  APP-010 (selection semantics), APP-011 (model-owned mouse selection)
- Future idea or candidate links explicitly requested by the user: none
- ADRs: `docs/adr/0006-catalog-grid-rendering.md` (rendering geometry already documented
  there; no ADR change required)

## Problem

The media grid's square cell accepts a mouse click anywhere inside the cell, including the
letterbox padding around an aspect-fit thumbnail. Owner testing showed this is wrong: it
causes accidental selections when the user clicks the empty gutter inside a tile. The
decision is to match Apple Photos — only a click inside the actual thumbnail face selects;
clicks in the letterbox behave like clicks in the inter-tile gutter.

## Scope

In scope:

- Restrict mouse-selection hit-testing to the aspect-fit thumbnail face for decoded
  thumbnails.
- Treat letterbox clicks as empty-space clicks: a plain letterbox click clears selection,
  anchor, and base; a modified (⇧/⌘) letterbox click is a no-op that leaves selection and
  anchor unchanged.
- Keep the existing model-owned selection path from spec 0046 unchanged; only the initial
  hit classification changes.
- Share one geometry definition between the tile renderer and the hit-test.
- Unit tests for the geometry helper and controller-level tests for letterbox vs. face
  behavior.

Out of scope (unchanged in this increment):

- Shift-click, ⌘-click, and keyboard selection semantics (spec 0046).
- The selection ring, animation, and no-blank grid invariant (specs 0046/0047/0038).
- Grid zoom, structural apply policy, and tile detail fetching.
- VoiceOver / accessibility activation behavior; AX still activates the whole cell.

## Definition Of Ready

- [x] Goal, scope, and non-goals are explicit.
- [x] Current repo state was inspected (see below).
- [x] Owner decision restated as precise acceptance examples below.
- [x] Observable acceptance examples listed.
- [x] No future ideas introduced.
- [x] Ownership, side effects, persistence, cancellation, errors, instrumentation, and tests
      addressed below.
- [x] Three alternatives compared per changed mechanism.
- [x] No retirement proof needed beyond the removal of the whole-cell hit assumption.
- [x] Stale-document audit defined.
- [x] Code-comment accuracy audit defined.
- [x] Performance evidence: not performance-sensitive; no profiling required.
- [x] Open questions: none outstanding.

## Current Repo State (verified by inspection before implementation)

- `MediaGridCollectionView.mouseDown(with:)`
  ([MediaGridCollectionView.swift](../../Otos/Views/MediaGridCollectionView.swift)) calls
  `indexPathForItem(at:)` to find the clicked item. That API returns the item for any point
  inside the square cell, including letterbox padding.
- `MediaAssetTilePresentation.contentRect(imagePixelSize:bounds:)`
  ([MediaAssetTilePresentation.swift](../../Otos/Views/MediaAssetTilePresentation.swift))
  already computes the aspect-fit thumbnail face used by `MediaAssetTileView.layout()` to
  position `contentView` and by `setSelected(_:animated:)` to place the ring.
- `MediaAssetTileView` stores `currentImagePixelSize` after a thumbnail paints; while it is
  `nil` the tile shows a full-square placeholder.
- `MediaAssetCollectionItem.view` is a `MediaAssetTileView`, reachable from the collection
  view via `item(at:)`.

## Design

### Single shared geometry

Add a thin semantic wrapper `MediaAssetTilePresentation.thumbnailFaceRect(imagePixelSize:bounds:)`
that delegates to the existing `contentRect`. This makes the hit-test intent explicit and
keeps the renderer and the hit-test on one definition.

### Tile-view hit test

Add `MediaAssetTileView.hitTestsThumbnailFace(at pointInWindow: CGPoint) -> Bool`. It
converts the window point to tile coordinates and checks containment against
`thumbnailFaceRect`. For a placeholder (`currentImagePixelSize == nil`) the face equals the
full bounds, so the whole tile remains selectable — only decoded thumbnails with real
letterbox create dead zones.

### Collection-view click handler

In `MediaGridCollectionView.mouseDown(with:)`:

1. Convert the event location to collection-view coordinates.
2. Find the candidate index path with `indexPathForItem(at:)`.
3. If a candidate exists, fetch its `MediaAssetCollectionItem` and `MediaAssetTileView`.
4. If the tile view reports the point is outside the thumbnail face, treat the click as
   empty space (`hit = nil`).
5. If the item or tile view is temporarily unavailable, keep the candidate hit as a safe
   fallback so a real click is not dropped.
6. Forward `(hit, modifiers)` to `onMouseSelection` exactly as today.

`applyMouseSelection(hit:modifiers:)` already handles `hit == nil` as empty space, so no
change is needed in the controller's selection model.

## Alternatives Considered

1. **Controller computes the face from layout attributes.** The controller would call
   `layoutAttributesForItem(at:)` and `MediaAssetTilePresentation.contentRect` using a pixel
   size looked up from a side table. Rejected: it duplicates the pixel-size ownership (the
   tile view already owns it) and invites drift if the lookup differs from what the tile
   rendered.

2. **Tile view exposes only `currentImagePixelSize`.** The collection view would read the
   pixel size and compute `contentRect` itself. Rejected: it still exposes tile internals
   and spreads geometry knowledge across two files; a single `hitTestsThumbnailFace` method
   is a smaller, clearer boundary.

3. **Ask the item view to hit-test itself via `hitTest(_:)`.** Override
   `MediaAssetTileView.hitTest` to return `nil` for letterbox points. Rejected: this would
   also disable hit-testing for drag, context menus, and future interactions that may want
   the whole cell; it is too broad. The selection path should own the restriction, not the
   view's general hit-test.

Selected approach: tile view exposes a selection-specific `hitTestsThumbnailFace(at:)`,
collection view calls it only for mouse selection.

## Concurrency And Actor Ownership

All touched code runs on the MainActor. `MediaAssetTilePresentation.thumbnailFaceRect` is
`nonisolated` pure geometry. No background work is added or changed.

## Instrumentation

No new signposts needed. Existing selection telemetry (`MediaGridSelectionChanged`) and
empty-space logging continue to classify the click correctly because letterbox clicks will
now follow the existing empty-space path.

## Test And Acceptance Criteria

### Geometry unit tests

In `OtosTests/MediaAssetTilePresentationTests.swift`:

- Landscape thumbnail in a 120×120 cell (400×200 image): top-center and bottom-center
  letterbox points are misses; center is a hit.
- Portrait thumbnail in a 120×120 cell (200×400 image): left-center and right-center
  letterbox points are misses; center is a hit.
- Square thumbnail filling the cell: center is a hit; corner points inside the bounds are
  hits.
- Placeholder (`imagePixelSize == nil`): any point inside bounds is a hit.

### Controller integration tests

In `OtosTests/MediaAssetCollectionSelectionTests.swift`:

- Click the center of a landscape thumbnail → selects the item.
- Click in the top letterbox of the same tile → clears selection, anchor, and base.
- ⇧-click in the letterbox of a selected tile → selection unchanged (empty-space with
  modifier is a no-op).
- ⌘-click in the letterbox of an unselected tile → selection unchanged.

Extend the existing harness to configure one item with a known thumbnail pixel size and a
synthetic decoded image so `currentImagePixelSize` is set and the letterbox exists.

## Code-Smell Review For Target Area

- MainActor gravity: none; geometry is `nonisolated`, hit-test is MainActor as required by
  AppKit.
- SwiftUI body work: none; this is AppKit.
- State duplication: none; pixel size stays owned by the tile view.
- AppKit bridge sprawl: avoided by keeping geometry in `MediaAssetTilePresentation` and the
  hit-test decision in `MediaGridCollectionView`.
- Stringly typed facts: none.
- Test coupling: tests assert observable selection behavior, not internal coordinate paths.

## Stale-Document Audit

- `docs/product/PLAN-grid-selection-and-sidebar-fixes.md`: update Part 2 status to
  implemented.
- `docs/onboarding.md`: review the grid selection paragraph; update if it describes the
  whole cell as the hit area.
- `docs/specs/0046-grid-shift-click-range-selection.md`: no change; selection semantics
  untouched.
- `docs/adr/0006-catalog-grid-rendering.md`: no change; rendering geometry already
  documented.

## Retirement List

- The implicit assumption that the whole square cell is the selection hit area. Replaced
  by explicit thumbnail-face confirmation.
