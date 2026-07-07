# Spec 0046: Grid Shift-Click Range Selection

## Classification

- Work type: Bug fix
- Current requirement IDs: APP-010, APP-011 (shift-click range behavior; the anchor
  capture mechanism corrected for the multi-selection-collapse case, F5/F6)
- Future idea or candidate links explicitly requested by the user: none
- ADRs: ADR 0006 (the "Selection … require separate future specs/ADRs" sentence was
  resolved by this spec)

## Problem

`docs/requirements.md` APP-010 and spec 0031 document ⇧-click as extending a contiguous
range, Photos/Lightroom style. `NSCollectionView` does not give that for free: it treats
a mouse shift-click identically to a ⌘-click (toggle the clicked item only) — shift only
extends selection for keyboard ⇧+arrows, and `shouldSelectItemsAt` is documented
approve/refuse-only, so a delegate cannot return a superset there. So the grid keeps a
small anchor/base correction state and applies the full contiguous range as a same-turn
delta.

Owner decision D1 (captured 2026-07-06, see `UI.md` §1): shift-click must select the
contiguous display-order range between the anchor item and the clicked item; ⌘-click
behavior is unchanged.

The authoritative question the correction depends on is *what did the user click*. The
delegate callbacks alone cannot answer it in one case: a **plain click that collapses a
multi-selection onto an already-selected member** fires no `didSelectItemsAt` for the
clicked item (only `didDeselectItemsAt` for the ones dropped), so a handler that infers
the click from delegate callbacks plus `NSApp.currentEvent` never learns what was clicked
and leaves a stale anchor (F5). Reconstructing the click from callbacks is a structural
dead end for that case; the click itself must be observed where AppKit consumes it.

## Scope

In scope:

- A single `NSCollectionView` subclass, `MediaGridCollectionView`, that captures the
  hit-tested item and modifier flags at `mouseDown` and, after native selection settles,
  hands them to the controller.
- Anchor + base-selection model on `MediaAssetCollectionViewController`, corrected in a
  single `mouseSelectionFinished(hit:modifiers:)` owner.
- Correcting native shift-click's two-item toggle into a full contiguous range, applied
  synchronously in the same event turn (no visible flicker).
- Anchor lifecycle: set on plain/⌘-click (including the multi-selection-collapse case,
  F5), extended on ⇧-click, pruned by identity on structural applies with its base pruned
  of dead identities (F6), cleared on descriptor change, explicit `clearSelection`, and an
  empty-space plain click.
- Pure range-selection logic as `MediaGridSelection` helpers, fully unit tested without
  AppKit lifecycle.
- Controller-level tests driving `mouseSelectionFinished(hit:modifiers:)` directly.

Out of scope:

- Marquee/rubber-band drag selection semantics.
- Keyboard ⇧+arrow selection (already native and correct; never touches the anchor).
- Finder-style "extend from nearest edge" variants.
- Grid animation, placeholder, or zoom work (specs 0047, 0048).

## Current Repo State

Verified by inspection:

- `MediaAssetCollectionViewController`
  ([MediaAssetCollectionView.swift](../../Otos/Views/MediaAssetCollectionView.swift)) owns
  `selectionAnchorID`/`anchorBaseSelection` ephemeral state alongside its
  `collectionView.selectionIndexPaths` truth.
- The collection view is a `MediaGridCollectionView`
  ([MediaGridCollectionView.swift](../../Otos/Views/MediaGridCollectionView.swift)); the
  controller wires its `onMouseSelectionFinished` closure in `configureCollectionView()`.
- `NSCollectionViewDelegate` conformance
  ([MediaAssetCollectionSelection.swift](../../Otos/Views/MediaAssetCollectionSelection.swift))
  implements `didSelectItemsAt`/`didDeselectItemsAt` as telemetry-only observers.
- `restoreSelection(_:in:)` deselects the current selection then reselects survivors on
  every structural apply — the place that prunes a dangling anchor and its base.
- `completeStructuralApply`
  ([MediaAssetCollectionStructuralApply.swift](../../Otos/Views/MediaAssetCollectionStructuralApply.swift))
  calls `restoreSelection(context.preservedSelection, in: context.grid.orderedAssetIDs)`
  once per structural apply, or `clearSelection(reason:)` on a descriptor change.
- `MediaGridSelection`
  ([MediaGridSelection.swift](../../Otos/Views/MediaGridSelection.swift)) is a
  `nonisolated enum` of pure helpers (`pruned`, `orderedSelection`, `shiftRangeSelection`,
  `selectionDelta`) unit tested in `OtosTests/MediaGridSelectionTests.swift`.
- `mutationGate.displayedOrderedIDs`
  ([MediaGridMutationGate.swift](../../Otos/Views/MediaGridMutationGate.swift)) is the live
  display-order source used by the range math and `copy()`.

Platform fact: `NSResponder.mouseDown(with:)` runs AppKit's selection tracking loop
synchronously — it does not return until the click is fully processed (the tracking loop
has seen mouse-up, selection is final, and the `didSelect`/`didDeselect` callbacks have
been delivered). So reading `selectionIndexPaths` immediately after `super.mouseDown`
returns yields the settled selection. Programmatic `selectItems(at:)`/`deselectItems(at:)`
do not re-enter the tracking loop, so the range correction cannot feed back into itself.
(The synchronous-return property was confirmed empirically with a standalone probe; a
fully faithful headless reproduction of the *selection commit* could not be driven —
recorded as an after-DoD live-verification limitation — because synthetic events on an
off-screen window do not exercise `NSCollectionView`'s hit-test selection; real clicks on
the on-screen window select today, and the shipping delegate-callback path already relied
on this synchronous delivery.)

## Definition Of Ready

- [x] Goal, scope, and non-goals are explicit.
- [x] Current repo state was inspected.
- [x] Captured user guidance (D1) is restated as a precise requirement below.
- [x] Observable current requirements and acceptance examples are listed.
- [x] No future ideas introduced.
- [x] Ownership, side effects, cancellation, errors, privacy, instrumentation, and tests
      are addressed below.
- [x] Three-plus alternatives compared, including the superseded delegate-inference path.
- [x] Retirement proof for the removed delegate-inference machinery.
- [x] Stale-document audit defined.
- [x] Code-comment accuracy audit defined.
- [x] No new jank surface (synchronous, same-turn correction after the native tracking
      loop); no profiling required for this increment.
- [x] Open questions: none outstanding.

## Captured Requirements For User Verification

| ID or label | Type | Captured requirement | Current or candidate | Storage location |
| --- | --- | --- | --- | --- |
| D1 | Functional | Shift-click selects the contiguous display-order range between the anchor item and the clicked item, Photos/Lightroom style; ⌘-click behavior stays as-is. | Current | `docs/requirements.md` APP-010, this spec |
| F5 | Functional (regression) | A plain click collapsing a multi-selection onto an already-selected member re-anchors to that item; a following ⇧-click ranges from it, not the prior anchor. | Current | `docs/requirements.md` APP-010, this spec |
| F6 | Non-functional (regression) | An anchor that survives a structural apply keeps a base pruned of removed identities, so a later shift-range target equals the live selection and the shift-range signpost does not misfire. | Current | `docs/requirements.md` APP-011, this spec |

## Architectural Alternatives

### Alternative A (rejected): `shouldSelectItemsAt` returns the full target range

Cons: `NSCollectionView.h` documents `shouldSelectItemsAt` as approve/refuse only (a
subset filter); returning items outside the proposed set is undocumented behavior with no
macOS prior art (`UI.md` F6). Rejected — undocumented territory for a product invariant.

### Alternative B (rejected): maintain a parallel selection model, mirror into AppKit

Cons: creates a second source of selection truth alongside
`collectionView.selectionIndexPaths`, contradicting APP-011 and the "state duplication"
code smell. Rejected.

### Alternative C (rejected): correct inside the delegate callbacks via `NSApp.currentEvent` inference

Reconstructs "what did the user click" from `didSelect`/`didDeselect` callbacks plus
`NSApp.currentEvent`, with special-casing for paired-deselect ordering. Cons: there is a
case AppKit provides no callback for — a plain click collapsing a multi-selection onto an
already-selected member fires no `didSelectItemsAt` for the clicked item — so the handler
cannot learn what was clicked and leaves a stale anchor (F5). This is a structural hole in
delegate-callback inference, not a typo. Rejected.

### Alternative D (selected): capture the click at `mouseDown`

`MediaGridCollectionView.mouseDown(with:)` hit-tests the click location and records the
modifier flags *before* calling `super.mouseDown`, which runs the native selection
tracking loop. When `super` returns, native selection is final, so the controller receives
the authoritative `(clicked item, modifiers)` pair and reads the settled selection. This
closes F5 (the clicked item is known even when no callback fires for it) and removes the
event-type/paired-deselect guessing. The correction stays a same-turn delta with no paint
between the native result and the correction, preserving the no-flicker property. The
delegate callbacks revert to pure telemetry.

## Selected Approach

Alternative D. One new file `Otos/Views/MediaGridCollectionView.swift` — the app's only
`NSCollectionView` subclass — exposes `onMouseSelectionFinished: ((IndexPath?,
NSEvent.ModifierFlags) -> Void)?`, set by the controller. `mouseDown` captures
`indexPathForItem(at:)` and `event.modifierFlags`, calls `super.mouseDown`, then invokes
the closure. The controller wires it to `mouseSelectionFinished(hit:modifiers:)` in
`MediaAssetCollectionSelection.swift`, which is the single owner of the shift-range anchor.

```swift
// MediaGridSelection.swift (unchanged pure helper)
nonisolated static func shiftRangeSelection(
    anchor: MediaAssetID,
    clicked: MediaAssetID,
    base: Set<MediaAssetID>,
    orderedIDs: [MediaAssetID]
) -> Set<MediaAssetID>
```

## Interfaces, Ownership, And Data Flow

- `MediaGridCollectionView` (MainActor `NSCollectionView` subclass) observes the click and
  forwards it; it owns no selection semantics.
- `MediaAssetCollectionViewController` (MainActor) owns `selectionAnchorID` and
  `anchorBaseSelection` alongside its `collectionView.selectionIndexPaths` truth. Selection
  remains ephemeral AppKit-only state per APP-011.
- `mouseSelectionFinished(hit:modifiers:)` semantics (after `super.mouseDown` returned):

  | Click | Behavior |
  | --- | --- |
  | `hit == nil`, no ⇧/⌘ | Native cleared selection (empty-space click). Clear `selectionAnchorID` and `anchorBaseSelection`. |
  | `hit == nil`, ⇧ or ⌘ held | Leave anchor and base untouched (covers shift/⌘ marquee starts on empty space). |
  | `hit = X`, plain | `selectionAnchorID = X`, `anchorBaseSelection = selectedIdentities()` (post-collapse — the F5 fix: X is known even though no `didSelect` fired). |
  | `hit = X`, ⌘ (no ⇧) | `selectionAnchorID = X`, `anchorBaseSelection = selectedIdentities()` (post-toggle). |
  | `hit = X`, ⇧, anchor exists | `target = MediaGridSelection.shiftRangeSelection(anchor:clicked:base:orderedIDs:)`; `applySelectionDelta(from: selectedIdentities(), to: target)`; emit `MediaGridShiftRangeApplied` when the delta is non-empty; anchor/base unchanged so chains recompute from the same anchor. |
  | `hit = X`, ⇧, no anchor | `selectionAnchorID = X`, `anchorBaseSelection = selectedIdentities()` (same fallback as a plain click). |

  When both ⇧ and ⌘ are held, ⇧ wins (range over toggle). Keyboard ⇧+arrow selection stays
  native and never touches the anchor.
- Anchor lifecycle beyond clicks:
  - `restoreSelection(_:in:)`: if the anchor asset survives, keep it and prune
    `anchorBaseSelection` to the surviving identities (F6); if the anchor asset is gone,
    clear both anchor and base.
  - `clearSelection(reason:)` and the `resetSelection == true` branch of `perform(_:)`
    clear anchor and base (the latter calls `clearSelection`).
- `MediaGridSelection.shiftRangeSelection` is a pure, `nonisolated`, stateless function —
  no actor isolation concerns, no I/O.

## Retirement Proof

Replaces the delegate-inference mechanism. Grep-proven zero remaining references to:
`UserSelectionEventKind`, `handleUserSelectionEvent`, `applyShiftRangeCorrection`, and
`NSApp.currentEvent` (the event-inference read) across code and tests. The delegate methods
`didSelectItemsAt`/`didDeselectItemsAt` are pure `logSelection` telemetry again. Kept
unchanged: `MediaGridSelection.shiftRangeSelection`/`selectionDelta`/`pruned`,
`applySelectionDelta`, `restoreSelection` (delta-based), `clearSelection`, and all of
`OtosTests/MediaGridSelectionTests.swift`.

## Living Documentation And Comment Audit

- `docs/requirements.md`: APP-010 gains an acceptance clause for the multi-selection
  collapse re-anchor (F5); APP-011 gains the anchor-base pruning behavior (F6); both source
  lists gain `MediaGridCollectionView.swift`.
- `docs/adr/0006-catalog-grid-rendering.md`: selection ownership wording already resolved;
  no further change required by this increment beyond confirming it does not describe a
  delegate-inference mechanism.
- `docs/specs/0031-grid-selection-and-copy.md`: its delegate-callback mechanism note is
  updated to point at the mouseDown-capture owner.
- `docs/onboarding.md`: the grid selection paragraph describes the `MediaGridCollectionView`
  mouseDown capture.
- File guides in `MediaAssetCollectionView.swift` (bridge selection paragraph),
  `MediaAssetCollectionSelection.swift`, and the new `MediaGridCollectionView.swift`
  describe the mouseDown capture and the no-feedback-loop guarantee.

## Instrumentation And Performance

- `logSelection(reason:)` uses reasons `"shiftRange"`, `"anchorSet"`, `"mouseEmpty"`,
  `"select"`, `"deselect"`, and `"restore"` in the `UI` OSLog category.
- Signpost event `MediaGridShiftRangeApplied` (`OtosSignpost.ui`) fires only when the
  shift-range delta is non-empty.
- No profiling required: the corrected path is a same-turn AppKit call with bounded set
  operations over the visible display order, after the native tracking loop already ran.

## Code-Smell Review

- MainActor gravity: none added — anchor/base already live on the MainActor controller.
- State duplication: anchor/base are small ephemeral correction state, not a second
  selection truth; `selectionIndexPaths` remains authoritative and both are pruned to match
  it on every structural apply (F6).
- AppKit bridge sprawl: exactly one narrow `NSCollectionView` subclass whose only job is to
  forward the observed click — the minimum surface SwiftUI/AppKit cannot otherwise provide.
- Stringly typed domain facts: none introduced; reasons stay plain `String` parameters.
- Test coupling: controller tests drive `mouseSelectionFinished(hit:modifiers:)` and assert
  observable `selectionIndexPaths` membership and anchor-visible effects, not event-routing
  internals.

## Acceptance Criteria

Grid shows assets A…Z in display order (`mutationGate.displayedOrderedIDs`).

1. Click C, then ⇧-click H → {C, D, E, F, G, H} selected.
2. Then ⇧-click F (same anchor C) → {C, D, E, F} selected — range contracted.
3. Click C, ⌘-click K, then ⇧-click M → {C, K, L, M} (base {C, K} ∪ K…M).
4. ⇧-click R with no prior selection (no anchor) → {R} only.
5. {A, B, C} selected; plain click B (collapsing the multi-selection); ⇧-click F → B…F
   selected, not A…F (F5).
6. Click empty space; ⇧-click D → only {D}; empty-space ⇧-click leaves the anchor intact.
7. A background enrichment structural apply during an active range selection preserves both
   selection and anchor by identity (no shift, no loss); a removed identity is pruned from
   the anchor base (F6).
8. A structural apply that removes the anchor asset clears the anchor; the next ⇧-click
   behaves as a plain click.
9. A query-descriptor change (`resetSelection == true`) clears anchor and base along with
   the selection.

## Verification

- Local checks: `script/verify.sh` (Xcode 27 beta) from the increment worktree.
- Focused tests:
  - `MediaGridSelectionTests`: forward range, backward range, anchor == clicked, anchor
    missing from ordered IDs, clicked missing, base union preserved across a second
    shift-click, empty ordered list.
  - `MediaAssetCollectionSelectionTests`: drives `mouseSelectionFinished(hit:modifiers:)`
    directly (no `NSEvent` construction) — anchor set on plain/⌘-click, shift-range applied
    and contracted, ⌘-then-⇧ union, ⇧-with-no-anchor, ⇧⌘ behaves as ⇧, the F5 collapse
    re-anchor, empty-space plain/⇧ clicks, anchor prune on removal, F6 base pruning, and the
    descriptor-change clears.
- Step 0 platform verification: recorded above under Current Repo State (synchronous-return
  confirmed by probe; selection-commit reproduction is a recorded after-DoD limitation).
- Stale-document audit: confirms requirements, ADR 0006, spec 0031, onboarding, and the
  touched file guides describe the mouseDown-capture design; no document is left claiming a
  delegate-inference correction or that shift-click behaves like ⌘-click.
- Code-comment accuracy audit: confirms the three touched/new file guides explain the
  mouseDown capture and the no-feedback-loop guarantee without narrating AppKit syntax.
- CI expectations: remote CI gate must pass; Xcode 27 build/test proof comes from local
  `script/verify.sh`.
