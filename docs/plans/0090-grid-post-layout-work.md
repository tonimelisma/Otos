# Plan 0090 — One Owner For Post-Layout Grid Work

## Goal

Replace two hand-rolled copies of the same "park work until the collection view
has a real layout, then run it once" mechanism with a single owner. The second
copy landed in `917b04f` (#191) with its own comments saying it mirrors the
first — that is the signal to build the abstraction, not a third pair of flags.

Scope is a **behavior-preserving refactor of the AppKit grid boundary plus the
tests it currently lacks**. Lowest priority in this plan set: the current code is
correct. Run it after 0085–0089, or drop it if higher-value work appears.

## Why now

`917b04f` fixed a real bug with real evidence: live logs showed
`visibleDetailRequestCount=0` and `preheatCount=0` on every reorder-only apply
for an entire session — no thumbnail requests issued at all. The diagnosis
(a `reloadData`-class apply invalidates item layout without resolving it
synchronously, so `indexPathsForVisibleItems()` reads an empty pass) is correct,
and `layoutSubtreeIfNeeded()` is the right flush.

The problem is the shape of the fix, and one omission.

**The shape.** There are now two independent implementations of one idea:

Line numbers below are current as of `08721bb`.

| | Focus scroll | Post-apply detail/preheat |
| --- | --- | --- |
| pending state | `pendingFocusTargetID` (`MediaGridBridge.swift:186`) | `pendingPostApplyDetailReason` (`:195`) |
| re-entrancy flag | `focusLayoutRetryScheduled` (`:189`) | `postApplyLayoutRetryScheduled` (`:198`) |
| retry site | `viewDidLayout` (`:284`) | `viewDidLayout` → `retryPostApplyDetailPassIfNeeded()` (`:308`) |
| flush | `layoutSubtreeIfNeeded()` (`:628`) | `layoutSubtreeIfNeeded()` (`MediaGridStructuralApply.swift:229`) |

The code comments state the duplication outright: "same class of race as
`pendingFocusTargetID`" (`MediaGridBridge.swift:193`), "Mirrors
`focusLayoutRetryScheduled`" (`:197`), "same pattern as `pendingFocusTargetID`"
(`MediaGridStructuralApply.swift:219-220`).

Two copies is a coincidence; the comments make it a decision. A third caller —
selection restore after a remap batch, strip scroll sync, any future post-apply
read of live layout — will copy it again, and the copy that forgets the
re-entrancy flag will schedule unbounded `DispatchQueue.main.async` work.

**The omission.** `917b04f` changed behavior on the path guarded by the repo's
strictest invariant — the media grid never blanks a painted thumbnail — and added
**no test**. Requirement rows covering thumbnail request behavior were later
marked verified against tests that predate this fix.

## Root cause

`NSCollectionView` has no "run this after the next real layout" affordance, so
each caller invents one. Two ingredients recur: a stashed piece of work, and a
one-shot flag so `viewDidLayout` (which fires often) does not schedule the same
work repeatedly.

That is a work queue with coalescing. Naming it once removes the duplication and
gives the invariant a place to be tested.

## Design

Add a small `@MainActor` type owned by `MediaGridViewController`:

```swift
/// Work that must observe a resolved collection-view layout.
///
/// `NSCollectionView` invalidates item layout without resolving it synchronously,
/// so `indexPathsForVisibleItems()` / `layoutAttributesForElements(in:)` read an
/// empty pass right after a reloadData-class apply, and scrolling a zero-sized clip
/// is a silent no-op. Callers submit work here instead of hand-rolling a
/// pending/scheduled flag pair; the queue flushes layout when it can, and defers to
/// `viewDidLayout` when the frame has no size yet.
@MainActor
final class GridPostLayoutWorkQueue {
    enum Readiness { case ranNow, deferred }

    /// Keyed so a repeated submission of the same kind replaces rather than stacks.
    enum WorkKind: Hashable { case focusScroll, detailAndPreheat }

    func submit(_ kind: WorkKind, reason: String, work: @escaping () -> Void) -> Readiness
    func runDeferredWork()   // called from viewDidLayout
}
```

Semantics, each matching current behavior exactly:

1. If `collectionView.frame.width > 0` and `view.window != nil`, call
   `layoutSubtreeIfNeeded()` and run the work synchronously — `.ranNow`.
2. Otherwise stash it under its `WorkKind` — `.deferred`. A second submission of
   the same kind replaces the first (newest-value coalescing; today's code does
   this implicitly by overwriting `pendingFocusTargetID`).
3. `viewDidLayout` calls `runDeferredWork()`, which hops once to the next main-queue
   turn (scrolling *during* layout is a silent no-op — `:285-287`) and runs each
   stashed item once. The one-shot flag becomes queue-internal, so no caller can
   forget it.

Both existing call sites then read as one line each, and `MediaGridViewController`
loses four stored properties.

`WorkKind` is a closed enum rather than a free-form key on purpose: a new
post-layout consumer must add a case, which puts it in front of a reviewer.

## Stages

### Stage 1 — Characterization tests for current behavior

Refactor without an oracle is a rewrite. Write these first, against the code as
it stands today, and require them green before and after:

1. A `reloadData`-class apply on a laid-out grid issues visible-detail requests
   (`visibleDetailRequestCount > 0`) — the regression `917b04f` fixed, currently
   untested.
2. An apply against a zero-width frame issues none, then issues them exactly once
   after `viewDidLayout` reports a non-zero frame.
3. Repeated `viewDidLayout` calls with work pending run it **once**, not once per
   call — the re-entrancy flag's purpose.
4. A focus-scroll request against a zero-width frame scrolls once after layout.
5. The no-blank invariant holds across all of the above: a tile painted for asset
   A still shows A's thumbnail after every path (extend
   `MediaGridPaintInvariantTests`, which already owns this question).

Test 3 is the one that catches the bug a third hand-rolled copy would introduce.

These tests are the deliverable of Stage 1 even if the refactor never happens —
they cover a real bug that shipped untested.

### Stage 2 — Introduce the queue behind the existing call sites

Add `GridPostLayoutWorkQueue`, route `runPostApplyDetailAndPreheatPass` through
it, delete `pendingPostApplyDetailReason` and `postApplyLayoutRetryScheduled`.
Stage 1's tests must stay green unmodified — that is the oracle, per AGENTS.md
Code Review lens A.

### Stage 3 — Migrate the focus-scroll path

Route `scrollToFocusTarget` through the queue; delete `pendingFocusTargetID` and
`focusLayoutRetryScheduled`. Note `pendingFocusTargetID` is also read at
`MediaGridBridge.swift:585,596,601,616,630,642` and
`MediaGridStructuralApply.swift:177` — those reads are the "did the apply land the
focus target" question, which is not the same question as the retry. Keep that
state if it is genuinely a second question; only the retry pair is being replaced.
Decide this from the code and state the decision in the PR.

### Stage 4 — Requirements and docs

Update the rows covering grid detail requests and focus scroll to cite the Stage 1
tests. Update `docs/architecture.md:76-84` (the grid subsystem paragraph) to name
the queue as the owner of post-layout work. No ADR: this is a mechanism inside an
existing boundary, not a new decision.

## Verification

- Stage 1 tests green before Stage 2 and unmodified after Stage 3.
- `bash script/verify.sh` green.
- Runtime evidence, since this is the jank path: run `script/smoke-run.sh --jank`
  and confirm via `script/logs.sh` that `visibleDetailRequestCount > 0` on
  reorder-only applies and that no main-actor span exceeds 100 ms. Attach the
  worst-span summary to the PR (AGENTS.md requires profiler/log evidence for
  changes touching jank or rendering).
- `MediaGridViewController` has four fewer stored properties.

## Non-goals and guards

- Do not change *when* work runs or *what* it does. This is behavior-preserving;
  any observable difference is a bug in the refactor.
- Do not generalize the queue beyond the grid. Two call sites justify one small
  type in one file, not a framework.
- Do not add a third pending/scheduled flag pair anywhere. If a new post-layout
  consumer appears mid-plan, it uses the queue.
- Do not skip Stage 1. Refactoring the no-blank path without characterization
  tests risks the one invariant CLAUDE.md marks absolute.
