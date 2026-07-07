# Spec 0047: Grid Animation And Placeholder Polish

## Classification

- Work type: Feature
- Current requirement IDs: APP-006 (grid rendering), APP-010/APP-011 (selection — ring
  animation only, selection semantics unchanged), APP-015 (no-blank invariant, untouched)
- Future idea or candidate links explicitly requested by the user: none
- ADRs: `docs/adr/0006-catalog-grid-rendering.md` (amended: animated-apply timing and
  insert/remove choreography recorded as this ADR's rendering-polish mechanics)

## Problem

The media grid's already-animating apply path (small inserts/removes, per the spec
0039 reloadData-class fallback policy) uses AppKit's default diffable-apply animation
with no tuned duration or curve, inserted/removed tiles get the same plain frame glide
as surviving tiles, the selection ring is an instant square-wave with no fade, thumbnail
arrival pops in with zero transition, and an unloaded tile's gray placeholder carries no
signal of what kind of media is coming. Owner decision D2 (`UI.md` §1) asks for this
polish on the paths that already animate, without touching the measured reloadData
fallback policy (constraint 2) or the no-blank invariant (constraint 1).

## Scope

In scope:

- Tuned duration/timing-curve wrapper around the animated (`animatingDifferences: true`)
  diffable apply branch only.
- A subclassed compositional layout that fades+shrinks only the index paths a given
  diffable apply batch actually inserted or deleted.
- Animated (fade in/out) selection ring, gated on making `restoreSelection` delta-based
  so a surviving tile's `isSelected` is never reassigned.
- Fade/crossfade on async-decoded thumbnail arrival only (never on a cache-hit repaint),
  with a per-column stagger.
- A centered media-kind placeholder icon (film/photo) on the existing gray placeholder
  square, visible only before a thumbnail has ever painted for that tile.
- One `MediaGridAnimation` namespace holding every new duration/curve/geometry constant.

Out of scope (unchanged in this increment):

- The reloadData-class fallback for measured-large or reorder-only applies (spec 0039) —
  byte-for-byte unchanged, verified by the unmodified
  `MediaGridStructuralApplyPolicyTests`-class coverage still passing.
- Shift-click selection semantics (spec 0046) — only the ring's paint animation changes.
- Grid zoom / variable column count (increment 3; this spec adds a named `columnCount`
  constant that increment 3 will make user-adjustable, but does not change grid density).
- Spinner or shimmer placeholders — explicitly rejected (D6): a spinner or shimmer on a
  merely queued tile fabricates in-progress activity that is not happening yet.
- Continuous pinch-driven layout morphing — not part of this increment's polish.

## Definition Of Ready

- [x] Goal, scope, and non-goals are explicit.
- [x] Current repo state was inspected (see below).
- [x] Owner guidance D2/D6/D7 restated as precise requirements below.
- [x] Observable acceptance examples listed.
- [x] No future ideas introduced beyond `UI.md`'s already-scoped increment 2.
- [x] Ownership, side effects, persistence, cancellation, errors, instrumentation, tests
      addressed below.
- [x] Three alternatives compared per changed mechanism.
- [x] No retirement proof needed beyond the `updatePlaceholderBackground` →
      `updatePlaceholderPresentation` rename and the `restoreSelection` deselect-all
      implementation, both covered below.
- [x] Stale-document audit defined.
- [x] Code-comment accuracy audit defined.
- [x] Performance evidence requirement stated (hitch profiling); agent-environment
      limitation recorded where profiling cannot be captured interactively.
- [x] Open questions: none outstanding.

## Current Repo State (verified by inspection before implementation)

- `MediaAssetCollectionViewController.applySnapshot` called
  `dataSource.apply(snapshot, animatingDifferences:, completion:)` directly, with no
  `NSAnimationContext` wrapping either branch
  ([MediaAssetCollectionView.swift](../../Otos/Views/MediaAssetCollectionView.swift)).
- `makeLayout()` returned a plain `NSCollectionViewCompositionalLayout` with a hardcoded
  `count: 6` group
  ([MediaAssetCollectionLayout.swift](../../Otos/Views/MediaAssetCollectionLayout.swift)).
- `MediaAssetCollectionItem.isSelected`'s `didSet` called `tileView?.setSelected(isSelected)`
  with no animation parameter
  ([MediaAssetCollectionItem.swift](../../Otos/Views/MediaAssetCollectionItem.swift)).
- `restoreSelection` (spec 0046) deselected the entire current selection then reselected
  survivors — safe only because no paint happens between the two calls today; adding an
  animated ring would make every same-descriptor structural apply blink every survivor's
  ring.
- `applyImage`'s `reason: String` parameter
  ([MediaAssetTileView.swift](../../Otos/Views/MediaAssetTileView.swift)) was already
  unused (`reason _: String`), a leftover from a prior increment — confirms D1/constraint
  5's premise.
- `updatePlaceholderBackground()` set only the gray background color; no icon existed.
- `MediaTileDetail.bestKind: MediaKind?` was already available at the tile boundary
  (spec 0044), unused by placeholder presentation.
- No test in the repo constructed an `NSCollectionViewUpdateItem` or exercised
  `NSCollectionViewLayout`'s update-tracking hooks; the header
  (`NSCollectionViewLayout.h`) declares `NSCollectionViewUpdateItem` with only readonly
  properties and no public initializer, so a real one cannot be synthesized in a test.

## Captured Requirements For User Verification

| ID or label | Type | Captured requirement | Current or candidate | Storage location |
| --- | --- | --- | --- | --- |
| D2 | Functional/non-functional | Grid change animations (insert/remove/apply) should be visibly prettier on the already-animating path; the reloadData-fallback policy stays untouched. | Current | This spec |
| D6 | Functional | Placeholder tiles get a media-kind icon (film for video, photo otherwise) on the existing gray square; no spinner. | Current | This spec |
| D7 | Functional | Thumbnail arrival animates: fade/crossfade on first decode and same-asset replacement, with a small per-column stagger on a batch landing. | Current | This spec |

## Architectural Alternatives

### A1 — Tuned apply animation

**Alternative A (rejected): raise animation duration only, no curve.** Pros: trivial.
Cons: does not address the "mild overshoot" request; AppKit's default linear/ease curve
looks mechanical. **Alternative B (rejected): custom `NSAnimationContext` per apply call
site.** Pros: none over a single wrapper. Cons: duplicates the same duration/curve setup
at every call site; violates one-path-one-owner. **Alternative C (selected): wrap only the
`animatingDifferences: true` branch of the existing single `applySnapshot` call site** in
an `NSAnimationContext` group using `MediaGridAnimation`'s named duration/curve. The
`false` branch is untouched (constraint 2). AppKit has no spring API (verified,
`NSAnimationContext.h`); the "mild overshoot" is a bezier whose second control point's y
exceeds 1.

### A2 — Insert/remove choreography

**Alternative A (rejected): `NSCollectionViewTransitionLayout`.** Cons: built for
layout-to-layout transitions (used later for zoom), not per-item insert/remove
choreography; wrong tool. **Alternative B (rejected): custom `NSCollectionViewItem`
appear/disappear animation from the item side.** Cons: items do not know whether they are
appearing because of an insert vs. a scroll-driven dequeue; the layout is the only object
that receives update-batch context. **Alternative C (selected): subclass
`NSCollectionViewCompositionalLayout`** (`MediaGridAnimatedLayout`), recording inserted/
deleted index paths in `prepare(forCollectionViewUpdates:)` and clearing them in
`finalizeCollectionViewUpdates()`, then fading+shrinking only those paths in the
appear/disappear attribute hooks. All other appearing/disappearing items (initial layout
install, scroll dequeue, a future zoom swap) return `super`'s attributes unchanged, so
only genuine batch inserts/deletes get the effect.

### A3 — Selection ring animation

**Alternative A (rejected): animate unconditionally without changing `restoreSelection`.**
Cons: every same-descriptor structural apply would deselect-then-reselect every survivor,
and with a real 100–120 ms animation that flip becomes visible as a ring blink on every
background enrichment apply — a correctness regression, not polish. **Alternative B
(rejected): a separate "did selection actually change" boolean passed alongside
`isSelected`.** Cons: a second signal that can drift from the real selection set; more
surface than needed. **Alternative C (selected): make `restoreSelection` delta-based**
(`deselect(current − survivors)`, `select(survivors − current)`, via the same
`MediaGridSelection.selectionDelta` helper the shift-range correction already uses), so a
survivor's `isSelected` is never reassigned and therefore never animates. `setSelected(_:
animated:)` then animates unconditionally from `isSelected`'s `didSet`, and
`prepareForReuse` passes `animated: false` so a recycled item never carries over a stale
animation.

### D1/6d — Thumbnail arrival fade

**Alternative A (rejected): fade on every `applyImage` call, including cache hits.**
Cons: a scroll-back repaint or recycled-cell synchronous repaint would fade, reading as
flicker and contradicting the no-blank invariant's spirit. **Alternative B (rejected): a
snapshot-overlay crossfade layered above the image view.** Cons: parallel rendering
machinery with no proven need over a plain `CATransition`. **Alternative C (selected):**
replace the already-unused `reason: String` on `applyImage` with a typed
`TilePaintApplication` (`cacheHit` / `asyncLoad`); only `asyncLoad` adds a `CATransition`
(`.fade`) before setting `imageView.layer.contents`. This single mechanism covers both
first paint (placeholder → image) and a same-asset newer-thumbnail replacement (old → new
crossfade — invariant-safe because the old contents stay on the layer through the
transition). A per-column stagger (`beginTime` + `.backwards` fill mode) is included as
the lowest-priority flourish (D2/6e); it is a decorative `CATransition` timing detail, not
new async machinery, so there is nothing to "drop back to" if it proves unreliable beyond
removing these two lines.

### D6 — Placeholder icon

**Alternative A (rejected): a spinner.** Rejected per D6 — fabricates progress for a
merely queued tile. **Alternative B (rejected): shimmer/skeleton sweep.** Deferred
per `UI.md` §9 pending hitch evidence the owner has not requested. **Alternative C
(selected): a static, dim (`alpha 0.35`) SF Symbol** (`film` for a known video, `photo`
otherwise, covering both a known image and a not-yet-known kind) centered on the existing
gray square, sized to a quarter of the shorter content dimension clamped to 16–40 pt,
visible only while no thumbnail has ever painted for that tile.

## Selected Approach

Alternatives C above, combined behind one `MediaGridAnimation` constants namespace so
every duration/curve/geometry value has one source of truth for tests and review.

## Interfaces, Ownership, And Data Flow

- `MediaGridAnimation` (new, `Otos/Views/MediaGridAnimation.swift`): `nonisolated enum` of
  scalar constants and one computed `CAMediaTimingFunction`. No state, no I/O.
- `MediaGridUpdateItem` / `MediaGridAnimatedLayoutPolicy` (new,
  `Otos/Views/MediaGridAnimatedLayout.swift`): a plain-Swift mirror of the three readable
  `NSCollectionViewUpdateItem` properties this layout needs, and a pure function from a
  batch of those mirrors to the inserted/deleted index-path sets. Exists specifically so
  the bookkeeping is unit-testable without constructing a real (uninitializable)
  `NSCollectionViewUpdateItem`.
- `MediaGridAnimatedLayout` (same file): `NSCollectionViewCompositionalLayout` subclass,
  MainActor (inherits its superclass's isolation), owns the current batch's tracked index
  paths as private state cleared every `finalizeCollectionViewUpdates()`. Returned by
  `MediaAssetCollectionViewController.makeLayout()`
  ([MediaAssetCollectionLayout.swift](../../Otos/Views/MediaAssetCollectionLayout.swift)),
  which also now owns the named `columnCount` constant increment 3 will publish.
- `MediaGridSelection.selectionDelta` (new, in the existing
  [MediaGridSelection.swift](../../Otos/Views/MediaGridSelection.swift)): pure
  `(current, target) -> (toDeselect, toSelect)`, shared by `restoreSelection` and the
  spec 0046 shift-range correction so there is exactly one "minimal selection delta"
  algorithm.
- `TilePaintApplication` (new, in
  [MediaAssetTilePresentation.swift](../../Otos/Views/MediaAssetTilePresentation.swift)):
  `cacheHit` / `asyncLoad`, replacing the dead `reason: String` on `applyImage`.
  `MediaAssetTilePresentation.placeholderIconSystemName(for:)` and
  `MediaAssetTileLayout.placeholderIconSide(contentBounds:)` /
  `placeholderIconFrame(contentBounds:)` are pure geometry/policy helpers.
- `MediaAssetTileView` (AppKit, MainActor): gains `placeholderIconView`,
  `currentBestKind`, `currentColumn` and an `animated` parameter on `setSelected`.
  `updatePlaceholderBackground()` is renamed `updatePlaceholderPresentation()` and now
  owns background + icon together.
- `MediaAssetCollectionItem.configure` and `MediaAssetTileView.configure` gain a
  `column: Int` parameter (`indexPath.item % MediaAssetCollectionViewController.columnCount`),
  read only for the thumbnail-fade stagger.
- No persistence, network, or privacy surface changes. No new actor boundary: all new
  code runs on the existing MainActor AppKit boundary or is `nonisolated` pure logic.

## Retirement Proof

- `updatePlaceholderBackground()` is fully renamed to `updatePlaceholderPresentation()`;
  no call site or comment references the old name (grepped clean).
- `restoreSelection`'s deselect-all-then-reselect body is fully replaced by the
  delta-based implementation; no code path still deselects survivors.
- `applyImage`'s dead `reason: String` parameter is fully replaced by
  `TilePaintApplication`; no `String`-typed reason remains on that method.
- `setSelected(_:)` (no `animated:`) no longer exists; both call sites
  (`MediaAssetCollectionItem`, `prepareForReuse`) use the new signature.

## Living Documentation And Comment Audit

- `docs/adr/0006-catalog-grid-rendering.md`: record the tuned apply animation and the
  `MediaGridAnimatedLayout` insert/remove choreography as this ADR's rendering-polish
  mechanics; note the selection-ring animation and its `restoreSelection` precondition.
- `docs/requirements.md`: APP-006 gains acceptance text for the animated small-apply
  path, insert/remove choreography, ring animation, thumbnail fade, and placeholder icon;
  cross-reference this spec.
- `docs/onboarding.md`: update the grid/selection sections to describe the animated
  paths and the delta-based `restoreSelection` precondition.
- `docs/index.md`: add this spec.
- File guides updated in place: `MediaAssetCollectionView.swift` (`applySnapshot`),
  `MediaAssetCollectionSelection.swift` (`restoreSelection`, `applySelectionDelta`),
  `MediaAssetTileView.swift` (placeholder presentation, paint application, selection
  animation), new guides in `MediaGridAnimation.swift` and `MediaGridAnimatedLayout.swift`.
  No comment narrates Core Animation syntax; each explains why a value is what it is or
  why a path is safe (e.g., the no-feedback-loop and no-blink guarantees).

## Instrumentation And Performance

- No new OSLog category. Existing signposts (`MediaGridStructuralApply`,
  `MediaTileLoadApplied`, `MediaGridSelectionChanged`) already bracket every touched path;
  none are added, matching the "add none unless a gap appears" guidance — the new
  animations are Core Animation work the render server performs, not new MainActor spans.
- Required evidence: `script/profile.sh "Animation Hitches" 10s` during (a) fast
  scrolling with placeholder→thumbnail churn and (b) small animated applies with an
  active selection. This agent environment cannot drive live scrolling/selection
  interaction to populate a meaningful trace window (no attached display session driving
  real user gestures); this is recorded as a residual, non-blocking after-DoD limitation,
  consistent with the same limitation recorded for screenshot-based visual QA in prior
  increments (PRs #46, #47). `MainRunLoopStallMonitor` JSONL continues to be produced by
  the existing smoke-run path and is unaffected by this change (no new MainActor work).

## Code-Smell Review

- MainActor gravity: none added — every new animation is Core Animation work configured
  once per event and left to the render server; no per-frame MainActor work.
- State duplication: `MediaGridAnimatedLayout`'s tracked index paths are process-local,
  cleared every batch, and never a second source of grid structure. `selectionDelta` is
  reused (not reimplemented) between spec 0046 and this spec.
- Stringly typed domain facts: `TilePaintApplication` replaces the last stringly typed
  `reason` on `applyImage`, per constraint 5.
- Test coupling: `MediaGridAnimatedLayoutTests` exercises the pure policy function, never
  the real `NSCollectionViewUpdateItem`/Core Animation internals it cannot construct in a
  test in the first place.
- AppKit bridge sprawl: `MediaGridAnimatedLayout` is one narrow layout subclass at the
  existing collection-view boundary, not a new parallel rendering path.

## Acceptance Criteria

1. A scan adds a small number of new assets to an already-displayed grid → new tiles
   fade+shrink-in over `MediaGridAnimation.applyDuration` with the tuned curve; surviving
   tiles glide; nothing blanks.
2. A large or reorder-only apply → instant reloadData-class apply exactly as before
   (unchanged `MediaGridStructuralApplyPolicy` behavior and tests).
3. Scrolling back to a previously painted row → instant repaint, no fade (`cacheHit`).
4. A visible row's first thumbnail decode → tiles fade in with a per-column stagger.
5. An unloaded video tile shows a dim film icon; an unloaded image tile (or a tile whose
   kind is not yet known) shows a dim photo icon; both sit on the existing gray square;
   the icon disappears the instant a thumbnail paints.
6. Selecting a tile fades its accent ring in over ~120 ms; a background enrichment apply
   while a tile is selected causes zero ring blink on that survivor.

## Outstanding Review Follow-Up

Scanning the last five PRs before this increment's PR found one unclaimed finding on
PR #51 (spec 0046): a descriptor-changing structural apply cleared the visible selection
but did not always clear `selectionAnchorID`/`anchorBaseSelection` — `restoreSelection`'s
anchor prune only clears an anchor whose *asset* left the new ordered IDs, which is not
the same condition as "the descriptor changed" (the previously anchored asset can still
be present in a new scope/sort/filter's results). Fixed in this increment:
`StructuralApplyCompletionContext` now carries `resetSelection`, and
`completeStructuralApply` calls `clearSelection(reason: "descriptorChange")` directly on
a descriptor-changing apply, mirroring the already-correct `.refreshVisible` path, instead
of relying on `restoreSelection`'s identity-based anchor prune.
`descriptorChangingApplyClearsAnchorEvenWhenTheAnchoredAssetSurvives` (in
`OtosTests/MediaAssetCollectionSelectionTests.swift`) regression-tests exactly the
scenario the finding described.

## Verification

- Local checks: `script/verify.sh` (Xcode 27 beta) from the increment worktree.
- Focused tests:
  - `MediaGridAnimatedLayoutTests` (new): insert/delete bookkeeping from the pure
    `MediaGridUpdateItem` mirror, including move/reload/none exclusion and an empty
    batch.
  - `MediaGridSelectionTests`: new `selectionDelta` coverage (survivors excluded from
    both sides, identical sets, empty-to-full, full-to-empty).
  - `MediaAssetTilePresentationTests`: new placeholder-icon symbol-name and
    side/frame-geometry (clamped range, centering) coverage.
  - Existing `MediaGridStructuralApplyPolicy`-class tests in
    `MediaAssetCollectionTests.swift` pass unchanged (proves the fallback policy is
    untouched).
  - `MediaAssetCollectionSelectionTests` (spec 0046) pass unchanged (proves selection
    correctness is preserved by the delta-based `restoreSelection`).
- Performance/log evidence: hitch-profile capture is a recorded, non-blocking
  after-DoD limitation in this agent environment (see Instrumentation).
- Stale-document audit: confirms ADR 0006, requirements, onboarding, and index describe
  the landed animation/placeholder design and no document still describes an instant,
  iconless placeholder or a deselect-all `restoreSelection`.
- Code-comment accuracy audit: confirms new/renamed methods explain the no-blink and
  no-flicker guarantees, not Core Animation syntax.
- CI expectations: remote CI gate must pass; Xcode 27 build/test proof comes from local
  `script/verify.sh`.
