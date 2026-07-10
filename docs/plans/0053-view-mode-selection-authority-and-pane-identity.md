# Plan 0053 — Repair view-mode selection authority and pane identity

Fixes the eight defects reported against the plan-0052 implementation (PRs #89–#91).
Written for an implementing agent who has not read the review conversation: every
change names the file, the current defective line(s), the replacement design, and
the test that proves it. Delete this file when the work is fully done.

Three increments, each its own worktree + PR + DoD:

- **Stage A** (`fix/selection-authority`) — selection truth is written only by
  intents; renderers never write the model.
- **Stage B** (`fix/pane-identity`) — pane images carry asset identity; loupe strip
  clicks change the image; per-slot request lifecycle.
- **Stage C** (`fix/strip-input-and-layout`) — strip keyboard/first-responder,
  centering, and a horizontal-scrolling strip layout that feeds the existing
  scroll-driven loading.

---

## 0. The two invariants this plan restores

**I1 — One-way selection flow.** `CatalogWindowViewModel.gridSelection` is the only
selection truth. It is written by exactly four writer classes: (1) mouse-gesture
intents, (2) view-mode intents (`openLoupe`/`applyComparePair`/…), (3) native
keyboard reconcile, (4) the ViewModel's own state-driven prune/clear in
`applyState`. AppKit's `selectionIndexPaths` is a render output. **No code path may
compute a model write from `selectedIdentities()` except the gated native-keyboard
reconcile.** The current code violates this in three places (§A below) — that is the
root cause of "selection doesn't persist across view changes."

**I2 — Pane content is identity-keyed and monotonic.** What a loupe/compare pane
shows is a function of *the asset it is supposed to show*: the enrichment thumbnail
immediately, replaced by the full-size decode when ready, never a stale image that
belongs to a different asset, never a regression from image to blank. The current
code renders bare `CGImage?` slots with no identity (§B below) — the root cause of
wrong/stale/duplicated pane images.

### Symptom → root cause → stage

| # | Reported symptom | Root cause | Stage |
| --- | --- | --- | --- |
| 1 | Loupe entry: strip not selected, not centered | F1a wipe (selection); no scroll-to-focus (centering) | A + C |
| 2 | Loupe: clicking strip never changes the big image | F3 no loupe branch in `applyGridClick` | B |
| 3 | Loupe: arrows beep | F4 nothing is first responder after mode switch | C |
| 4 | Compare entry: not selected/centered | F1a + no scroll-to-focus | A + C |
| 5 | Compare: new image stalls instead of showing thumbnail | F2 stale non-nil slot shadows the id-keyed thumbnail fallback | B |
| 6 | Compare: same image appears in both panes while loading | F2 identity-less slots + loader LRU hit on the moved member | B |
| 7 | Compare: third image shows but strip doesn't select it | F1a/F1b wipes + echo corruption | A |
| 8 | Loupe: strip selects X but big image is some other asset | F2 (stale slot) + F3 (focus never follows click) | B |

Latent defects fixed alongside: F1b delegate echo corrupts anchor/base (regresses
APP-010 ⇧-chain contraction); F5 strip's orthogonal section never triggers
scroll-driven thumbnail loading; F6 `reconcileFocusAfterGridChange` is dead code
(never called), so a deleted focused file leaves a ghost loupe focus.

---

## Stage A — Selection authority (`fix/selection-authority`)

### A0. The three violations being removed

- **F1a.** [Otos/Views/MediaGridStructuralApply.swift:45] `preservedSelection =
  resetSelection ? [] : selectedIdentities()` snapshots *AppKit live selection*
  (empty on every freshly created controller — and a controller is recreated on
  every mode switch), and the completion (same file, `completeStructuralApply`,
  the `if context.resetSelection` block) either clears the model via
  `clearSelection(reason:)` or reconciles the model down to that empty snapshot via
  `restoreSelection(_:in:)` → `pruneSelection(preserved:to:)` →
  `reconcilingSelection(preserved)`. Either branch destroys the selection the
  ViewModel just set in `openLoupe`/`applyComparePair`. (The gate's
  `displayedDescriptor` starts at `.default` — [Otos/Views/MediaGridMutationGate.swift:93]
  — so a fresh controller's first apply is `descriptorChanged == true` whenever the
  live query isn't the default, hitting the clear branch; a default query hits the
  restore-∅ branch. Both wipe.)
- **F1b.** [Otos/Views/MediaGridSelectionController.swift:42-50]
  `didSelectItemsAt`/`didDeselectItemsAt` call
  `selectionHandlers.reconcileNative(selectedIdentities())` unconditionally. These
  delegates also fire for the controller's **own** two-phase programmatic writes
  (`applySelectionDelta`, same file), so the deselect-phase callback adopts a
  half-applied live set into the model; `reconcilingSelection` additionally sets
  `base = live`, silently breaking ⇧-chain contraction; and in compare mode
  `reconcileNativeSelection` rebuilds the pair with `older: capped.first`
  ([Otos/ViewModels/CatalogWindowViewModelSelection.swift:85-93]), stomping FIFO
  and re-issuing pane decodes up to three times per click.
- **F1c.** [Otos/Views/MediaGridBridge.swift:93-94] `receive(grid)` then
  `syncSelectionFromModel()`: on a fresh controller the sync runs before items
  exist (every `dataSource.indexPath(for:)` is nil → no-op), and the apply
  completion then wipes the model (F1a). There is no model→view seeding tied to
  apply completion.

### A1. ViewModel: state-driven prune/clear moves into `applyState`

File: `Otos/ViewModels/CatalogWindowViewModel.swift`, `applyState(_:)` (currently
~line 379). Immediately after `state = nextState` (the existing
`mediaIdentityChanged` computation just below it already derives the same facts —
reuse its inputs, don't recompute):

```swift
let descriptorChanged = previousState.mediaGrid.descriptor != nextState.mediaGrid.descriptor
let orderChanged = previousState.mediaGrid.orderedAssetIDs != nextState.mediaGrid.orderedAssetIDs
if descriptorChanged {
    clearGridSelection(reason: "descriptorChange")
} else if orderChanged {
    gridSelection = gridSelection.selection.isEmpty
        ? .empty
        : gridSelection.pruned(to: nextState.mediaGrid.orderedAssetIDs)
}
if descriptorChanged || orderChanged {
    reconcileFocusAfterGridChange(
        previousOrderedIDs: previousState.mediaGrid.orderedAssetIDs,
        descriptorChanged: descriptorChanged
    )
}
```

This is also the **F6 fix**: `reconcileFocusAfterGridChange`
([Otos/ViewModels/CatalogWindowViewModelViewMode.swift:107]) finally gets its call
site. Its internals keep working in Stage A (they call `requestPreview`); Stage B
rewrites those internals.

Ordering guarantee the implementer must not break: `applyState` runs on the
MainActor *before* SwiftUI re-renders and before the bridge's
`updateNSViewController` → `receive(grid)` → apply → completion. So by the time any
collection view processes the new order, the model is already pruned/cleared —
the view only ever *renders* the model.

### A2. Controller: renderers render; the wipe paths are deleted

File: `Otos/Views/MediaGridStructuralApply.swift`

- Delete `preservedSelection` from `StructuralApplyCompletionContext` and the
  snapshot at line 45. Delete the `resetSelection` field *only if* it is now unused
  after this change (it is also used to decide nothing else — verify; `resetScroll`
  stays).
- In `completeStructuralApply`, replace the whole
  `if context.resetSelection { clearSelection(...) } else { restoreSelection(...) }`
  block with:

```swift
renderSelectionFromModel(reason: "structuralApply")
```

File: `Otos/Views/MediaGridSelectionController.swift`

- Delete `restoreSelection(_:in:)` (lines ~153-157). Add:

```swift
/// Model → view, one direction. Idempotent; safe to call at any point where the
/// data source already contains the model's identities (apply completion, SwiftUI
/// update). Identities not yet in the data source are skipped and re-rendered by
/// the next apply completion.
func renderSelectionFromModel(reason: String) {
    applySelectionDelta(
        from: selectedIdentities(),
        to: selectionHandlers.currentSelection().selection
    )
    logSelection(reason: reason)
}
```

- Rewrite `clearSelection(reason:)` to stop writing the model
  (`selectionHandlers.clear` call deleted): it becomes AppKit-only
  (`deselectItems` of the current paths) and is called from nowhere except…
  nothing. Grep call sites: `perform(_:)`'s `.refreshVisible` branch
  ([Otos/Views/MediaGridBridge.swift], `case let .refreshVisible`) — replace
  `clearSelection(reason: "descriptorChange")` with
  `renderSelectionFromModel(reason: "descriptorRefresh")`. If no callers remain,
  delete `clearSelection` entirely.
- **Echo suppression (F1b):** add to `MediaGridViewController` (property block in
  `Otos/Views/MediaGridBridge.swift`):

```swift
/// True while applySelectionDelta is writing selectionIndexPaths. The
/// didSelect/didDeselect delegates fire synchronously for programmatic writes;
/// while this is set they must not reconcile the (by definition half-applied)
/// live set into the model.
private(set) var isApplyingModelSelection = false
```

  In `applySelectionDelta` wrap the two write calls:

```swift
isApplyingModelSelection = true
defer { isApplyingModelSelection = false }
```

  In both delegates:

```swift
guard !isApplyingModelSelection else {
    logSelection(reason: "select")   // or "deselect" — telemetry only
    return
}
_ = selectionHandlers.reconcileNative(selectedIdentities())
```

File: `Otos/Views/MediaGridBridge.swift`

- `updateNSViewController`: replace `controller.syncSelectionFromModel()` with
  `controller.renderSelectionFromModel(reason: "swiftuiUpdate")`; delete
  `syncSelectionFromModel` (lines ~456-460).

### A3. ViewModel selection intents: shrink the surface

File: `Otos/ViewModels/CatalogWindowViewModelSelection.swift`

- `applyGridClick`: **delete** the `liveSelection` parameter and the
  `gridSelection = gridSelection.reconcilingSelection(liveSelection)` line (line
  ~48). Native keyboard changes now reach the model eagerly through the gated
  delegate reconcile; the gesture no longer needs (and must not have) a
  view→model read. Add the loupe empty-space rule while here:

```swift
// Loupe/compare: empty-space clicks are no-ops — selection must keep
// mirroring focus (loupe) / the pair (compare).
if viewMode != .grid, hit == nil {
    return gridSelection
}
```

- Delete `pruneSelection(preserved:to:)` (the apply path no longer calls it;
  `applyState` prunes the model directly).
- `reconcileNativeSelection`: keep the grid/loupe branch
  (`reconcilingSelection(live)`). **Compare branch:** replace the pair rebuild with
  a no-op that re-renders from the model — native multi-selection is disabled in
  the strip in Stage C; until then, ignoring native writes in compare is the safe
  behavior:

```swift
if viewMode == .compare {
    return gridSelection
}
```

- `MediaGridSelectionHandlers`: remove `prune` and `clear` closures; `applyClick`
  loses the `liveSelection` argument. Update `from(_:)` and every construction
  site (ContentView passes `.from(viewModel)`; tests construct fakes).

File: `Otos/Views/MediaGridSelectionController.swift` — `applyMouseSelection`: drop
the `live` argument to `applyClick` (keep reading `live` only for the delta write's
`from:` set).

### A4. Stage A tests

Update in place: `OtosTests/MediaGridSelectionControllerTests.swift`,
`OtosTests/MediaGridBridgeTests.swift`,
`OtosTests/CatalogWindowViewModelSelectionTests.swift` (signatures shrank).
`OtosTests/GridSelectionTests.swift` must pass **unmodified**.

New tests (names are normative):

1. `CatalogWindowViewModelSelectionTests.testSelectionSurvivesFreshControllerFirstApply`
   — ViewModel with selection {X, Y}; build a `MediaGridViewController` wired via
   `MediaGridSelectionHandlers.from(viewModel)`; `receive` a grid containing X, Y;
   drive the apply to completion (existing test helpers drive the gate); assert
   `viewModel.gridSelection.selection == [X, Y]` **and**
   `controller.selectedIdentities() == [X, Y]`.
2. `…testSelectionSurvivesModeRoundTrip` — select {X} via `applyGridClick`;
   `openLoupe(id: X)`; simulate strip controller create/receive/complete; assert
   model selection == {X}; `exitToGrid()`; fresh grid controller
   create/receive/complete; assert model selection == {X} and AppKit selection
   rendered.
3. `MediaGridSelectionControllerTests.testProgrammaticDeltaDoesNotReconcile` — spy
   handlers counting `reconcileNative` calls; call `applySelectionDelta` moving
   {A}→{B}; assert zero reconcile calls (delegates fired, suppression held). Then
   simulate a native change (call the delegate directly with
   `isApplyingModelSelection == false`) and assert exactly one reconcile.
4. `…testShiftChainContractionAfterNativeEcho` — real mouseDown/mouseUp event
   pairs (existing pattern in this test file): click 1, ⇧-click 4, ⇧-click 3 →
   selection {1,2,3}. Guards the base-stomp regression.
5. `CatalogWindowViewModelSelectionTests.testApplyStatePrunesRemovedIdentities` —
   selection {X, Y}; deliver a same-descriptor state without Y through
   `applyState` (use the existing observation test support); assert selection {X},
   anchor rules per `GridSelection.pruned(to:)`.
6. `…testDescriptorChangeClearsAtApplyState` — selection {X}; deliver a state with
   a different descriptor; assert selection empty *before* any bridge exists.
7. `…testFocusReconcileRunsOnGridChange` (F6) — loupe focused on X; deliver a
   same-descriptor state without X; assert `focusedAssetID` moved per
   `BrowserModePolicy.pruneFocus`.

### A5. Stage A probe

- **A-P1**: the suppression design assumes NSCollectionView fires
  `didSelect/didDeselectItemsAt` synchronously for programmatic
  `selectItems/deselectItems` on the current macOS. Test 3 proves it either way:
  if delegates do *not* fire programmatically the flag is harmless dead weight and
  the test's second half still passes; if they fire asynchronously (they do not,
  but verify), the flag design must change to generation-stamped suppression —
  stop and flag for review rather than improvising.

---

## Stage B — Pane identity and the loupe click path (`fix/pane-identity`)

### B0. The violations being removed

- **F2.** [Otos/ViewModels/CatalogWindowViewModel.swift:75,81] bare
  `previewImage: CGImage?` (shared by loupe *and* compare-left) and
  `compareRightPreviewImage: CGImage?`; never cleared on focus/pair change
  ([CatalogWindowViewModelViewMode.swift:156-177]); views render any non-nil image
  regardless of asset ([Otos/Views/LoupeView.swift:35],
  [Otos/Views/CompareView.swift:51]); one shared `previewIsDownloading`; one shared
  `previewGeneration` whose `.downloading` retry bump
  ([CatalogWindowViewModelViewMode.swift:254]) invalidates the sibling pane's
  in-flight decode.
- **F3.** [Otos/ViewModels/CatalogWindowViewModelSelection.swift:50-55]
  `applyGridClick` has a compare branch but no loupe branch: strip clicks in loupe
  change selection but never `focusedAssetID` or the displayed image.

### B1. New pane model (ViewModel)

File: `Otos/ViewModels/CatalogWindowViewModel.swift` — delete `previewImage`,
`compareRightPreviewImage`, `previewIsDownloading`, `previewGeneration`. Add:

```swift
enum PaneSlot: CaseIterable, Hashable { case loupe, compareLeft, compareRight }

/// A full-size decode bound to the asset it belongs to. Views render `image` only
/// when `id` matches the pane's asset; otherwise they fall back to the id-keyed
/// enrichment thumbnail. That identity check is what makes stale decodes harmless.
struct PanePreview: Equatable {
    let id: MediaAssetID
    let image: CGImage
    static func == (l: Self, r: Self) -> Bool { l.id == r.id && l.image === r.image }
}

var panePreviews: [PaneSlot: PanePreview] = [:]
var downloadingSlots: Set<PaneSlot> = []
```

File: `Otos/ViewModels/CatalogWindowViewModelViewMode.swift` — replace the
`PreviewSlot` enum, `requestPreview(for:generation:slot:)`, and every
`previewGeneration &+= 1` call with:

```swift
/// Single source for "which asset should this pane show right now".
func expectedAsset(for slot: PaneSlot) -> MediaAssetID? {
    let ordered = state.mediaGrid.orderedAssetIDs
    switch slot {
    case .loupe:
        return viewMode == .loupe ? focusedAssetID : nil
    case .compareLeft:
        return viewMode == .compare ? comparePair.panes(in: ordered).left : nil
    case .compareRight:
        return viewMode == .compare ? comparePair.panes(in: ordered).right : nil
    }
}

/// Idempotent reconciliation of all three slots against expectation. Call after
/// EVERY focus/pair/mode mutation — this is the only pane-request entry point.
func refreshPanePreviews() {
    for slot in PaneSlot.allCases {
        let expected = expectedAsset(for: slot)
        if panePreviews[slot]?.id != expected {
            panePreviews[slot] = nil
            downloadingSlots.remove(slot)
        }
        if let expected, panePreviews[slot] == nil {
            requestPanePreview(expected, slot: slot)
        }
    }
}
```

`requestPanePreview(_ id: MediaAssetID, slot: PaneSlot)` (private): detail fetch →
`previewLoader.preview` → on MainActor: **the only staleness guard is asset
identity** — `guard expectedAsset(for: slot) == id else { return }` — then:
`.image` → `panePreviews[slot] = PanePreview(id: id, image: image)`,
`downloadingSlots.remove(slot)`; `.downloading` → `downloadingSlots.insert(slot)`
and schedule one 500 ms retry task that re-checks `expectedAsset(for: slot) == id`
before calling `requestPanePreview` again; `.unavailable` →
`downloadingSlots.remove(slot)` (thumbnail fallback stays). **No generations
anywhere** — delete the `generation` field from `PreviewImageLoader.Request` and
change `preview(for:)` to return `Outcome` (not a tuple).

Callers to rewrite onto `refreshPanePreviews()`: `openLoupe`, `focusNeighbor`,
`applyComparePair` (also **delete its `focusedAssetID = panes.left` line** —
compare must not retarget loupe), `reconcileFocusAfterGridChange`, `enterCompare`,
`setViewMode`. `exitToGrid`: `panePreviews = [:]`, `downloadingSlots = []`, keep
`focusedAssetID` (Stage C uses it to center the grid on return).

### B2. Loupe click path (F3)

File: `Otos/ViewModels/CatalogWindowViewModelSelection.swift`, in `applyGridClick`
after the compare branch:

```swift
if viewMode == .loupe, let hit, !shift, !command {
    focusedAssetID = hit
    gridSelection = gridSelection.plainClick(hit)
    refreshPanePreviews()
    return gridSelection
}
// loupe + modified click falls through: selection semantics apply, focus unchanged
```

### B3. Views render by identity

New file `Otos/Views/PanePresentation.swift`:

```swift
/// Pure pane-content decision so the identity rule is unit-testable without views.
nonisolated enum PanePresentation {
    enum Display: Equatable {
        case full(CGImage)
        case thumbnail(MediaAssetID)
        case empty
    }
    static func display(paneID: MediaAssetID?, preview: PanePreview?) -> Display {
        guard let paneID else { return .empty }
        if let preview, preview.id == paneID { return .full(preview.image) }
        return .thumbnail(paneID)
    }
}
```

`Otos/Views/LoupeView.swift` / `Otos/Views/CompareView.swift`: replace the
`if let preview … else if let id …` pane bodies with a switch over
`PanePresentation.display(paneID:preview:)`; `.thumbnail(id)` renders the existing
`ThumbnailPlaceholderView`/`CompareThumbnailPlaceholder` (dedupe the two into one
shared `PaneThumbnailView` in `PanePresentation.swift` — they are line-identical).
Spinner: each pane takes its own `isDownloading: Bool`
(`downloadingSlots.contains(.loupe)` etc. wired in `Otos/ContentView.swift`); the
shared `previewIsDownloading` parameter is deleted from both views.

### B4. Loader cleanup

File: `Otos/Services/PreviewImageLoader.swift`

- Delete `pin(ids:)` (lines ~82-89): it is never called and is a purge, not a pin.
- Move decode off the actor so two panes decode concurrently and the actor stays
  responsive: make `decodeImage`/`decodeVideoPoster` `nonisolated` (they touch no
  actor state) and run the per-request work in the existing spawned `Task` as a
  `Task.detached(priority: .userInitiated)`; only the `cache`/`inFlight`
  bookkeeping stays actor-isolated. The dataless/materialize gates keep their
  current order (status → materialize → re-check status → decode).
- `CacheEntry` gains `let longEdge: Int`; a cache hit requires
  `entry.longEdge >= request.targetLongEdge` (screen changes re-decode instead of
  upscaling). Same-session file-content staleness is an accepted limitation —
  record it in the PR notes, do not build stamp plumbing.

### B5. Stage B tests

Rewrite `OtosTests/PreviewImageLoaderTests.swift` for the new signature (no
generation tuple). New `OtosTests/PanePresentationTests.swift`: identity rule
(matching id → `.full`, mismatched → `.thumbnail(paneID)`, nil pane → `.empty`).
New `OtosTests/CatalogWindowViewModelViewModeTests.swift` (fake loader injected —
add a loader protocol seam or an injectable closure on the ViewModel if
constructor injection is simpler; choose constructor injection):

1. `testStaleDecodeDiscardedByIdentity` — focus X, let the fake loader complete
   *after* focus moved to Y; assert `panePreviews[.loupe]` is nil-or-Y, never X.
2. `testLoupeStripClickMovesFocusSelectionAndPreview` — `applyGridClick(hit: Y)`
   in loupe → `focusedAssetID == Y`, selection {Y}, loader saw a request for Y.
3. `testPairChangeClearsOnlyChangedSlots` — pair (A,B) → click C (pair (B,C)):
   `panePreviews[.compareLeft]` cleared iff its id ≠ B; no request re-issued for a
   slot whose id already matches (B's cache path may satisfy it, but
   `refreshPanePreviews` must not clear a matching pane).
4. `testDownloadingRetryDoesNotDisturbSiblingPane` — left slot `.downloading`
   retry loop while right slot's decode completes; assert right pane applies.
5. `testCompareDoesNotRetargetLoupeFocus` — focus X in loupe, enter compare on
   (A,B), exit, re-enter loupe → focus is still governed by
   `BrowserModePolicy.loupeEntryFocus` with anchor semantics, not silently A.
6. FIFO integration: with echo suppression from Stage A, drive strip clicks
   through `applyMouseSelection` on a real controller: (A,B)→click C→(B,C) with
   `older == B`; click D→(C,D). Put it in `MediaGridBridgeTests`.

### B6. Stage B probe

- **B-P1**: rapid-arrow storm — hold simulated → through 20 focus changes with a
  slow fake loader; assert the final pane matches the final focus and no
  intermediate image for a wrong asset was ever published (record `panePreviews`
  mutations in the test observer). This is the no-generation design's proof.

---

## Stage C — Strip input, centering, and layout (`fix/strip-input-and-layout`)

### C0. The violations being removed

- **F4.** No first-responder management: entering loupe destroys the grid
  collection view (the previous first responder); the SwiftUI
  `.focusable()/.onKeyPress` fallbacks ([LoupeView.swift:60-72],
  [CompareView.swift:33-45]) never receive focus → arrows reach the window →
  beep. No `scrollToItems` call exists anywhere in the strip path → nothing ever
  centers.
- **F5.** [Otos/Views/MediaGridPresentation.swift:76]
  `orthogonalScrollingBehavior = .continuous` scrolls inside an internal embedded
  scroll view, so the controller's observer on the outer clip view
  ([MediaGridBridge.swift, `installScrollObserver`]) never fires for strip
  scrolling: no detail queries, no preheat, no viewport reporting → distant strip
  tiles never load thumbnails.

### C1. Horizontal strip layout (F5)

File: `Otos/Views/MediaGridPresentation.swift`, `makeStripLayout(tileEdge:)`:
delete `section.orthogonalScrollingBehavior`; build the layout with a horizontal
configuration so the *collection view itself* scrolls horizontally:

```swift
let configuration = NSCollectionViewCompositionalLayoutConfiguration()
configuration.scrollDirection = .horizontal
return MediaGridAnimatedLayout(section: section, configuration: configuration)
```

File: `Otos/Views/MediaGridAnimatedLayout.swift`: add
`init(section: NSCollectionLayoutSection, configuration: NSCollectionViewCompositionalLayoutConfiguration)`
delegating to `super.init(section:configuration:)`; the existing `init(section:)`
keeps grid behavior identical.

With the outer scroll view now the horizontal scroller, the existing
`scrollBoundsChanged` → detail-query/preheat pipeline works in strip mode with no
further changes. Verify with the runtime probe below.

- **C-P1 (run this spike FIRST, before building on it):** horizontal
  `scrollDirection` + `MediaGridAnimatedLayout` subclass + diffable applies +
  `scrollToItems(at:scrollPosition: .centeredHorizontally)` on the current macOS,
  in the running app with the smoke library. Evidence: strip scrolls, tiles load
  while scrolling (`script/logs.sh` shows `ui.mediaGrid.scrollBounds` windows with
  `detailQueryStarted > 0` while in loupe), centering lands. **Fallback** if the
  animated-layout subclass misbehaves horizontally: give the strip a plain
  `NSCollectionViewCompositionalLayout` (no animated subclass — the strip needs no
  move animations); keep the grid on `MediaGridAnimatedLayout`.

### C2. First responder (F4)

File: `Otos/Views/MediaGridBridge.swift`, `MediaGridViewController`:

```swift
override func viewDidAppear() {
    super.viewDidAppear()
    // The collection view owns keyboard input in every presentation: arrows
    // (grid: native selection; strip: forwarded focus/pair intents), Return, Esc.
    // Mode switches recreate the controller, so claim first responder on appear.
    view.window?.makeFirstResponder(collectionView)
}
```

- **C-P2**: verify `view.window` is non-nil at `viewDidAppear` under
  `NSViewControllerRepresentable` hosting (it should be). Fallback: retry once via
  `DispatchQueue.main.async`.

Delete the now-dead SwiftUI key handling: `.focusable()` and all three
`.onKeyPress` modifiers in both `LoupeView.swift` and `CompareView.swift` (keep
`onTapGesture(count: 2)` for loupe exit). One keyboard path: AppKit `keyDown`.

### C3. Strip keyboard completeness

File: `Otos/Views/MediaGridCollectionView.swift` `keyDown` — in strip mode
(`forwardsArrowKeys == true`) additionally **consume** (return without calling
`super`): ↑ (126), ↓ (125), ⇧+←/→, Home/End (115/119), PageUp/PageDown (116/121).
Native vertical/extension navigation is meaningless in a single row and would
corrupt the focus/pair invariants through the native path. Also override
`selectAll(_:)`: no-op in strip mode, `super` in grid.

### C4. Centering (the rest of symptoms 1 and 4)

File: `Otos/Views/MediaGridBridge.swift`

- `MediaGridBridgeView` gains `var focusTargetID: MediaAssetID?` (default nil).
  `updateNSViewController` calls `controller.receiveFocusTarget(focusTargetID)`.
- Controller:

```swift
private var lastFocusTargetID: MediaAssetID?
private var pendingFocusTargetID: MediaAssetID?

/// Scrolls the target to center when it changes. If the item is not in the data
/// source yet (fresh controller before its first apply), parks it; the apply
/// completion retries. Never scrolls when the target is unchanged, so user
/// scrolling is not fought.
func receiveFocusTarget(_ id: MediaAssetID?) {
    guard id != lastFocusTargetID else { return }
    lastFocusTargetID = id
    scrollToFocusTarget(id)
}

private func scrollToFocusTarget(_ id: MediaAssetID?) {
    guard let id else { pendingFocusTargetID = nil; return }
    guard let path = dataSource.indexPath(for: id) else {
        pendingFocusTargetID = id
        return
    }
    pendingFocusTargetID = nil
    collectionView.scrollToItems(
        at: [path],
        scrollPosition: presentation.isStrip ? .centeredHorizontally : .centeredVertically
    )
}
```

- `completeStructuralApply`: after `renderSelectionFromModel`, add
  `if let pending = pendingFocusTargetID { scrollToFocusTarget(pending) }`.

Wiring in `Otos/ContentView.swift` (and through `LoupeView`/`CompareView`/
`MediaGridView`, each of which passes it into their `MediaGridBridgeView`):

- Loupe strip: `focusTargetID = viewModel.focusedAssetID`.
- Compare strip: the newest pair member —
  `viewModel.comparePair.members.first { $0 != viewModel.comparePair.older } ?? leftID`.
- Grid: `focusTargetID = viewModel.focusedAssetID` — so exiting loupe centers the
  grid on the last-viewed asset (fresh grid controller, parked target, centered at
  first apply completion).

### C5. Stage C tests

1. `MediaGridBridgeTests.testStripScrollTriggersDetailQueries` — strip
   presentation, apply a grid, mutate the clip view's bounds origin horizontally,
   run the coalescing task; assert `lastDetailQueryIDs` changed.
2. `…testFocusTargetCentersAfterFirstApply` — fresh strip controller;
   `receiveFocusTarget(X)` *before* any apply (parks); receive + complete apply;
   assert the clip view's visible rect midpoint ≈ X's item frame midX (±1 tile).
3. `…testFocusTargetUnchangedDoesNotScroll` — scroll manually, call
   `receiveFocusTarget` with the same id, assert bounds unchanged.
4. `…testStripConsumesVerticalAndExtensionKeys` — send ↑/⇧→/⌘A key events to the
   strip collection view in a window; assert selection and model unchanged.
5. First-responder: host the controller in an `NSWindow`, trigger `viewDidAppear`,
   assert `window.firstResponder === collectionView` (covers C-P2).

---

## Deletions master list (grep-verify all gone at the end)

| Symbol | File |
| --- | --- |
| `previewImage`, `compareRightPreviewImage`, `previewIsDownloading`, `previewGeneration` | CatalogWindowViewModel.swift |
| `PreviewSlot`, `requestPreview(for:generation:slot:)` | CatalogWindowViewModelViewMode.swift |
| `pruneSelection(preserved:to:)`, handlers `prune`/`clear`, `applyClick` live-selection param | CatalogWindowViewModelSelection.swift |
| `restoreSelection(_:in:)`, model-writing `clearSelection` | MediaGridSelectionController.swift |
| `syncSelectionFromModel()`, `preservedSelection` context field | MediaGridBridge.swift / MediaGridStructuralApply.swift |
| `Request.generation`, tuple return, `pin(ids:)` | PreviewImageLoader.swift |
| `.focusable()` + `.onKeyPress` blocks, shared `previewIsDownloading` param | LoupeView.swift, CompareView.swift |
| `orthogonalScrollingBehavior` line | MediaGridPresentation.swift |

## Requirements / docs (same PR as the stage that lands them)

- `docs/requirements.md`: APP-019 gains "selection persists across view-mode
  switches (grid ↔ loupe ↔ compare round trip preserves the model selection)";
  APP-020 gains "strip click changes the loupe image; focused asset is selected
  and centered in the strip; arrows work immediately without a priming click; the
  pane shows the enrichment thumbnail immediately and never an image belonging to
  a different asset"; APP-021 gains the same pane-identity clause plus "FIFO
  replacement is preserved across programmatic selection echoes"; APP-022 gains
  "strip scrolling loads thumbnails (scroll-driven detail queries fire)".
  APP-010's acceptance keeps ⇧-chain contraction — now also guarded by test A4.4.
- `docs/architecture.md`: in the grid boundary paragraph, add one sentence:
  "AppKit surfaces never write selection truth; the model flows one way,
  ViewModel → renderer, and `selectionIndexPaths` is render output."
- `docs/adr/0016-view-modes-and-preview-decode.md`: amend Consequences with the
  pane-identity model (PanePreview + expected-asset guard replacing generation
  counters) and the horizontal-configuration strip layout decision (orthogonal
  sections rejected: internal scroller starves scroll-driven loading).

## Verification (per stage, agent-owned)

- `script/verify.sh` green (requirements-authority + lint + build + test).
- Runtime evidence with the smoke library, attached to each PR:
  - Stage A: log trace of grid→loupe→compare→grid with `op=viewMode.set` entries
    and a selection-count log line proving the same identities survive.
  - Stage B: `op=preview.decode` traces showing per-slot requests keyed to the
    expected asset; a rapid-arrow session with no wrong-asset publishes.
  - Stage C: `ui.mediaGrid.scrollBounds` windows with `detailQueryStarted > 0`
    while strip-scrolling; centering visible in a screenshot or measured in test.
- Each PR: full DoD report per CLAUDE.md (post on PR and send to user in full).

## Non-goals

Pick/drop flags, loupe 1:1 zoom/pan, video playback, neighbor prefetch, loader
same-session file-staleness stamps (roadmap/accepted-limitation notes only).
