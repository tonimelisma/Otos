# Plan 0002 — Code Review of PRs #57–#61 and Top-Up Fixes

> Non-authoritative plan. Delete when done.
> Execution order: **second** — these are real user-facing bugs in freshly
> landed code; fix them before larger refactors (0003+) churn the same files.
> §2 is the detailed review the owner requested; §3 turns its findings into
> work items.

## 1. Scope of the review

Reviewed at `main = 086ac19`, covering:
- **#57** model-owned grid mouse selection (`GridSelection`,
  `MediaGridCollectionView`, `applyMouseSelection`)
- **#58** PLAN.md relocation (no code)
- **#59/#60** thumbnail-only hit area (`hitTestsThumbnailFace`,
  `thumbnailFaceRect`)
- **#61** sidebar selection policy, `SidebarRow` alignment, honest eject
  (`SidebarSelectionPolicy`, `CatalogWindowViewModelSidebarPolicy`,
  `RemovableEjectOutcome`, quiesce/availability decoupling)

## 2. Review findings

### What is correct and should not be regressed

- `GridSelection` ([Otos/Views/GridSelection.swift](../../Otos/Views/GridSelection.swift))
  is a clean pure model; anchor/base semantics match the Finder idiom; the
  file guide accurately explains why the model owns selection.
- `MediaGridCollectionView.mouseDown` correctly never calls `super.mouseDown`,
  so there is no AppKit commit to race — the prior class of timing bugs is
  structurally gone. `window?.makeFirstResponder(self)` preserves keyboard
  focus.
- `applyMouseSelection` computes gestures from the model only and writes
  `selectionIndexPaths` last, via the minimal delta (ring never blinks for
  survivors).
- Store `quiesceRemovableSource` no longer flips availability
  ([CatalogStore.swift:1492](../../Otos/Stores/CatalogStore.swift)) — sidebar
  removal is now driven by real detach/unmount, exactly the honest-eject
  design. Eject failure resumes nothing it shouldn't and surfaces an alert
  through `RemovableEjectOutcome`.
- `SidebarRow` gives every row one 20 pt icon rail; the ejecting spinner state
  is per-identity and cleared on outcome.
- `CatalogWindowPolicy.resolvedSidebarSelection` now resolves hidden-All-Media
  and removable paths correctly, including the removable-path validity check.

### F-A (HIGH, functional bug): a re-inserted remembered card does not auto-select

[CatalogWindowViewModelSidebarPolicy.swift:22-28](../../Otos/ViewModels/CatalogWindowViewModelSidebarPolicy.swift)

```swift
let previousIdentities = Set(previous.removableSources.compactMap(\.deviceIdentity))
let newlyAttached = next.removableSources.filter { source in
    guard source.isAvailable, let identity = source.deviceIdentity else { return false }
    return !previousIdentities.contains(identity)
}
```

`previousIdentities` is built from **all** previous removable sources,
including remembered-but-unavailable ones. A known card (remembered from a
previous session, or ejected earlier this session) is *already present* as an
unavailable row; when re-inserted, its identity is unchanged and only its
availability flips `unavailable → available` — so `newlyAttached` is empty and
no auto-jump happens. Re-inserting a known card is the *most common* insert
case, and the owner's decision is "always jump to a newly-inserted card."

**Fix:** compare against previously *available* identities:

```swift
let previousAvailable = Set(
    previous.removableSources.filter(\.isAvailable).compactMap(\.deviceIdentity)
)
```

**Test:** `ViewModelDefaultSelectionTests` gains a case: previous state has
the identity unavailable, next state has it available → selection jumps.
Also verify at runtime via `script/logs.sh` while re-inserting a real card.

### F-B (MEDIUM, robustness): the initial-default latch can burn on a pre-load empty state

[CatalogWindowViewModelSidebarPolicy.swift:36-45](../../Otos/ViewModels/CatalogWindowViewModelSidebarPolicy.swift)

`applySidebarSelectionPolicy` runs on every `applyState`. The Projection marks
itself dirty and publishes immediately on subscription
([CatalogProjection.swift:67](../../Otos/Services/CatalogProjection.swift)),
which can precede `store.start()` completing — the first published state can
legitimately contain **zero roots**. In that case `defaultSelection` returns
`.allMedia` and `hasAppliedInitialDefault` latches `true`; the real
startup-default (single library, or connected card with an *unchanged*
identity set across the two states) is never applied.

Two mitigations exist today and make the symptom intermittent rather than
constant: (a) a card attached at startup appears as `newlyAttached` on the
*second* state (previous was empty) and jumps via the attach path; (b) the
Projection resolves `.allMedia → defaultSelection(...)` when All Media is
hidden, so single-library scope self-corrects. But the latch itself is wrong:
it records "I applied the default" when it only applied it to an empty world.

**Fix:** only latch when the state is *loaded*, e.g.

```swift
guard !userHasChosenSource, !hasAppliedInitialDefault,
      !(next.libraries.isEmpty && next.removableSources.isEmpty)
else { return }
```

(A state with zero roots of both kinds is either pre-load or a genuinely
empty catalog; in the genuinely-empty case there is nothing to select, so not
latching is also correct — the default applies once the first root is added.)

**Test:** feed the ViewModel an empty state then a one-library state; expect
`.library(theOne)` selected. Feed empty → card state; expect the card.

### F-C (MEDIUM, correctness of error surface): eject "busy" detection is heuristic and English-only

[CatalogWindowViewModelMutation.swift:97-115](../../Otos/ViewModels/CatalogWindowViewModelMutation.swift)

```swift
error.domain == NSCocoaErrorDomain && (error.code == NSUserCancelledError || error.code == 512)
... description.localizedCaseInsensitiveContains("in use") || ...("busy")
```

- `NSUserCancelledError` (3072) is *the user declining*, not "busy" — mapping
  it to the "couldn't be ejected because it's in use" alert is wrong.
- `512` is `NSFileWriteUnknownError` — a magic number standing in for "maybe
  busy".
- Substring-matching `localizedDescription` fails on any non-English locale.

**Fix (keep it small; no DiskArbitration rewrite yet):**
1. Map `NSUserCancelledError` to a silent no-alert outcome (user cancelled —
   just clear the spinner).
2. Detect busy via the *underlying* error where available:
   `error.userInfo[NSUnderlyingErrorKey]`, checking for
   `com.apple.DiskArbitration.DADissenterError` codes or POSIX `EBUSY`
   (16) in `NSPOSIXErrorDomain`. Keep the substring check only as a last-chance
   fallback, and keep `.failed(description)` (which shows the OS-localized
   message anyway) for everything unrecognized.
3. Log the full error domain/code at `error` level so real-world busy shapes
   can be collected from logs and the mapping refined with evidence.

**Test:** unit-test `removableEjectOutcome(for:)` with constructed NSErrors
(POSIX EBUSY underlying, user-cancelled, unknown).

### F-D (LOW): `drainWork` outcome is unchecked

[EnrichmentCoordinator.swift:228-242](../../Otos/Services/EnrichmentCoordinator.swift)
polls up to 5 s for in-flight work under the root, then `performEjectRemovableSource`
proceeds regardless. If work is still in flight the unmount will fail busy —
which is *handled* — but the log cannot distinguish "drained then busy from
elsewhere" from "never drained".

**Fix:** return `Bool` (drained or timed out); log the timeout with the
remaining in-flight count at `error` level in the eject path. No behavior
change beyond the log.

### F-E (LOW, edge): hit-test falls back to full-square for non-materialized items

[MediaGridCollectionView.swift:32-42](../../Otos/Views/MediaGridCollectionView.swift)
— when `item(at:)` returns nil or the item is not a `MediaAssetTileView`, the
letterbox check is skipped and the click selects on the full square.
`indexPathForItem(at:)` only returns visible items so this is rare (a
mid-scroll click). Accept and document, or treat unresolvable-as-face-miss;
**recommendation: accept + one comment line** — treating it as a miss would
make clicks during scroll feel dead.

### F-F (LOW, decide-and-document): anchor/base semantics after native keyboard selection

[MediaAssetCollectionSelection.swift:64](../../Otos/Views/MediaAssetCollectionSelection.swift)
reconciles only the `selection` field. After `⌘A`, a ⇧-click computes
`base ∪ range` where `base` is the pre-⌘A base — so the selection *contracts*
from "everything" to that union. Finder contracts to exactly `anchor…clicked`;
the current behavior contracts to `staleBase ∪ range`. Neither crashes;
the difference is user-visible only in this corner.

**Recommendation:** in `reconcilingSelection`, when the adopted live selection
differs from the model's, also set `base = liveSelection` (keyboard changes
become the new islands; anchor unchanged). Then ⌘A + ⇧-click *keeps*
everything (superset union) — predictable and non-destructive. Add one
`GridSelectionTests` case documenting whichever semantic is chosen.

### F-G (Informational, carried debt)

- The §1.5 selection acceptance matrix is covered at the model/controller
  level (`GridSelectionTests`, `MediaAssetCollectionSelectionTests` drive
  `applyMouseSelection` directly); no real-`NSEvent`/CGEvent integration test
  exists. Accepted limitation from PR #57 — unchanged by this plan.
- First-paint fade visual check and hitch traces (spec 0047/0048 F9 evidence)
  remain outstanding owner-run items; the observability work in plan 0003
  makes the log side of that easier. Not blocking.

## 3. Work items (one increment)

1. Fix F-A (+ unit test + manual runtime verification with a real card:
   insert, eject, re-insert — watch `log stream` for the selection intent).
2. Fix F-B (+ two unit tests).
3. Fix F-C (+ unit tests for the outcome mapping; keep alert copy unchanged).
4. Fix F-D (return Bool; eject logs timeout).
5. F-E: add the accepting comment.
6. F-F: implement the recommended reconcile-base semantic + test (or, if the
   owner prefers Finder-contract semantics, set `base = []` on keyboard
   divergence instead — one-line difference, same test file).
7. Update the affected requirement rows (APP sidebar/selection rows) and the
   ADR-0014 wording if plan 0001 has landed it; otherwise note for 0001.

## 4. Acceptance criteria

- Re-inserting a previously known card always selects it (unit + manual).
- Cold launch with one library and no card lands on that library even when
  the first projected state is empty (unit).
- Eject of an in-use volume shows the localized failure alert; user-cancelled
  eject shows no alert; spinner always clears (unit + manual with a file held
  open on the card).
- `script/verify.sh` green; no selection-model regressions
  (`GridSelectionTests`, `MediaAssetCollectionSelectionTests` all pass).

## 5. Risks

Small, localized diffs. The only semantic choice is F-F; it is flagged as a
decision with a recommendation rather than silently changed.
