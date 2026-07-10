# ADR 0006: Catalog Grid Rendering

## Status

Accepted.

## Decision Scope

This ADR owns the media browser rendering technology, layout, reusable item
boundary, and structural/detail collection update mechanics.

It references but does not own catalog truth, publication cadence, availability,
and ordering. ADR 0010 owns Store-executed ordering, identity-plus-generation grid
publication, and visible detail reads. ADRs 0002, 0004, and 0005 retain
scan/persistence, UI ownership, and publication ownership. This ADR owns the grid's
AppKit rendering, structural/detail update mechanics, the no-blank invariant
enforcement, animation and zoom, model-owned mouse selection, and the thumbnail-only
hit area (all folded in below). Sidebar source selection and the source lifecycle
(default/attach selection, All-Media visibility, eject) are owned by ADR 0014.
Preview still requires a separate future ADR if implemented. Thumbnail storage is
owned by ADR 0009; this ADR owns how the visible grid renders and refreshes those
thumbnail-backed values, including the invariant that a painted same-asset thumbnail
never blanks while the asset remains on screen. Scan-time media eligibility (UTType
image or movie) is owned by ADR 0002; the grid displays every cataloged eligible
asset.

## Context

The previous large media table can enter a permanent AppKit/SwiftUI table stall
with continuous heap growth after repeated scope changes (captured by `sample` and
heap evidence at the time). Otos needs a thumbnail-backed browser that can scale to
large libraries without putting one SwiftUI hosting tree behind every tile.

Paint truth for visible tiles is owned by `TileContentStore` (monotonic detail + decoded image); tiles only render that value. The no-blank invariant adds a stricter rendering fact: a tile whose thumbnail has
already painted must never render placeholder content for that same on-screen asset.
Baseline diagnostics showed large reorder-only snapshots being applied with
`animatingDifferences: false`; the macOS 27 AppKit SDK header documents that this
path applies by calling `reloadData` (`NSDiffableDataSource.h`), and AppKit does not
provide `applySnapshotUsingReloadData`. ReloadData tears down visible items, so
no-blank correctness cannot rely on AppKit preserving cell instances. The invariant
is enforced by `TileContentStore` (cost-bounded decoded images, visible IDs pinned
against prune and budget eviction) so a painted thumbnail never regresses to nil
for a visible asset; tiles are pure renderers of that store value. Diffable apply
semantics only affect how much work AppKit does. Same-descriptor same-membership
reorders (the enrichment trickle that publishes ~1/s while Best Date enrichment
runs) animate with `animatingDifferences: true`, which moves surviving items
instead of recreating them — measured `applyCallMs` for K = 1–3 movers at n ≈ 23k
is in the low tens of milliseconds (`docs/research/grid-reorder-cadence-and-appkit-diffable-apply.md`).
Descriptor-changed reorders and large membership applies keep the reloadData-class
path. The once-per-second reorder cadence is intentional; the hitch was the
reloadData teardown, not how often applies run.

## Alternatives

1. SwiftUI `LazyVGrid`: smallest source surface, but preserves large SwiftUI view
   graph risk and offers weak explicit backpressure.
2. `NSCollectionViewFlowLayout`: reusable cells, but requires manual column
   sizing and resize invalidation.
3. `NSCollectionViewCompositionalLayout`: reusable cells plus native fractional
   groups and diffable identity.
4. Custom AppKit tiler: maximum control, but needlessly rebuilds scrolling,
   reuse, layout, and accessibility.

## Decision

Use a narrow `NSViewControllerRepresentable` containing `NSCollectionView`,
`NSCollectionViewCompositionalLayout`, and `NSCollectionViewDiffableDataSource`.
The layout has one full-width group with square fractional items sized from the
current column count, 12-point section insets, and 8-point effective gaps.
Column count is user-selected, 3–9, default 6 (spec 0048) — not an invariant six
— owned by `CatalogWindowViewModel.gridColumnCount` and persisted across
launches; the AppKit controller only ever renders the published value through
one `receiveColumnCount(_:)` path, whether the request came from the View menu, a
toolbar slider, or a pinch gesture. That path and the diffable structural-apply
path are arbitrated by a single owner, `MediaGridMutationGate`, which holds
column-count truth (`installedColumnCount`/`requestedColumnCount`) and guarantees a
zoom swap and a structural apply never run concurrently in either direction: a zoom
requested during an apply, or a grid state arriving during a zoom swap, parks and
drains once the in-flight mutation completes. Zoom uses discrete animated layout
swaps (`NSAnimationContext` plus `NSCollectionView.animator().collectionViewLayout`),
never a continuous interactive transition: macOS exposes
`NSCollectionViewTransitionLayout` but no `startInteractiveTransition` driver
(that API is UIKit-only, verified against the Xcode 27 beta SDK), so there is no
documented way to drive a transition incrementally from a pinch gesture.

Tiles are layer-backed frame-layout AppKit views, not SwiftUI hosting views or
Auto Layout trees. Each square collection cell is transparent; the visible tile
face is the loaded thumbnail's native aspect-fit rect, or a full-square neutral
placeholder before the thumbnail is known. A dim, centered media-kind icon (film
for a known video, photo otherwise) sits on the placeholder until a thumbnail
paints for that tile for the first time — never a spinner or shimmer, which would
fabricate progress that is not happening (spec 0047). Tiles do not render
filename or relative date text. Only content whose generated best kind is video
gets a bottom-right badge inside the face: centered duration text when
available, otherwise a film symbol. The badge darkened area is right-aligned to
the thumbnail face with no outer inset and symmetric internal horizontal
padding. Images have no video badge, blue tint, or video-only backing color.

Apply a diffable snapshot when ordered IDs change. Small and user-visible
insert/remove changes, and same-descriptor same-membership reorders (enrichment
trickle), animate with a tuned duration and ease-out-with-overshoot curve
(`MediaGridAnimation`), applied through an explicit
`NSAnimationContext` group around the animated apply branch only. While scroll
bounds have tickled within the last 250 ms, the group still calls
`apply(animatingDifferences: true)` but sets `duration = 0` — mid-scroll move
animations are invisible churn that feeds Core Animation commit pressure
(plan 0009). Never downgrade to `animatingDifferences: false` for that case;
that is the reloadData teardown path. A `MediaGridAnimatedLayout` fades and
shrinks only the index paths a given apply batch actually inserted or deleted,
leaving every other appearing/disappearing item (scroll dequeue, a future zoom
swap) — and every moved item in a move-only batch — at `super`'s unmodified
attributes so moves animate as plain position changes. Reorder-only completion
skips `TileContentStore.prune` (membership identical by definition). The
mutation gate retains `displayedOrderedIDSet` with `displayedOrderedIDs` so
apply-policy summarize does not rebuild the previous-order Set every apply.
Descriptor-changed reorders (sort/scope/filter flips) and large membership
applies (`n ≥ 1000`) use AppKit's reloadData-class diffable path
(`animatingDifferences: false`), completely unaffected by the animation tuning
above. Same-descriptor reorders are structurally bounded to small mover counts
by enrichment batch caps within one projection tick; do not add LIS/mover-count
gating without a fresh measurement against the research harness table. This is
visually safe because `TileContentStore` holds any decoded thumbnail for a
visible (pinned) asset and never drops it under budget pressure, so a recycled
tile can synchronously repaint and never downgrades a painted same-asset image
to placeholder content. The fallback is an apply-policy choice only; it does not
make the catalog or `TileContentStore` a source of media truth. A thumbnail's
arrival from an async decode (never a store hit) fades in; a store-hit repaint
(scroll-back, recycled-cell sync repaint) stays instant to
avoid reading as flicker. A per-column stagger flourish was attempted and
retired: a delayed, backwards-filled `CATransition` held first-paint tiles at
their prior (`nil`) contents during the delay, showing a transparent gap
instead of the placeholder — a no-blank-invariant violation the owner's own
plan had pre-authorized dropping rather than fixing with async machinery.

For unchanged IDs, re-read visible details through the Store-backed detail reader
and reconfigure the existing visible items in place. Do not call AppKit item reload
for a detail-only refresh: reload enters the reuse lifecycle, and reusable tile
cleanup clears the thumbnail before the async loader repaints it. Before each
reconfigure, merge, or dequeue paint pass, pin the current visible identity set once
in `TileContentStore`; do not re-derive that set per tile. Scroll-driven viewport
reporting, visible detail queries, and preheat look-ahead coalesce on a trailing
~16 ms edge and skip a new detail query when the visible identity list is unchanged,
matching the enrichment viewport's newest-value delivery and avoiding per-bounds-tick
Store cancellation. Permit one structural apply at a time and retain only the latest
pending grid state. Reset scroll and selection only when the query descriptor changes; same-descriptor
structural applies restore surviving selected identities through the minimal
selection delta (`MediaGridSelection.selectionDelta`), so a surviving tile's
selection state is never reassigned and its animated ring never blinks on a
background apply. The selection ring is drawn on the visible tile face, so it
follows the thumbnail aspect instead of the whole square cell, and fades in/out
over a tuned duration rather than snapping.

## Why This Is Simplest Correct

The verified table failure justifies leaving SwiftUI for this one rendering
surface. Collection view supplies the required bounded reuse and identity
lifecycle without a custom renderer. Compositional layout directly expresses a
responsive column count and removes flow-layout width bookkeeping; rebuilding
the same layout type with a new column count is what makes zoom a small,
data-driven change rather than a new rendering mechanism.

## Consequences

- Media rendering has one narrow MainActor AppKit boundary.
- SwiftUI remains responsible for window composition and empty-state shell.
- Collection updates are imperative but isolated and state-machine tested.
- Same-identity background enrichment or fact-detail updates do not recycle
  visible cells; if AppKit does recycle a visible cell for structural reasons, the
  tile synchronously repaints from `TileContentStore` when available. Video badge
  updates do not participate in image identity.
- Missing detail rows, detail-query failures, and nil thumbnail decode results
  are information loss, not proof that a painted same-asset thumbnail should be
  cleared.
- Native AppKit selection and responder-chain copy behavior live at this boundary
  so SwiftUI and the ViewModel do not mirror high-cardinality selection state.
  Mouse selection is model-owned: a pure `GridSelection` value is the single
  selection truth, `MediaGridCollectionView.mouseDown` does not call `super.mouseDown`
  (AppKit's native mouse-selection tracking loop never runs, so there is no commit to
  race), and `selectionIndexPaths` is a render output written from the model — not a
  second selection model. The prior read-AppKit-then-correct design coupled the
  computation to AppKit's undocumented mouseDown/mouseUp commit timing and lost the
  race; owning the model removes that class of bug. Keyboard selection (⌘A, ⇧-arrows)
  stays native and the model reconciles from `selectionIndexPaths` afterward: when the
  live selection differs, `base` becomes the live set (anchor unchanged) so a later
  ⇧-click unions against the keyboard result instead of a stale pre-keyboard base.
- Only a click inside the tile's aspect-fit thumbnail *face* selects the tile;
  letterbox padding around a decoded thumbnail is treated as empty space (matching
  Photos). The face geometry is shared with the renderer through
  `MediaAssetTilePresentation` so the hit-test and the drawn face cannot drift.
- Settings may continue using SwiftUI `Table`; this decision concerns only the
  high-cardinality media browser.

## References

- Apple, [NSCollectionView](https://developer.apple.com/documentation/appkit/nscollectionview)
- Apple, [NSCollectionView layout ownership](https://developer.apple.com/documentation/appkit/nscollectionview/collectionviewlayout)
- Apple, [UTType.movie](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/movie)
- `NSDiffableDataSource.h` (macOS 27 SDK): `animatingDifferences: false` applies via
  `reloadData`; there is no `applySnapshotUsingReloadData`.
- Implemented in `Otos/Views/MediaGrid*.swift`, `Otos/Views/MediaGrid*.swift`,
  `Otos/Views/MediaAssetTileView.swift`, `Otos/Views/GridSelection.swift`;
  requirements APP-006/010/011/015.
