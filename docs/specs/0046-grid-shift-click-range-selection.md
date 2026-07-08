# Spec 0046: Grid Mouse Selection Model

## Classification

- Work type: Bug fix (rework of the Increment B shift-click mechanism, PLAN.md Part 1).
- Current requirement IDs: APP-010, APP-011 (mouse selection model; the grid owns a pure
  selection model and AppKit renders it).
- Future idea or candidate links explicitly requested by the user: none.
- ADRs: ADR 0006 (selection ownership wording already resolved; this spec owns the
  *mechanism* by which mouse selection is applied, not the rendering ownership ADR 0006
  already decides).

## Problem

Owner hand-testing reported three selection defects (PLAN.md §1.1):

1. **Range contraction drops the clicked tile.** Click tile 1, ⇧-click tile 4 →
   `{1,2,3,4}` (correct). Then ⇧-click tile 3 → `{1,2}` instead of `{1,2,3}`. The
   clicked tile 3 is wrongly deselected.
2. **Selection "remembers" the old set.** After some ⇧-selections, a plain click shows
   only the clicked tile (correct visually), but the *next* ⇧-click re-adds the
   previously-selected tiles.
3. **⌘-deselect leaves a polluting anchor.** Select a tile, ⌘-click it to deselect
   (nothing selected). A following ⇧-click selects a whole range from the
   just-deselected tile *and* re-adds prior selection.

### Root cause (verified in code)

`MediaGridCollectionView.mouseDown` called `onMouseSelectionFinished` immediately after
`super.mouseDown`. The handler `mouseSelectionFinished(hit:modifiers:)` then read
`selectedIdentities()` — i.e. `collectionView.selectionIndexPaths` — and used it as an
*input* to compute the corrected selection (as `current` for the shift-range, and as
`base` for plain/⌘ clicks). That read is the bug: AppKit's `selectionIndexPaths` is
mid-gesture during the mouse event sequence, and its commit timing across
mouseDown/mouseUp is not a stable, documented contract. The handler computed its
correction from a stale/pre-commit value, and AppKit's own subsequent commit then partly
overwrote the correction. Bugs 1–3 are all the same defect — reading AppKit's selection
as an *input* to a computation that AppKit then overwrites.

The unit tests in `MediaAssetCollectionSelectionTests` encoded the false assumption: they
pre-settled the native selection with `selectItems`/`deselectItems` and then called the
handler, simulating a settled native selection that the real mouse path never provides at
that point. They tested a model of the timing that was wrong, so they passed while the app
was broken.

### Why the fix is "stop reading AppKit selection as input," not "read it later"

Moving the read to a later hook does not fix the design flaw: any code that treats
AppKit's `selectionIndexPaths` as an *input* to its own selection computation is coupled
to AppKit's commit timing, which is undocumented for the mouse event sequence. The fix is
to stop reading AppKit's selection as input entirely: own a pure selection model as the
single source of truth, treat AppKit's `selectionIndexPaths` as an *output we write*, and
never invoke AppKit's native mouse selection at all — so there is no competing commit to
race. This makes the Increment-B failure mode impossible by construction and removes the
mouseDown-vs-mouseUp timing dependency entirely.

## Scope

In scope:

- A pure, `nonisolated` selection model type `GridSelection` (new file
  `Otos/Views/GridSelection.swift`) that owns selection, anchor, and base, with
  `plainClick`/`commandClick`/`shiftClick`/`commandShiftClick`/`clearedBySpace`/`pruned`
  operations. Fully unit-tested without AppKit.
- `MediaGridCollectionView` owns the mouse path: it overrides `mouseDown`, does **not**
  call `super.mouseDown`, captures `(hit, modifiers)`, and asks the controller to compute
  the gesture against the controller's `GridSelection` (never `collectionView.selectionIndexPaths`)
  and write `selectionIndexPaths` as the last operation. `window?.makeFirstResponder(self)`
  preserves keyboard focus that `super.mouseDown` would otherwise have handled.
- Thumbnail-only hit area (PLAN.md Part 2) is a separate increment. Until it lands, the
  `hit` passed to the selection model is the raw `indexPathForItem(at:)` result; clicks in
  a tile's letterbox still select that tile, as today.
- The controller owns a single `GridSelection` value, replacing
  `selectionAnchorID`/`anchorBaseSelection`. `applySelectionDelta` remains the one place
  that mutates `selectionIndexPaths`, now driven by `gridSelection.selection`.
- Structural-apply integration: same-descriptor apply prunes `gridSelection` to survivors
  (delta write, preserving the no-ring-blink property); descriptor-changing apply resets
  `gridSelection = .empty` and clears selection.
- Keyboard selection (`⌘A`, ⇧+arrows) stays native; the model is kept in sync by
  reconciling `gridSelection.selection` from `selectedIdentities()` at the start of the
  next mouse gesture (and on `selectAll`), so a keyboard change is observed without the
  model ever being read as input for its own computation. Anchor/base are left as-is on
  keyboard selection (native behavior, as today).
- Tests driving real `mouseDown`+`mouseUp` event pairs against a windowed collection view
  (attempt `CGEvent` for hit-test fidelity; fall back to driving the handler directly if
  the environment blocks synthetic HID events), plus pure-model tests for `GridSelection`.

Out of scope:

- Thumbnail-only hit area (PLAN.md Part 2 — separate spec). Until that lands, `hit` is the
  raw `indexPathForItem(at:)` result.
- Marquee/rubber-band drag selection. The grid has none (verified: no drag-source or
  marquee delegate methods exist), which is what makes "do not call `super.mouseDown`"
  safe.
- Sidebar selection policy and eject (PLAN.md Parts 3–5 — separate specs).

## Current Repo State

Verified by inspection at the start of this increment:

- `MediaGridCollectionView` ([`MediaGridCollectionView.swift`](../../Otos/Views/MediaGridCollectionView.swift))
  overrides `mouseDown`, calls `super.mouseDown(with:)`, then invokes
  `onMouseSelectionFinished?(hit, modifiers)`. `hit` is `indexPathForItem(at:)` of the
  converted click location.
- `MediaAssetCollectionViewController` ([`MediaAssetCollectionView.swift`](../../Otos/Views/MediaAssetCollectionView.swift))
  owns `selectionAnchorID: MediaAssetID?` and `anchorBaseSelection: Set<MediaAssetID>`,
  wired in `configureCollectionView()` via `collectionView.onMouseSelectionFinished = { …
  mouseSelectionFinished(hit:modifiers:) }`.
- `mouseSelectionFinished(hit:modifiers:)`
  ([`MediaAssetCollectionSelection.swift`](../../Otos/Views/MediaAssetCollectionSelection.swift))
  reads `selectedIdentities()` (i.e. `collectionView.selectionIndexPaths`) as `current`
  for shift-range computation and as `base` for plain/⌘ clicks. This read-then-correct is
  the root cause.
- `applySelectionDelta(from:to:)` deselects/selects only the delta, preserving the spec
  0047 no-ring-blink property for survivors. Kept; now driven by `gridSelection.selection`.
- `restoreSelection(_:in:)` prunes the anchor/base on structural apply (F6 behavior);
  `clearSelection(reason:)` clears them. Both fold into `GridSelection.pruned` / `.empty`.
- `MediaGridSelection` ([`MediaGridSelection.swift`](../../Otos/Views/MediaGridSelection.swift))
  holds pure helpers `pruned`, `orderedSelection`, `shiftRangeSelection`,
  `selectionDelta`. `shiftRangeSelection` and `pruned` are subsumed by `GridSelection`;
  `orderedSelection` and `selectionDelta` stay.
- `MediaGridMutationGate.displayedOrderedIDs` is the live display order used for range
  math and `copy()`. Unchanged.
- No drag-source, marquee, or rubber-band delegate methods exist anywhere in the grid
  (grep-verified: `canDragItems`, `draggingSession`, `pasteboardWriterFor`, `marquee`,
  `rubberband` appear only in comments). This confirms "do not call `super.mouseDown`"
  loses no functionality.
- Tests: `MediaAssetCollectionSelectionTests` pre-settles the selection with
  `selectItems`/`deselectItems` then calls `mouseSelectionFinished`, encoding the false
  timing assumption. `MediaGridSelectionTests` tests the pure helpers directly.

Platform fact (corrected): `NSCollectionView`'s default `mouseDown` runs a mouse-tracking
loop whose selection-commit timing across the mouse event sequence is not a stable,
documented contract. The selected approach never calls `super.mouseDown` and never reads
`selectionIndexPaths` as input, so AppKit's commit timing is irrelevant. This replaces the
prior spec's claim that `super.mouseDown` returns with selection final — that claim could
not be headlessly reproduced and the owner's hand-testing showed it does not hold for the
read-as-input pattern this spec replaces.

## Definition Of Ready

- [x] Goal, scope, and non-goals are explicit.
- [x] Current repo state was inspected and summarized above.
- [x] Captured user guidance is restated as precise requirements below (D1, B1/B2/B3).
- [x] Observable requirements and acceptance examples are listed (acceptance matrix).
- [x] No future ideas introduced.
- [x] Ownership, side effects, cancellation, errors, privacy, instrumentation, and tests
      are addressed below.
- [x] Three-plus alternatives compared, including the superseded mouseDown-capture path.
- [x] Retirement proof for the removed machinery.
- [x] Stale-document audit defined.
- [x] Code-comment accuracy audit defined.
- [x] No new jank surface (synchronous, same-turn write; `super.mouseDown` not called);
      no profiling required for this increment.
- [x] Open questions: none outstanding. The "Step 0 probe" is no longer a mechanism
      *choice* — because the design is timing-independent, Step 0 is an agent-runnable
      end-to-end test (see Verification), not an empirical gate.

## Captured Requirements For User Verification

| ID or label | Type | Captured requirement | Current or candidate | Storage location |
| --- | --- | --- | --- | --- |
| D1 | Functional | Shift-click selects the contiguous display-order range between the anchor item and the clicked item, Photos/Lightroom style; plain click selects {clicked}; ⌘-click toggles; ⌘⇧-click extends the range from the anchor while keeping existing islands. | Current | `docs/requirements.md` APP-010, this spec |
| B1 | Functional (bug fix) | A second ⇧-click from the same anchor that contracts the range must keep the clicked tile selected: click 1, ⇧-click 4 → {1,2,3,4}; ⇧-click 3 → {1,2,3}. | Current | `docs/requirements.md` APP-010, this spec |
| B2 | Functional (bug fix) | After a plain click collapses a multi-selection, the next ⇧-click ranges from the clicked item only and does not re-add the previously-selected tiles: select {C,D,E}, plain-click D, ⇧-click G → {D,E,F,G}, not {C,D,E,F,G}. | Current | `docs/requirements.md` APP-010, this spec |
| B3 | Functional (bug fix) | After ⌘-clicking the sole selected tile to deselect (selection empty), a ⇧-click ranges from that deselected pivot and adds nothing stale: click B, ⌘-click B (∅), ⇧-click E → {B,C,D,E}. | Current | `docs/requirements.md` APP-010, this spec |
| F5 | Functional (regression, preserved) | A plain click collapsing a multi-selection onto an already-selected member re-anchors to that item; a following ⇧-click ranges from it. | Current | `docs/requirements.md` APP-010, this spec |
| F6 | Non-functional (regression, preserved) | A structural apply that keeps the anchor prunes dead identities from the base; one that removes the anchor clears anchor and base. | Current | `docs/requirements.md` APP-011, this spec |

## Architectural Alternatives

### Alternative A (rejected): apply the correction in `mouseUp` after `super.mouseUp`

Override `mouseUp`, capture `(hit, modifiers)` at `mouseDown`, and after `super.mouseUp`
compute the gesture and write `selectionIndexPaths`. Pros: still calls super, so any
future marquee/reorder would keep working. Cons: depends on the view receiving a separate
`mouseUp` and on `super.mouseUp` committing a final selection — the same class of
undocumented timing coupling that caused the bug. If AppKit's tracking loop consumes
mouse-up internally (no separate `mouseUp` delivered), this design silently breaks.
Rejected: it trades one timing coupling for another without removing the root cause
(reading AppKit selection as input).

### Alternative B (rejected): keep reading AppKit selection, but read it "later"

Keep `mouseSelectionFinished` reading `selectedIdentities()` as input, just at a later
hook. Cons: this is the root cause, not a fix — any read of `selectionIndexPaths` as an
input to our selection computation couples us to AppKit's commit timing. Rejected.

### Alternative C (rejected): maintain a parallel selection model mirrored into AppKit, read AppKit as truth

Cons: creates a second source of selection truth alongside `collectionView.selectionIndexPaths`,
contradicting APP-011 and the "state duplication" code smell — the exact failure mode of
the prior design. Rejected.

### Alternative D (selected): own a pure selection model; AppKit renders it; never call `super.mouseDown`

`MediaGridCollectionView` overrides `mouseDown` and does **not** call `super.mouseDown`.
It captures `(hit, modifiers)`, asks the controller to compute the gesture against the
controller's own `GridSelection` value (never `collectionView.selectionIndexPaths`), and
writes `collectionView.selectionIndexPaths = indexPaths(gridSelection.selection)` as the
last operation. Because `super.mouseDown` is never called, AppKit's selection-tracking
loop never runs, so there is no competing commit and no timing dependency. Because the
model is the single source of truth, `selectionIndexPaths` is purely an output we write.
Programmatic `selectionIndexPaths =` / `selectItems` / `deselectItems` do not re-enter
`mouseDown`, so there is no feedback loop. The grid uses neither marquee nor drag-reorder
(grep-verified), so calling `super` bought nothing to begin with;
`window?.makeFirstResponder(self)` preserves focus. This is the simplest correct design:
one model, one write, no timing coupling. It makes the Increment-B failure mode
impossible by construction.

## Selected Approach

Alternative D.

### New pure type: `GridSelection`

New file `Otos/Views/GridSelection.swift`. `nonisolated`, no AppKit, fully unit-tested.

```swift
nonisolated struct GridSelection: Equatable {
    private(set) var selection: Set<MediaAssetID>
    private(set) var anchor: MediaAssetID?
    /// The "islands" a ⇧-range unions with — snapshot at the last plain/⌘ click.
    private(set) var base: Set<MediaAssetID>

    static let empty = GridSelection(selection: [], anchor: nil, base: [])

    func plainClick(_ id: MediaAssetID) -> GridSelection
    func commandClick(_ id: MediaAssetID) -> GridSelection
    func shiftClick(_ id: MediaAssetID, orderedIDs: [MediaAssetID]) -> GridSelection
    func commandShiftClick(_ id: MediaAssetID, orderedIDs: [MediaAssetID]) -> GridSelection
    func clearedBySpace() -> GridSelection
    func pruned(to orderedIDs: [MediaAssetID]) -> GridSelection
}
```

Normative rules:

- `plainClick(x)` → `selection = {x}`, `anchor = x`, `base = {x}`.
- `commandClick(x)` → `s = selection.symmetricDifference([x])`; `selection = s`,
  `anchor = x`, `base = s`. (⌘ toggles; the clicked item becomes the pivot even when it
  was deselected — matches Finder.)
- `shiftClick(x, order)`:
  - if `anchor` or `x` is not in `order` → behave as `plainClick(x)` (fallback; a removed
    anchor must not resurrect a stale range).
  - else `range = order[min(i,j)…max(i,j)]`; `selection = base ∪ range`; `anchor` and
    `base` unchanged (so a chain of ⇧-clicks from the same anchor grows/shrinks).
- `commandShiftClick(x, order)` **(eng default)**: if `anchor` or `x` missing →
  `plainClick(x)`; else `selection = selection ∪ range(anchor…x)`; `anchor`/`base`
  unchanged. (⌘⇧ extends and *keeps* existing islands, rather than collapsing to the
  range. This corrects the prior behavior where ⇧⌘ collapsed to ⇧ and dropped islands.)
- `clearedBySpace()` → `.empty`.
- `pruned(to order)`: `selection = selection ∩ order`; `base = base ∩ order`; if `anchor`
  not in `order` → `anchor = nil` and `base = []`. Used on a same-descriptor structural
  apply. A *descriptor change* instead resets to `.empty` (handled by the caller, not
  `pruned`).

This subsumes `MediaGridSelection.shiftRangeSelection` and `MediaGridSelection.pruned`,
and the ad-hoc anchor/base bookkeeping in `MediaAssetCollectionSelection.swift`.

### AppKit integration

The controller owns `var gridSelection = GridSelection.empty` (replaces
`selectionAnchorID`/`anchorBaseSelection`).

`MediaGridCollectionView.mouseDown(with:)`:

1. `let hit = indexPathForItem(at: convert(event.locationInWindow, from: nil))`
2. `let modifiers = event.modifierFlags`
3. `window?.makeFirstResponder(self)` (preserve focus that `super.mouseDown` would have
   handled).
4. Do **not** call `super.mouseDown(with:)`.
5. Call `onMouseSelection?(hit, modifiers)` — the controller computes the gesture and
   writes `selectionIndexPaths`.

Gesture classification (in the controller, from the captured event):

- `hit == nil` (empty space), no ⇧/⌘ → `gridSelection = gridSelection.clearedBySpace()`;
  write selection to `[]`.
- `hit == nil` with ⇧ or ⌘ → no change to `gridSelection` or selection (leave anchor
  intact; covers ⇧/⌘ empty-space which AppKit would have used to start a marquee — we
  have no marquee, so it is a no-op).
- `hit = x`, plain → `gridSelection = gridSelection.plainClick(x)`.
- `hit = x`, ⌘ (no ⇧) → `gridSelection = gridSelection.commandClick(x)`.
- `hit = x`, ⇧ (no ⌘) → `gridSelection = gridSelection.shiftClick(x, orderedIDs)`.
- `hit = x`, ⇧⌘ → `gridSelection = gridSelection.commandShiftClick(x, orderedIDs)`.

Before computing the new model, reconcile `gridSelection.selection` from
`selectedIdentities()` so a prior native keyboard change (⌘A, ⇧-arrows) is observed.
Then compute the gesture, then write via `applySelectionDelta(from: selectedIdentities(),
to: gridSelection.selection)` so survivors are not reassigned (preserves spec 0047
no-ring-blink). `orderedIDs` comes from `mutationGate.displayedOrderedIDs`.

`selectedIdentities()` is read **only** to (a) reconcile the model's `selection` field
with native keyboard changes and (b) compute the delta for the write — it is never used as
an input to the gesture computation. The gesture is computed solely from `gridSelection`.

`MediaGridCollectionView`'s closure is renamed `onMouseSelection` (from
`onMouseSelectionFinished`) to reflect that selection is no longer "finished" by AppKit at
the call site — the controller finishes it.

### Structural-apply and descriptor-change integration

- Same-descriptor apply (`resetSelection == false`):
  `gridSelection = gridSelection.pruned(to: grid.orderedAssetIDs)`, then
  `applySelectionDelta(from: selectedIdentities(), to: gridSelection.selection)`. Delta
  write preserves the no-ring-blink property.
- Descriptor-changing apply (`resetSelection == true`): `gridSelection = .empty` and
  `clearSelection(reason: "descriptorChange")` (as today).
- `restoreSelection(_:in:)` folds into the pruned path; `clearSelection(reason:)` sets
  `gridSelection = .empty`.

## Interfaces, Ownership, And Data Flow

- `GridSelection` (`nonisolated`, value type) is the single source of selection truth for
  the grid. Pure, no I/O, no AppKit.
- `MediaGridCollectionView` (MainActor `NSCollectionView` subclass) owns the mouse path:
  captures the click, does not call `super.mouseDown`, asks the controller to apply the
  gesture, and the controller writes `selectionIndexPaths` last. It owns no selection
  semantics.
- `MediaAssetCollectionViewController` (MainActor) owns `gridSelection: GridSelection`.
  `collectionView.selectionIndexPaths` is a render output, snapshotted before each
  structural apply (for delta restore) and written by `applySelectionDelta`.
- `applySelectionDelta(from:to:)` remains the single mutator of `selectionIndexPaths`,
  now always driven by `gridSelection.selection`. Keyboard ⇧+arrow / ⌘A selection stays
  native (AppKit writes `selectionIndexPaths` directly); the model reconciles its
  `selection` field from `selectedIdentities()` at the start of the next mouse gesture,
  and its anchor/base are left as-is (native behavior, as today).
- Concurrency: all selection state is MainActor; `GridSelection` operations are
  `nonisolated` value-type computations. No actor isolation concerns, no I/O.

## Retirement Proof

Replaces the Increment B mouseDown-capture-as-input mechanism. Removed:

- `MediaGridCollectionView.onMouseSelectionFinished` closure property → renamed
  `onMouseSelection` (the "finished" framing is gone).
- `MediaAssetCollectionViewController.selectionAnchorID`,
  `anchorBaseSelection`, and `mouseSelectionFinished(hit:modifiers:)` → replaced by
  `gridSelection` and `applyMouseSelection(hit:modifiers:)`.
- `MediaGridSelection.shiftRangeSelection` and `MediaGridSelection.pruned` → folded into
  `GridSelection`.

Kept unchanged: `MediaGridSelection.orderedSelection`, `MediaGridSelection.selectionDelta`,
`MediaGridClipboard`, `applySelectionDelta`, `copy(_:)`, `validateUserInterfaceItem`,
`selectedIdentities()` (now used only for reconciliation and delta writes, not gesture
input), `logSelection(reason:)`.

Grep-proven zero remaining references to the removed symbols across code and tests after
implementation.

## Living Documentation And Comment Audit

- `docs/requirements.md`: APP-010 gains acceptance clauses for B1/B2/B3 (contracting
  range keeps the clicked tile; collapse then ⇧-click does not re-add; ⌘-deselect then
  ⇧-click ranges from the pivot); APP-011's "live truth" wording is updated to reflect
  that `selectionIndexPaths` is a render output the model drives, not an input. Source
  lists: `GridSelection.swift` added; `MediaGridSelection.swift` retains
  `orderedSelection`/`selectionDelta`/`MediaGridClipboard`.
- `docs/adr/0006-catalog-grid-rendering.md`: confirm the selection-ownership wording is
  still accurate; update any wording that describes reading `selectionIndexPaths` as
  input.
- `docs/specs/0031-grid-selection-and-copy.md`: its delegate-callback/selection note is
  updated to point at the model-owned mouse path.
- `docs/onboarding.md`: the grid selection paragraph describes `GridSelection` as the
  model and the no-`super.mouseDown` mouse path.
- File guides in `MediaAssetCollectionView.swift` (bridge selection paragraph),
  `MediaAssetCollectionSelection.swift`, `MediaGridCollectionView.swift`, and the new
  `GridSelection.swift` describe the model-owned design and the no-feedback-loop /
  no-timing-coupling guarantee. The prior "after `super.mouseDown` returns, native
  selection is final" comments are removed — they described a timing contract this spec
  no longer depends on.

## Instrumentation And Performance

- `logSelection(reason:)` uses reasons `"plainClick"`, `"commandClick"`, `"shiftRange"`,
  `"commandShiftRange"`, `"emptySpace"`, `"shiftEmptySpace"`, `"select"`, `"deselect"`,
  `"restore"`, `"descriptorChange"` in the `UI` OSLog category.
- Signpost event `MediaGridShiftRangeApplied` (`OtosSignpost.ui`) fires when a ⇧-range or
  ⇧⌘-range delta is non-empty.
- No profiling required: the path is a synchronous value-type computation over the
  visible display order plus a bounded delta write, with no `super.mouseDown` tracking
  loop. Strictly less main-thread work than the prior design.

## Code-Smell Review

- MainActor gravity: none added — `gridSelection` is MainActor; `GridSelection`
  operations are `nonisolated`.
- State duplication: **removed.** The prior `selectionAnchorID`/`anchorBaseSelection`
  alongside `selectionIndexPaths` was a split truth; `GridSelection` is now the single
  model and `selectionIndexPaths` is explicitly a render output.
- AppKit bridge sprawl: unchanged — one `NSCollectionView` subclass, now with a simpler
  job (capture, don't-call-super, forward).
- Stringly typed domain facts: none introduced; reasons stay plain `String` parameters
  for log telemetry.
- Test coupling: controller tests drive real `mouseDown`+`mouseUp` event pairs and assert
  observable `selectionIndexPaths` membership, not internal model fields. Pure-model
  tests assert `GridSelection` value transitions directly.

## Acceptance Criteria

Grid shows assets A B C D E F G H in display order; `▓` = selected.

| # | Action sequence | Expected final | Guards |
| --- | --- | --- | --- |
| 1 | click C | `C` | plain sets anchor+base |
| 2 | click C, ⇧-click F | `C D E F` | forward range |
| 3 | …then ⇧-click D | `C D` | **contract from same anchor (B1)** |
| 4 | click F, ⇧-click C | `C D E F` | backward range |
| 5 | click B, ⌘-click E | `B E` | ⌘ adds island, anchor→E |
| 6 | …then ⇧-click G | `B E F G` | ⇧ ranges E…G, keeps island B |
| 7 | click C, ⇧-click F, ⌘-click D | `C E F` | ⌘ removes inside a range |
| 8 | select `C D E`, plain-click D | `D` | **collapse; base becomes {D} (B2)** |
| 9 | …then ⇧-click G | `D E F G` | **must NOT re-add C,E (B2)** |
| 10 | click B, ⌘-click B | `∅` | anchor stays B, base `∅` |
| 11 | …then ⇧-click E | `B C D E` | **ranges from pivot B, nothing stale (B3)** |
| 12 | click empty space | `∅` | clears selection+anchor |
| 13 | ⇧-click with empty selection | `{clicked}` | no-anchor fallback |
| 14 | ⌘⇧-click H after `B E` selected (anchor E) | `B E F G H` | extend, keep islands |
| 15 | select `C D`, background apply removes D | `C` | prune survivors + base (F6) |
| 16 | select `C D` (anchor C), background apply removes C | `∅` | anchor removed → clear anchor+base |

## Verification

- Local checks: `script/verify.sh` (Xcode 27 beta) from the increment worktree.
- Step 0 (agent-runnable end-to-end proof, per PLAN.md §1.3.2): an integration test builds
  a real windowed `MediaGridCollectionView`, drives the click handler with real
  `mouseDown`/`mouseUp` pairs (attempt `CGEvent` posting for true hit-test fidelity; if the
  environment blocks synthetic HID events, drive our own handler directly), and asserts the
  acceptance matrix against `selectionIndexPaths`. This is deterministic regardless of
  AppKit's native mouse-selection timing, because the design no longer depends on it.
  Record in the DoD whether `CGEvent` could be driven; if not, that is an accepted
  limitation (the owned-path test still proves the matrix).
- Focused tests:
  - `GridSelectionTests`: every model operation — plainClick, commandClick (toggle in and
    out, pivot-on-deselect), shiftClick (forward, backward, contract from same anchor,
    no-anchor fallback, missing-anchor/missing-clicked fallback, base union outside range,
    empty order), commandShiftClick (extend keeping islands, fallback), clearedBySpace,
    pruned (survivor prune, base prune, anchor-removed clear).
  - `MediaAssetCollectionSelectionTests`: drives real `mouseDown`+`mouseUp` event pairs
    against a windowed collection view (no pre-settled selection) for the acceptance
    matrix rows 1–14, plus structural-apply prune rows 15–16 and the descriptor-change
    clear. Asserts `selectedIdentities()` membership.
- Stale-document audit: confirms requirements, ADR 0006, spec 0031, onboarding, and the
  touched file guides describe the model-owned, no-`super.mouseDown` design; no document
  is left claiming `super.mouseDown` returns with selection final, or that the handler
  reads `selectionIndexPaths` as input.
- Code-comment accuracy audit: confirms the touched/new file guides explain the
  model-owned design and the no-timing-coupling guarantee without narrating AppKit syntax
  or referencing the retired mouseDown-capture mechanism.
- CI expectations: remote CI gate must pass; Xcode 27 build/test proof comes from local
  `script/verify.sh`.
