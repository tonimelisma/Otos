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
instead of recreating them — the measured synchronous apply call (the structural-apply line's `commitMs`) for K = 1–3 movers at n ≈ 23k
is in the low tens of milliseconds (`docs/research/grid-reorder-cadence-and-appkit-diffable-apply.md`).
Descriptor-changed reorders and large membership applies keep the reloadData-class
path. AppKit holds the grid's order as one section — an item's index path is its
position, a day header's is keyed by its day — and the day sections are the layout's,
because AppKit does work for every section it holds on each update: at the owner's 5,000
days a one-photo batch cost about 93 M main-thread instructions against about 30 M with one
section, so a small removal or insertion (Move to Trash, a stack expanding, an import's
arrival) animates as a batch at any grid size
(`docs/research/2026-11-15-grid-removal-without-a-reload.md`). The once-per-second reorder cadence is intentional; the hitch was the
reloadData teardown, not how often applies run.

## Alternatives

1. SwiftUI `LazyVGrid`: smallest source surface, but preserves large SwiftUI view
   graph risk and offers weak explicit backpressure.
2. `NSCollectionViewFlowLayout`: reusable cells, but requires manual column
   sizing and resize invalidation.
3. `NSCollectionViewCompositionalLayout`: reusable cells plus native fractional
   groups, but it solves every section on each invalidation, about 0.5 M instructions
   a section: 2.7 G instructions and about 320 ms of main thread for every reload and
   every batch at the owner's 4,816 days, and enrichment publishes a reorder every few
   seconds. Used until 2026-11-15; replaced by Otos's own `MediaGridLayout`, which
   keeps its pixel geometry exactly
   (`docs/research/2026-11-15-grid-layout-without-compositional-solve.md`). The
   filmstrip, one section solved once, keeps it.
5. `NSCollectionViewDiffableDataSource` over the compositional layout: identity
   diffing for free, but its snapshot costs days × items to build (13–15 s at the
   owner's 158,000 items over 5,000 days) and macOS has no section snapshot or
   multi-section append to avoid that. Used until 2026-11; replaced by Otos's own
   `MediaGridStructure` and a classic data source.
4. Custom AppKit tiler: maximum control, but needlessly rebuilds scrolling,
   reuse, layout, and accessibility.

For a grid state that arrives while an earlier apply's tiles still move (an act's result,
which must show within 100 ms):

6. Hold it as pending until AppKit reports the motion finished. Used until 2026-11-16: a
   Put Back waited 191 ms for the Trash removal's motion, and five Deletes in a row each
   waited for the one before.
7. End the running motion at its final frames (`removeAllAnimations`), then apply. AppKit
   allows it, but every moving tile jumps to its end before moving again, and it is not
   needed: AppKit already starts a new batch's motion from where each tile is drawn.
8. Shorter or no motion. A shorter motion only shortens the wait, and the 0.35 s motion is
   DES-070's duration for content changing place.

For an act whose publication was made from an order the grid has not shown (a read that
moved photos, published just before the act and skipped by the window's newest-wins
delivery), which at the owner's 160,000 items cost a comparison of the two whole orders,
40–47 ms of the act's 100 ms:

9. Compare the two orders, as before: the act's result waits for a pass over every item.
10. The act first against what the grid shows, the reorder after: the user asked for the
    act, the reorder is background. But the act's edit names positions in an order the
    grid never showed, so it must be carried onto the shown one by identity, and a Put
    Back's item placed there beside neighbours that the reorder may have moved to another
    day, splitting a day the next apply joins again; the grid would show an order no
    publication holds, and the reorder would still be compared in full after it.
11. Both as one composed edit (chosen). The reorder is described where it is made, in the
    walk Projection already makes to tell two orders equal, and the act's edit composes
    with it at the cost of the two edits. The grid shows only published orders, applies the
    act and the reorder in the one batch that turns what it shows into the newest, in the
    turn that delivers it, with selection, focus and the anchor kept as for any batch, and
    compares nothing. A new query's order is still published whole and compared.

## Decision

Use a narrow `NSViewControllerRepresentable` containing `NSCollectionView`,
`MediaGridLayout`, and the controller as its
`NSCollectionViewDataSource` over one `MediaGridStructure` value.
The layout is arithmetic: square tiles in equal columns sized from the current column
count, 12-point section insets, 4-point tile insets (8-point effective gaps), and a
fixed-height full-width day header per day section. `MediaGridLayoutGeometry` holds
the sections' unrounded start positions (one pass over the section counts at
`prepare()`), answers any frame directly, and answers a rect query by binary search
over sections and arithmetic over rows, so its cost is the elements returned, not the
grid's size. Frames are rounded to backing pixels as the compositional layout it
replaced rounded them, and `MediaGridLayoutTests` keeps that layout's measured frames
as its oracle. Scrolling never invalidates it; a width change or a backing-scale
change does.
Column count is user-selected, 3–9, default 6 (APP-006) — not an invariant six
— owned by `CatalogWindowViewModel.gridColumnCount` and persisted across
launches; the AppKit controller only ever renders the published value through
one `receiveColumnCount(_:)` path, whether the request came from the View menu,
toolbar −/+ buttons, or a pinch gesture. That path and the structural-apply
path are arbitrated by a single owner, `MediaGridMutationGate`, which holds
column-count truth (`installedColumnCount`/`requestedColumnCount`) and guarantees a
zoom swap and a structural apply never run concurrently in either direction: a zoom
requested during an apply's build and commit, or a grid state arriving during a zoom
swap, parks and drains once the in-flight mutation completes. A structural apply is in
flight only until its commit returns (below, "Applies do not wait for motion"); a zoom
swap is in flight until its motion ends, because its anchor scroll is animated and its
visible-detail pass reads the viewport that scroll ends at. Zoom uses discrete animated layout
swaps (`NSAnimationContext` plus `NSCollectionView.animator().collectionViewLayout`),
and a same-mode SwiftUI presentation update never installs the new grid density
first: `receiveColumnCount(_:)` is the sole layout-swap path for grid zoom. Zoom is
never a continuous interactive transition: macOS exposes
`NSCollectionViewTransitionLayout` but no `startInteractiveTransition` driver
(that API is UIKit-only, verified against the Xcode 27 beta SDK), so there is no
documented way to drive a transition incrementally from a pinch gesture.

Under Date sort the grid groups into day sections (DES-069, APP-030). The layout asks,
at each `prepare()`, which sections carry a header, so `.day` and `.ungrouped`
sections can differ in whether they carry one without rebuilding the layout object on
a data change. Which sections carry one is answered from the controller's `MediaGridStructure`, the one value the
collection view's data source, the layout, the day bar, the headers, selection, drag,
prefetch, zoom and scroll anchoring all read. The structure is built fresh from
`CatalogMediaGridState.orderedAssetIDs` plus a parallel `dayBuckets: [Date?]` on every
structural apply, in one pass: sections are contiguous ranges of the order, keyed by day
(`.day(nil)` for the unknown-date run, `.ungrouped` for any other sort); identity lookups
read the position index of the publication's shared `CatalogGridContent`, which Projection
makes off the main actor (an order made by an edit takes its source's index with the edit
applied, ADR 0005), so the structure builds no index of its own. It is pure and independent of AppKit. An animated apply
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
plus an insert, because AppKit cannot move it there; an item changing between surviving
sections is an explicit move; within a surviving section the longest run of its own items
already in old order stays and every other item is an explicit move, so a few photos
changing day in a large grid are a few moves. Both the apply policy's summary and the
batch read one `MediaGridStructureChange`, which pairs sections by key, compares each
pair's items from both ends for the runs they share, and looks up by identity only what
lies between those runs and the items of unpaired sections: a few photos changing day
look up a few hundred identities, not the library
(`docs/research/2026-11-15-grid-reorder-follows-the-change.md`). That comparison is only
for a new query's order. Every other publication says how its order was made from the ones
before it (`CatalogGridContent.Edit`: positions removed from the old order, positions
inserted into the new, an item in both being a move): a hide, a Put Back, a stack expanding
or collapsing, and a read that moved photos, which Projection describes in the same walk
that tells two orders equal (`Edit.between`, ADR 0005). Each content keeps, for every
earlier order still held anywhere, the edit from it, the edits of the publications between
composed (`Edit.followed(by:)`, held weakly, so no order is kept alive for its lineage). So
a grid showing an older order than the one an act's publication was made from — the window
applies only the newest publication, and an act often lands just after a read that moved
photos — still takes the act in by an edit: its structure is the old sections edited and
its batch the edit's deletes, inserts and moves, what a fresh build and a full comparison
make, at the cost of the sections and the edit, not the grid
(`docs/research/2026-11-15-grid-hide-follows-the-removal.md`,
`docs/research/2026-11-17-acts-on-an-unshown-reorder.md`). A change no batch can describe (surviving
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
holds same-descriptor structural-apply *adoption* while the user scrolls
(`scrollHold`, released after the same 250 ms quiet threshold). Only the user's ticks begin
it (`MediaGridScrollInput`): inside AppKit's live-scroll bracket (a gesture with its momentum,
or the scroller) or while a scroll-wheel event is handled (a wheel mouse sends no bracket). A
bounds change Otos makes itself (an apply keeping its anchor, a focus scroll, a clamp after a
layout) holds nothing: at the owner's library size each Move to Trash's own anchor-keeping
apply otherwise held the next act's result for the whole threshold
(`docs/research/2026-11-17-acts-at-the-owners-library-size.md`). Enrichment
reorders park newest-wins and apply once on quiet; descriptor-changed grids
bypass the hold; zoom swaps are unaffected. AppKit's base layout supplies the
attributes a batch animates between (a survivor from its old frame to its new one, an
insert fading in, a delete fading out — measured identical to what the compositional
layout supplied), and `MediaGridLayout` additionally shrinks only the index paths a
given apply batch actually inserted or deleted, leaving every other
appearing/disappearing item (scroll dequeue, a zoom swap) — and every moved item in a
move-only batch — at `super`'s unmodified attributes so moves animate as plain
position changes. Reorder-only completion
skips `TileContentStore.prune` (membership identical by definition), and so does the
completion of an apply that followed an edit: a Move to Trash's tiles come back by its Put
Back, inserted beside their neighbours, and come back painted (APP-015); the next apply of a
new query's order, published whole, prunes them, and until then they are off-screen tiles like
any other, which the store keeps only within its off-screen limit (below). The
apply-policy summary reads membership from the previous structure's own identity
index, so no apply rebuilds a set of the identities on screen.
Descriptor-changed reorders (sort/scope/filter flips) and large membership
applies (`n ≥ 1000` items inserted plus removed, because an animated batch pays for
every removed item as well as every inserted one) use `reloadData`,
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
admits the apply. The exception is an order made from the one on screen by edits (a
Move to Trash's hide, its Put Back's items inserted beside their neighbours, a stack
expanding or collapsing, a read that moved photos, composed across publications the window
skipped: `CatalogGridContent.edit(from:)`) naming fewer positions than the reload threshold:
its structure is the old sections edited, its batch the edit's deletes, inserts and moves, a cost
of the sections and the edit rather than the items, so it is built in the main-actor turn
that delivered it and committed in the same turn; a larger edit (a scan's arrivals) looks up
every identity it inserts and is built off the main actor like any other. Sending a small one off the main actor bought
nothing and cost the act's result a second main-thread turn, which the sandbox tour
measured at 106 ms (`docs/research/2026-11-16-grid-applies-during-motion.md`). The AppKit half — scroll anchor capture, handing AppKit the structure
(`reloadData`, or `performBatchUpdates` with the structure switched inside the update
block), the anchor restore — then runs synchronously on the main actor. Nothing on screen
can change between the halves: the gate is in flight, so no other apply or zoom swap runs
and a grid arriving meanwhile parks.

**Applies do not wait for motion.** An apply is complete when its commit returns: from
that moment AppKit's data, layout and item views hold the new structure, and only the
drawn positions are still travelling to their frames. So the apply's completion — tile
pruning, the visible-detail pass, the selection render, the gate's drain — runs as the
commit returns, and the gate is free at once. A grid that arrives while tiles still move
is committed in its own turn: AppKit accepts a batch issued during another's motion, and
starts each moving tile's new motion from where it is drawn, so a tile changes course
toward its newest place rather than jumping; every batch's completion still arrives,
finished, possibly out of order
(`docs/research/2026-11-16-grid-applies-during-motion.md`). That completion only reports
how long the motion ran (`op=ui.mediaGrid.motion`); the grid counts the motions still
running (`motionsInFlight`, logged as `motionsInFlightAtCommit` on each apply) and waits
for none. A Move to Trash, a Put Back, or five Deletes pressed in a row each show their
result in the turn their state arrives (DES-119). The build reads every item once to cut the day
sections and once to compare the days a reorder left alone, and looks up and diffs only
what changed: 0.54 G instructions (Debug) to move 200 photos between days in a grid of
158,000 items over 5,000 days, where looking up every identity took 4.5 G
(`docs/research/2026-11-15-grid-reorder-follows-the-change.md`), and the diffable snapshot it replaced
took 54 G (13–15 s on the owner's library), because AppKit's snapshot copies its whole
item set on every mutating call and has no call that appends to more than one section
(`docs/research/2026-11-14-grid-structure-without-diffable-snapshot.md`). The apply call
stays on the main actor; with the arithmetic layout its layout share is a pass over the
section counts, which the layout takes from the structure in one value rather than one
count and one header flag asked per section, and what remains of a batch is AppKit's own update bookkeeping, about
20 ms at the owner's 158,765 items plus about 0.4 M instructions a move
(`docs/research/2026-11-15-grid-layout-without-compositional-solve.md`). Reset scroll and selection only when the sidebar scope changes; a filter or
sort change keeps the user's place by anchoring on a visible selected tile or the top tile's
nearest survivor (APP-042); same-descriptor
structural applies restore surviving selected identities through the minimal
selection delta (`MediaGridSelection.selectionDelta`), so a surviving tile's
selection state is never reassigned and its animated ring never blinks on a
background apply. The selection ring is drawn on the visible tile face, so it
follows the thumbnail aspect instead of the whole square cell, and fades in/out
over a tuned duration rather than snapping.

### What the tile store keeps

`TileContentStore` keeps the visible tiles, pinned, and off screen the most recently used
`offscreenScreens` (16) screens of the visible set's size, at least 64 tiles a screen: the four
the preheat look-ahead decodes (two screens either way of the visible one) and twelve more that
were scrolled past, so a scroll back over them paints from the store. A tile beyond that is
dropped, its entry and image together, and read and decoded again if it comes back on screen;
the look-ahead decodes it before it arrives in an ordinary scroll. The drop runs when an entry
is added and a quarter of the limit has gathered past it, one sort of the held entries, so its
cost is the entries the store holds, never the scope. The 256 MB image budget stays as a cap.
With the owner's 256-pixel thumbnails (about 196–256 KB counted each) the budget holds
1,000–1,300 tiles and the limit about 1,100 at the default six columns, so on his library the
store keeps about what it kept before; on a library whose thumbnails are smaller, the limit
binds.

This is what the store was designed to hold. Bounded by the byte budget alone, it kept every
tile it had ever decoded until the budget's count of 4 bytes a pixel reached 256 MB, and a
backlog keeps bringing new tiles on screen: on a new 160,002-file library of 64 × 64 thumbnails
the store held 3,757, 5,921 and 8,844 decoded tiles at footprints of 453, 608 and 754 MB, each
costing about 37 KB (a 16 KB surface, a 14 KB and a 2.5 KB decoder buffer and about 4.6 KB of
Image I/O and Core Animation objects) against the 16 KB the budget counted, and about 44 % of
the footprint at the last
(`docs/research/2026-11-17-tile-store-under-a-backlog.md`). On a library of small thumbnails,
a scroll back past sixteen screens of tiles now shows placeholder content on tiles until their
thumbnails decode, as a tile evicted under the budget always did: no
tile on screen is ever blanked (APP-015).
Rejected: a smaller byte budget (the bytes a tile costs depend on its thumbnail and its
decoder, not on the 4 bytes a pixel the store can count, so a budget sized for one library
keeps 16 times as many tiles of another); pruning to a range of positions around the visible
one on every apply (a reorder moves which items stand there, so it costs a walk of the range
per apply, and it drops a tile that has only moved).

## Why This Is Simplest Correct

The verified table failure justifies leaving SwiftUI for this one rendering
surface. Collection view supplies the required bounded reuse and identity
lifecycle without a custom renderer. The grid's geometry is a uniform square grid with
one fixed-height header a section, so the smallest correct layout is that arithmetic
itself: a general solver has nothing to solve, and at the owner's thousands of days its
per-section solve was the main thread's largest cost. Rebuilding the same layout type
with a new column count is what makes zoom a small, data-driven change rather than a
new rendering mechanism.

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
- The gate tells whether a grid needs a structural apply by the identity of its order
  and days (`CatalogGridContent.sharesOrder`), never by comparing the library-sized
  arrays on the main actor: Projection hands an equal order on as the same one, and an
  order it rebuilt that the gate does not recognise costs an apply with an empty diff,
  not a wrong grid.
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
- Apple, [NSCollectionViewLayout](https://developer.apple.com/documentation/appkit/nscollectionviewlayout);
  `docs/research/2026-11-15-grid-layout-without-compositional-solve.md` (the
  compositional layout's geometry and animation measured against `MediaGridLayout`).
- Implemented in `OtosKit/Views/MediaGrid*.swift` (the layout in `MediaGridLayout.swift`),
  `OtosKit/Views/MediaAssetTileView.swift`, `OtosKit/Views/GridSelection.swift`,
  `OtosKit/ViewModels/CatalogWindowViewModelSelection.swift`;
  requirements APP-006/010/011/015/030.
