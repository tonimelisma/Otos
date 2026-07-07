# Spec 0048: Grid Zoom

## Classification

- Work type: Feature
- Current requirement IDs: APP-006 (grid rendering — column count is no longer fixed at
  six)
- Future idea or candidate links explicitly requested by the user: a larger-thumbnail
  tier / originals-at-max-zoom is noted as a future idea outside `docs/requirements.md`
  (D5 below records the accepted softness limitation this increment does not fix)
- ADRs: `docs/adr/0006-catalog-grid-rendering.md` (amended: column count ownership
  changes from "invariant six columns" to "user-selected 3–9, default 6"; the "zoom
  requires a future spec/ADR" sentence is resolved by this spec)

## Problem

The grid was permanently fixed at six columns. Owner decision D3 (`UI.md` §1) asks for
user-adjustable density — 3 columns (max zoom, biggest tiles) to 9 columns (min zoom,
smallest tiles), default 6 — with the item nearest the viewport center staying anchored
across a zoom ("the middle row stays"), persisted across launches, and reachable from
the View menu, a toolbar slider, and a pinch gesture (D4).

## Scope

In scope:

- `GridColumnCount`: pure bounds/validation/slider-mapping policy (3–9, default 6).
- `CatalogWindowViewModel.gridColumnCount` (published) plus one
  `setGridColumnCount(_:)` intent every surface shares, persisted to `UserDefaults`.
- Parametrized `makeLayout(columnCount:)`, still returning `MediaGridAnimatedLayout`
  (spec 0047) unchanged.
- An animated column-count swap on the AppKit controller that never overlaps a diffable
  structural apply, with the viewport-center tile kept anchored.
- View menu Zoom In/Out (⌘+/⌘−, disabled at the bounds), a toolbar slider, and a pinch
  gesture, all driving the one ViewModel intent.
- Fixing the hardcoded `columns=6` startup log to report the actual count.

Out of scope:

- Larger thumbnails or a second preview tier for high zoom levels (D5, accepted
  limitation, recorded below).
- Continuous pinch-driven `NSCollectionViewTransitionLayout` morphing — rejected in
  `UI.md` §9 as undocumented territory on macOS; zoom uses discrete animated layout
  swaps instead (F4/F5 in `UI.md` §2).
- Any change to shift-click selection (spec 0046) or apply/placeholder animation (spec
  0047) beyond what a variable column count requires of them (none — both already
  operate in terms of the current layout/apply state, not a column-count constant).

## Definition Of Ready

- [x] Goal, scope, and non-goals are explicit.
- [x] Current repo state was inspected (below).
- [x] Owner guidance D3/D4/D5 restated as precise requirements below.
- [x] Observable acceptance examples listed.
- [x] No future ideas introduced beyond the explicitly-flagged D5 follow-up idea.
- [x] Ownership, side effects, persistence, cancellation, concurrency addressed below.
- [x] Three alternatives compared for the two decisions that had real alternatives
      (transition mechanism, pinch delta plumbing).
- [x] No retirement proof needed beyond the hardcoded `columns=6` log and the prior
      `static let columnCount = 6` constant (spec 0047 already flagged that constant as
      provisional; both are fully replaced here).
- [x] Stale-document audit defined.
- [x] Code-comment accuracy audit defined.
- [x] Performance evidence requirement stated; agent-environment limitation recorded
      where interactive profiling cannot be captured.
- [x] Open questions: none outstanding.

## Current Repo State (verified by inspection before implementation)

- `MediaAssetCollectionViewController.columnCount` was a `static let` of `6` (spec 0047
  explicitly flagged this as the seam this increment would replace).
  `makeLayout()` took no parameter
  ([MediaAssetCollectionLayout.swift](../../Otos/Views/MediaAssetCollectionLayout.swift)).
- The startup log hardcoded `"columns=6"`
  ([MediaAssetCollectionView.swift](../../Otos/Views/MediaAssetCollectionView.swift)).
- `CatalogWindowViewModel` had no `UserDefaults`-backed published property; every other
  piece of session state (`sidebarSelection`, `queryDescriptor`) is plain `@Observable`
  state with no persistence, and no existing ViewModel or Service read/wrote
  `UserDefaults` anywhere in the repo — this increment's `gridColumnCountDefaults`
  injection point (defaulting to `.standard`) is the first, added specifically so tests
  never touch the real shared defaults domain.
- `preheatLookahead`
  ([MediaAssetCollectionPrefetch.swift](../../Otos/Views/MediaAssetCollectionPrefetch.swift))
  was confirmed purely viewport-rect based (`scrollView.contentView.bounds`,
  `layoutAttributesForElements(in:)`) with no column-count assumption — no change
  needed, re-confirming the pre-planning note in `UI.md`.
- `NSCollectionViewUpdateItem` and `NSCollectionViewLayoutAttributes.indexPath` facts
  from spec 0047 continued to apply; this spec additionally verified (Xcode 27 beta SDK,
  `NSMagnificationGestureRecognizer.h`) that `magnification` is a plain cumulative
  `CGFloat` with no delta API, and (`NSCollectionViewLayout.h`) that
  `layoutAttributesForItemAtIndexPath:`/`layoutAttributesForElements(in:)` exist on
  `NSCollectionViewLayout` for reading current item frames.

## Captured Requirements For User Verification

| ID or label | Type | Captured requirement | Current or candidate | Storage location |
| --- | --- | --- | --- | --- |
| D3 | Functional | Grid zoom: 9 columns min zoom, 3 columns max zoom, default 6; discrete levels, animated reflow, the viewport-center item stays anchored. | Current | This spec |
| D4 | Functional | Zoom surfaces: ⌘+/⌘− menu commands, pinch gesture, and a toolbar slider; all drive one intent. | Current | This spec |
| D5 | Product / accepted limitation | Thumbnails stay 256 px and will look soft at 3–4 columns on Retina; accepted for now, no thumbnail regeneration or second preview tier in this increment. | Candidate (future idea, not a requirement) | This spec; a larger-thumbnail tier is future work outside `docs/requirements.md` |

## Architectural Alternatives

### Column-count ownership and plumbing

**Alternative A (rejected): the AppKit controller owns and persists column count
itself.** Cons: duplicates the `UserDefaults`-backed published-state pattern the
ViewModel already owns for every other piece of session state; the pinch gesture would
mutate the layout directly, contradicting "one user action, one implementation path"
(a pinch-driven change and a menu-driven change would be different code paths).
**Alternative B (rejected): thread column count through the query descriptor /
Projection.** Cons: column count is pure rendering state, not catalog truth or a query
parameter; routing it through the Store/Projection round trip would add async latency
and unrelated coupling to a value that never needs to touch SQLite. **Alternative C
(selected): `CatalogWindowViewModel` owns one published `gridColumnCount` and one
`setGridColumnCount(_:)` intent** that every surface — View menu and toolbar slider
directly, the AppKit pinch gesture through an `onColumnCountChangeRequested` callback —
calls. The published value round-trips back into `updateNSViewController`, which is the
only place that calls `setColumnCount(_:)` on the controller. This mirrors how sort and
filter intents already work and keeps the AppKit boundary a pure renderer of ViewModel
state, per the existing selection/apply ownership split.

### Zoom transition mechanism

**Alternative A (rejected): `NSCollectionViewTransitionLayout` with a continuous,
pinch-driven interactive transition.** Cons: macOS exposes the transition-layout type
but no `startInteractiveTransition` driver (that API is UIKit-only) — verified against
the Xcode 27 beta SDK; there is no macOS prior art for driving this incrementally.
Rejected as undocumented territory for a product invariant. **Alternative B (rejected):
a custom transition layout interpolating between two `NSCollectionViewCompositionalLayout`
instances frame-by-frame.** Cons: significant new rendering machinery for a decorative
transition; `NSCollectionView.animator().collectionViewLayout = newLayout` already
animates surviving item frames natively (F4, verified against `NSCollectionView.h`).
**Alternative C (selected): discrete animated layout swaps.** Each zoom step installs a
freshly built `MediaGridAnimatedLayout` inside an `NSAnimationContext` group and asks
the animator to scroll to the anchor tile; AppKit interpolates surviving item frames
natively. Items newly entering the viewport during the swap may pop in rather than fade
— an accepted, documented fallback (`UI.md` F5), not a defect to fix with a custom
transition layout.

### Pinch-to-column-count plumbing

**Alternative A (rejected): request one column-count delta per threshold crossing,
immediately, from inside the pinch handler.** Cons: `columnCount` on the controller does
not update until the full round trip through the ViewModel intent and back through
`updateNSViewController` completes; requesting multiple deltas against the
not-yet-updated `columnCount` in one synchronous burst (a fast pinch can cross several
0.3-magnification thresholds in one `.changed` delivery) would send the same target
value repeatedly instead of accumulating. **Alternative B (selected): coalesce a burst
of crossings into one net delta** (`MediaGridPinchZoomPolicy.consumeSteps`, a pure
function returning the net step count and leftover sub-threshold magnification) and
issue exactly one `onColumnCountChangeRequested` call per `.changed` delivery. This is
also what makes the pinch math independently unit-testable without a live gesture
recognizer.

## Selected Approach

Alternatives C/C/B above. `GridColumnCount` (new, `Otos/Models/GridColumnCount.swift`)
is the one source of the 3–9 bounds, the load-time validation rule, the
clamp-a-deliberate-request rule, and the slider-value mapping. `MediaGridZoomPolicy`
(new, `Otos/Views/MediaGridZoomPolicy.swift`) holds the pure "nearest tile to viewport
center" anchor pick and the pinch-step coalescing, both fully unit-testable without
`NSCollectionView`. `MediaAssetCollectionZoom.swift` (new) is the AppKit-boundary file
for the pinch gesture and the animated swap; `MediaAssetCollectionStructuralApply.swift`
(spec 0047's completion-side file, which also now holds the apply-starting side moved
here in this increment to keep file lengths under the repo's lint budget) drains a
zoom deferred by an in-flight structural apply. `CatalogWindowViewModelGridZoom.swift`
(new) holds the `setGridColumnCount`/`zoomInGrid`/`zoomOutGrid` intents, split out of
`CatalogWindowViewModel.swift` for the same file-length reason (that main file's
`addLibrary`/`ensureLibrary`/`removeLibrary`/`ejectRemovableSource`/`forgetRemovableSource`
wrappers were also consolidated into the existing `CatalogWindowViewModelMutation.swift`
in the same pass, since they already thematically belonged there).

## Interfaces, Ownership, And Data Flow

```
⌘+/⌘− menu ─┐
toolbar slider ─┼→ CatalogWindowViewModel.setGridColumnCount(Int) ── clamps 3…9,
pinch gesture ─┘        persists UserDefaults "mediaGridColumnCount",
 (AppKit → callback up)  publishes gridColumnCount
                              │
              MediaGridView → MediaAssetCollectionView(columnCount:)
                              │ updateNSViewController (every SwiftUI update)
              controller.setColumnCount(_:) → animated layout swap (or deferred)
```

- `CatalogWindowViewModel.gridColumnCount: Int` (published, `@Observable`), loaded in
  `init` via the injected `gridColumnCountDefaults: UserDefaults` (defaults to
  `.standard`; tests inject an isolated suite). `setGridColumnCount(_:)` clamps via
  `GridColumnCount.clamped`, no-ops if unchanged, else assigns and persists.
  `zoomInGrid`/`zoomOutGrid` are ±1 convenience wrappers.
- `MediaAssetCollectionView` (representable) gains `columnCount: Int` and
  `onColumnCountChangeRequested: (Int) -> Void`, threaded from `ContentView` through
  `MediaGridView`.
- `MediaAssetCollectionViewController.setColumnCount(_:)` is the *only* place that ever
  installs a new column-count layout. No-ops if unchanged; if
  `applyGate.isApplyInFlight`, stores the request in `pendingColumnCount` and returns
  (never a layout swap concurrent with a diffable apply); otherwise swaps immediately.
  `completeStructuralApply` drains `pendingColumnCount` exactly once, right after its
  own `performApplyGateAction(applyGate.complete(...))` call — if that call already
  started a new apply from a pending grid state, `setColumnCount`'s own in-flight check
  re-defers correctly with no extra bookkeeping needed.
- The swap picks an anchor index path (the pinch-gesture's captured item if a pinch is
  in progress, else `MediaGridZoomPolicy.nearestToCenter` over the currently visible
  tiles' frames, else `nil` for an empty grid), then runs
  `NSAnimationContext.runAnimationGroup` assigning
  `collectionView.animator().collectionViewLayout` and, if there is an anchor,
  `collectionView.animator().scrollToItems(at:scrollPosition: .centeredVertically)`.
  Completion re-requests visible details, reports the viewport, and re-preheats — the
  viewport now holds a different identity set at a different tile size.
- The pinch gesture (`NSMagnificationGestureRecognizer`, added in
  `configurePinchZoomGesture()`) never mutates `columnCount` or the layout; it only
  calls `onColumnCountChangeRequested`. Its accumulated magnification and captured
  anchor index path are controller-local ephemeral state, reset on `.began`/
  `.ended`/`.cancelled`/`.failed`.
- Concurrency/actor ownership: everything in this spec is MainActor AppKit/SwiftUI
  state, matching the existing grid boundary; `GridColumnCount` and
  `MediaGridZoomPolicy` are `nonisolated` pure value/function namespaces with no actor
  affinity, tested directly without MainActor hops.

## Retirement Proof

- The prior `static let columnCount = 6` constant on the controller no longer exists;
  every reference (`makeLayout()`, the startup log) uses the instance `columnCount` or
  the new `makeLayout(columnCount:)` parameter. The `indexPath.item % columnCount`
  computation at both `configure` call sites was retired in the same pass: it only ever
  fed spec 0047's per-column thumbnail-fade stagger, which a review finding proved
  unsafe (see spec 0047's Post-Merge Correction) and which this increment's own work
  fully removed, along with the `column:` parameter it threaded through
  `MediaAssetCollectionItem`/`MediaAssetTileView` configure and `MediaAssetTileView`'s
  `currentColumn` state.
- The hardcoded `"columns=6"` startup log string is gone; it now interpolates the
  actual installed count.
- `mediaBrowserUsesReusableSixColumnAppKitGrid` (source hygiene) is renamed
  `mediaBrowserUsesReusableVariableColumnAppKitGrid` and asserts the new
  `GridColumnCount` bounds instead of the retired hardcoded `"count: 6"` / `"static let
  columnCount = 6"` literals; it also moved to a new dedicated file
  (`MediaGridZoomSourceHygieneTests.swift`) to keep `SourceHygieneTests.swift` under its
  type-body-length budget.

## Living Documentation And Comment Audit

- `docs/adr/0006-catalog-grid-rendering.md`: column-count ownership changes from
  "invariant six columns" to "user-selected 3–9, default 6"; record the zoom decision
  (discrete animated swaps, not continuous transition-layout morphing) and resolve the
  "zoom requires a future spec/ADR" sentence.
- `docs/requirements.md`: APP-006 gains acceptance text for variable column count,
  persistence, and the D5 softness limitation; cross-reference this spec.
- `docs/onboarding.md`: the grid section gains the zoom intent/data-flow path — this is
  an ownership/data-flow change and is updated in this increment.
- `docs/index.md`: add this spec.
- File guides updated in place: `MediaAssetCollectionView.swift` (representable
  contract), `MediaAssetCollectionLayout.swift` (parametrized layout factory),
  `MediaAssetCollectionStructuralApply.swift` (now owns both apply start and
  completion, plus the pending-zoom drain), `CatalogWindowViewModel.swift` (points to
  the split-out zoom file). New guides in `MediaAssetCollectionZoom.swift`,
  `MediaGridZoomPolicy.swift`, `GridColumnCount.swift`, and
  `CatalogWindowViewModelGridZoom.swift`.

## Instrumentation And Performance

- New signpost interval `MediaGridZoomApply` around the animated swap; completion logs
  `columns=old→new anchorPresent=bool trigger=pinch|external` at info level
  (`trigger` is derived from whether a pinch anchor is currently captured, a
  simplification over threading an explicit menu/slider/pinch label through the
  ViewModel's plain `Int` published value — the diagnostic value is "was this
  gesture-driven," not which of the two non-gesture surfaces was clicked).
- Required evidence: repeated zoom in/out at real library scale via
  `script/profile.sh "Animation Hitches" 10s`. As with spec 0047's equivalent
  requirement, this agent environment cannot drive live pinch/menu/slider interaction
  to populate a meaningful trace window; recorded as the same class of non-blocking
  after-DoD limitation already accepted in PRs #46/#47/#52. `script/smoke-run.sh`
  provides non-interactive runtime evidence that the new code paths do not crash or
  regress existing counters (see Verification).

## Code-Smell Review

- MainActor gravity: none added — the animated swap is one Core Animation transaction
  per user zoom action, not per-frame work.
- State duplication: `pendingColumnCount`/pinch state are ephemeral controller-local
  state with a single drain path, not a second source of column-count truth;
  `gridColumnCount` has exactly one owner (`CatalogWindowViewModel`).
- Stringly typed domain facts: none introduced (`trigger` in the log line is a
  diagnostic string, consistent with existing `reason:` log parameters elsewhere in
  this boundary, not a domain fact requiring a typed enum).
- Test coupling: `MediaGridZoomPolicyTests` and `GridColumnCountTests` exercise pure
  functions; `MediaAssetCollectionZoomTests` asserts observable controller state
  (`columnCount`, `pendingColumnCount`), not animation internals.
- File length: three files that grew past the repo's 500-line lint budget while
  implementing this spec were reorganized along existing thematic boundaries (see
  Selected Approach) rather than suppressing the lint rule.

## Acceptance Criteria

1. ⌘+ three times from default → 6 → 5 → 4 → 3 columns, each an animated reflow; a
   fourth ⌘+ does nothing (menu item disabled at the minimum).
2. Pinch out over a specific tile → that tile's row stays anchored near the gesture
   location; edge tiles slide out of the viewport as columns shrink.
3. Slider dragged fully left → 9 columns; relaunching the app still shows 9 columns.
4. Requesting a zoom while a large scan is applying → the zoom lands right after the
   apply completes; no crash, no torn layout, selection intact.
5. Selected tiles keep their (spec 0047) animated rings through a zoom — selection is
   untouched by layout swaps.

## Verification

- Local checks: `script/verify.sh` (Xcode 27 beta) from the increment worktree.
- Focused tests:
  - `GridColumnCountTests` (new): clamp bounds, validation fallback for unset/garbage
    stored values, slider-value mapping round trip.
  - `MediaGridZoomPolicyTests` (new): nearest-to-center anchor pick (including empty
    grid → `nil` and order-stable ties) and pinch-step coalescing (below threshold,
    single crossing each direction, multi-crossing coalesced into one net delta,
    sub-threshold remainder retained across calls).
  - `CatalogWindowViewModelGridZoomTests` (new): default/stored/garbage load behavior,
    clamp+persist+publish, a fresh ViewModel instance reading back a persisted value,
    zoom in/out bounds — every test uses an isolated `UserDefaults` suite, never
    `.standard`.
  - `MediaAssetCollectionZoomTests` (new): immediate swap with no apply in flight,
    no-op on an unchanged request, and the pending-zoom deferral/exactly-once-drain
    behavior driven through the real `completeStructuralApply` path.
  - `MediaGridZoomSourceHygieneTests` (renamed/moved): still AppKit
    `NSCollectionView`/`NSCollectionViewCompositionalLayout`-based, still not a table,
    now asserting the `GridColumnCount` 3–9 bounds instead of a hardcoded six.
- Performance/log evidence: hitch-profile capture is a recorded, non-blocking
  after-DoD limitation (see Instrumentation); `script/smoke-run.sh` provides
  non-interactive confirmation that the app builds, launches, and runs its existing
  scan/scroll smoke path without new crashes or invariant-watchdog regressions.
- Stale-document audit: confirms ADR 0006, requirements, onboarding, and index describe
  the landed variable-column-count design and no document still claims an invariant
  six columns.
- Code-comment accuracy audit: confirms new/relocated files explain current ownership
  and mechanics, not increment history.
- CI expectations: remote CI gate must pass; Xcode 27 build/test proof comes from local
  `script/verify.sh`.
