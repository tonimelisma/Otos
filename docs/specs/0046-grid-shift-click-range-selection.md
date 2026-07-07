# Spec 0046: Grid Shift-Click Range Selection

## Classification

- Work type: Bug fix
- Current requirement IDs: APP-010, APP-011 (behavior corrected to match already-documented intent; no wording change)
- Future idea or candidate links explicitly requested by the user: none
- ADRs: ADR 0006 (amend the "Selection … require separate future specs/ADRs" sentence)

## Problem

`docs/requirements.md` APP-010 and spec 0031 already document ⇧-click as
extending a contiguous range, Photos/Lightroom style. That was never true:
`NSCollectionView` treats mouse shift-click identically to ⌘-click (toggle the
clicked item only) — shift only extends selection for keyboard ⇧+arrows, and
`shouldSelectItemsAt` is documented approve/refuse-only, so a delegate cannot
return a superset there. Clicking item C then shift-clicking item H today
leaves only {C, H} selected instead of the contiguous range C…H. This is a
verified repo-state/behavior mismatch, not a new feature: implementation must
catch up to what APP-010 already claims.

Owner decision D1 (captured 2026-07-06, see `UI.md` §1): shift-click must
select the contiguous display-order range between the anchor item and the
clicked item; ⌘-click behavior is unchanged.

## Scope

In scope:

- Anchor + base-selection model added to `MediaAssetCollectionViewController`.
- Correcting native shift-click's two-item toggle into a full contiguous range,
  applied synchronously in the same delegate turn (no visible flicker).
- Anchor lifecycle: set on plain/⌘-click, pruned by identity on structural
  applies, cleared on descriptor change and explicit `clearSelection`.
- Pure range-selection logic as a new `MediaGridSelection` helper, fully unit
  tested without AppKit lifecycle.
- Controller-level tests that host a real `MediaAssetCollectionViewController`.

Out of scope:

- Marquee/rubber-band drag selection semantics.
- Keyboard ⇧+arrow selection (already native and correct).
- Finder-style "extend from nearest edge" variants.
- Any change to `restoreSelection`'s deselect-all-then-reselect implementation
  (increment 2 makes that delta-based for ring-animation reasons; unrelated
  here).
- Grid animation, placeholder, or zoom work (increments 2 and 3).

## Current Repo State

Verified by inspection:

- `MediaAssetCollectionViewController` ([MediaAssetCollectionView.swift](../../Otos/Views/MediaAssetCollectionView.swift):61) has no anchor state today.
- `NSCollectionViewDelegate` conformance ([MediaAssetCollectionSelection.swift](../../Otos/Views/MediaAssetCollectionSelection.swift):18-29) implements
  `didSelectItemsAt`/`didDeselectItemsAt` as telemetry-only observers; AppKit
  fires `didSelectItemsAt` for a shift-click on a currently-unselected item and
  `didDeselectItemsAt` for a shift-click on a currently-selected item (native
  toggle semantics) — both must route into one correction path.
- `restoreSelection(_:in:)` ([MediaAssetCollectionSelection.swift](../../Otos/Views/MediaAssetCollectionSelection.swift):69-80) deselects the current
  selection then reselects survivors; this already runs on every structural
  apply and is the natural place to prune a dangling anchor.
- `completeStructuralApply` ([MediaAssetCollectionStructuralApply.swift](../../Otos/Views/MediaAssetCollectionStructuralApply.swift):20) calls
  `restoreSelection(context.preservedSelection, in: context.grid.orderedAssetIDs)`
  once per structural apply — the anchor prune must happen in the same call.
- `perform(_:)` ([MediaAssetCollectionView.swift](../../Otos/Views/MediaAssetCollectionView.swift):233-236) calls `clearSelection(reason:
  "descriptorChange")` when `resetSelection` is true — anchor must clear there
  too.
- `MediaGridSelection` ([MediaGridSelection.swift](../../Otos/Views/MediaGridSelection.swift)) is a `nonisolated enum` of pure helpers
  (`pruned`, `orderedSelection`) already unit tested without AppKit lifecycle
  in `OtosTests/MediaGridSelectionTests.swift` — the natural home for the new
  pure range function.
- `mutationGate.displayedOrderedIDs` ([MediaGridMutationGate.swift](../../Otos/Views/MediaGridMutationGate.swift)) is the live display-order
  source already used by `copy()`.
- No test today instantiates a live `MediaAssetCollectionViewController`
  (`OtosTests/MediaAssetCollectionTests.swift` only exercises the pure
  `MediaGridMutationGate` and `MediaGridStructuralApplyPolicy` types).
  `UI.md`'s reference to an existing controller-hosting test pattern does not
  match the repo; this spec introduces that pattern instead of reusing one.

Platform fact (verified against the Xcode 27 beta macOS SDK,
`NSCollectionView.h`): programmatic `selectItems(at:)`/`deselectItems(at:)` do
not re-enter `NSCollectionViewDelegate` methods, so a correction applied inside
the delegate callback cannot feed back into itself.

## Definition Of Ready

- [x] Goal, scope, and non-goals are explicit.
- [x] Current repo state was inspected.
- [x] Captured user guidance (D1) is restated as a precise requirement below.
- [x] Observable current requirements and acceptance examples are listed.
- [x] No future ideas introduced.
- [x] Roadmap/planning docs not consulted beyond `UI.md`, which the user
      explicitly authored for this task.
- [x] Ownership, side effects, persistence, cancellation, errors, privacy,
      instrumentation, and tests are addressed below.
- [x] Three alternatives compared.
- [x] No retirement proof needed (additive bug fix, no structure replaced).
- [x] Stale-document audit defined.
- [x] Code-comment accuracy audit defined.
- [x] No new jank surface (synchronous, same-frame correction); no profiling
      required for this increment.
- [x] Open questions: none outstanding.

## Captured Requirements For User Verification

| ID or label | Type | Captured requirement | Current or candidate | Storage location |
| --- | --- | --- | --- | --- |
| D1 | Functional | Shift-click selects the contiguous display-order range between the anchor item and the clicked item, Photos/Lightroom style; ⌘-click behavior stays as-is. | Current (fixes APP-010's already-documented but unimplemented claim) | `docs/requirements.md` APP-010 (unchanged wording, now true), this spec |

## Architectural Alternatives

### Alternative A: `shouldSelectItemsAt` returns the full target range

Pros: no post-hoc correction step.

Cons: `NSCollectionView.h` documents `shouldSelectItemsAt` as approve/refuse
only (a subset filter); returning items outside the proposed set is
undocumented behavior with no macOS prior art (verified header inspection,
`UI.md` F6). Rejected — undocumented territory for a product invariant.

### Alternative B: Maintain a parallel selection model, mirror into AppKit

Pros: full control over range semantics without depending on native toggle
quirks.

Cons: creates a second source of selection truth alongside
`collectionView.selectionIndexPaths`, contradicting APP-011 ("the collection
view's own `selectionIndexPaths` is the live truth") and the "state
duplication" code smell. Every future selection reader would need to pick the
right model. Rejected.

### Alternative C: Anchor + base-selection state, corrected synchronously inside the existing delegate callbacks

Pros: reuses `selectionIndexPaths` as the only truth; correction is a same-turn
delta (`deselectItems`/`selectItems`) with no intermediate paint, so no
flicker; anchor/base are two small pieces of ephemeral controller state, already
the pattern this controller uses for `preheatIDs`/`detailQueryGeneration` and
similar; pure range math is a fully unit-testable value function.

Cons: must route both `didSelectItemsAt` and `didDeselectItemsAt` through one
path (native toggle asymmetry) and must remember to prune/clear the anchor at
every existing selection-clearing site.

Selected because it keeps one selection truth, adds the smallest correct state,
and every failure mode (missed callback, stale anchor) has a concrete owner
site identified above.

## Selected Approach

Add `selectionAnchorID: MediaAssetID?` and `anchorBaseSelection: Set<MediaAssetID>`
to `MediaAssetCollectionViewController`. Route `didSelectItemsAt` and
`didDeselectItemsAt` into one `handleUserSelectionEvent(indexPaths:event:)`.
That method reads `event` for `.leftMouse*` type and `.shift` in
`modifierFlags` (passed in as a parameter rather than read from
`NSApp.currentEvent` internally, so tests can synthesize the event directly);
when a single-index-path event is shift-eligible and an anchor exists in the
current display order, it computes the corrected target set with a new pure
helper and applies the delta. Every other event (multi-path, non-shift,
keyboard-driven, no prior anchor) falls through to anchor/base bookkeeping only,
leaving AppKit's native result untouched.

```swift
// MediaGridSelection.swift
nonisolated static func shiftRangeSelection(
    anchor: MediaAssetID,
    clicked: MediaAssetID,
    base: Set<MediaAssetID>,
    orderedIDs: [MediaAssetID]
) -> Set<MediaAssetID>
```

Returns `base ∪ orderedIDs[min(i,j)...max(i,j)]` when both `anchor` and
`clicked` are found in `orderedIDs`; returns `{clicked}` when either is
missing (anchor lost identity, or — defensively — the clicked ID is somehow
absent from display order).

## Interfaces, Ownership, And Data Flow

- `MediaGridSelection.shiftRangeSelection` is a pure, `nonisolated`, stateless
  function — no actor isolation concerns, no I/O.
- `MediaAssetCollectionViewController` (MainActor) owns `selectionAnchorID` and
  `anchorBaseSelection` alongside its existing `collectionView.selectionIndexPaths`
  truth. No new type is surfaced to SwiftUI; selection remains ephemeral
  AppKit-only state per APP-011.
- Event plumbing:
  - Plain click (no ⇧, no ⌘): AppKit already sets selection = {clicked} and
    fires `didSelectItemsAt`. Handler sets anchor = clicked, base = {clicked}.
  - ⌘-click: AppKit toggles clicked and fires the matching
    select/deselect delegate call. Handler sets anchor = clicked, base =
    selection immediately after the toggle (i.e., `selectedIdentities()`
    read inside the callback).
  - ⇧-click on X, single index path, `NSApp.currentEvent` is a left-mouse
    event with `.shift`: handler computes
    `target = MediaGridSelection.shiftRangeSelection(anchor:, clicked: X, base:, orderedIDs: mutationGate.displayedOrderedIDs)`
    and applies `deselectItems(at: current − target)` then
    `selectItems(at: target − current, scrollPosition: [])`. Anchor is
    unchanged (the base and anchor persist across a chain of shift-clicks);
    only `anchorBaseSelection` stays as recorded at the last non-shift
    click/⌘-click, per D1's "successive shift-clicks recompute from the same
    anchor/base" requirement.
  - Anchor missing from `orderedIDs` at shift-click time: treated as a plain
    click (anchor = X, base = {X}), matching the "anchor missing" acceptance
    example.
  - Keyboard ⇧+arrows, marquee drags, ⌘A: `indexPaths.count != 1` or the
    current event is not a left-mouse click, so the handler only updates
    anchor/base to the resulting selection's single item when exactly one item
    ends up selected, otherwise leaves anchor/base untouched (⌘A leaving a
    stale single-item anchor is harmless — the next plain/⌘/shift click
    resets it, and a shift-click with a now-invalid anchor degrades to a
    plain click per the rule above).
- Anchor lifecycle beyond clicks:
  - `restoreSelection(_:in:)` prunes the anchor by identity the same way it
    prunes selection survivors: if `selectionAnchorID` is not in the new
    `ordered` array, clear both anchor and base.
  - `clearSelection(reason:)` and the `resetSelection == true` branch of
    `perform(_:)` clear anchor and base (already call
    `clearSelection`, which now also clears anchor state).

## Retirement Proof

Not applicable — additive fix, nothing removed.

## Living Documentation And Comment Audit

- `docs/requirements.md`: APP-010's wording already describes the target
  behavior; no text change needed, only the evidence file list gains
  `MediaGridSelection.swift`'s new function and this spec if APP-010's
  citation list is updated for traceability.
- `docs/adr/0006-catalog-grid-rendering.md`: line 16 currently reads
  "Selection, preview, and zoom require separate future specs/ADRs if
  implemented." Update to drop "Selection" now that this spec owns it, keeping
  preview and zoom deferred (zoom gets its own ADR amendment in increment 3).
- `docs/specs/0031-grid-selection-and-copy.md`: add a note that shift-click
  range selection's implementation gap was closed by spec 0046 (0031 predates
  the F6 platform-behavior discovery).
- `docs/onboarding.md`: the selection paragraph, if any, gains one sentence on
  anchor/base state; check during implementation.
- File guide in `MediaAssetCollectionView.swift`:6-32 already describes
  selection as fully native; add anchor/base to that description.
- `MediaAssetCollectionSelection.swift` file guide: extend to describe the
  anchor/base correction path and why it is safe from feedback loops
  (programmatic select/deselect do not re-enter the delegate).
- No comment narrates syntax or increment history.

## Instrumentation And Performance

- `logSelection(reason:)` gains reasons `"shiftRange"` and `"anchorSet"` in the
  existing `UI` OSLog category (already at debug level with count).
- New signpost event `MediaGridShiftRangeApplied` (via `OtosSignpost.ui`,
  matching the existing `emitEvent` pattern) carries no payload beyond the
  existing count log; an event, not an interval, because the correction is a
  single synchronous call with no useful sub-span.
- No profiling required: the corrected path is a same-frame AppKit call with
  bounded set operations over the visible display order, well under any hang
  budget, and does not touch the MainActor budget differently than the
  existing native toggle it replaces.

## Code-Smell Review

- MainActor gravity: none added — anchor/base already live on the MainActor
  controller with the rest of its ephemeral state; no work moves that
  shouldn't be there.
- State duplication: anchor/base are small ephemeral correction state, not a
  second selection truth — `selectionIndexPaths` remains authoritative and the
  anchor is pruned to match it on every structural apply.
- Stringly typed domain facts: none introduced; reasons stay plain `String`
  parameters consistent with the existing `logSelection(reason:)` pattern.
- Test coupling: controller tests assert observable `selectionIndexPaths`
  membership and anchor-visible-effects (via subsequent shift-click results),
  not internal event-routing mechanics.

## Acceptance Criteria

Grid shows assets A…Z in display order (`mutationGate.displayedOrderedIDs`).

1. Click C, then ⇧-click H → {C, D, E, F, G, H} selected.
2. Then ⇧-click F (same anchor C) → {C, D, E, F} selected — range contracted.
3. Click C, ⌘-click K, then ⇧-click M → {C, K, L, M} (base {C, K} ∪ K…M).
4. ⇧-click R with no prior selection (no anchor) → {R} only.
5. A background enrichment structural apply during an active range selection
   preserves both selection and anchor by identity (no shift, no loss).
6. A structural apply that removes the anchor asset clears the anchor; the
   next ⇧-click behaves as a plain click.
7. A query-descriptor change (`resetSelection == true`) clears anchor and base
   along with the selection.

## Verification

- Local checks: `script/verify.sh` (Xcode 27 beta) from the increment
  worktree.
- Focused tests:
  - `MediaGridSelectionTests`: forward range, backward range, anchor ==
    clicked, anchor missing from ordered IDs, clicked missing, base union
    preserved across a second shift-click, empty ordered list.
  - New controller-hosting tests (first of their kind — see Current Repo
    State) in `OtosTests/MediaAssetCollectionTests.swift` or a new
    `MediaAssetCollectionSelectionTests.swift`: anchor set on plain
    select/⌘-click; shift-click range applied through the real delegate path
    using a synthesized `NSEvent` with `.shift` in `modifierFlags`; anchor
    pruned when its asset is removed by a structural apply; anchor cleared on
    `resetSelection`.
- Performance/log evidence: not applicable (no new jank surface).
- Stale-document audit: confirms `docs/requirements.md`, ADR 0006, spec 0031,
  onboarding, and both touched file guides describe the landed anchor/base
  design; no document is left claiming shift-click behaves like ⌘-click.
- Code-comment accuracy audit: confirms the two touched file guides explain
  anchor/base ownership and the no-feedback-loop guarantee without narrating
  AppKit syntax.
- CI expectations: remote CI gate (checkout sanity, workflow YAML, text
  hygiene, script inventory, macOS lint) must pass; Xcode 27 build/test proof
  comes from local `script/verify.sh` per repo policy.
