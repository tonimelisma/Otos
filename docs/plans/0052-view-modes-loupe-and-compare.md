# Plan 0052 — View modes: Loupe and Compare with filmstrip

Approved 2026-07-09. Execution is three separate increments (worktree + PR each);
this file is deleted when the work is fully done.

---

## 0. Research findings

### 0.1 Lightroom semantics (the model to copy)

Cloud Lightroom **has no compare view at all** (before/after toggle only; side-by-side
is a years-old unfulfilled feature request). Lightroom **Classic** is the model.
Sources: Adobe helpx "browse and compare photos", jkost.com (Adobe evangelist),
mastering-lightroom.com, lightroomqueen.com.

**View switching in LrC:** `G` grid, `E` loupe, `C` compare, `N` survey; toolbar
icons for each. **Double-click a grid thumbnail → loupe; double-click the loupe
image → back to grid.** Return/Space also enter loupe from grid.

**Compare view pair semantics** (research reference only — Otos deliberately
rejects the Select/Candidate role model; the owner-decided symmetric design is
§1.3):

- The two panes are **Select** (left) and **Candidate** (right).
- **Select = the *active* photo** of the selection (LrC "most selected" — the one
  with the brightest cell, i.e. the one you plain-clicked before extending). It is
  **not** "the two last images clicked" and needs no special ⌘-click ritual.
- **Candidate = the next photo of the selection in display order** after the Select.
- **Long shift-selection of N images: you see the anchor photo + the photo right
  after it; ← / → cycle the Candidate through the remaining N−2** while the Select
  stays fixed. That's the whole trick: compare is "one fixed reference vs a rotating
  challenger", not "the two ends of the range".
- **Exactly 2 selected:** active = Select, other = Candidate.
- **1 selected:** Select = it; Candidate = the adjacent photo in the filmstrip
  (LrC: "the last previously selected photo or an adjacent photo").
- Controls: **Swap** (exchange the two), **Make Select** (promote Candidate to
  Select, advance to next Candidate — LrC ↑), zoom-link padlock (out of scope v1).
  Filmstrip marks Select with a white diamond, Candidate with a black diamond.
- Clicking a filmstrip photo while in compare replaces the **Candidate**.

### 0.2 SF Symbols (verified on this machine)

Availability confirmed at runtime on this macOS 27 beta via
`NSImage(systemSymbolName:)` (43 candidates checked, rendered to a contact sheet;
script in session scratchpad). Recommended trio — same stroke weight, consistent
wide-rectangle family, each a literal picture of its mode:

| Mode | Symbol | Reads as |
| --- | --- | --- |
| Grid | `square.grid.2x2` | classic thumbnail grid (Apple's canonical grid glyph) |
| Loupe + strip | `squares.below.rectangle` | one large rectangle with a row of small squares below — *exactly* "big image + filmstrip" |
| Compare + strip | `rectangle.split.2x1` | one frame split into two side-by-side panes |

Runner-ups if you want a different flavor: `rectangle.grid.2x2` (wide-cell grid,
matches the other two's aspect), `photo` (loupe), `square.split.2x1` (compare).
All verified available. `squares.below.rectangle.fill` does **not** exist (only
outline) — a `.fill`-variant trio is not achievable, so the outline trio is the set.

### 0.3 Codebase facts that shape the design

- **No double-click path exists.** `MediaGridCollectionView.mouseDown` swallows the
  gesture (no `super`), forwards `(hit, modifiers)`; `event.clickCount` is unread.
  APP-010 explicitly records "double-click activation, previews … remain absent".
- **Selection** is a pure `GridSelection` value (selection/anchor/base) owned by the
  AppKit `MediaGridViewController` (spec 0046), ephemeral, *not surfaced to SwiftUI*
  (APP-011). The anchor is precisely LrC's "active photo" analog.
- **Thumbnails are 256 px long edge** (`ThumbnailStore.maxPixelSize`); no
  original-size decode path exists anywhere. A loupe needs a new byte-reading owner.
- **Byte reads must gate on `FileMaterialization.status` (SF_DATALESS)**; deliberate
  non-blocking materialization exists (`FileMaterialization.materialize`, injectable
  `FileMaterializationProviders` — already unit-testable).
- **The ViewModel already holds the full ordered ID list** (`state.mediaGrid.orderedAssetIDs`)
  and mode-independent query state; `gridColumnCount` shows the established pattern
  for ViewModel-owned UI state with a single intent path.
- The grid bridge machinery (mutation gate, `TileContentStore`, decode dedup,
  prefetch, no-blank invariant APP-015) is exactly what a 23k-item filmstrip needs;
  building a second thumbnail engine would violate one-owner-per-question.

---

## 1. Product behavior (proposed)

### 1.1 Mode switcher

- One segmented control (grouped 3-part button) in the toolbar, leftmost of the
  primary group: Grid / Loupe / Compare with the symbols above; `.help` tooltips.
- View menu items with **⌘1 / ⌘2 / ⌘3** (Finder/Photos convention; LrC's bare
  G/E/C can be layered on later at the responder level, out of v1).
- Both surfaces call the same ViewModel intent (`setViewMode`). Session-only state,
  not persisted (same policy as sort/filter, APP-014). Default `.grid`.

**Keyboard, all modes (owner decision):** arrows always change the selection.

| Mode | ← / → / ↑ / ↓ | Return | Esc |
| --- | --- | --- | --- |
| Grid | Move selection through the grid (native NSCollectionView navigation, ⇧ extends — kept native, but now *specified in APP-010 and tested*, with prompt reconcile into the ViewModel model so the switcher/loupe/compare always see current selection) | **Open loupe on the active item** (anchor, else first selected; no-op on empty selection) — same `openLoupe` intent as double-click | — |
| Loupe | ← / → move focus; selection follows as a plain click | — | Back to grid |
| Compare | ← / → slide the comparison window (= selection, §1.3) | — | Back to grid |

First-responder management is part of the increment: on every mode switch the
active surface (grid / loupe container / strip) becomes first responder, so keys
work immediately without a priming click.

### 1.2 Loupe (large image + filmstrip)

- **Enter:** double-click a grid tile (opens that asset), **Return in the grid**
  (opens the active item), or ⌘2/segment (opens the selection's anchor, else first
  selected in display order, else first item). All three call the one `openLoupe`
  intent.
- **Content:** the image aspect-fit in the full detail area; filmstrip at the bottom.
  The 256 px thumbnail (upscaled, already in memory or instantly loadable) paints
  immediately; the full-size decode replaces it when ready — never the reverse, and
  never a blank (loupe adopts the APP-015 monotonic rule).
- **Dataless originals:** show the upscaled thumbnail plus a small progress badge,
  kick deliberate non-blocking materialization, decode on arrival. Viewing is an
  explicit user action; its download cost is accepted (consistent with ADR 0008's
  policy, which already permits eager whole-library materialization).
- **Video:** large poster frame + existing duration badge; no playback in v1
  (roadmap note).
- **← / →:** move focus through display order; selection follows as a plain click
  (LrC behavior). Filmstrip auto-scrolls to keep focus visible.
- **Exit:** double-click the image, Esc, ⌘1, or the segment — back to grid,
  scrolled to the focused asset, selection intact.
- **Churn rules:** focused asset pruned by a structural apply → focus moves to the
  nearest survivor by prior index. Descriptor change → stay in mode, focus first
  item (selection already clears today).

### 1.3 Compare (two images + filmstrip) — symmetric, zero chrome

Owner decision: LrC's Select/Candidate asymmetry (labels, Swap, Make Select, ↑
promotion, diamond markers) is **rejected**. Compare is a pure *viewer* of two
peer images; curation arrives later as pick/drop flags on tiles/panes, not as
pane roles. One rule drives everything:

> **The two panes show the two compared images; a click (or arrow) brings one
> image in and drops the one that has been on screen longer.**

- **Pair = selection, capped at two.** In compare mode the compared pair *is* the
  selection, so the strip needs no second highlight vocabulary — the standard
  accent ring marks the two compared items and nothing else.
- **Enter:** ⌘3/segment. Pair = first two selected in display order; 1 selected →
  it + its next display-order neighbor; 0 selected → the first two in scope.
  Selection becomes the pair.
- **Panes:** left/right by display order (no roles, so no swap is ever needed),
  aspect-fit, no labels, no buttons.
- **Filmstrip click:** the clicked image replaces the *older* pane ("the two last
  images touched"). Modified clicks (⌘/⇧) behave the same — the 2-cap makes
  range/toggle gestures meaningless here, so compare drops gestures rather than
  adding new ones. Native ⌘A/⇧-arrows are clamped by the same cap on reconcile.
- **← / →:** the same rule applied to a display-order neighbor — the comparison
  window *slides*: comparing (A, B) → steps to (B, next(B)); ← steps to
  (prev(A), A). Sequential burst culling falls out for free: (1,2) → (2,3) → (3,4).
- Only 1 item in scope → second pane shows an empty placeholder.
- Structural apply removes a pane member → nearest display-order survivor takes
  its place (same rule as loupe focus). Exit as loupe; the pair stays selected
  in the grid.

### 1.4 Filmstrip (shared by loupe and compare)

- Full current scope in display order (not just the selection) — LrC behavior;
  fixed height (~76 pt), horizontal scroll, same square tiles, same selection
  gestures (plain/⌘/⇧/⌘⇧ against the same selection model), same no-blank paint.

---

## 2. Architecture

### 2.1 Selection ownership moves to the ViewModel (Increment 1, pure refactor)

Loupe/compare entry and the filmstrip both need the selection + anchor, and the
grid's NSViewController **deallocates** when SwiftUI swaps the detail view — an
AppKit-owned selection would die on every mode switch. Two renderers (grid, strip)
of one selection truth means the truth must live above both: `GridSelection` value
moves into `CatalogWindowViewModel`; the pure model type is unchanged.

Spec 0046's race-free property is preserved **exactly**: the collection view still
swallows `mouseDown` and forwards `(hit, modifiers)`; the controller now calls a
*synchronous* MainActor closure into the ViewModel, gets the updated
`GridSelection` back as the return value, and writes `selectionIndexPaths` from it
as the last operation of the gesture — same thread, same ordering, no SwiftUI
round-trip in the write path. Native keyboard selection (⌘A, ⇧-arrows) reconciles
upward through the existing delegate telemetry hooks (idempotent adoption, no
feedback loop: programmatic delta writes echo an equal set). Structural-apply
restore prunes via the ViewModel with the same `pruned(to:)` logic.

Oracle: behavior-preserving — `GridSelectionTests` unchanged; controller/bridge
tests keep asserting the same observable behavior with injection updated.

### 2.2 View mode state (ViewModel-owned, like `gridColumnCount`)

```swift
enum BrowserViewMode { case grid, loupe, compare }
```

`private(set) var viewMode`, `focusedAssetID: MediaAssetID?`, and
`comparePair: (select:candidate:)?` on the ViewModel; every entry/exit/navigation
rule from §1 is a **pure policy type** (`BrowserModePolicy`, `ComparePairPolicy`)
so the LrC rules are unit-tested without UI. Views stay passive.

### 2.3 `PreviewImageLoader` — the second deliberate byte-reading owner (new ADR)

A new small actor, the loupe/compare analog of `EnrichmentCoordinator`'s byte-read
role, and the app's only full-size decode path:

- `preview(for:detail, targetLongEdge) async -> PreviewOutcome`
  (`.image(CGImage)`, `.downloading`, `.unavailable`).
- **Gates on `FileMaterialization.status` immediately before every byte read**;
  dataless → returns `.downloading`, requests deliberate non-blocking
  materialization (existing helper, injectable providers), re-decodes on arrival.
- Decode: Image I/O `CGImageSourceCreateThumbnailAtIndex` with
  `kCGImageSourceThumbnailMaxPixelSize` = main-display backing long edge
  (downsampled decode, bounded memory; embedded RAW previews preferred — probe P4);
  videos via `QLThumbnailGenerator` at the same target.
- Per-id in-flight coalescing; stale results rejected by focus generation; small
  pinned LRU (focus ± 1 + compare pair; byte-capped ~256 MB — at a 3000 px edge one
  frame ≈ 24 MB, so this is ~10 frames, no eviction churn).
- Fully instrumented: `MediaIO` signposts + `op=preview.decode` logs with decodeMs,
  source (imageio/quicklook/embedded), materialization outcome.

Requires **ADR 0016** (who may read bytes; where full-size decode lives; rejected
alternatives: enrichment-side pregenerated large previews — violates "no scale
machinery before measurement", doubles overlay disk; SwiftUI `AsyncImage`/NSImage
direct — no dataless gate, no coalescing, main-thread decode risk).

### 2.4 Filmstrip = the existing AppKit bridge, parameterized

`MediaGridViewController` gains a presentation config (`.grid(columnCount:)` vs
`.strip(tileEdge:)`): strip uses a horizontal compositional layout + horizontal
scroller, no pinch/zoom plumbing, no column-count gate actions; everything else —
mutation gate structural applies, `TileContentStore`, decode dedup, prefetch,
selection delta rendering, no-blank invariant — is shared, one owner. Fallback if
the probe (P3) finds grid-specific entanglement: extract the shared tile-paint
engine into one owned helper used by a lean strip controller (still one paint
owner; more files).

Grid and strip are never on screen simultaneously; each is one
`NSViewControllerRepresentable` instance in the mode-switched SwiftUI detail.

### 2.5 One implementation path per action

Double-click, segment, and menu all funnel to `openLoupe(_:)`/`setViewMode(_:)`;
arrows funnel to `focusNext/Previous` / `slideCompare(_:)`; strip and grid clicks
funnel to the same selection intents. No parallel behavior paths.

---

## 3. Increments (three PRs)

### Increment 1 — `refactor/selection-ownership`

Behavior-preserving; existing tests are the oracle.

| File | Change |
| --- | --- |
| `Otos/ViewModels/CatalogWindowViewModelSelection.swift` (new) | Owns `gridSelection: GridSelection`; synchronous gesture intents `applyGridClick(hit:modifiers:orderedIDs:)`, `reconcileNativeSelection(_:)`, `pruneSelection(to:)`, `clearSelection(reason:)`; exposes ordered-selection + anchor reads |
| `Otos/ViewModels/CatalogWindowViewModel.swift` | Wire new file; no other behavior change |
| `Otos/Views/MediaGridSelectionController.swift` | Gesture computation delegates to injected closures; keeps `applySelectionDelta`, minimal-delta write, logging |
| `Otos/Views/MediaGridBridge.swift` | New closure params (`selectionHandler` bundle); controller no longer owns `gridSelection` |
| `Otos/Views/MediaGridStructuralApply.swift` | Restore path sources/prunes through the ViewModel closures |
| `Otos/ContentView.swift` | Wire closures from ViewModel |
| `OtosTests/MediaGridSelectionControllerTests.swift`, `MediaGridBridgeTests.swift` | Injection updates only; same behavioral assertions (real mouseDown/mouseUp event pairs stay) |
| `OtosTests/CatalogWindowViewModelSelectionTests.swift` (new) | Intent-level coverage |
| `docs/requirements.md` APP-011 | Owner wording (ViewModel-owned model, AppKit renders); behavior clauses unchanged |
| `docs/architecture.md` | Selection ownership row |

### Increment 2 — `feat/loupe-view` (mode state + switcher + loupe + strip + decode)

| File | Change |
| --- | --- |
| `Otos/Models/BrowserViewMode.swift` (new) | Mode enum + `BrowserModePolicy` (entry focus, arrow navigation, prune-survivor focus) — pure |
| `Otos/Services/PreviewImageLoader.swift` (new) | §2.3 actor + outcome types |
| `Otos/Views/LoupeView.swift` (new) | Passive composition: image pane (upscaled-thumb → full swap, downloading badge) + strip |
| `Otos/Views/MediaStripSupport` (inside bridge files) | Presentation config `.grid`/`.strip`; horizontal layout in `MediaGridLayoutFactory`; gate/zoom paths conditioned |
| `Otos/Views/MediaGridCollectionView.swift` | `clickCount == 2` on an unmodified click → `onItemDoubleClick(id)` after normal selection; grid config: `keyDown` forwards Return → `openLoupe` (arrows stay native, reconciled promptly); strip config: `keyDown` forwards ←/→/Esc per mode |
| `Otos/ViewModels/CatalogWindowViewModel.swift` (+ small new extension file) | `viewMode`, `focusedAssetID`, intents (`setViewMode`, `openLoupe(id:)`, `exitToGrid`, `focusNext/Previous`), loader lifetime + focus-generation stale rejection, neighbor prefetch (only if P4 measures > 100 ms) |
| `Otos/ContentView.swift` | Detail switches on mode; toolbar segmented picker; zoom ± disabled outside grid |
| `Otos/Views/CatalogToolbarControls.swift` | `ViewModePicker` control |
| `Otos/OtosApp.swift` | View menu: Grid ⌘1 / Loupe ⌘2 (⌘3 lands in Increment 3) |
| `docs/adr/0016-view-modes-and-preview-decode.md` (new) | §2.3 decision |
| `docs/requirements.md` | APP-001 (may now claim preview/loupe), APP-010 (double-click clause removed; arrow-key selection movement and Return→loupe specified as tested behavior), new APP-019 (mode switcher), APP-020 (loupe incl. Return/double-click entry), APP-022 (filmstrip), APP-023 (preview decode + dataless policy) |
| `docs/architecture.md` | Dataflow + where-to-change rows |
| Tests (new) | `BrowserModePolicyTests`, `PreviewImageLoaderTests` (fake `FileMaterializationProviders`: dataless→downloading→materialized→decode; stale rejection; coalescing), strip-config bridge tests, double-click real-event-pair test |

### Increment 3 — `feat/compare-view`

| File | Change |
| --- | --- |
| `Otos/Models/ComparePairPolicy.swift` (new) | Pure, ~4 functions: entry derivation (all selection cardinalities), FIFO click update, slide(±1) (defined as click-of-neighbor, so it shares the FIFO rule), prune-on-apply |
| `Otos/Views/CompareView.swift` (new) | Two aspect-fit panes + strip. No labels, no buttons, no swap/promote chrome |
| `Otos/ViewModels/…` | `comparePair` state (= capped selection) + intents (`enterCompare`, `compareClick(id:)`, `slideCompare(_:)`); compare-mode gesture interpretation (strip forwards `(hit, modifiers)` as always, the ViewModel maps it per mode) |
| `Otos/OtosApp.swift` | Compare ⌘3 |
| `docs/requirements.md` | New APP-021 (symmetric pair semantics: cap-2 selection, FIFO replacement, sliding window; explicitly *no* select/candidate roles) |
| Tests (new) | `ComparePairPolicyTests` (every §1.3 rule), ViewModel intent tests |

`MediaAssetTileView` is untouched (no role markers — accent ring only), and the
compare surface ships with zero new buttons.

---

## 4. Validation probes and fallbacks

| # | External behavior depended on | Probe (before building on it) | Fallback |
| --- | --- | --- | --- |
| P1 | SwiftUI segmented `Picker` renders as one grouped control in a macOS 27 toolbar | 5-line toolbar spike in the app, screenshot/inspect | `ControlGroup` of three toggle-style buttons (pattern already in `CatalogZoomControl`) |
| P2 | Second click of a double-click arrives as `mouseDown` with `clickCount == 2` when `super.mouseDown` is never called | Unit test driving two real mouseDown/mouseUp event pairs at the same point (per the spec-0046 lesson: real events, never pre-settled state) | Track click timestamps/locations ourselves with `NSEvent.doubleClickInterval` |
| P3 | `NSCollectionViewCompositionalLayout` horizontal-scroll config works with `MediaGridAnimatedLayout` + diffable applies + existing item class | Strip spike behind the config enum; scroll + structural-apply smoke with logs | Extract shared tile-paint engine; lean dedicated strip controller (§2.4) |
| P4 | Image I/O downsampled decode is fast enough (JPEG/HEIC/RAW); embedded RAW previews exist at useful sizes | Measure decodeMs on real library samples via the loader's instrumentation (`script/logs.sh`), compare `ThumbnailFromImageAlways` vs embedded-preview path | RAW via `QLThumbnailGenerator` large representation; add ±1 prefetch if > 100 ms |
| P5 | `QLThumbnailGenerator` returns large video posters at ~3000 px | Same measurement pass on library videos | `AVAssetImageGenerator` poster path |
| P6 | Non-blocking materialization from a user-initiated loupe view (OneDrive/iCloud) | Existing injectable-provider unit tests + one manual dataless-file log trace (`op=preview.decode` + materialization outcome) | Poll-interval tuning; surface a retry affordance on `timedOut` |
| P7 | Synchronous closure ViewModel↔controller keeps selection write as the gesture's last op (no SwiftUI-cycle reordering) | Increment-1 tests assert selection state synchronously after the event pair | Controller-local echo write + reconcile (still ViewModel-owned truth) |

## 5. Verification

- `script/verify.sh` per increment (requirements-authority + lint + build + test).
- Runtime evidence per increment: `script/logs.sh` decode/mode-switch traces on the
  25k smoke library; `script/profile.sh` scroll pass over the strip (main-actor
  spans < 100 ms; strip scroll well below).
- Adversarial pass on the no-blank invariant in loupe/strip (APP-015 extension):
  reorder storms + detail-query failures while loupe is open.
- DoD per CLAUDE.md: full report on each PR, autonomous merge + cleanup.

## 6. Open questions (defaults chosen, flag if you disagree)

1. **Mode persistence across launches** — default: session-only, start in grid
   (matches APP-014 sort/filter policy).
2. **Loupe 1:1 zoom/pan** (LrC click-to-zoom) — deferred to a follow-up increment;
   v1 is fit-to-window. Roadmap note.
3. **Video playback in loupe** — v1 poster frame only. Roadmap note.
4. **Bare-key shortcuts G/E/C** (LrC muscle memory) — deferred; ⌘1/2/3 in v1.
