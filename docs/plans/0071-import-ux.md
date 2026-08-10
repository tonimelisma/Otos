# Plan 0071 — Import UX and concurrent import architecture

Follows `docs/research/2026-08-09-import-ux-benchmark.md`. Records the owner's decisions
and the architecture that concurrent multi-source import requires.

## 1. Owner decisions captured

1. **Four user-facing states**: *Not ready → Ready to import → Importing → Done*.
2. **"New media" is the vocabulary.** The `copy · preexisting · companion · blocked ·
   skipped packages` string goes away.
3. **The leaked invariant goes** ("Cleanup/eject withheld while blocked…").
4. **Per-card decisions inline; Settings keeps them as defaults.** Editing for one card
   never rewrites the default and never affects another attached card.
5. **The grid is the plan view.** The `Details…` modal sheet goes away.
6. **No per-item selection.**
7. **Eager planning on attach, causing no UI change.** Each source plans independently so
   its plan is ready when selected. Attaching never moves the user.
8. **Determinate progress with Cancel** — where a true denominator exists.
9. **Multiple imports may run concurrently.** Each removable source and each import batch
   shows the status of *its own* import; selecting a different source or batch shows that
   one. The batch view shows each item as it lands.
10. **Destination remembered per removable source**, listed in Settings by last use.
11. **No "choose a destination library" state.** A destination is always defaulted.
12. **Delete-after-import is a checkbox on the pre-import bar**, like eject — no
    completion alert, no destructive styling. Short button titles.
13. **Launch-time selection of a connected card is kept.**
14. **Session overrides discard on detach.**
15. **The sidebar shows the last five import batches plus an expansion affordance.**

## 2. What "blocked" means

Three producers, one meaning: **Otos refuses to author a destination path it cannot prove
is safe.** A refusal to guess, not an error.

- **`.noUsableDate`** — `MediaTransferPlanner.swift:181`. No `captureWallCompact` **and** no
  `contentModifiedAt` (`MediaOperationModels.swift:69`), evaluated per naming bundle, so one
  undatable member blocks its RAW+JPEG siblings. Rare — mtime is nearly always present.
  **Over-block finding:** the bundle is blocked *before* the policy is consulted. Under
  `.none` folder policy and `.original` name policy, `folderPath` returns `""` (`:450`) and
  `baseFileName` returns the source stem (`:465`) — the timestamp is never used, yet the
  bundle is still blocked. Block only when the selected policy needs a date. Stage 1.
- **`.filesystemObservationUnavailable("namespaceUnreadable")`** — `:365`, `:278`. The
  destination folder could not be read, so the candidate's freeness is unproven. The one
  users will actually meet, and on a cloud-synced destination it is **transient**.
- **`.filesystemObservationUnavailable("suffixExhausted")`** — `:331`. All 10,000 suffix
  retries collided. Effectively unreachable.

`skippedPackageCount` counts filesystem bundles the scanner declined to descend
(`CatalogScanner.swift:355`) — on a camera card, essentially always zero.

**Conclusion:** blocked and skipped-package are rare exceptions. They get zero permanent
real estate and surface only when nonzero.

## 3. The pipeline, step by step

Per source **S** with destination **D**. Every phase below is verified in source.

| # | Phase | Owner | What it touches | Byte reads? |
|---|---|---|---|---|
| 1 | **Attach** | `RemovableVolumeMonitor` / `CameraSourceMonitor` → `CatalogStore` | Registers the root; `refreshSources` creates `presentations[S] = .inventory`, seeds `destinationBySource[S]`, marks dirty, schedules a build (`MediaOperationCoordinator.swift:461-503`) | no |
| 2 | **Inventory** | `CatalogScanner` | Enumerates S for filesystem facts only; writes `media_asset` rows; bumps S's occupancy revision | no |
| 3 | **Metadata gate** | `MediaOperationCoordinator` | `.waitingForMetadata(done, total)` iff source kind ≠ MTP **and** some source file has neither wall time nor mtime (`:744-764`) | source only |
| 4 | **Snapshot** | coordinator | Builds `ImportPlanningSnapshot`: `sourceMedia`, `destinationOccupants` (from catalog), policy, both occupancy revisions, generation | no |
| 5a | **Folder set** | `MediaTransferPlanner.destinationFolders` | A suffix changes the file name, never the folder, so the candidate folder set is complete before any occupancy is known (`:23-34`) | no |
| 5b | **Namespace read** | `FilesystemNamespaceSemantics.enumerateNamespace` | Reads exactly those destination folders — directory entries and `lstat` only, explicitly no materialization (`:17-19`) | **no** |
| 5c | **Pure plan** | `MediaTransferPlanner.planImport` | One pass: `reserved = Set(destinationOccupants.keys)`, then per bundle per suffix `decideCandidate` → copy / skipPreexisting / blocked / advanceSuffix, inserting each claim into `reserved` (`:40-72`) | no |
| 6 | **Ready** | coordinator | `readyPlans[S] = plan`; `.ready(totals, generation, skippedPackageCount)` | — |
| 7 | **Import** | `queueImport(S)` → `runExecution` | `executing.insert(S)` (`:288`) | — |
| 8 | **Execute per entry** | `MediaImportExecutor` | journal `beginImportOperation` → copy into a hidden adjacent staging file `.<UUID>.otos-import-staging` in D → **`ExclusivePublication.publish`** → Store settlement (batch, provenance, source digest, overlay reuse) → optional source delete | yes (the copy) |
| 9 | **Cleanup** | executor | `.skipPreexisting` source deletions when allowed (`:308-319`); auto-eject only on complete success with zero blocked | — |
| 10 | **Occupancy bump** | Store → `handlePlanningChange` | Dirties **every** source mapped to D and reschedules its build (`:451-456`) | — |

Two facts from step 8 matter more than anything else in this plan:

**`ExclusivePublication` never overwrites.** It probes `VOL_CAP_INT_RENAME_EXCL` and uses
`renamex_np(RENAME_EXCL)`, else hard-link + unlink, else check-then-act — all three return
`.destinationExists` rather than clobbering (`ExclusivePublication.swift:49-111`). There is
already a hard safety floor under every race described below.

**On `.destinationExists` the entry is dropped silently.** The staging file is removed, the
journal operation is abandoned, a foreign occupant is recorded, and the entry returns
`.skippedForeign` (`MediaImportExecutor.swift:743-758`). The source file is *not* deleted —
deletion only happens on the settled path (`:1086`) — so **no data is lost**. But the file
is not imported, and the user is never told: `skippedForeignCount` appears only in a log
line (`:173`), while the footer's totals come from the pre-execution plan.

## 4. Where concurrent plans conflict

| # | Conflict | Mechanism | Today's outcome |
|---|---|---|---|
| C1 | **Two ready plans reserve the same destination name** | `reserved` is *per plan* (`planImport:44`). Cards A and B both enumerate D before either executes, both see the name free, both claim it | Second publish gets `.destinationExists` → **silently not imported**, counted only in a log |
| C2 | **A ready plan is stale because another import took its name** | A settles → D's occupancy bumps → `handlePlanningChange` dirties B → B replans and advances the suffix | **Self-heals** — but only if the rebuild finishes before the user presses Import on B. Otherwise it degrades to C1 |
| C3 | **Two executions interleave in the same folder** | Staging names are UUID-based, so staging never collides; publication is exclusive | Safe. Reduces to C1 |
| C4 | **Replan storm** | Every per-entry settlement bumps D's occupancy, and `:451-456` dirties every source mapped to D; the `!executing.contains` guard covers only the executing source | B and C replan continuously throughout A's import, each re-enumerating D's namespace |
| C5 | **Catalog/filesystem skew** | `reserved` is seeded from catalog occupants while `decideCandidate` consults the live namespace | Belt and braces; not a cross-plan issue |

C1 is the only real correctness gap, and C4 is the only real performance gap. C2 and C3
are already handled.

## 5. Options for the reservation problem

| | Approach | What changes | Verdict |
|---|---|---|---|
| **O1** | **Leave the collision, make it visible.** Report `.skippedForeign` in the Done summary and offer a re-import | Executor reporting only | Insufficient alone — the user still has to re-run. Keep as the **safety net**, not the solution |
| **O2** | **One shared reservation ledger per destination, owned by the coordinator** | `reservations: [LibraryRootPath: Set<MediaRelativePath>]` holding names claimed by any *ready or executing* plan for D. `planImport` already takes `reserved` as `inout` (`:44,53`), so it is seeded from the ledger instead of only the plan's own occupants. Claims are released on replan, cancel, detach, and failure; on settlement they graduate into real occupancy | **Recommended** |
| O3 | **Serialize planning per destination** — only one plan may be ready per D at a time | Coordinator queue | Rejected — defeats decision 9, whose whole point is several cards ready at once |
| O4 | **Just-in-time naming inside the executor** under a per-destination lock | Plans become intent, not paths | Rejected — pre-flight counts depend on skip-vs-copy classification, which depends on names, so the ready state would lose its numbers. Also moves naming into the executor |

**Recommendation: O2 with O1 retained as the backstop.** O2 makes `reserved` mean what its
name already says — reserved across the app, not within one plan. The planner stays pure and
nonisolated; only the coordinator changes, and the ledger is the coordinator's because the
coordinator is already the single owner of ready plans.

Rules the ledger must satisfy, each testable without UI:

1. A claim is created when a plan reaches `.ready` and released when that plan is superseded,
   cancelled, or its source detaches.
2. A claim is *converted*, not released, when its entry settles — the name becomes real
   occupancy and the next namespace read sees it.
3. Claims are revalidated after every await, against the destination's occupancy revision —
   the existing typed ownership fact, not a generated token (CLAUDE.md).
4. A crash loses the ledger; that is safe, because `ExclusivePublication` remains the floor
   and the next plan re-reads the namespace.

## 6. Planning several sources at once

The planner is **already** safe to run concurrently: `MediaTransferPlanner` is `nonisolated`,
pure, accepts only immutable `Sendable` values, and performs no I/O in `planImport`
(`:9-12`). N sources can plan in parallel today with zero shared mutable state.

What they actually share is two things:

- **The name space of D** → solved by the ledger (§5).
- **The namespace *read* of D** → N cards planning into D each call `enumerateNamespace`
  over overlapping folder sets. The clean fix is not a cache: it is **deduplicating identical
  work at a known-identical revision**. One namespace read per `(destination,
  destinationOccupancyRevision)`, shared by every plan built at that revision, discarded when
  the revision changes. The invalidation key already exists and is already the planner's
  input.

Combined with the C4 fix — during any execution targeting D, suppress destination-driven
rebuilds for all sources mapped to D and coalesce them into one rebuild per source after
settlement — the concurrent case becomes: N pure plans, one shared read, one ledger.

### Do we need a POC?

Split the question honestly:

- **Correctness — no POC.** The ledger and the shared-read dedup are unit-testable against
  the existing pure planner. A test that builds two snapshots for the same destination and
  asserts disjoint claims is a better artifact than a POC.
- **Cost — yes, a measurement, not a POC.** The open empirical question is what
  `enumerateNamespace` costs on a real cloud-synced library (the 25k-asset OneDrive root in
  `docs/research/2026-08-01-…`) and how often C4 currently fires per import. That determines
  whether the shared read is worth building at all, per CLAUDE.md's measure-before-optimizing
  rule. Instrument first: `op=plan.namespace.enumerate` with folder count, entry count, and
  elapsed; `op=plan.rebuild` with its trigger. Then decide.

**Recommended order:** C4 fix (pure win, no new structure) → instrument → ledger → decide on
the shared read from the numbers.

## 7. `waitingForMetadata` is source-side only

Verified: the gate reads `snapshot.sourceMedia` and fires only when a source file has
**neither** `captureWallCompact` **nor** `contentModifiedAt`, and never for MTP sources
(`MediaOperationCoordinator.swift:744-760`). The destination is only *enumerated* —
directory entries and `lstat`, with `FilesystemNamespaceSemantics` documenting that byte
reads are never triggered and cloud placeholders are never materialized (`:17-19`). **A
dataless destination cannot block planning**, which is the required property.

Consequence for the UI: because mtime is almost always present, `waitingForMetadata` is
usually satisfied immediately and its `done/total` ratio is nearly always `total/total`.
Basing the "not ready" progress bar on it — as an earlier revision of this plan did — was
wrong.

## 8. How "not ready" is actually shown

The status must never require scrolling. The grid is the plan view, but the grid scrolls, so
**the grid is not the status surface**. Status lives in exactly two fixed places:

1. **The sidebar row for that source** — the only surface visible when the card is not
   selected, and the only way to see several cards' states at once (decision 9). An
   indeterminate ring while preparing; a count when ready; a determinate ring while importing.
2. **The pre-import bar** for the selected source — pinned to the bottom, never scrolling
   with the grid.

Inside the bar, honest denominators only:

| Phase | Denominator available? | Shown |
|---|---|---|
| `inventory` | No — the file count is unknown until enumeration ends | `Finding items… 412 found` (rising count, no bar) |
| `waitingForMetadata` | Yes, but nearly always already satisfied | `Reading dates… 412 of 1,204` |
| `planning` 5b | Yes — the folder set is computed before any read | Determinate bar over folders read |
| `planning` 5c | Yes — bundle count is known | Folded into the same bar |
| `executing` | Yes — items and bytes | `412 of 1,204 · 1.1 GB of 3.2 GB` + Cancel |

HIG: prefer determinate, never fake a ratio, keep it moving, avoid vague labels, consistent
location.

## 9. What the user must always know, and where it is said

Four facts, and each has exactly one owner in the UI:

| Fact | Owner |
|---|---|
| how many new items will be copied | status line |
| whether anything will be removed from the card | the **delete checkbox, including its count in the label** |
| whether the card will be ejected | the eject checkbox |
| whether anything needs attention | status line, only when nonzero |

The earlier revision overloaded the button because it treated the button as self-describing
in isolation. It is not in isolation — it sits beside its own checkbox. Putting the scope in
the checkbox label resolves this without a long button:

> ☑︎ **Delete all 212 items from the card after importing**
> ☐ Eject the card after importing

The count in the label updates live, so the consequence is stated by the control that causes
it. The button then stays short.

| Scenario | Status line | Button |
|---|---|---|
| 12 new, 200 already imported | `12 new · 3.2 GB — 200 already in your library` | `Import` |
| 12 new, 3 blocked | `12 new · 3.2 GB · 3 need attention` | `Import` |
| 0 new, 212 already imported, delete **off** | `Nothing new — all 212 items are already in your library` | `Import` (disabled) |
| 0 new, 212 already imported, delete **on** | `Nothing new — all 212 items are already in your library` | **`Delete from Card`** |
| Card is empty | `This card is empty` | `Import` (disabled) |
| Everything blocked | `Nothing can be imported yet · 5 need attention` | `Import` (disabled) |

`Delete from Card` is still one intent — `queueImport` on a plan whose copy count is zero —
so there is no second implementation path. No destructive styling: per HIG, a deliberately
chosen destructive action does not get the red treatment, and the checkbox above it is the
deliberate choice.

**Open question:** whether the button should carry the count (`Import 12 New Items`, the
Capture One pattern) or stay bare (`Import`) with the count one line above. Capture One's
button sits far from its counts; here they are adjacent. Recommended: bare, per decision 12's
preference for short titles.

## 10. Grid badges — exactly two

With status in fixed chrome and no per-item selection, only two badges earn their place:

- **Already in your library** — a subdued check. This is per-item information available
  nowhere else, and it is what makes the word "new" honest.
- **Needs attention** — on blocked tiles. It earns its place only as the *target* of the
  status line's jump affordance: you need to recognize the item when you arrive at it.

Nothing else. No companion badge, no per-tile destination path, no disposition text — those
were the `Details…` sheet's job and the sheet is being deleted.

Badges compose *over* tile content and never replace it. **Open decision:** if the AppKit
tile cannot compose a badge without touching the thumbnail paint path, the badge layer needs
its own design first — the no-blank-grid invariant outranks this entire plan.

## 11. Import batches in the sidebar

Precedent: **Photos has one `Imports` sidebar item**, and the content area groups by import
session date. Capture One keeps the last ten import collections. HIG says: "Group hierarchy
with disclosure controls if your app has a lot of content", and "in general, show no more
than two levels of hierarchy in a sidebar. When a data hierarchy is deeper than two levels,
consider using a split view interface that includes a content list between the sidebar items
and detail view."

| | Approach | Verdict |
|---|---|---|
| **A** | **Last 5 rows + an `All Imports…` row.** Selecting it puts a browsable list of every batch — date, item count, source — in the content area. Choosing one there navigates the content area to that batch | **Recommended.** Matches HIG's "deeper than two levels → content list" and Photos' precedent |
| B | Disclosure triangle on the `Imports` header expanding every batch inline | Rejected — HIG endorses disclosure for space, but hundreds of inline rows is the thing it is trying to prevent |
| C | An `Older…` submenu | Rejected — not a native sidebar idiom |

Rule for the selected older batch: the sidebar shows **the last five, plus whatever is
currently selected**. Selecting a batch from `All Imports…` adds it as a sixth, highlighted
row for as long as it stays selected, then it drops away. This keeps the sidebar bounded
without ever selecting something invisible.

Every batch is retained (decision 15 caps display, not storage), consistent with overlay
lifecycle: overlay for an item is purged only when the item is proven deleted.

## 12. Per-source status with concurrent imports

Decision 9's requirement — each source and each batch shows *its own* status — is already how
the coordinator is shaped: `presentations`, `readyPlans`, `buildTasks` and `executing` are all
keyed by source. `executing` stays a `Set`. What must change:

- The sidebar row for a **source** shows that source's phase.
- The sidebar row for a **batch** shows that batch's progress; the batch view lists items as
  they settle (they already appear per-entry via Store settlement).
- The pre-import bar belongs to the **selected source**; the progress bar belongs to the
  **selected batch**. Selecting card A during card B's import shows A's pre-import bar and no
  progress bar — B's progress is on B's batch row and in B's batch view.

## 13. What this deletes

`ImportPlanOverlay.swift` and the `Details…` button · `ImportPlanFooter.totalsText` ·
`ImportPlanFooter.policyText` · the 11 prose cases of `readinessText` · the
`.waitingForDestination` user-facing state · `ImportPlanDetailReader` if nothing else consumes
it (confirm, do not assume). Every deletion removes *display*, not capability.

## 14. Stages

- **Stage 1 — planner correctness.** Block on `.noUsableDate` only when the selected policy
  needs a date (§2).
- **Stage 2 — churn (C4).** During any execution targeting D, suppress destination-driven
  rebuilds for all sources mapped to D and coalesce one rebuild per source after settlement.
- **Stage 3 — instrumentation.** `op=plan.namespace.enumerate` (folders, entries, elapsed) and
  `op=plan.rebuild` (trigger). This is the evidence base for §6's cost question.
- **Stage 4 — reservation ledger (C1)**, with `.skippedForeign` surfaced in the Done summary as
  the backstop.
- **Stage 5 — destination identity.** Device-identity-keyed persistence, the three-step default,
  removal of `.waitingForDestination`, Destination column + Last Seen sort in Settings.
- **Stage 6 — four-state presentation.** Coordinator-owned presentation type; sidebar ring;
  honest denominators per §8; Cancel.
- **Stage 7 — per-source session overrides.** `sessionOptions` seeded from `ImportPreferences`,
  discarded on detach; the two checkboxes inline with live counts in labels.
- **Stage 8 — grid badges, delete the sheet** (§10).
- **Stage 9 — status/button matrix** (§9).
- **Stage 10 — batch sidebar** (§11) and per-batch progress (§12).
- **Stage 11 — shared namespace read**, only if Stage 3's numbers justify it.
- **Stage 12 — enrichment/planning separation.** Planning needs no hashes (ARC-046A matches
  size and mtime); hold removable-source content hashing until that source's plan is ready.

## 15. Non-goals

Tokens in naming, secondary destinations, metadata templates, import presets, per-item
selection, post-copy byte verification, Photos-style grouped import sections, and any change
to the compare-pair meaning of grid selection (APP-021).

**Explicit non-claim:** Otos does not verify destination bytes. The XXH3-128 digest at
settlement is the *source* content hash reused as overlay
(`CatalogStoreImportJournal.swift:139-153`). The UI must never say "verified".

## 16. Open decisions

1. **Button count** — bare `Import` (recommended) or `Import 12 New Items`?
2. **Badge composition** — can the AppKit tile compose a badge without touching the thumbnail
   paint path? Blocks Stage 8 if not.
3. **Shared namespace read** — build it, or leave N independent reads? Decide from Stage 3.
