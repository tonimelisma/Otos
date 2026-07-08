# PLAN.md — Grid Selection, Tile Hit Area, and Sidebar/Sources Fixes

> **Non-authoritative planning document.** This plan explains what to fix and why,
> in enough detail for a junior engineer to implement. It does **not** describe
> current behavior. Each numbered part below must still become a decision-complete
> spec in `docs/specs/` (and any ADR) per the spec-driven workflow before
> implementation, and `docs/requirements.md` is the authoritative record once work
> lands. **Delete this file when all parts are done.**
>
> Reviewed against `main` at `bd74459` (after PRs #54/#55/#56). Product decisions in
> this plan were made by the owner (Taylor) on 2026-07-07; where a decision was left to
> engineering it is marked **(eng default)** with the Finder/Photos-conventional choice.

---

## 0. Background: how these bugs were found

The owner tested the grid and sidebar by hand and reported eight defects. Investigation
(reading the code + web research + reading the previous-generation app in
`../Otos Studio_old/`) grouped them into four independent workstreams. Three of the
selection bugs share **one root cause that is a design flaw in the shipped Increment B
work (spec 0046, PR #55)**: it assumed `NSCollectionView` finalizes selection inside
`super.mouseDown(with:)`. It does not — `NSCollectionView` commits mouse selection at
**mouseUp**. Everything in Part 1 flows from correcting that assumption.

Authoritative confirmation of the timing:
- Apple Developer Forums — "tableview mousedown" (selection settles during the mouse
  event *sequence*, not immediately).
- cocoa-dev / mailing-list threads: the documented workaround for reading
  `selectionIndexPaths` accurately is to override `mouseUp:`, because after
  `super.mouseDown()` the property is still the pre-click value.

Canonical multi-selection idiom (for Part 1's model), from macOS Finder/Photos, Windows
Explorer, and the W3C ARIA APG listbox/grid patterns: an **anchor + selection** model
where plain/⌘ clicks move the anchor, ⇧-click ranges from the anchor without moving it,
and ⌘ toggles single items and composes with ⇧ ranges.

---

## Part 1 — Grid selection rework (fixes bugs 1, 2, 4)

### 1.1 Symptoms (owner-reported)

1. **Range contraction drops the clicked tile.** Click tile 1, ⇧-click tile 4 →
   `{1,2,3,4}` (correct). Then ⇧-click tile 3 → **`{1,2}`** instead of `{1,2,3}`. The
   clicked tile 3 is wrongly deselected.
2. **Selection "remembers" the old set.** After some ⇧-selections, a plain click shows
   only the clicked tile (correct visually), but the *next* ⇧-click re-adds the
   previously-selected tiles.
3. **⌘-deselect leaves a polluting anchor.** Select a tile, ⌘-click it to deselect
   (nothing selected). A following ⇧-click selects a whole range from the
   just-deselected tile *and* re-adds prior selection.

### 1.2 Root cause (verified in code)

`MediaGridCollectionView.mouseDown` ([`Otos/Views/MediaGridCollectionView.swift:26`](Otos/Views/MediaGridCollectionView.swift))
calls `onMouseSelectionFinished` immediately after `super.mouseDown`. But
`NSCollectionView` commits the click's selection on **mouseUp**, *after* that call. So
`mouseSelectionFinished` ([`Otos/Views/MediaAssetCollectionSelection.swift:64`](Otos/Views/MediaAssetCollectionSelection.swift)):

- reads `selectedIdentities()` (i.e. `collectionView.selectionIndexPaths`) while it is
  still the **pre-click** value, and
- applies a range correction that AppKit's own mouseUp commit then **partly overwrites**.

Trace of bug 1's second ⇧-click (state `{1,2,3,4}`, anchor 1, base `{1}`):

| when | what happens | selection |
|---|---|---|
| `super.mouseDown` returns | AppKit has not committed yet | `{1,2,3,4}` |
| our handler | `current={1,2,3,4}`, `target=base∪range(1…3)={1,2,3}`, deselect 4 | `{1,2,3}` |
| AppKit commits at mouseUp | ⇧-click **toggles the single clicked item 3**; 3 was selected → deselect | **`{1,2}`** |

Bug 2/4 are the same defect on the *base snapshot*: a plain/⌘ click's `base = selectedIdentities()`
is taken before AppKit's mouseUp collapse/toggle, so `base` captures the stale
pre-click selection, and the next ⇧-click unions it back in.

Why our unit tests missed it: `OtosTests/MediaAssetCollectionSelectionTests.swift`
**simulates** a settled native selection (`selectItems`/`deselectItems`, then calls the
handler). That encodes the false assumption instead of testing a real mouseDown→mouseUp.

### 1.3 Target design — own the selection model; AppKit renders it

**Principle:** the app owns a pure selection *model* as the single source of truth.
AppKit's native `selectionIndexPaths` is treated as an **output we write**, never an
**input we read mid-gesture**. Because we never depend on AppKit's intermediate state
and we always perform the last write of the gesture, the mouseDown/mouseUp timing
becomes irrelevant.

#### 1.3.1 New pure type: `GridSelection`

New file `Otos/Views/GridSelection.swift`. `nonisolated`, no AppKit, fully unit-tested.

```swift
nonisolated struct GridSelection: Equatable {
    private(set) var selection: Set<MediaAssetID>
    private(set) var anchor: MediaAssetID?
    /// The "islands" a shift-range unions with — snapshot at the last plain/⌘ click.
    private(set) var base: Set<MediaAssetID>

    static let empty = GridSelection(selection: [], anchor: nil, base: [])

    func plainClick(_ id: MediaAssetID) -> GridSelection            // {id}, anchor=id, base={id}
    func commandClick(_ id: MediaAssetID) -> GridSelection          // toggle id; anchor=id; base=result
    func shiftClick(_ id: MediaAssetID, orderedIDs: [MediaAssetID]) -> GridSelection
    func commandShiftClick(_ id: MediaAssetID, orderedIDs: [MediaAssetID]) -> GridSelection
    func clearedBySpace() -> GridSelection                          // empty-space plain click → .empty
    func pruned(to orderedIDs: [MediaAssetID]) -> GridSelection     // structural-apply survivor prune
}
```

**Rules (normative):**
- `plainClick(x)` → `selection={x}`, `anchor=x`, `base={x}`.
- `commandClick(x)` → `s = selection.symmetricDifference([x])`; `selection=s`, `anchor=x`,
  `base=s`. (⌘ toggles; the clicked item becomes the pivot even when it was deselected —
  this matches Finder.)
- `shiftClick(x, order)`:
  - if `anchor` or `x` is not in `order` → behave as `plainClick(x)` (fallback; a removed
    anchor must not resurrect a stale range).
  - else `range = order[min(i,j)…max(i,j)]`; `selection = base ∪ range`; **anchor and base
    unchanged** (so a chain of ⇧-clicks from the same anchor grows/shrinks).
- `commandShiftClick(x, order)` **(eng default)**: `selection = selection ∪ range(anchor…x)`;
  anchor/base unchanged. (⌘⇧ extends and *keeps* existing islands, rather than "range
  wins" — the current code collapses ⌘⇧ to ⇧, which drops islands.)
- `clearedBySpace()` → `.empty`.
- `pruned(to order)`: `selection = selection ∩ order`; `base = base ∩ order`;
  if `anchor` not in `order` → `anchor = nil` and `base = []`. Used on a same-descriptor
  structural apply. A **descriptor change** instead resets to `.empty` (see 1.3.3).

This subsumes today's `MediaGridSelection.shiftRangeSelection`/`pruned` and the ad-hoc
anchor/base bookkeeping in `MediaAssetCollectionSelection.swift`.

#### 1.3.2 AppKit integration (the timing fix)

Controller owns `var gridSelection = GridSelection.empty` (replaces
`selectionAnchorID`/`anchorBaseSelection`).

**Mechanism: fully own the mouse selection path (timing-independent — this is the whole
point of the fix).** Increment B broke *because* it read/wrote selection around AppKit's
native mouse selection and lost the mouseDown-vs-mouseUp race. We remove the race entirely
by never invoking AppKit's native selection for a click:

- `MediaGridCollectionView` overrides `mouseDown(with:)`: hit-test the thumbnail face
  (Part 2) and read modifiers; compute the gesture; update `gridSelection` using the
  model's own `selection` as `current` (**never** read `collectionView.selectionIndexPaths`
  to decide anything); then write
  `collectionView.selectionIndexPaths = indexPaths(gridSelection.selection)`.
- **Do not call `super.mouseDown`** for the selection (the grid uses neither rubber-band
  marquee nor drag-reorder, so nothing is lost). Call `window?.makeFirstResponder(self)`
  to preserve keyboard focus. Programmatic `selectionIndexPaths =` does not re-enter the
  mouse path, so there is no feedback loop and no dependency on when AppKit would have
  committed. There is no later AppKit write to race, so the exact Increment-B failure is
  impossible by construction.
- **Keyboard** (`⌘A`, `⇧`+arrows) stays native but is kept in sync: override `selectAll(_:)`
  and the arrow/`⇧`-arrow responder methods (or reconcile the model from `selectionIndexPaths`
  on any keyboard-driven change — anchor becomes the focused item, base becomes the result).

**Step 0 — empirical verification (agent-runnable; do not skip).** Because the design is
timing-independent, the verification is not a mechanism *choice* but an end-to-end proof:
an integration test builds a real windowed `MediaGridCollectionView`, drives the click
handler with real `mouseDown`/`mouseUp` pairs (attempt `CGEvent` posting for true hit-test
fidelity; if the environment blocks synthetic HID events, drive our own handler directly),
and asserts the §1.5 matrix against `selectionIndexPaths`. This is deterministic regardless
of AppKit's native mouse-selection timing, precisely because we no longer depend on it.
Record in the spec whether `CGEvent` could be driven; if not, that is an accepted
limitation (the owned-path test still proves the matrix). *Optional, for the record only:*
a ~20-line instrumented subclass the owner can run once to document the underlying
`NSCollectionView` mouseUp-commit fact — not a gate.

**Gesture classification** (in the collection view, from the captured event):
- Determine `hit`: the tile **whose thumbnail rect contains the point** (Part 2), else
  `nil` (empty space or letterbox).
- `shift = modifiers.contains(.shift)`, `command = modifiers.contains(.command)`.
- Map to: empty-space (`hit==nil`, no ⇧/⌘) → `clearedBySpace()`; `hit==nil` with ⇧/⌘ →
  no change (leave selection/anchor); `hit=x` plain → `plainClick`; `hit=x` ⌘ (no ⇧) →
  `commandClick`; `hit=x` ⇧⌘ → `commandShiftClick`; `hit=x` ⇧ → `shiftClick`.

`orderedIDs` for range math comes from `mutationGate.displayedOrderedIDs` (already the
live display order).

#### 1.3.3 Structural-apply and descriptor-change integration

- In `completeStructuralApply` / the apply path
  ([`Otos/Views/MediaAssetCollectionStructuralApply.swift`](Otos/Views/MediaAssetCollectionStructuralApply.swift)):
  same-descriptor apply → `gridSelection = gridSelection.pruned(to: grid.orderedAssetIDs)`
  then write `selectionIndexPaths` from it (still a **delta** write so a survivor tile's
  `isSelected` is not reassigned — preserve the spec 0047 no-ring-blink property).
  Descriptor-changing apply → `gridSelection = .empty` and clear selection (as today).
- Keep `applySelectionDelta` (delta write) as the one place that mutates
  `selectionIndexPaths`, driven by `gridSelection.selection`.

### 1.4 Retirement

Delete `selectionAnchorID`, `anchorBaseSelection`, `mouseSelectionFinished`,
`MediaGridSelection.shiftRangeSelection`, and the `MediaGridCollectionView.onMouseSelectionFinished`
closure (replaced by the mouseUp/owned path). Keep `selectionDelta`, `pruned` (folded
into `GridSelection`), `MediaGridClipboard`, and copy/`orderedSelection`.

### 1.5 Tests (acceptance matrix)

Drive real `mouseDown`+`mouseUp` event pairs against a windowed collection view (not a
pre-settled selection). Pure-model tests for `GridSelection` cover every row without
AppKit. Items `A B C D E F G H` in display order; `▓` = selected.

| # | Action sequence | Expected final | Guards |
|---|---|---|---|
| 1 | click C | `C` | plain sets anchor+base |
| 2 | click C, ⇧-click F | `C D E F` | forward range |
| 3 | …then ⇧-click D | `C D` | **contract from same anchor (bug 1)** |
| 4 | click F, ⇧-click C | `C D E F` | backward range |
| 5 | click B, ⌘-click E | `B E` | ⌘ adds island, anchor→E |
| 6 | …then ⇧-click G | `B E F G` | ⇧ ranges E…G, keeps island B |
| 7 | click C, ⇧-click F, ⌘-click D | `C E F` | ⌘ removes inside a range |
| 8 | select `C D E`, plain-click D | `D` | **collapse; base becomes {D} (bug 2)** |
| 9 | …then ⇧-click G | `D E F G` | **must NOT re-add C,E (bug 2)** |
| 10 | click B, ⌘-click B | `∅` | anchor stays B, base `∅` |
| 11 | …then ⇧-click E | `B C D E` | **ranges from pivot B, nothing stale (bug 4)** |
| 12 | click empty space / letterbox | `∅` | clears selection+anchor |
| 13 | ⇧-click with empty selection | `{clicked}` | no-anchor fallback |
| 14 | ⌘⇧-click H after `B E` selected (anchor E) | `B E F G H` | extend, keep islands |
| 15 | select `C D`, background apply removes D | `C` | prune survivors + base |

---

## Part 2 — Thumbnail-only hit area (fixes bug 3)

> **Status: implemented** (spec 0049, `Otos/Views/MediaAssetTilePresentation.swift`,
> `Otos/Views/MediaAssetTileView.swift`, `Otos/Views/MediaGridCollectionView.swift`).

### 2.1 Symptom & decision

Clicking the **whitespace/letterbox** inside a tile's square cell (the padding around an
aspect-fit thumbnail) selects the tile. **Owner decision: match Photos — only a click
*inside the aspect-ratio'd thumbnail* selects; the rest of the square is not a target.**
(Note: this corrects an earlier assumption that Photos selects the whole cell — it does
not.)

### 2.2 Root cause

Each cell is a full **square** ([`MediaAssetCollectionLayout.makeLayout`](Otos/Views/MediaAssetCollectionLayout.swift:8)),
but the thumbnail is drawn aspect-fit inside it via
`MediaAssetTilePresentation.contentRect(imagePixelSize:bounds:)`
([`Otos/Views/MediaAssetTileView.swift`](Otos/Views/MediaAssetTileView.swift), used in
`layout()`). AppKit's `indexPathForItem(at:)` returns the item for **any** point in the
square, including the letterbox.

### 2.3 Target design

In the collection-view click handler (Part 1's gesture classification), after finding a
candidate `indexPath` via `indexPathForItem(at:)`, **confirm the point is inside that
tile's thumbnail face**:

- Get the item's frame: `collectionView.layoutAttributesForItem(at: indexPath)?.frame`
  (in collection-view coordinates), or the item view's frame.
- Compute the thumbnail face within that frame using the *same* geometry the tile renders
  with: `MediaAssetTilePresentation.contentRect(imagePixelSize:, bounds:)`. The pixel
  size is the decoded thumbnail's size; for a not-yet-decoded placeholder tile the face
  is the full square (placeholder fills the square), so a click there still selects — only
  a **decoded** thumbnail with real letterbox has a dead zone. (Confirm the placeholder
  face is full-square in `updatePlaceholderPresentation`; it is.)
- If the click point is **outside** `contentRect` → treat as **empty space** (Part 1:
  `clearedBySpace()`), i.e. it deselects like clicking the gutter.

**Where the geometry lives:** expose a small helper, e.g.
`MediaAssetTilePresentation.thumbnailFaceRect(imagePixelSize:, in bounds:)` reusing
`contentRect`, so the hit-test and the renderer share one definition (no drift). Unit-test
the helper: a landscape thumbnail's top/bottom letterbox is a miss; the center is a hit; a
placeholder (nil pixel size) is a full-square hit.

**Edge note:** the tile view (`MediaAssetTileView`) already knows its own `currentImagePixelSize`.
An alternative implementation is to ask the item's view to hit-test itself
(`tileView.thumbnailContains(pointInTile)`), which avoids duplicating the pixel-size
lookup in the controller. Prefer whichever keeps the geometry in one place.

---

## Part 3 — Sidebar default-selection policy (fixes auto-select + single-library)

### 3.1 Symptoms & decisions

1. **No removable auto-select.** At startup with a card attached, the app stays on "All
   Media" instead of showing the card. Inserting a card does not switch to it.
   **Owner decision: at startup select the (first/most-recently-attached) connected
   removable/camera source if any; and inserting a card should *always* jump to it.**
2. **"All Media" never hides.** With a single library the sidebar still shows a redundant
   "All Media" row and lands there. **Owner decision: hide "All Media" and auto-select the
   library when there is exactly one *library*. "All Media" aggregates only fixed
   libraries (never cameras/removables), so its visibility depends solely on the library
   count — cameras/removables do not matter.**

### 3.2 Root cause

- Startup selection is hard-wired: `CatalogWindowViewModel` initializes
  `sidebarSelection = .allMedia`, `queryDescriptor = .default`, and
  `CatalogWindowPolicy.resolvedSidebarSelection`
  ([`Otos/Services/CatalogWindowPolicy.swift:37`](Otos/Services/CatalogWindowPolicy.swift))
  only **demotes** an invalid `.library` back to `.allMedia`; it never **promotes** to a
  sensible default.
- Attach flows to `.attachRemovableVolume`
  ([`Otos/ViewModels/CatalogWindowViewModelSourceMonitoring.swift:12`](Otos/ViewModels/CatalogWindowViewModelSourceMonitoring.swift))
  which persists the source but never changes the *selection*.
- "All Media" is rendered unconditionally
  ([`Otos/Views/SidebarView.swift:15`](Otos/Views/SidebarView.swift)).

### 3.3 Target design — a pure `SidebarSelectionPolicy`

New file `Otos/Services/SidebarSelectionPolicy.swift`, `nonisolated`, no side effects,
fully unit-tested (mirrors `CatalogWindowPolicy`):

```swift
nonisolated enum SidebarSelectionPolicy {
    /// Whether the "All Media" aggregate row/selection should exist.
    /// True iff there are 2+ fixed libraries. (All Media never includes removable/camera.)
    static func showsAllMedia(libraries: [CatalogLibraryState]) -> Bool

    /// Selection to use at launch / when no explicit user choice is in effect.
    /// Priority: a connected removable/camera source (most-recently-attached) →
    /// else the single library (when exactly one) → else .allMedia.
    static func defaultSelection(
        libraries: [CatalogLibraryState],
        removableSources: [CatalogLibraryState]   // connected only
    ) -> SidebarSelection

    /// When a source attaches, the selection to switch to (always the new card), or nil
    /// to leave selection unchanged (attach of a non-removable / already-selected).
    static func selectionOnAttach(
        attached: CatalogLibraryState
    ) -> SidebarSelection?

    /// When the currently-selected source disappears, fall back to defaultSelection.
    static func selectionOnSelectedSourceRemoved(
        libraries: [CatalogLibraryState],
        removableSources: [CatalogLibraryState]
    ) -> SidebarSelection
}
```

**Ownership / wiring:**
- The **ViewModel** applies the policy when projected state changes and on attach, issuing
  the *same* `selectSidebar`/`setQueryDescriptor` intent every surface uses (one path).
  Add `@ObservationIgnored private var userHasChosenSource = false`, set `true` in
  `setQueryDescriptor` when the change originates from an explicit user sidebar click, and
  keep `false` at launch. **Owner decision is "always jump to inserted card,"** so
  `selectionOnAttach` fires regardless of `userHasChosenSource`; the flag only governs
  whether the *default* re-applies when sources change for other reasons (so we don't yank
  a browsing user back to All Media on an unrelated availability blip).
- **Startup:** after the first projected state arrives (libraries/sources known), if the
  user has not chosen, apply `defaultSelection`. (Selection must run once sources are
  loaded, not from `init`, because sources come from the async Store.)
- **On attach:** in the attach handler, after the source is persisted and projected, call
  `selectionOnAttach` and select it.
- **On detach of the selected source:** if the projected `resolvedSidebarSelection`
  drops to invalid, apply `selectionOnSelectedSourceRemoved` (generalizes the current
  `currentSelectionWasRemoved` → `.allMedia` fallback in `applyState`).
- **All Media visibility:** `SidebarView` renders the "All Media" row only when
  `showsAllMedia` is true; `CatalogWindowPolicy` must also stop resolving to `.allMedia`
  when it is hidden — extend `resolvedSidebarSelection` to fall back to the single library
  instead of `.allMedia` in that case. Consider adding an explicit **empty/onboarding**
  `SidebarSelection` (or window state) for "no libraries yet" so the grid can show an
  "Add a library" affordance instead of an empty All Media.

**Requirements impact:** APP-004/005-style sidebar/selection requirements in
`docs/requirements.md` change (observable behavior). Capture the new default-selection and
All-Media-visibility rules there once implemented.

---

## Part 4 — Sidebar row icon alignment

### 4.1 Symptom & root cause

The "All Media" row uses SwiftUI `Label("All Media", systemImage: "square.grid.2x2")`
([`Otos/Views/SidebarView.swift:15`](Otos/Views/SidebarView.swift)), while library and
removable rows use a hand-rolled `HStack(spacing: 10) { Image(...).frame(width: 16); Text }`
([`Otos/Views/SidebarView.swift:20`](Otos/Views/SidebarView.swift)). Two different layout
systems → different icon widths and text leading, so the "four squares" glyph and its
label don't line up with the folder/sdcard/camera rows. (`square.grid.2x2` is also a wider
glyph than `folder`.)

### 4.2 Target design

One reusable row view used by **every** sidebar row:

```swift
private struct SidebarRow<Trailing: View>: View {
    let systemImage: String
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)   // single shared icon rail
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            trailing()
        }
    }
}
```

Use it for All Media (`square.grid.2x2`), libraries (`folder`), removable
(`LibraryRootKind.sidebarSystemImage` = `sdcard`/`camera`), with the eject button (Part 5)
as the trailing accessory. All icons share one leading rail; all titles share one text
rail. This can ride along with Part 3.

---

## Part 5 — Honest eject that actually ejects (fixes eject bug)

### 5.1 Symptom

Clicking the eject button removes the source from the sidebar but the physical volume is
**not** ejected (it stays mounted in Finder).

### 5.2 Root cause (verified in code)

`performEjectRemovableSource` ([`Otos/ViewModels/CatalogWindowViewModelMutation.swift:140`](Otos/ViewModels/CatalogWindowViewModelMutation.swift)) does:

1. `quiesceRemovableSource(identity)` → in the Store this calls
   `setAvailability(.unavailable)` ([`Otos/Stores/CatalogStore.swift:1503`](Otos/Stores/CatalogStore.swift)).
2. The sidebar shows only `removableSources.filter(\.isAvailable)`
   ([`Otos/Views/SidebarView.swift:32`](Otos/Views/SidebarView.swift)) → **the row
   vanishes the instant we quiesce, before any physical eject.**
3. `unmountAndEjectDevice(url)` runs; if it **throws** (e.g. the volume is busy), the error
   is **swallowed** (logged only) and `resumeRemovableSource` restores availability.

So removal is tied to our internal *quiesce*, not to a real unmount, and failures are
invisible. The volume can be busy because — unlike the old app — the current app reads
bytes **directly off the volume** during enrichment (thumbnails/metadata) and can
materialize cloud placeholders; an in-flight read at eject time keeps the volume busy.

### 5.3 What the previous app did (reference: `../Otos Studio_old/`)

- The eject *call* is identical: `DiskVolumeCommandService.eject` →
  `NSWorkspace.shared.unmountAndEjectDevice(at:)`
  (`Otos Studio_old/.../Infrastructure/DiskVolumeCommandService.swift`).
- **Removal is driven by the real unmount event.** `ForegroundMediaRootPresenceEventSource`
  observes `NSWorkspace.didUnmountNotification` and calls `refreshRootAvailability`
  (`Otos Studio_old/.../Infrastructure/MediaRootPresenceEventSource.swift`,
  `App/AppRuntimeBuilder.swift:287`). The row disappears **because the volume actually
  unmounted**, not because we pre-marked it unavailable.
- **Eject is `async throws` end-to-end** (`SourceSession.eject()` →
  `ejectHandler()` → `unmountAndEjectDevice`), so the UI layer can surface a failure.
- **It doesn't hold the volume busy**: the old app *stages* (copies) the files it needs
  into an app staging directory (`volumeStagingDirectory`, `stagedMaterializations`), so
  at eject time it isn't holding open handles on the volume's originals.

### 5.4 Target design

1. **Drive UI removal from the real unmount, not from quiesce.**
   - Do **not** hide the row on `quiesce`. A quiesced-but-still-mounted source stays
     visible. The sidebar filter should key off "is the volume still mounted," which the
     monitor already tracks via `didUnmountNotification` → `.detachRemovableSource`
     ([`Otos/Services/RemovableVolumeMonitor.swift:98`](Otos/Services/RemovableVolumeMonitor.swift)).
   - Concretely: either stop making `quiesce` flip availability to `.unavailable`, or give
     the sidebar a separate "mounted" signal so quiesce no longer hides the row. Keep
     `quiesce` meaning "pause our work," decoupled from "present in sidebar."
2. **Release the volume before unmounting.** The eject intent must **await** the release of
   everything Otos holds under that root before calling `unmountAndEjectDevice`:
   - cancel/await enrichment work for that source (`coordinator?.drainWork(under:)` — verify
     it actually finishes in-flight reads, not just marks intent),
   - cancel any decode/preheat tasks reading that root,
   - ensure no open file handles remain.
   Treat "we still hold the volume" as the primary failure to eliminate.
3. **Surface failures.** Prefer DiskArbitration (`DADiskUnmount`/`DADiskEject` with a
   completion + dissenter) for a precise busy/who-holds-it reason; otherwise catch the
   thrown error from `unmountAndEjectDevice` and present a standard macOS alert:
   *"The disk 'CARD' couldn't be ejected because it's in use."* Never swallow. Return an
   `EjectOutcome` (`.ejected` / `.busy(reason)` / `.failed(error)`) from the intent so the
   ViewModel maps it to a transient row state and/or an alert.
4. **Transient "Ejecting…" state.** While the eject runs, show the row as busy (spinner in
   the trailing accessory from Part 4) so the action feels responsive; resolve to removal
   (on `didUnmount`) or back to normal + alert (on failure).
5. **Verify the URL.** Confirm `root.path.url` is the volume mount root (`/Volumes/NAME`),
   not a normalized/sub path, or `unmountAndEjectDevice` will no-op/err.

### 5.5 Tests
- Unit: the sidebar-visibility rule shows a quiesced-but-mounted source and hides only on
  unmount. `EjectOutcome` mapping to UI states.
- Integration (agent-drivable subset): simulate a `didUnmount` after a successful eject
  removes the row; simulate an eject error surfaces an alert and keeps the row.
- Manual (after-DoD, needs real hardware): plug a card, eject, confirm Finder shows it
  unmounted and the row disappears; hold the volume busy (copy a large file) and confirm
  the alert appears and the row stays.

---

## 6. Sequencing, process, and Definition of Done

Each part is its own spec-driven **fix increment** with a dedicated worktree/branch,
decision-complete spec (amend `docs/specs/0046` for Part 1; new specs for Parts 2–5; ADR
only where a reusable boundary/persistence policy changes), full `script/verify.sh`
(Xcode 27 beta) evidence, instrumentation, the last-five-PRs review-comment sweep, a
repo-wide stale-document audit, and one final DoD report — per `CLAUDE.md`.

**Recommended order:**
1. **Part 1 — grid selection rework.** Highest user pain; reverts a flawed shipped design.
   Land the `GridSelection` model + the fully-owned mouse-path integration + the §1.5
   matrix first.
2. **Part 2 — thumbnail-only hit area.** Small; composes with Part 1's empty-space rule.
   Can land with Part 1 or right after.
3. **Part 3 + Part 4 — sidebar selection policy + row unification.** One increment
   (`SidebarSelectionPolicy`, the empty/onboarding state, and the shared `SidebarRow`).
4. **Part 5 — honest eject.** Separate; involves real volume-release work, an
   `EjectOutcome`, and error-surfacing UI.

**Invariants to preserve throughout:**
- No-blank grid invariant (spec 0038 / ADR 0006): selection changes must not blank painted
  thumbnails; keep delta writes so a survivor tile's `isSelected` is never reassigned.
- One user action, one implementation path: menu/slider/pinch/keyboard/mouse and tests all
  converge on the same owner intents.
- Views stay passive; pure policy types (`GridSelection`, `SidebarSelectionPolicy`,
  thumbnail-face geometry) hold the logic and are unit-tested without AppKit.

**Delete this `PLAN.md` in the final part's PR.**
