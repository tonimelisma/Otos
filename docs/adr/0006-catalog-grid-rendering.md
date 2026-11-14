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
Loupe/compare preview decode is owned by ADR 0016. Thumbnail storage is
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
Large and query-changing structural applies go through `reloadData`, which tears
down visible items, so no-blank correctness cannot rely on AppKit preserving cell
instances. The invariant
is enforced by `TileContentStore` (cost-bounded decoded images, visible IDs pinned
against prune and budget eviction) so a painted thumbnail never regresses to nil
for a visible asset; tiles are pure renderers of that store value. Which apply path
runs only affects how much work AppKit does. Same-descriptor same-membership
reorders (the enrichment trickle that publishes ~1/s while Date-sort enrichment
runs) animate as a batch of moves, which moves surviving items
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
   groups.
5. `NSCollectionViewDiffableDataSource` over the compositional layout: identity
   diffing for free, but its snapshot costs days × items to build (13–15 s at the
   owner's 158,000 items over 5,000 days) and macOS has no section snapshot or
   multi-section append to avoid that. Used until 2026-11; replaced by Otos's own
   `MediaGridStructure` and a classic data source.
4. Custom AppKit tiler: maximum control, but needlessly rebuilds scrolling,
   reuse, layout, and accessibility.

## Decision

Use a narrow `NSViewControllerRepresentable` containing `NSCollectionView`,
`NSCollectionViewCompositionalLayout`, and the controller as its
`NSCollectionViewDataSource` over one `MediaGridStructure` value.
The layout has one full-width group with square fractional items sized from the
current column count, 12-point section insets, and 8-point effective gaps.
Column count is user-selected, 3–9, default 6 (APP-006) — not an invariant six
— owned by `CatalogWindowViewModel.gridColumnCount` and persisted across
launches; the AppKit controller only ever renders the published value through
one `receiveColumnCount(_:)` path, whether the request came from the View menu,
toolbar −/+ buttons, or a pinch gesture. That path and the structural-apply
path are arbitrated by a single owner, `MediaGridMutationGate`, which holds
column-count truth (`installedColumnCount`/`requestedColumnCount`) and guarantees a
zoom swap and a structural apply never run concurrently in either direction: a zoom
requested during an apply, or a grid state arriving during a zoom swap, parks and
drains once the in-flight mutation completes. Zoom uses discrete animated layout
swaps (`NSAnimationContext` plus `NSCollectionView.animator().collectionViewLayout`),
and a same-mode SwiftUI presentation update never installs the new grid density
first: `receiveColumnCount(_:)` is the sole layout-swap path for grid zoom. Zoom is
never a continuous interactive transition: macOS exposes
`NSCollectionViewTransitionLayout` but no `startInteractiveTransition` driver
(that API is UIKit-only, verified against the Xcode 27 beta SDK), so there is no
documented way to drive a transition incrementally from a pinch gesture.

Under Date sort the grid groups into day sections (DES-069, APP-030) via a
`sectionProvider` closure on `NSCollectionViewCompositionalLayout` rather than a
fixed `section:`, so `.day` and `.ungrouped` sections can differ in whether they
carry a header without rebuilding the layout object on a data change. Which sections
carry one is answered from the controller's `MediaGridStructure`, the one value the
collection view's data source, the layout, the day bar, the headers, selection, drag,
prefetch, zoom and scroll anchoring all read. The structure is built fresh from
`CatalogMediaGridState.orderedAssetIDs` plus a parallel `dayBuckets: [Date?]` on every
structural apply, in one pass: sections are contiguous ranges of the order, keyed by day
(`.day(nil)` for the unknown-date run, `.ungrouped` for any other sort), with an identity
→ position index for lookups. It is pure and independent of AppKit. An animated apply
matches sections by key to derive its batch; nothing else compares sections across
applies, so there is no section-level invalidation to go stale.

The controller is a classic `NSCollectionViewDataSource` over that value, not an
`NSCollectionViewDiffableDataSource`. AppKit's diffable snapshot copies its whole item set
on every mutating call and offers no call that fills more than one section, so a
day-grouped grid cost days × items to describe: 13–15 s for the owner's 158,000 items
over about 5,000 days, during which the grid was blank
(`docs/research/2026-11-14-grid-structure-without-diffable-snapshot.md`). Query changes
and large membership changes call `reloadData`, which is what the diffable non-animated
apply did. Small and same-query reorder applies call `performBatchUpdates` with
`MediaGridBatchUpdates`: sections only in the old structure are deleted and only in the
new inserted; an item crossing into an inserted or out of a deleted section is a delete
plus an insert, because AppKit cannot move it there; among the rest, the longest run
already in old order stays and every other item is an explicit move, so a few photos
changing day in a large grid are a few moves. A change no batch can describe (surviving
sections that swap order, a repeated section key — neither occurs under Date sort)
reloads.

A day is named twice — in flow at the head of its run, and by
`MediaGridDayBarView` held at the grid's top edge. **Those are one label drawn
twice, not two kinds of object**: `MediaGridDayLabel.swift` owns the single view both
hosts draw, so neither can restyle it, and the label takes DES-022's `content` value
because it is a section header rather than chrome. The two occupy the same rect —
`supplementariesFollowContentInsets` is off, because following the section insets put
the header at x=12 w=876 against the bar's x=0 w=900 and the label jumped 12 pt
sideways at every handoff — so the handoff needs no animation at all. The bar alone
draws a DES-023 hairline at its bottom edge, the contextual scroll edge macOS draws
while content passes beneath a floating element (`NSTitlebarSeparatorStyle.automatic`). An earlier revision gave the bar
the `bar` value and left the header bare; the two immediately read as unrelated things
that happened to be adjacent, which is the defect this arrangement exists to prevent.

The header is deliberately not pinned. `pinToVisibleBounds` does not stick the
current header: it moves every header of the section out of the collection view into
`_NSScrollViewFloatingSubviewsContainerView`, where AppKit recomputes each frame from
the main thread on every bounds change while the tiles move on the compositor, so the
header visibly slides against its own run under main-thread load. It also installs an
`NSScrollPocket` sized to the bar, whose `PocketBlur` portals the tiles passing
beneath, and macOS 26+ offers no public way to decline it — `NSScrollEdgeEffectStyle`
is settable only on titlebar and split-view-item accessory view controllers, and
SwiftUI's `NavigationSplitView` does not vend its `NSSplitViewItem`. The bar is held
by constraints that never change, so a constant frame cannot separate from the content
it labels, and app-owned colors honor DES-022/023/084 and DES-070/075. Which day it
names — the day owning the viewport's top edge, including the inset gap between runs,
which belongs to the day being left — is the pure `MediaGridDayBarPolicy`, and that is
what makes DES-069 testable without a live collection view. The bar reserves no space and is shown
continuously wherever there is a day to name: at the top of the grid it rests exactly
on the first header and draws the same label in the same rect, so leaving it on costs
nothing visible and removes a state. It is resolved on every scroll-bounds change
rather than behind `flushScrollDrivenWork`'s coalesce — a trailing-edge debounce with
no maximum wait, cancelled by each bounds change, so work behind it does not run until
scrolling stops. That cadence is right for restarting Store queries and wrong for a
label naming what the user is looking at. The label is the one `NSHostingView` kind in this
otherwise pure-AppKit grid — justified by cardinality (one per day and one per grid,
not one per tile), letting it reuse `DesignPalette`'s SwiftUI dynamic-appearance colors
instead of AppKit-native dynamic-color infrastructure built for a low-cardinality view.
Alternatives weighed, including pushing the bar out with the incoming header and
dropping the in-flow header entirely, are in
`docs/research/2026-09-04-grid-day-header-pinning-and-scroll-edge-effect.md`.

Tiles are layer-backed frame-layout AppKit views, not SwiftUI hosting views or
Auto Layout trees. Each square collection cell is transparent; the visible tile
face is the loaded thumbnail's native aspect-fit rect, or a full-square neutral
placeholder before a real thumbnail is known. A dim, centered glyph sits on the
placeholder — never a spinner or shimmer: loading uses `photo` / `r.square`
(RAW) / `film` (video); enrichment that stamped the asset with no obtainable
thumbnail (QuickLook icon fallback rejected) uses `photo.slash` (image and RAW)
or `video.slash` (video). Broken tiles never show a lower-right kind badge.
Tiles do not render filename or relative date text. Lower-right shaded badges
appear only after a real thumbnail has painted: video tiles show
center-justified clip length when known, otherwise a film icon (duration
extraction failed); raw image tiles show the word `RAW` in the same shaded
style; plain images and all placeholder/broken tiles show no lower-right badge.
The badge darkened area is right-aligned to the thumbnail face with no outer
inset; text is centered on its measured width within the badge (including when
the min-width clamp wins). Faces under 56 pt hide the badge. Images have no
blue tint or video-only backing color.

Apply a new structure when ordered IDs or day buckets change. Small and user-visible
insert/remove changes, and same-descriptor same-membership reorders (enrichment
trickle), animate as a `performBatchUpdates` batch with a tuned duration and
ease-out-with-overshoot curve (`MediaGridAnimation`), applied through an explicit
`NSAnimationContext` group around the batch only. While scroll
bounds have tickled within the last 250 ms (or Reduce Motion is on, or an anchored
strip restore would scroll by the survivors' own travel), the group still runs the
batch but sets `duration = 0` — mid-scroll move
animations are invisible churn that feeds Core Animation commit pressure. Never downgrade to `reloadData` for that case;
that is the teardown path. Separately, `MediaGridMutationGate`
holds same-descriptor structural-apply *adoption* while scroll is live
(`scrollHold`, released after the same 250 ms quiet threshold): enrichment
reorders park newest-wins and apply once on quiet; descriptor-changed grids
bypass the hold; zoom swaps are unaffected. A `MediaGridAnimatedLayout` fades and
shrinks only the index paths a given apply batch actually inserted or deleted,
leaving every other appearing/disappearing item (scroll dequeue, a future zoom
swap) — and every moved item in a move-only batch — at `super`'s unmodified
attributes so moves animate as plain position changes. Reorder-only completion
skips `TileContentStore.prune` (membership identical by definition). The
apply-policy summary reads membership from the previous structure's own identity
index, so no apply rebuilds a set of the identities on screen.
Descriptor-changed reorders (sort/scope/filter flips) and large membership
applies (`n ≥ 1000` on either side: the grid on screen or the next one, because
an animated batch pays for every removed item as well as every inserted one) use `reloadData`,
completely unaffected by the animation tuning
above. Same-descriptor reorders keep only the longest in-order run in place and move
the rest, so their batch is as small as the change. This is
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
pending grid state. A structural apply has two halves inside that one exclusive slot.
The pure half — the next `MediaGridStructure`, the diff summary against the structure on
screen, and, for an animated apply, the `MediaGridBatchUpdates` between the two — is
built off the main actor (`@concurrent`) from `Sendable` values copied when the gate
admits the apply. The AppKit half — scroll anchor capture, handing AppKit the structure
(`reloadData`, or `performBatchUpdates` with the structure switched inside the update
block), the anchor restore — then runs synchronously on the main actor. Nothing on screen
can change between the halves: the gate is in flight, so no other apply or zoom swap runs
and a grid arriving meanwhile parks. The build is linear in items and flat in days: 0.16 G
instructions for 158,000 items over 5,000 days, where the diffable snapshot it replaced
took 54 G (13–15 s on the owner's library), because AppKit's snapshot copies its whole
item set on every mutating call and has no call that appends to more than one section
(`docs/research/2026-11-14-grid-structure-without-diffable-snapshot.md`). The apply call
stays on the main actor and still grows with days: compositional layout re-solves every
section on a reload, measured in the same note. Reset scroll and selection only when the sidebar scope changes; a filter or
sort change keeps the user's place by anchoring on a visible selected tile or the top tile's
nearest survivor (APP-042); same-descriptor
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

- Media rendering has one narrow MainActor AppKit boundary. The structure a structural
  apply hands it is built off the main actor; only the apply itself runs on it.
- Batch derivation is Otos's code, not AppKit's: a wrong batch raises inside AppKit, so
  `MediaGridStructureTests` replays every derived batch against the structure it must
  produce, including randomized changes, and drives a live collection view through it.
- SwiftUI remains responsible for window composition and empty-state shell.
- Collection updates are imperative but isolated and state-machine tested.
- Same-identity background enrichment or fact-detail updates do not recycle
  visible cells; if AppKit does recycle a visible cell for structural reasons, the
  tile synchronously repaints from `TileContentStore` when available. Video badge
  updates do not participate in image identity.
- Missing detail rows, detail-query failures, and nil thumbnail decode results
  are information loss, not proof that a painted same-asset thumbnail should be
  cleared.
- Native AppKit selection rendering and responder-chain copy behavior live at this
  boundary. Selection *truth* is a pure `GridSelection` value owned by
  `CatalogWindowViewModel` so grid and filmstrip surfaces share one model across mode
  switches; the AppKit controller is a synchronous renderer of that value.
  `MediaGridCollectionView.mouseDown` does not call `super.mouseDown` (AppKit's native
  mouse-selection tracking loop never runs, so there is no commit to race), and
  `selectionIndexPaths` is a render output written from the model — not a second
  selection model. The prior read-AppKit-then-correct design coupled the computation to
  AppKit's undocumented mouseDown/mouseUp commit timing and lost the race; owning the
  model removes that class of bug. Keyboard selection (⌘A, ⇧-arrows) stays native and
  the model reconciles from `selectionIndexPaths` afterward: when the live selection
  differs, `base` becomes the live set (anchor unchanged) so a later ⇧-click unions
  against the keyboard result instead of a stale pre-keyboard base.
- Only a click inside the tile's aspect-fit thumbnail *face* selects the tile;
  letterbox padding around a decoded thumbnail is treated as empty space (matching
  Photos). The face geometry is shared with the renderer through
  `MediaAssetTilePresentation` so the hit-test and the drawn face cannot drift.
- Settings may continue using SwiftUI `Table`; this decision concerns only the
  high-cardinality media browser.
- Day-section grouping needed no changes to `MediaGridStructuralApplyPolicy` or
  `MediaGridMutationGate`: both operate purely on flat `[MediaAssetID]`/
  `Set<MediaAssetID>` identity, agnostic to section structure, because sections
  are rebuilt fresh from current data on every apply rather than independently
  diffed. The no-blank invariant (APP-015) holds across a day-bucket change
  (enrichment correcting a capture date moves an asset between sections) for the
  same reason it holds across any other structural churn: `TileContentStore` is
  keyed by asset identity, not position or section.

## References

- Apple, [NSCollectionView](https://developer.apple.com/documentation/appkit/nscollectionview)
- Apple, [NSCollectionView layout ownership](https://developer.apple.com/documentation/appkit/nscollectionview/collectionviewlayout)
- Apple, [UTType.movie](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/movie)
- `NSDiffableDataSource.h` (macOS 27 SDK): single-section mutators only, no section
  snapshot; `docs/research/2026-11-14-grid-structure-without-diffable-snapshot.md`.
- Implemented in `Otos/Views/MediaGrid*.swift`, `Otos/Views/MediaGrid*.swift`,
  `Otos/Views/MediaAssetTileView.swift`, `Otos/Views/GridSelection.swift`,
  `Otos/Views/MediaGridDayHeaderView.swift`,
  `Otos/ViewModels/CatalogWindowViewModelSelection.swift`;
  requirements APP-006/010/011/015/030.
