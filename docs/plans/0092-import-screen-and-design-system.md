# 0092 — Import Screen Redesign And Design-System Adoption

Rebuild the import status surface to `docs/design/import-bar.md`, and make
`docs/design/design-system.md` a rule set the repo actually enforces rather than a
document someone remembers to read.

Written to be followed in order by someone who has not seen the design work. Each
increment is a separate PR with its own Definition of Done. Do not start an
increment before the one above it has landed on `main` — the later ones read facts
the earlier ones publish.

## Read first

| Document | Why |
| --- | --- |
| `docs/design/design-system.md` | The `DES-*` rules. Every UI decision below cites one. |
| `docs/design/import-bar.md` | The screen spec: layout, seven states, every string, twelve journeys. **Copy is final** — implement strings verbatim. |
| `docs/design/hig-validation.md` | Why the contrast and control rules are what they are, plus the re-test procedure at the foot. |
| `AGENTS.md` → Code Review (C) | The five-check design pass every one of these PRs must run. |

The `.dc.html` mockups live in `docs/design/mockups/`. The markdown is authoritative;
where they disagree, the markdown wins.

## Where the design and the code disagree

Found by auditing the spec against the source. **These are the traps.** Each is
already recorded in the spec at the point where it bites; they are collected here so
nobody rediscovers them the hard way.

| # | Fact | Evidence |
| --- | --- | --- |
| 1 | The footer derives every user-facing string inside the view. It is not passive, and it is why the copy rewrite touches one file. | `ImportPlanFooter.swift:232-333` |
| 2 | `failed(problem: String)` carries raw internal tokens (`snapshotUnavailable`, `namespaceLeaseUnavailable`, …) and the footer prints them as `Failed: <problem>`. Published internal vocabulary, forbidden by DES-035/DES-039. | `MediaOperationCoordinator.swift:340,489,780,812,855`; `MediaImportExecutor.swift:137,152,169` |
| 3 | State G wants `The card was removed` and `Summer Photos isn't available`. **Neither has a producer.** Pulling a card removes the session and the row instead of failing. Those producers are work, not an assumption. | as above |
| 4 | `blocked` never means "can't be read". It means `noUsableDate` (readable, but no date to file it under) or `filesystemObservationUnavailable` (a destination problem). An earlier draft's `3 items can't be read` was a fabricated diagnosis. | `MediaOperationModels.swift:109-112`, `MediaTransferPlanner.swift:206,305` |
| 5 | `presentationsStream()` is `.bufferingNewest(1)` — a dropping buffer. Anything edge-triggered off it (such as "move the selection when execution starts") can silently never fire. Carry facts as state on the presentation instead. | `MediaOperationCoordinator.swift:138` |
| 6 | `MediaTransferPlanner` mints a **throwaway** `ImportBatchID()` into every plan. The real one is minted at execution start. Reading `plan.mode`'s batch would select a row that never exists. | `MediaTransferPlanner.swift:77` vs `MediaImportExecutor.swift:141` |
| 7 | Destination selection today is *this device's last destination → last used anywhere → first available*, and `fixedAvailable` is **never sorted**, so even the fallback is store order rather than anything the user sees. Owner decision: first library, always. | `MediaOperationCoordinator.swift:650,711-718` |
| 8 | There is no user-controlled library order to be "first" in. Roots are fetched `ORDER BY path`, then re-sorted by display name for display. | `CatalogStorePersistence.swift:502`, `CatalogWindowPolicy.swift:10-18` |
| 9 | The sidebar shows a progress indicator for every import state unconditionally, while the footer shows the same status. This is the duplication DES-040 forbids. | `SidebarView.swift:104-129` |
| 10 | `MediaOperationProgress` has counts and bytes but **no time base**, so `about 40 seconds left` cannot be computed from it. | `MediaOperationModels.swift:194-199` |
| 11 | DES-021's 60%/45% text values cannot be expressed with `.secondary`/`.tertiary`. They need a named palette, which DES-020 was rewritten to permit. | `design-system.md` DES-020, DES-021 |
| 12 | `LoupeView.swift:82` uses `.font(.system(size: 60))`, the repo's only DES-002 violation. Fix it when the guard in Increment 1 starts failing on it. | `LoupeView.swift:82` |

Two things the spec claimed that the code already does correctly, so **do not
"fix" them**: `beginExecutionIfPossible` does stay Ready on a zero-copy plan when
delete is requested (`MediaOperationCoordinator.swift:319`), and the coordinator does
mark the session dirty after settlement and re-plan, which is what makes state F
derived rather than remembered (`MediaOperationCoordinator.swift:497`).

## Increment 0 — the design docs (this PR)

Landed with this plan. Merged `design-system.md` three-way rather than overwriting it
(the handoff forked before the curation commit, so a copy would have deleted
`DES-066/067/068`, `DES-076`, `DES-085`); renumbered the handoff's day-sections rule
to `DES-069` to clear a collision with curation; corrected the internal
contradictions and the code-claims listed above; folded `INSTALL.md` into
`AGENTS.md` → Code Review (C) and deleted it.

## Increment 1 — make the rules enforceable

Cheap structural checks, in the spirit of `script/requirements-authority-check.sh`.
Without these, the design system decays quietly.

**Files:** `script/guard-design-system.sh` (new), `script/verify.sh`,
`script/dod-report.sh`, `.github/workflows/*` (add to the text-hygiene job).

1. Write `script/guard-design-system.sh` with two checks, each an `rg` invocation
   plus an allowlist file:
   - **No font or colour literals under `Otos/Views/`** (DES-001, DES-020): fail on
     `.system(size:`, a hex literal, `Color(red:`, `NSColor(red:`. Today this fails
     on exactly one line, `LoupeView.swift:82` — fix that line in this increment
     rather than allowlisting it.
   - **No domain nouns in user-facing strings** (DES-035, DES-039): fail on `plan`,
     `disposition`, `companion`, `preexisting`, `blocked`, `inventory`, `replan`,
     `execution`, `queued` appearing inside a `Text(` literal.
2. Call it from `script/verify.sh` beside the other guards.
3. Add one line to `script/dod-report.sh`: *"UI change: cites the DES-* rules it
   satisfies, and was reviewed in light and dark."*

**Done when:** `script/verify.sh` is green, and reverting the `LoupeView` fix makes
the new guard fail.

## Increment 2 — the palette

DES-021 and DES-022 are the only two places Otos defines its own colour values, and
both are marked deviations. They need one home before any view can use them.

**Files:** `Otos/Views/DesignPalette.swift` (new — or `Otos/Support/`, but it is
view-facing), `Otos/Views/` consumers.

1. One type holding the DES-021 text values (label 85%; L3 60%; L4 45%) and the
   DES-022 chrome values (light content `#FFFFFF`, sidebar `#FAFAFB`, bar `#FBFBFC`;
   dark `#1C1C1E` / `#242426` / `#2A2A2C`) and the DES-023 hairline, each with both
   appearances, resolved through the environment colour scheme.
2. Honour DES-084: under Increase Contrast, hairlines revert to the system separator
   and L4 is promoted to L3's value.
3. The guard from Increment 1 must allowlist this one file, and only this file.

**Done when:** a view can express every DES-021/022/023 value without writing a
literal, and `hig-validation.md`'s measured ratios are reproduced by the values
shipped.

**Note:** the contrast numbers in `hig-validation.md` were computed by the designer,
not measured on a build. Re-measure with Accessibility Inspector once a surface uses
them, and correct that table if they differ.

## Increment 3 — publish the facts the bar needs

Pure model and coordinator work, no UI. Do this before the footer rewrite; doing it
after means writing the footer twice.

**Files:** `Otos/Models/MediaOperationModels.swift`,
`Otos/Services/MediaOperationCoordinator.swift`,
`Otos/Services/MediaImportExecutor.swift`.

Work from the table in `import-bar.md` → *What the presentation must carry*:

1. **Typed failure reason.** Replace `failed(problem: String)` with an enum whose
   cases are causes a user can act on — source removed, destination unavailable, out
   of space — plus one case for the unexpected, whose detail goes to the log and
   whose clause names no cause. Add the two missing producers (trap #3).
2. **Attention items.** Carry the blocked entries' `MediaAssetID`s and their reason,
   not just `blockedCount`, so `Show them` can select them and so the clause can name
   the real cause (trap #4).
3. **Batch ID** on the presentation, present on every frame from execution start
   onward — as state, never as an event (trap #5, trap #6).
4. **Remaining time.** Give `MediaOperationProgress` a time base and compute
   bytes-over-elapsed for the current run. Per DES-032 it is hedged (`about 40
   seconds left`) and **omitted** until the rate is meaningful — never guessed.
5. **Destination display name**, **card-still-exists**, **copied-just-now scoped to
   this attachment**, and a **fully-clean** flag covering skips, failures and
   attention items (the auto-dismiss gate).

**Tests:** `OtosTests/MediaOperation*Tests.swift`. Assert observable boundaries — a
failure maps to its typed reason; a blocked entry surfaces its ID and reason; the
batch ID survives a dropped intermediate frame; remaining time is absent at the start
of a run. Do not assert on string spellings here; that is Increment 5's mapper.

**Done when:** every row of the presentation table is answered "yes", and no user-facing
string exists in the model layer.

## Increment 4 — user-ordered libraries

Owner decision: **the first available library is the import destination, always.**
That is only honest if the user controls which library is first, so order stops being
derived and becomes a stored property of the root.

**Files:** `Otos/Stores/CatalogStorePersistence.swift` (migration),
`Otos/Stores/CatalogStore.swift`, `Otos/Services/CatalogWindowPolicy.swift`,
`Otos/Views/SettingsView.swift`, `Otos/ViewModels/CatalogWindowViewModel.swift`,
`Otos/Services/MediaOperationCoordinator.swift`.

1. **Schema.** Add `sort_index INTEGER NOT NULL` to `library_root` in a new
   migration, backfilled in the current display order so nothing moves on upgrade.
   New libraries append at `max+1`. Order lives on the root row — never a parallel
   list in preferences, which would drift when a root is removed.
2. **Read path.** `fetchCatalog` orders by `sort_index`.
   `CatalogWindowPolicy.sortLibraries` stops sorting library roots and preserves
   stored order; removable sources keep their own rule. **This changes sidebar
   ordering** — expect `CatalogProjectionTests#windowStateSortsLibrariesAndAssets`
   and `SidebarSelectionPolicyTests` to need updating, and read them before you start.
3. **Settings UI.** Drag to reorder, plus `Move Up` / `Move Down` in the row context
   menu and `⌘↑` / `⌘↓` — drag alone is not completable from the keyboard (DES-080).
   All three call one `moveLibrary(from:to:)` intent (one action, one path).
   If SwiftUI's `.onMove` misbehaves on the Xcode 27 baseline, fall back to an
   `NSTableView` reorder; verify this early, it is the only unknown in this increment.
4. **Destination rule.** Delete `destinationByDeviceIdentity` and
   `lastUsedDestination` and the persisted device mapping they write. The default
   destination becomes the first available library in stored order, recomputed each
   time the surface appears for a source. A per-run pop-up choice applies to the
   attached session and is not remembered across attachments.

**Consequence to expect, and it is intended:** reordering changes the default
destination, so a card attached at the time re-plans against the new first library
and its counts change.

**Done when:** the first row under **Libraries** in the sidebar is what `Copy into`
shows, dragging a library to the top changes it, and the whole reorder is performable
with the keyboard alone.

## Increment 5 — rebuild the bar

The main event. Everything above exists so this increment is only layout, mapping and
copy.

**Files:** `Otos/Views/ImportPlanFooter.swift`, one new pure mapper, `ContentView.swift`.

1. **Extract the mapper first.** One pure, `Sendable`, testable function from
   `MediaOperationSourcePresentation` to a drawn-state value: which of the seven
   states, and the exact strings. It holds all copy. It is not a view, has no
   SwiftUI import, and is where the state inventory table becomes code.
2. **Rebuild the view as three zones** — *what* / *choices* / *the act*, left to
   right, one fixed height across every state (DES-018, DES-053). The current
   three-row stack is the layout defect. The view renders the mapper's output and
   calls intents; it derives nothing.
3. **The seven states, A–G**, exactly as drawn in the spec, including the C variants
   (nothing-new, empty card), E's cancelling variant, and F's attached/gone split.
   Height is constant: a state with an empty middle zone holds blank space rather
   than shrinking. The two permitted omissions are where a control's *subject* no
   longer exists — the empty card and the card-gone case.
4. **Every string verbatim** from the spec's state sections and copy-rewrite table.
   Byte figures per DES-005A; anything that ticks is `.monospacedDigit()` (DES-005).
5. **Controls** per DES-054: destination as a pop-up button with the introductory
   label `Copy into` and no `Choose…` placeholder; `Eject the card` and `Erase the
   card` as checkboxes pre-set from Settings, changing this run only (DES-027A).
6. **The erase-only alert**, with its second sentence stated only when the plan proves
   every item is already in the destination.
7. **Motion** per DES-070–075: enter slides up 24 pt with fade over 0.35 s; between
   states cross-fade the left block and swap the right button in place; the completion
   checkmark scales from 0.6 with overshoot; all of it becomes a 0.15 s cross-fade
   under Reduce Motion.
8. **Accessibility** per DES-080–084: tab order left to right, Return imports, Escape
   cancels during E, L1 announced as a live region on state change only.

**Tests:** the mapper is the oracle — assert state and strings for each row of the
state inventory, including every variant. `OtosTests/` gains an
`ImportBarPresentationTests`. Do not test the view's layout by reading source text;
that is forbidden and CI guards it.

**Done when:** the state inventory table and the copy-rewrite table are both fully
covered by mapper tests, and no domain noun survives the Increment 1 guard.

## Increment 6 — one owner for status

**Files:** `Otos/Views/SidebarView.swift`, `Otos/ViewModels/CatalogWindowViewModel.swift`.

1. **Remove the duplication.** While the bar is on screen for an operation, neither
   the removable row nor the batch row shows an indicator.
2. **When the selection is elsewhere**, exactly one row shows a 32 pt determinate
   bar: the batch row once the batch exists, the removable row before that.
3. **Move the selection once**, at execution start, to the new batch — reading the
   batch ID off the presentation as state (Increment 3), with the two rules from the
   spec: only if the user has not navigated away, and never twice.

**Done when:** an import in progress is reported in exactly one place at any moment,
and journeys J1, J2 and J10 hold.

## Increment 7 — grid day headers (DES-069)

**Do this last, and treat it as its own plan if it grows.** It is the only increment
that touches the AppKit grid, which owns the no-blank invariant (APP-015) and the
structural-apply machinery (ARC-023). The grid is currently one section
(`MediaGridPresentation.swift:41-61`); day sections mean supplementary header views,
a section-aware data source, and a pinned-header layout.

Read `docs/adr/0006-catalog-grid-rendering.md` before touching anything, and treat
"no painted thumbnail ever blanks" as the acceptance bar, not a nice-to-have.

## Requirements and ADRs

**`docs/requirements.md`** — update in the same PR as the behavior:

- `APP-001` — the claim list changes when the footer does.
- `APP-002` — sidebar ordering becomes user-owned (Increment 4); status ownership
  changes (Increment 6).
- `APP-003` — Settings gains library reordering (Increment 4).
- New row for the import bar's user-facing states and copy (Increment 5), citing
  `DES-030`, `DES-053`, `DES-054`.

**ADRs to write:**

- **0023 — User-ordered libraries and the deterministic import destination.** Owns
  the decision to store order on the root, drop the device/last-used heuristics, and
  make the first library decisive. Rejected alternatives: a default-library flag
  (hides the decisive fact in Settings), an ordered path list in preferences (state
  duplication, drifts on removal).
- **0017** (media operation ownership) needs a revision, not a new ADR, when the
  typed failure reason and the enriched presentation land in Increment 3.

## Risks

- **Increment 4 changes sidebar order**, which several existing tests assert. Read
  them first; expect to update, not delete, them.
- **SwiftUI `.onMove` on macOS** is the one genuine unknown. Verify it in the first
  hour of Increment 4 so the `NSTableView` fallback is a planned branch, not a
  surprise.
- **Increment 7 is the one that can regress a shipped invariant.** Everything else is
  additive or confined to the footer.
- **Contrast values in `hig-validation.md` are computed, not measured.** Treat the
  table as a claim to verify in Increment 2, not as evidence.
