# Plan 0054 — Focus centering, pane-task ownership, QoS, and strip/toolbar UX

Follow-up to plan 0053 (PRs #92/#94/#95). Fixes the three residual centering bugs,
the flaky pane tests, and the QoS inversions; adds the four UX changes Taylor asked
for on 2026-07-10. Written to be implementable without the review conversation.
Delete this file when the work is fully done.

Four increments, each its own worktree + PR + DoD:

- **Stage A** (`fix/focus-centering-and-pane-tasks`) — centering retry on window
  attach (bugs: loupe-entry strip centers only when the image loads; loupe→grid
  starts at top for seconds; grid→compare centers late or never), pane-request
  task ownership (fixes the flaky `waitForPane` tests deterministically), explicit
  task priorities (QoS warning #2 class).
- **Stage B** (`feat/compare-positional-pair`) — compare clicks become positional:
  plain click replaces the **right** pane, ⌘-click replaces the **left** pane.
- **Stage C** (`feat/strip-resize-and-zoom-segment`) — resizable filmstrip
  (48–192 pt, persisted) and a fused −/+ zoom segment control.
- **Stage D** (measurement, likely no product code) — GRDB reader-pool QoS
  inversion (warning #1): quantify, then decide.

---

## Stage A — Centering retry + pane-task ownership (`fix/focus-centering-and-pane-tasks`)

### A0. Root cause of the three centering bugs (all one defect)

`scrollToFocusTarget` ([Otos/Views/MediaGridBridge.swift], added in PR #95) parks
the target into `pendingFocusTargetID` when `view.window == nil` — which is always
true during a fresh controller's first `updateNSViewController` pass (every mode
switch creates a fresh controller; SwiftUI attaches the view to the window only
later in the commit). The **only** retry site is `completeStructuralApply`. So the
parked target is honored only when the *next* gate activity produces an apply
completion after window attach:

- **Loupe entry:** the next SwiftUI update after window attach is typically the
  full-size decode landing (`panePreviews` mutation → body → `receive(grid)` →
  gate drain → completion → retry). Hence "the strip doesn't scroll until the
  image has loaded" — the image arrival is what pokes the retry.
- **Loupe → grid:** the fresh grid controller parks; the retry lands on the next
  *background enrichment apply*, seconds later. Until then the grid sits at the
  top (descriptor-changed first apply also `scrollToTop()`s). Hence "several
  seconds at the beginning, then jumps".
- **Grid → compare:** same parking; in a quiet scope there may be *no* later
  apply — "sometimes never". Arrow keys work instantly because `slideCompare`
  *changes* `focusTargetID`, and `receiveFocusTarget` scrolls immediately now
  that the window exists.

### A1. Fix: retry parked targets at window attach (and on re-delivery)

File: `Otos/Views/MediaGridBridge.swift`

1. `viewDidAppear()` — after the `makeFirstResponder` logic, add:

```swift
if let pending = pendingFocusTargetID {
    scrollToFocusTarget(pending)
}
```

2. `receiveFocusTarget(_:)` — the unchanged-id early return must still retry a
   parked target (belt and braces for any order of update passes):

```swift
guard id != lastFocusTargetID else {
    if let pending = pendingFocusTargetID {
        scrollToFocusTarget(pending)
    }
    return
}
```

3. `scrollToFocusTarget(_:)` — add one more park condition and instrumentation.
   A fresh collection view can be window-hosted but not yet laid out; scrolling a
   zero-sized clip is a silent no-op. Park when layout hasn't sized yet, and log
   every decision so the agent can verify from `script/logs.sh` which path fired:

```swift
guard view.window != nil, collectionView.frame.width > 0 else {
    pendingFocusTargetID = id
    OtosLog.ui.debug("op=ui.mediaGrid.focusTarget phase=park … reason=window/layout")
    return
}
…
OtosLog.ui.debug("op=ui.mediaGrid.focusTarget phase=scroll …")
```

   (Full log fields: `id`, `presentation`, `reason`. Keep `phase=park|scroll`.)

4. `viewDidLayout()` — override; if `pendingFocusTargetID != nil` and the frame is
   now non-zero, retry once. This closes the "window attached before first layout"
   ordering without polling.

**Acceptance (drive in the running app, verify via logs):** double-click into
loupe → one `phase=scroll` within the same interaction (no decode dependency);
Esc back to grid → grid centered on the focused asset immediately; ⌘3 from grid →
strip centered immediately, quiet scope or not.

Tests (`OtosTests/MediaGridStripInputTests.swift`):
- `focusTargetParkedBeforeWindowScrollsOnViewDidAppear` — receive grid + focus
  target with no window; then host in a window and fire `viewDidAppear`; assert
  the clip bounds centered on the target (existing centering assertion helpers).
- `focusTargetRetryOnRedeliveredSameID` — park, then call `receiveFocusTarget`
  again with the same id after hosting; assert scrolled.

### A2. Pane-request task ownership (fixes `waitForPane` flakiness at the root)

**Why the tests flake:** `requestPanePreview`
([Otos/ViewModels/CatalogWindowViewModelViewMode.swift:216]) spawns a
fire-and-forget `Task` with no owner, so tests can only poll
(`waitForPane` — 2 s wall-clock deadline, 10 ms sleeps; `staleDecodeDiscardedByIdentity`
even uses bare double `Task.yield()`). Under parallel Swift Testing execution on a
loaded machine, the multi-hop chain (detail read → loader actor → MainActor) can
exceed the poll budget: wall-clock polling over unowned asynchrony *is* the flake.
It is also a CLAUDE.md smell on its own — long-running work with no owner, no
cancellation: an arrow storm leaves orphan tasks fetching details and queuing
decodes for focuses the user already left.

Design (file: `CatalogWindowViewModelViewMode.swift` + state in
`CatalogWindowViewModel.swift`):

```swift
@ObservationIgnored var paneRequestTasks: [PaneSlot: Task<Void, Never>] = [:]
```

- `requestPanePreview(_ id:, slot:)`: first `paneRequestTasks[slot]?.cancel()`,
  then store `paneRequestTasks[slot] = Task(priority: .userInitiated) { … }`.
  Inside the task: after the detail fetch `await`, `guard !Task.isCancelled` —
  this stops superseded requests *before* they enqueue a full-size decode in the
  loader, bounding an arrow storm's decode pileup by construction (≤ 1 in-flight
  request per slot; the loader's per-id dedup covers the rest).
- The 500 ms `.downloading` retry task is stored in the same slot map (it
  *replaces* the completed request task), so it is owned and cancellable too.
- `exitToGrid()` and `isolated deinit` cancel all three slots.

Test changes (`OtosTests/CatalogWindowViewModelViewModeTests.swift`):
- Delete `waitForPane` and the yield/sleep loops. Await determinism instead:
  `await model.paneRequestTasks[.loupe]?.value` after releasing the fake, then
  assert synchronously. `FakePreviewLoader` keeps its continuation design.
- `downloadingRetryDoesNotDisturbSiblingPane` awaits the two slot tasks instead
  of the 20-iteration yield loop.
- Keep one polling-free storm test (`rapidArrowStormKeepsFinalFocusIdentity`)
  driving 20 `focusNext()` calls, then awaiting the final slot task.

### A3. Explicit priorities on the UI-serving spawn points (QoS warning #2 class)

The Xcode runtime warning showing `PreviewImageLoader.decodeImage` on a
Default-QoS thread matches the **pre-#94** call path (decode ran inside the actor
at inherited priority). Stage B of plan 0053 already moved the decode to
`Task.detached(priority: .userInitiated)`. Remaining hardening so no future path
regresses to ambient/default priority:

- `PreviewImageLoader.preview(for:)` line ~79: `Task { await self.decode(request) }`
  → `Task(priority: .userInitiated) { … }` (the dedup task inherits ambient
  priority today; make it explicit).
- `requestPanePreview` / retry tasks: explicit `.userInitiated` (done in A2).
- `CatalogWindowViewModel.start()` consumers: give `stateConsumptionTask` an
  explicit `.userInitiated` (it feeds the UI truth) and leave the
  forwarding/startup tasks at their current priorities — do not blanket-elevate
  background lanes (enrichment stays deliberately below UI).

**Verification:** re-run the app under Xcode's runtime-issues QoS checker and the
Time Profiler; assert no `decodeImage`-on-Default warning recurs; attach the
trace/log evidence to the PR.

---

## Stage B — Positional compare clicks (`feat/compare-positional-pair`)

Owner decision (2026-07-10): the FIFO "replaces whichever has been on screen
longer" rule is replaced by **positional replacement** — a plain click in the
strip replaces the **right** pane; a ⌘-click replaces the **left** pane. The left
pane naturally becomes the stable reference without any role chrome.

File: `Otos/Models/ComparePairPolicy.swift` — `ComparePair` becomes positional:

```swift
nonisolated struct ComparePair: Equatable {
    var left: MediaAssetID?
    var right: MediaAssetID?
    static let empty = ComparePair(left: nil, right: nil)
    var members: [MediaAssetID] { [left, right].compactMap(\.self) }
}
```

Delete `older` and the display-order pane sorting (`panes(in:)` callers read
`left`/`right` directly). Policy functions:

- `entry(selection:orderedIDs:)` — unchanged inputs; first two selected in
  display order become `(left, right)`; one selected → it + next display-order
  neighbor as right; none → first two in scope.
- `click(_ id:, replacing: PanePosition, pair:)` with
  `enum PanePosition { case left, right }` — sets the named slot to `id`; if `id`
  already occupies the *other* slot, swap instead of duplicating (clicking the
  current left with no modifier must not show the same asset twice).
- `slide(_ delta:, pair:, orderedIDs:)` — same window semantics, now positional:
  `delta > 0 → (old right, next(right))`; `delta < 0 → (prev(left), old left)`.
- `prune(pair:survivingOrderedIDs:)` — a removed member's *own slot* is refilled
  with its nearest display-order survivor; the other slot is untouched.

Wiring:

- `applyGridClick` compare branch ([CatalogWindowViewModelSelection.swift])
  passes the modifier: plain/⇧ → `.right`, ⌘ (and ⌘⇧) → `.left`.
- `applyComparePair` — unchanged responsibilities (selection = members, anchor =
  left, `refreshPanePreviews()`); `expectedAsset(for:)` reads `pair.left`/`.right`
  directly (display-order sorting of panes is gone — panes are stable slots).
- Strip focus target in compare ([Otos/ContentView.swift:131]) becomes "the
  most recently replaced slot's asset": track
  `var lastReplacedComparePane: PanePosition?` next to `comparePair`, set by the
  click/slide intents, and target that slot's asset (entry: `right`).
- `reconcileNativeSelection`'s compare no-op stays.

Requirements: APP-021 acceptance rewritten (positional replacement; explicit
"plain replaces right, ⌘ replaces left, same-asset click swaps instead of
duplicating"; arrows keep the sliding window). Tests: rewrite
`ComparePairPolicyTests` for the positional rules (entry cardinalities, both
replacement positions, swap-not-duplicate, slide both directions at both ends,
prune per slot); update the ViewModel FIFO test to positional
(`fifoStripClickReplacesOlderMember` → `positionalClickReplacesNamedPane`).

---

## Stage C — Strip resize + fused zoom segment (`feat/strip-resize-and-zoom-segment`)

### C1. Resizable filmstrip

Lightroom Classic reference (researched 2026-07-10): the filmstrip is resized by
dragging its top edge; Adobe documents no exact pixel limits publicly — the
practical LrC range is roughly a 40 px minimum to ~190 px maximum thumbnail.
Otos values: **48 pt minimum, 192 pt maximum, default 72 pt**, persisted.

- `CatalogWindowViewModel`: `private(set) var stripTileEdge: CGFloat`, loaded in
  `init` from UserDefaults key `"mediaStripTileEdge"` (clamp on load), plus one
  intent `setStripTileEdge(_:)` that clamps to `48...192`, persists, publishes —
  exactly the `gridColumnCount` pattern ([CatalogWindowViewModel.swift:570-589]).
  Constants live in `MediaGridPresentation` (`minStripTileEdge`,
  `maxStripTileEdge`, existing `defaultStripTileEdge`).
- `LoupeView`/`CompareView`: take `stripTileEdge: CGFloat`; replace both
  hard-coded `MediaGridPresentation.defaultStripTileEdge` uses (frame height and
  `.strip(tileEdge:)`). Above the strip add an 8 pt drag divider:
  `Rectangle().fill(.clear).frame(height: 8).contentShape(Rectangle())` with
  `.onHover` push of `NSCursor.resizeUpDown` and a `DragGesture` that calls
  `setStripTileEdge(startEdge - translation.height)` continuously (drag up =
  bigger, matching LrC).
- Live relayout: `applyPresentation(_:)` already replaces the layout when the
  presentation value changes ([MediaGridBridge.swift:applyPresentation]), so the
  drag flows `intent → stripTileEdge → presentation .strip(tileEdge:) → layout
  replace`. **Probe C1-P1:** continuous drag at 23k items — watch
  `MediaGridLayoutReplace` signposts and the stall monitor; if per-tick layout
  replacement hitches, coalesce to `onEnded` commit with a lightweight live
  preview (frame-height change only during drag, layout replace on end). Record
  evidence either way.
- Requirements: APP-022 gains the resize row (range, persistence, drag surface).

### C2. Fused −/+ zoom control

Finding (researched 2026-07-10): on modern macOS, SwiftUI `ControlGroup` no
longer renders attached segments in toolbars — it only groups with "logical
spacing" (Sonoma+), which is exactly the separated look Taylor flagged. The native
fused momentary segment (Xcode/Finder style) is AppKit's `NSSegmentedControl`
with `trackingMode = .momentary`.

- **Probe C2-P1 (5 minutes, first):** wrap the existing `ControlGroup` in a
  single `ToolbarItem` instead of living inside `ToolbarItemGroup` and check the
  rendering on this macOS. If it fuses — done, zero new code.
- Otherwise: `ZoomSegmentedControl: NSViewRepresentable` in
  `CatalogToolbarControls.swift` — `NSSegmentedControl` with two SF Symbol
  segments (`minus`, `plus`), `trackingMode = .momentary`,
  `segmentStyle = .automatic`, per-segment enablement from `columnCount`
  (`setEnabled(_:forSegment:)` mirroring the current `.disabled` conditions),
  action maps `selectedSegment` 0/1 → the same two intents. The View menu items
  are untouched (same intents — one implementation path). Keep `.help` tooltips
  via `setToolTip(_:forSegment:)`.

---

## Stage D — GRDB reader-pool QoS inversion (measure, then decide)

**What the warning is** (screenshot, stack 1): a User-initiated thread blocks in
GRDB's `Pool.get()` — `barrierQueue.sync { itemsSemaphore.wait() … }`
(GRDB 7.11, `GRDB/Utils/Pool.swift:95`) — while some current reader-connection
holder runs at Utility/Default. `DispatchSemaphore` carries no ownership, so the
OS cannot donate priority: this is a real, structural inversion inside GRDB's
reader pool, hit whenever UI-facing reads (visible tile details, pane detail
fetch — `readQoS` defaults to `.userInitiated`) contend with lower-QoS holders
(enrichment claim/read traffic) for the `maximumReaderCount = 4` connections
([Otos/Stores/CatalogStorePersistence.swift:54]).

Per CLAUDE.md, no machinery before measurement — the inversion's *cost* is
bounded by the longest concurrent read. Stage D is a measurement increment:

1. Instrument: the visible-detail query path already logs `queryMs`; add the same
   to `MediaTileDetailReader.details(for:)` callers if missing, and capture a
   10-minute `script/profile.sh` session (enrichment storm + loupe arrowing) —
   record p50/p95 `queryMs` and the QoS-inversion instrument's wait durations.
2. Decision gate: if p95 UI-read wait is under ~10 ms, accept and document the
   warning as benign (requirements/ADR note; done). If UI reads measurably queue
   behind enrichment readers, the remedies in preference order are:
   (a) raise `maximumReaderCount` (cheap, one line — more WAL readers);
   (b) a dedicated read-only `DatabasePool` for UI-facing reads on the same WAL
   file so enrichment can never exhaust the UI's connections (needs an ADR — it
   is a second connection pool, real machinery).
3. Either outcome updates `docs/adr/0002`/`0015` (whichever owns persistence
   observability) with the evidence.

Also note for the record: QoS warning #2 (`decodeImage` on a Default thread with
a User-initiated waiter) matches the pre-#94 decode-on-actor call path; Stage A3
re-profiles to confirm it no longer reproduces on current main.

---

## Deletions / regression guards

- `waitForPane`, `waitUntilPending` polling in `CatalogWindowViewModelViewModeTests`
  replaced by awaits on owned slot tasks (A2).
- `ComparePair.older`, `panes(in:)` display-order sorting (B).
- Hard-coded `defaultStripTileEdge` uses in `LoupeView`/`CompareView` (C1).
- `GridSelectionTests` and `PanePresentationTests` pass unmodified in every stage.

## Verification (per stage, agent-owned)

`script/verify.sh` green; runtime log evidence attached per PR: Stage A —
`op=ui.mediaGrid.focusTarget` phase traces proving immediate centering on all
three transitions plus deterministic test suite (no polling helpers left);
Stage B — policy tests + a strip-click session trace; Stage C — drag-resize
stall-monitor evidence + toolbar screenshot; Stage D — profile artifacts and the
decision record. Full DoD report on each PR.

## Non-goals

Pick/drop flags, loupe 1:1 zoom, video playback, neighbor prefetch, strip zoom
gestures (pinch on strip), GRDB replacement.
