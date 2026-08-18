# 0095 — Honest Import: One Owner Per Fact, No Fabricated Values

## Read first

- `docs/design/import-bar.md` — the import screen spec. This plan does not
  redesign it; it makes the app actually satisfy it, and changes exactly two of
  its decisions (destination persistence, §Increment 10).
- `docs/design/design-system.md` — `DES-*` rules. Increment 11 rolls them out
  app-wide, which the owner confirmed 2026-08-17 is their intended scope.
- `docs/adr/0013-removable-and-device-sources.md`,
  `docs/adr/0019-import-plan-namespace-and-build-ownership.md`,
  `docs/adr/0021-concurrent-import-planning-and-destination-reservations.md`.

This plan assumes no prior context. Every increment states its goal, the exact
steps, how to verify, and how to roll back.

## What is wrong today

Import from an MTP camera has never worked. The evidence is one production run,
2026-08-17 20:40, captured via `script/logs.sh show --last 15m`:

```
20:40:20.909  catalog.removable.attach  kind=deviceMTP  displayName=ILCE-6700
20:40:21.168  import.plan phase=finish  copyCount=214 skipCount=37 sourceCount=251
20:40:21.168  import.attachToReady      elapsedMs=259
20:40:35.288  import.activity started                      ← user presses Import
20:40:35.349  mediaOperation.copy phase=staleSource  …×214 within 20 ms
20:40:35.573  catalog.device.scan.batch phase=finish  count=251 changedCount=0
20:40:35.613  mediaOperation.batch verified  published=0 failed=214
20:40:35.613  mediaOperation.batch finish    bytes=13268611386 elapsedMs=270 mbps=49143
```

The user pressed Import five times over 75 seconds (five `import.queue
phase=start`, zero `phase=rejected`). Attempts 1–4 published nothing. Attempt 5,
77 s after attach, published 4 of 214.

Nine distinct defects produced that run. They share one shape: **a fact is
derived twice by different code, or a missing value is replaced by a fabricated
one.**

### D1 · The plan is built from persisted rows before the device is live

The catalog holds asset rows for removable and device roots after detach, by
design (ADR 0008: a missing original is never a deletion). Verified in the live
catalog with nothing plugged in:

```
rowid  kind             path                              assets
 13    deviceMTP        …camera-…-313531434638             251     ← ILCE-6700
  2    removableVolume  /Volumes/4152150790                251
 10    removableVolume  /Volumes/CAMERA                     181
```

`MediaOperationCoordinator.refreshSources` creates a session the moment a root
becomes `available`, and `CatalogStore.importPlanningSnapshot` reads
`media_asset WHERE library_root_id = ?` with no filter. So a plan of 214 copies
was Ready **259 ms after attach**, built entirely from the previous session's
rows. No MTP enumeration can complete in 259 ms; this one completed at
20:40:35.573, **14.7 s later and 285 ms after the user pressed Import**.

### D2 · Device inventory landing never triggers a replan

`CatalogStore.recordDeviceCatalogBatch` ends with `notifyCatalogChanged()` only.
It never bumps `occupancyRevision` and never emits a `RootPlanningChange`. On the
consumer side, `refreshSources` updates an existing session's `root` and
destination but **never sets `isDirty`**. Import-plan staleness keys on
`occupancyRevision` (ADR 0019).

Net: the plan built at attach is the plan you get, permanently.

Both observed symptoms follow from D1+D2 alone:

| Situation | Rows at attach | Plan | What the bar says |
| --- | --- | --- | --- |
| First-ever attach of a camera | 0 | zero entries | `This card is empty` — while the grid fills with 110 tiles |
| Second attach | 251 stale | 214 copies | `214 new items` — every one fails `staleSource` |

### D3 · The camera's date is derived three ways in one file

`CameraSourceMonitor.swift` orders the same six `ICCameraFile` date properties
three different ways:

| Line | Used for | Precedence |
| --- | --- | --- |
| 569 | `DeviceCameraCatalogItem.captureDate` → stored as `media_asset.content_modified_at` | **creation**-first, 6 fields |
| 376 | `revalidate` — what execution demands | **modification**-first, 6 fields |
| 286 | companion `contentModifiedAt` | modification-only, 3 fields |

`revalidate` requires `abs(live − planned) < 1.0` s. The catalog stores the
*creation* date under a field the validator reads as the *modification* date. For
any file where the camera writes both — which is most of them — revalidation
fails even with a perfect readiness gate. This is why attempt 5, after
enumeration had completed, still matched only 4 of 214.

### D4 · The copy log reports work that did not happen

`mediaOperation.copy phase=finish` is emitted on the `staleSource` path using
`entry.source.byteSize` — the **planned** size. The batch aggregate then reported
`bytes=13268611386 elapsedMs=270 mbps=49143` for a run that moved zero bytes.
`AGENTS.md` forbids fabricating domain facts; logs are the agent's only window,
and this one cost a full round of wrong analysis.

### D5 · MTP is effectively uninstrumented

`CameraSourceMonitor.swift` is 709 lines with **two** `OtosLog` statements, both
`.debug`, neither of which fired in the captured run. There is no signal for
enumeration start, progress, completion, session open/close, or download.

### D6 · Progress has two publishers, one of which fabricates zeros

`MediaOperationCoordinator.presentation(for:)` synthesizes
`completedCount: 0, completedBytes: 0, totalBytes: 0, elapsedMs: 0` on every
`publish()`; `applyExecutionProgress` yields the real value on a separate path
and deliberately does not store it. `presentationsStream()` uses
`.bufferingNewest(1)`, so last-writer-wins, and `publish()` fires on every
catalog and planning change. `.completed` has the identical defect one case
below.

The import-bar spec diagnosed exactly this hazard for `batchID` and fixed that
one field; progress — the fact that changes ten times a second — was left as an
event with a second publisher.

### D7 · Session preferences have two owners

`session.preferences` lives on the coordinator; `sessionPreferencesBySource`
lives on the ViewModel. Every presentation frame spawns an unowned `Task` that
re-reads the coordinator once **per source** and wholesale-replaces the ViewModel
copy, while `setSessionPreferences` writes it optimistically. A checkbox toggled
during execution can be reverted by a frame that raced the write.

### D8 · Failure reasons are discarded three times

| Layer | Type | Lost |
| --- | --- | --- |
| `sourceStillMatches` | `-> Bool` | session closed vs. absent vs. size vs. date |
| `EntryOutcome.failed` | no payload | why this entry failed |
| `.completed(failedCount: 214)` | a count | that this was one systemic condition |

A total systemic failure is shaped exactly like "a few unreadable files", so the
mapper renders **Done**. Plan 0092 typed the coordinator's failures and stopped
one layer short of the executor's.

### D9 · Absence is rendered as a fabricated value

`ImportBarByteFormat.string(bytes:)` computes `max(1, Int(bytes / 1000))`, so
`0 bytes` renders as `1 KB`. Combined with D6 the bar read `1 KB of 1 KB`.

### Consequences visible in the UI

- The failure report is on screen ~265 ms, then the post-settlement replan lands
  `.ready(copyCount: 214)` and `doneFromRebuilt` (which requires
  `summary.copyCount == 0`) falls through to state C. *The bar flashes and
  returns unchanged.*
- `selectSidebar(.importBatch(…))` fires at execution start, but the batch
  published zero assets so no row ever appears. `CatalogWindowPolicy` invalidates
  the selection and falls back. *The bar disappears.* Confirmed in the projection
  log: `sidebarSelection=importBatch:1787024435291`,
  `resolvedSidebarSelection=library:…/camera-…`.

### Adjacent defects found while investigating

| # | Defect | Evidence |
| --- | --- | --- |
| D10 | Any mounted disk image becomes a permanent removable source. `RemovableVolumeMonitor.currentAttachments` filters on `volumeIsRemovable == true` alone. | `library_root` holds `/Volumes/Raycast` and `/Volumes/BoltAI 2` — app installer DMGs |
| D11 | `drawn.primaryEnabled` is read by 1 of 7 actions. The cancelling state maps to `primaryEnabled: false` and renders a live button. | `ImportPlanFooter.swift:246–316` |
| D12 | State F-incomplete's `Show them` selects **source** asset IDs while the user is on the batch row, whose grid holds **destination** IDs. Selects nothing. | `MediaImportExecutor.swift:327,331` → `selectAssets` |
| D13 | The bar draws two hairline dividers in every state, including when the middle zone is `.hidden`. The mockup has 13 hairlines across 22 bars — at most one per bar, only when a middle zone exists. | `ImportPlanFooter.swift:50–56` vs `docs/design/mockups/Otos Import.dc.html` |
| D14 | Zone widths: both *what* and *choices* take `.frame(maxWidth: .infinity)` and split the slack evenly; the mockup uses `grid-template-columns: auto 1fr auto`. | same |
| D15 | `DesignPalette` has callers in 2 of 13 view files. `DesignPalette.sidebar` and `.l4` have **zero** callers, so DES-013 and DES-022's sidebar value are unimplemented. | `grep DesignPalette Otos/` |
| D16 | `guard-design-system.sh` greps `Text("…")` literals under `Otos/Views` only, so every string in `ImportBarPresentation.swift` — the file that holds all the import copy — is invisible to it. DES-002's seven-styles rule is unenforced; `.font(.caption)` exists. | `script/guard-design-system.sh:45`, `ImportPlanFooter.swift:111` |
| D17 | Library reorganization has no UI entry point: `requestReorganizationConfirmation` and `canRequestReorganization` have zero references in app or tests, so ~1,700 production lines are unreachable. | `grep -rn` across `Otos/`, `OtosTests/` |
| D18 | Unreferenced: `pauseLoupeVideo`, `readyImportPlan`, `contentForTile`, `MediaOperationPlanEntry.isBlocked`, `SidebarSelectionPolicy.selectionOnAttach`, `BrowserViewMode.keyboardShortcutDigit` (menu hardcodes `"1"/"2"/"3"`). | same |
| D19 | `destinationBySource` is persisted, loaded at start, then unconditionally overwritten with `fixedAvailable.first` on every attach. Settings → Removable Media shows a **Destination** column reading a value that is never honored. | `MediaOperationCoordinator.swift:734–741`, `SettingsView.swift:157` |
| D20 | Auto-dismiss after 6 s on a fully clean run is specified in `import-bar.md` and has zero occurrences in the codebase. `isFullyClean` is published and documented as "the auto-dismiss gate" but only selects wording. | `grep autoDismiss` |
| D21 | `MediaOperationSourcePresentation.cardStillExists`'s doc comment says "Always `true` today"; increment 6 of plan 0092 made it vary and left the comment. | `MediaOperationModels.swift:280` vs `MediaOperationCoordinator.swift:854` |
| D22 | Curation announces `"Selected"` / `"Not selected"` on each of three buttons. DES-068 specifies the accessibility **value** `liked` / `not rated` / `disliked`, and DES-085 says it is announced **once** on the item, not three times across three controls. | `MediaChoiceControl.swift:59–60` |
| D23 | `AllImportsListView` renders `Button(.plain)` rows inside a `List` rather than a selectable list, so the All Imports surface has no keyboard navigation (DES-080). | `ContentView.swift:300–322` |
| D24 | `.help(eraseDisabledReason ?? "")` passes an empty tooltip when the control is enabled, and SwiftUI does not reliably surface `.help` on a `.disabled` `Toggle` — so DES-038's "explain it in that control's tooltip" may not reach the user at all. | `ImportPlanFooter.swift:151` |
| D25 | Otos's own instrumentation only persists to `logs/` while `script/logs.sh stream` is running. `logs.sh show` depends on macOS unified-log retention, which evicted a 21-hour-old import run entirely — one `mainThreadStall` line survived. CLAUDE.md says "No human reads logs — the agent does", but the agent could not read the run it most needed. | `logs/` newest prod capture is 2026-08-11; `logs.sh show --last 24h` returned 574 events |

## Owner decisions, 2026-08-17

| Question | Decision |
| --- | --- |
| Camera not yet enumerated | **Gate.** Bar sits in state A `Checking the camera…` with Import disabled until enumeration completes. No streaming/growing totals. |
| A run where every entry is `staleSource` | Not a failure — nothing was attempted and nothing was lost. The replan erasing it is correct. The fix is the gate, not a sticky error state. |
| Retry guard on repeated Import presses | None. Import is idempotent; re-planning skips preexisting. |
| Batch selection | Move the selection when the batch has its **first** asset, never before. |
| MTP support | Keep and fix. |
| Design-system rollout | App-wide, in this plan. |
| Destination | Persisted **per removable source**, shown and honored in Settings. Changes `import-bar.md`. |

## Constraints

| # | Constraint | Why |
| --- | --- | --- |
| C1 | Every behavior change updates its `docs/requirements.md` row in the same PR. | CLAUDE.md |
| C2 | No new process/workflow/tooling rows in `docs/requirements.md`. | CLAUDE.md |
| C3 | Tests assert observable behavior; no source-text substring assertions. | CLAUDE.md, CI-guarded |
| C4 | Each increment is one PR with full `script/verify.sh`, on a branch from a green `main`. | CLAUDE.md |
| C5 | Increment 1 lands first and alone — the remaining diagnosis depends on its logs. | D5 |
| C6 | The `MediaOperationSourcePresentation` shape may only be widened by the coordinator; no consumer re-derives a fact it could carry. | ADR 0017, `import-bar.md` §"What the presentation must carry" |

## Target end state

```
Import lifecycle, one direction, one writer per fact:

  device / volume monitor
        │  attach + live inventory
        ▼
  CatalogStore ── media_asset rows + occupancyRevision bump on device batches
        │            + CatalogLibraryActivity (.enumerating → .idle)
        ▼
  MediaOperationCoordinator
        │  ImportSourceReadiness gates session creation and the primary action
        │  SourceSession owns: plan, progress, settled outcome, preferences
        │  presentation(for:) is the ONLY constructor
        │  publish()          is the ONLY yield
        ▼
  MediaOperationSourcePresentation  (every fact the bar shows, typed, never synthesized)
        ▼
  ImportBarPresentation.map  (pure; strings only)
        ▼
  ImportPlanFooter           (renders; derives nothing; honors every field)
```

## Increments

Each is a separate PR. Steps are ordered; verification is the gate.

---

### Increment 1 · Instrument MTP, and stop the logs from lying

**Goal.** Make the device path observable and remove the fabricated byte
accounting, so the remaining increments can be verified from logs rather than
inferred. (D4, D5)

**Steps.**

1. Add `OtosLog.fileAccess` / `OtosSignpost` coverage to `CameraSourceMonitor`
   and `runCameraCatalogFlow`, in the repo's `op=… phase=… key=value` shape:
   `op=camera.session phase=open|close identity=…`;
   `op=camera.enumerate phase=start|batch|finish identity=… count=… elapsedMs=…`;
   `op=camera.revalidate phase=miss identity=… relativePath=… reason=…`;
   `op=camera.download phase=start|finish relativePath=… bytes=… elapsedMs=…`.
2. In `MediaImportExecutor.copyEntry`, move the `mediaOperation.copy
   phase=finish` emission so it reports **bytes actually written**, and never
   emits on a non-copy outcome. Add `phase=skipped reason=…` for those.
3. Make `mediaOperation.batch phase=finish` report observed bytes, not planned.
4. Close the retention hole (D25). `script/logs.sh` gains a `capture` mode that
   snapshots the unified log for a window into `logs/` without requiring a
   `stream` to have been running beforehand, so a run can be reconstructed after
   the fact. Every later increment's runtime verification depends on this.

**Verify.** `script/verify.sh`. Then attach the ILCE-6700, run
`script/logs.sh stream Catalog`, and confirm the enumeration timeline is visible
end to end and that a `staleSource` run reports `bytes=0`. Separately, run an
import *without* streaming and confirm `logs.sh capture` recovers it.

**Rollback.** Revert the PR; no behavior depends on it.

---

### Increment 2 · One camera date, one owner

**Goal.** Eliminate D3.

**Steps.**

1. Add `nonisolated enum CameraFileDate` with two named, documented functions
   over `ICCameraFile`: `captureDate(_:)` (creation-first) and
   `modificationDate(_:)` (modification-first), each with the single
   `validCameraDate` guard.
2. Replace all three ad-hoc chains (lines 286, 376, 569) with calls to it.
3. `DeviceCameraCatalogItem` gains **both** dates. `scannedFiles(for:)` maps
   `contentModifiedAt: item.modificationDate` and `createdAt: item.captureDate`
   — the fields the names promise.
4. `revalidate` compares against `CameraFileDate.modificationDate`, i.e. the same
   value the catalog stored.

**Verify.** `script/verify.sh` plus a new `CameraFileDateTests` suite covering:
creation ≠ modification; all-nil; the epoch-zero guard. Runtime: attach the
camera and confirm `op=camera.revalidate phase=miss` no longer fires for
unchanged files.

**Rollback.** Revert; increment 1's logging makes a regression visible.

---

### Increment 3 · Device inventory triggers a replan

**Goal.** Eliminate D2.

**Steps.**

1. `CatalogStore.recordDeviceCatalogBatch` and
   `completeDeviceCatalogEnumeration` bump `occupancyRevision` and emit
   `RootPlanningChange` for the device root when `changedCount > 0` (and always
   on completion).
2. `MediaOperationCoordinator.refreshSources` marks an existing session dirty
   when the root's `occupancyRevision` advanced past the one its plan captured
   — reusing the existing `lastSeenOccupancy` map rather than adding state.

**Verify.** `script/verify.sh` plus a `CatalogStoreDeviceInventoryTests` case
asserting the planning-change stream emits for a device root, and a coordinator
adversarial case asserting a session replans when device rows land after attach.

**Rollback.** Revert.

---

### Increment 4 · `ImportSourceReadiness` gates the offer

**Goal.** Eliminate D1, and make the empty-card state provable rather than
inferred. (owner decision: gate, not stream)

**Steps.**

1. Add `nonisolated enum ImportSourceReadiness { case preparing, ready,
   unreachable }`, derived purely from `CatalogLibraryState`
   (`availability` + `activity`) in a testable function beside
   `SidebarSelectionPolicy`.
2. `refreshSources` may create a session while `.preparing`, but
   `beginExecutionIfPossible` refuses unless `.ready`, and the published state
   stays in the Preparing family (state A) until then.
3. `ImportBarDrawnState` gains nothing: state A already exists. The mapper routes
   `.preparing` to `preparing(...)` with `Checking the camera…` /
   `Checking the card…` chosen by `RootKind`.
4. **C-empty requires proof.** `ready(...)`'s empty-card branch fires only when
   readiness is `.ready` *and* the plan's source snapshot was taken at the
   current `occupancyRevision`. Otherwise the surface stays in state A.

**Verify.** `script/verify.sh` plus mapper tests for each readiness value, and a
coordinator case asserting Import is refused while `.enumerating`. Runtime:
attach the camera, confirm the bar holds `Checking the camera…` for the whole
enumeration and that Import becomes enabled exactly once
`op=camera.enumerate phase=finish` is logged.

**Rollback.** Revert.

---

### Increment 5 · Typed entry outcomes, and systemic vs. per-item failure

**Goal.** Eliminate D8.

**Steps.**

1. `sourceStillMatches` returns `SourceValidation` — `.matches`,
   `.sourceNotReady`, `.changed(ChangedFact)`, `.absent`.
2. `EntryOutcome.failed(EntryFailure)` carries it.
3. `MediaImportExecutor` classifies the run: when every attempted entry failed
   with the same non-per-file reason, return
   `.failed(reason: MediaOperationFailureReason)` rather than
   `.completed(failedCount:)`.
4. `MediaOperationFailureReason` gains `.sourceNotReady`, whose clause is
   `The camera is still reading its card` / `The card is still being read`.

Per the owner decision, this state should now be unreachable in practice — the
increment-4 gate prevents it. It exists so that if it ever happens, the bar says
something true instead of "Done".

**Verify.** `script/verify.sh` plus executor tests for each classification and a
mapper test that a systemic failure reaches state G.

**Rollback.** Revert.

---

### Increment 6 · One presentation writer

**Goal.** Eliminate D6 and D7.

**Steps.**

1. `SourceSession` gains `lastProgress: MediaOperationProgress?` and
   `settledOutcome`.
2. Delete both synthetic literals in `presentation(for:)` (the `.executing`
   zero-progress and the `.completed` zero-summary). `.executing` reads
   `session.lastProgress`; `.completed` reads `session.settledOutcome`.
3. `applyExecutionProgress` and `applyExecutionResult` **store and call
   `publish()`**. Delete their private `continuation.yield` paths.
4. `MediaOperationSourcePresentation` gains `sessionPreferences:
   ImportPreferences`. Delete `refreshSessionPreferences`,
   `sessionPreferencesBySource`, and the per-frame `Task` in
   `applyImportPresentations`. `setSessionPreferences` stays as the one intent
   and the next `publish()` is the confirmation.
5. Same treatment for `refreshRemovableDestinations` / `removableDestinations`
   if it is still needed after increment 10; otherwise delete it there.

**Verify.** `script/verify.sh` plus a coordinator test asserting that a
`publish()` during execution carries the live progress (not zeros), and one
asserting a preference toggle survives an interleaved frame. Runtime: import and
confirm the bar counts monotonically with a remaining-time estimate appearing
after ~2 s.

**Rollback.** Revert.

---

### Increment 7 · Honest numbers

**Goal.** Eliminate D9 and close the class.

**Steps.**

1. `ImportBarByteFormat.string(bytes:)` returns `"0 KB"` for zero and never
   applies `max(1, …)`.
2. Audit `MediaOperationProgress` for fields that can be genuinely unknown and
   make them optional; the mapper omits rather than substitutes.
3. Extend `script/guard-design-system.sh` with a check that no user-facing string
   is built from a `??` default of `0`/`""` in `ImportBarPresentation.swift`.

**Verify.** `script/verify.sh` plus formatter tests at 0, 1, 999, 1_000,
99_999_999, 100_000_000, 99_999_999_999, 100_000_000_000.

**Rollback.** Revert.

---

### Increment 8 · The bar renders what it is handed, and matches the mockup

**Goal.** Eliminate D11, D12, D13, D14, D21.

**Steps.**

1. Every `primaryAction` case honors `drawn.primaryEnabled`; delete
   `.disabled(true)` hardcoding on `.importPending`.
2. Replace the `HStack` with a layout sized `auto 1fr auto`; *what* and *the act*
   size to content, the middle absorbs the slack.
3. Draw **one** hairline, before the middle zone, only when `middleZone` is
   `.choices` or `.progress`. Never before the act.
4. `.font(.caption)` → `.footnote`.
5. Fix the erase tooltip (D24): pass `.help` only when a reason exists, and
   verify at runtime that a disabled `Toggle` actually surfaces it. If SwiftUI
   will not, wrap the checkbox so the tooltip lands on an enabled container —
   DES-038 requires the explanation to reach the user, not merely to be attached.
6. State F-incomplete's reveal carries the **destination** IDs of items that
   landed, or the affordance is omitted; a reveal that selects nothing is worse
   than no reveal. `MediaImportExecutor` already knows both identities.
7. Move batch selection to first-asset (owner decision): the coordinator
   publishes `batchID` only once `importBatchAssetCount(batch) > 0`.
   `followNewBatchesOnce` is unchanged — it already acts on the value, not the
   transition.
8. Fix the stale `cardStillExists` doc comment.

**Verify.** `script/verify.sh` plus a rendered-action test (see below).
Screenshot light and dark, grayscale one (DES-022, DES-029), tab through with no
mouse (DES-080), run once with Reduce Motion (DES-075).

**New test seam.** `ImportPlanFooter` exposes
`struct RenderedPrimary { title: String; isEnabled: Bool; isDefault: Bool;
isDestructive: Bool }` derived from `ImportBarDrawnState`, and the button case
consumes it. This closes the gap that let D11 ship green: today the mapper is
fully covered and the renderer is not.

**Rollback.** Revert.

---

### Increment 9 · A disk image is not a camera card

**Goal.** Eliminate D10.

**Steps.**

1. Write `docs/research/2026-08-…-removable-volume-qualification.md`: measure
   `URLResourceValues` for a real SD card, a USB stick, a mounted app DMG, and a
   read-only DMG. Do not guess the predicate — record what the system reports.
2. Implement the qualification the research supports in
   `RemovableVolumeMonitor.currentAttachments`.
3. Add a one-time migration that removes already-persisted disk-image roots and
   their rows, keyed on the same predicate.

**Verify.** `script/verify.sh` plus qualification unit tests over recorded
resource-value fixtures. Runtime: mount a DMG, confirm no Removable row appears
and no import bar is offered.

**Rollback.** Revert; the migration is additive-safe (it deletes only roots the
new predicate rejects, and originals are untouched).

---

### Increment 10 · Per-source destination, and auto-dismiss

**Goal.** Land the two deferred decisions. Eliminate D19, D20.

**Steps.**

1. `import-bar.md` §"Destination control" and its Decisions table are rewritten:
   the destination is remembered per removable source, defaulting to the first
   library on first sight of that source. State the change explicitly; do not
   leave the old text.
2. `refreshSources` reads `destinationBySource[source.path]` before falling back
   to `fixedAvailable.first`. Settings → Removable Media's Destination column
   becomes truthful.
3. Auto-dismiss: the coordinator publishes a settled-at instant; the ViewModel
   owns one named task that clears the presentation 6 s after a settle that is
   `isFullyClean` **and** whose card is gone. Any new frame cancels it.
4. Update `docs/requirements.md` APP-029 and the ARC row for destination policy.

**Verify.** `script/verify.sh` plus a coordinator test that a re-attached source
gets its remembered destination, and a ViewModel test that a non-clean settle
does not dismiss.

**Rollback.** Revert; the persisted key already exists, so no schema change.

---

### Increment 11 · The design system, app-wide

**Goal.** Eliminate D15 and D16. Owner-confirmed scope: colors, type, and
hierarchy apply everywhere; mockups exist for the import screen only, so
non-import surfaces adopt the **rules**, not a new layout.

**Steps.**

1. Adopt `DesignPalette` in the ten view files that do not use it, starting with
   the chrome: `SidebarView` (DES-022 sidebar value — currently zero callers),
   `MediaGridView`, `CatalogToolbarControls`, `LoupeView`, `CompareView`,
   `PanePresentation`, `MediaChoiceControl`, `SettingsView`, `ContentView`.
2. Assign every user-facing string a level (DES-010–013) and give it the matching
   style. Either DES-013's L4 gets real uses (tile filename, loupe metadata) or
   DES-013 and `DesignPalette.l4` are retired in this PR — no third option.
3. Route the eight `CatalogMediaEmptyState` strings through a pure mapper beside
   the enum, and stop rendering `catalogIncompatible(detail)`'s raw internal
   string as the user-facing message — the same defect plan 0092 fixed for
   `Failed: <problem>`.
4. Curation accessibility (D22): the item — not each of three buttons — carries
   the accessibility value `liked` / `not rated` / `disliked`, announced once
   (DES-068, DES-085). Applies to Grid, filmstrip, Loupe, and each Compare pane.
5. `AllImportsListView` (D23) becomes a real selectable `List` reachable by
   keyboard (DES-080).
6. Harden `script/guard-design-system.sh`: scan `Otos/` not just `Otos/Views`;
   match string literals in any position, not only inside `Text("…")`; enforce
   DES-002's seven styles by rejecting any `.font(.x)` outside the allowed set.
   Extend its self-test for each new rule.
7. Fix everything the hardened guard then finds.

**Verify.** `script/verify.sh`. Per CLAUDE.md §Code Review (C): name each
surface's L1, assign every string a level, check zones and fixed height,
screenshot light and dark plus one grayscale, tab through with no mouse, run once
with Reduce Motion. Cite the `DES-*` IDs satisfied.

**Rollback.** Revert. Increment 11 touches no behavior.

---

### Increment 12 · No dead code, and doc closure

**Goal.** Eliminate D17 and D18, and close the docs.

**Steps.**

1. Reorganization gets its UI entry point back: a `Library` menu command wired to
   `requestReorganizationConfirmation`, enabled by `canRequestReorganization`.
   (`OtosApp.swift` carries a comment showing a `Library` menu once existed; the
   entry point was lost with it. Restoring ~10 lines is the correct call against
   deleting ~1,700 tested, ADR-justified lines.)
2. `reorganizationSummaryText` is rewritten to user vocabulary — it currently
   publishes `relocate`, `no-op`, `blocked`, `components` into a confirmation
   dialog, which increment 11's hardened guard will now catch.
3. Delete `pauseLoupeVideo`, `readyImportPlan`, `contentForTile`,
   `MediaOperationPlanEntry.isBlocked`.
4. `SidebarSelectionPolicy.selectionOnAttach` is either called by the ViewModel's
   attach path or deleted with its tests.
5. `BrowserViewMode.keyboardShortcutDigit` becomes the source of the menu
   shortcuts, or is deleted. One user action, one implementation path.
6. Update `docs/architecture.md` (readiness gate, single presentation writer),
   `docs/requirements.md` (APP-002, APP-029 and the device-source rows), and add
   an ADR for the readiness gate and single-writer presentation rule.
7. Delete this plan.

**Verify.** `script/verify.sh`; re-run the unreferenced-symbol sweep and confirm
it returns only protocol conformances and test seams.

**Rollback.** Revert.

---

## Requirements and ADR changes

| Increment | Document | Change |
| --- | --- | --- |
| 2, 3, 4 | `docs/requirements.md` | Device-source rows gain the readiness gate and the replan trigger |
| 4, 6 | new ADR | `ImportSourceReadiness` and the one-writer presentation rule |
| 5 | APP-029 | Typed systemic failure reaches state G |
| 8 | APP-029 | Batch selection on first asset; renderer honors `primaryEnabled` |
| 9 | `docs/research/` + ADR 0013 | Removable-volume qualification |
| 10 | `import-bar.md`, APP-029 | Per-source destination (**reverses** the current spec text); auto-dismiss |
| 11 | `design-system.md` | Any `DES-*` row changed or retired by the app-wide pass; DES-013 either gains real uses or is retired |
| 11 | APP row for curation | DES-068/DES-085 accessibility values become observable behavior |

## What this plan does not do

- No streaming/growing import totals (owner decision: gate).
- No retry guard or `Try Again`-only affordance (import is idempotent).
- No change to overlay lifecycle: device rows still persist after detach per
  ADR 0008. Increment 4 makes the *plan* refuse to trust them until the live
  device confirms; it does not delete them.
- No `CatalogStore` decomposition. It is 4,190 lines and its boundaries are worth
  revisiting, but nothing in this plan requires it and doing both at once would
  make every regression ambiguous.
- No grid-performance work. One `mainThreadStall bracketedOp=MediaGridViewController.applyStructure
  stallMs=109 latestItems=6848` was observed 2026-08-16 23:11:30, over Apple's
  100 ms threshold. It is real and it is unrelated to import correctness; it wants
  its own measurement-first plan, not a passenger seat in this one.
