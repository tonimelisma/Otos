# Plan 0071 — Import UX and concurrent import architecture

Follows `docs/research/2026-08-09-import-ux-benchmark.md`. Records the owner's decisions
and the architecture that concurrent multi-source import requires. The 2026-08-09 design
review verified every code claim in this plan against source, adopted its findings (§17),
and revised §5, §8, §9, §12, §13, and the stages accordingly. Accessibility is part of the
plan, not a follow-up (§18).

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
16. **Each source reads the destination namespace independently.** No shared or deduplicated
    read — the operation is directory entries plus `lstat` over a bounded folder set with no
    byte reads, and duplicating it across a few attached cards does not justify the machinery.
17. **No per-tile import badges, in either grid.** The progress bar is the progress
    indicator; tiles show media, not plan state (§10).
18. **The reservation ledger acquires claims atomically at publish time, not at ready
    time.** Concurrent builds stay fully parallel; each build seeds from the ledger, and the
    conflict check plus registration happen in one synchronous on-actor region against the
    *current* ledger. A conflicting build re-dirties and rebuilds; it never evicts a
    registered claim (§5).
19. **Card deletion and eject stay withheld while any blocked entry remains — and the Done
    state says so when the rule fires.** Decision 3 removed the leaked invariant *sentence*;
    it did not remove the invariant. The checkbox label never carries a count the rule will
    withhold (§9).
20. **Cancel is an owned intent.** The coordinator holds the executing source's executor so
    the bar's Cancel reaches it (§12).
21. **Byte-level import progress.** The executor aggregates in-flight copyfile offsets plus
    settled bytes into `MediaOperationProgress`, gated to bounded emission frequency, so one
    large file keeps the bar moving (HIG "keep progress indicators moving"). Implemented in
    this increment (§8, §17 F9).
22. **Accessibility is a requirement of every control this plan introduces** — VoiceOver,
    keyboard, no color-only state, Reduce Motion (§18).

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
  The metadata gate has the same blind spot, plus a second one: `shouldWaitForMetadata`
  (`MediaOperationCoordinator.swift:742-770`) waits on dates the selected policy may never
  use, and nothing re-wakes planning when enrichment supplies them — enrichment bumps
  neither occupancy nor plan revision (`CatalogStore.swift:1139`), so the state exits only
  via Import-press, an unrelated occupancy bump, or a preference change. Stage 1 makes the
  gate policy-aware and gives it a resume path (§17 F3).
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
already a hard safety floor under every race described below. Review caveat: the probe does
not actually parse the capability bit, and a non-`EEXIST` rename failure surfaces as
`.failed`, not `.destinationExists` — §17 F6.

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

### The race the first revision missed (2026-08-09 review)

The first revision created claims when a plan *reached* `.ready`, after the off-actor build.
But §6 runs builds in parallel, and two builds for the same destination seed from the same
ledger snapshot and the same namespace read, compute overlapping claims, and both publish —
the publish-time revalidation checked occupancy revisions only, and the destination's
occupancy did not change. Registering claims at ready time is too late; the acquisition
itself must be atomic (decision 18).

### Shape

`claimsBySource: [LibraryRootPath: Set<MediaRelativePath>]` on the coordinator — every
`.copy` final destination plus every companion destination of a live plan, keyed by source,
unioned over `destinationBySource[S] == D` on demand. N is the number of attached cards; a
second destination-keyed index is more bookkeeping than it saves. The ledger is in-memory
process state: never persisted, never consulted by the executor, never visible to UI, never
a second truth about D — the filesystem still wins any disagreement.

### Invariants

- **I1 Exclusivity.** No two live (ready or executing) plans for one destination hold
  overlapping claims. This is what makes C1 unrepresentable.
- **I2 Correspondence.** Every claim belongs to exactly one live plan and dies with it —
  supersede, detach, cancel, failure, execution end. Bounded size, no leaks.
- **I3 Conversion by death, not per-entry release.** Publication precedes settlement and
  settlement is durable, so when an execution ends — any outcome — every published name is
  already observable on disk and every unpublished name never will be. One release point per
  plan death keeps I2 trivially auditable.
- **I4 Atomic acquisition.** Conflict check plus registration happen in one synchronous
  on-actor region — at publish time, against the *current* ledger, never against the
  build-start snapshot.
- **I5 The ledger never weakens the floor.** Claims cover only names proven free at build
  time. If the disk changes underneath a claim, `ExclusivePublication` still refuses and the
  O1 backstop surfaces it. A crash loses the ledger; the next plan re-reads the namespace.

### Mechanics

1. **Seed.** Build start hands the task `ledgerClaims(D)`; `planImport` gains
   `additionalReserved: Set<MediaRelativePath>`, unioned into `reserved` at
   `MediaTransferPlanner.swift:44`. `decideCandidate`'s first check (`:359-363`) already does
   the right thing with a ledger claim: advance the suffix, never collapse.
2. **Publish-time conflict check.** The existing synchronous revalidation region
   (`MediaOperationCoordinator.swift:685-708`) gains one condition:
   `planClaims ∩ ledgerClaims(D, excluding self) == ∅`. Empty → release the source's old
   claims, register the new ones, publish `.ready`. Nonempty → the existing stale path
   (`:704-707`): discard, `dirty.insert`, rebuild — the retry seeds from the updated ledger
   and suffixes past the winner. Convergence: the actor serializes publish regions, every
   retry sees strictly more seeded claims, a retry never evicts a registered claim, and
   suffix space (10,000) bounds it.
3. **Release points.** Supersede: in the same region that registers the new plan. Detach:
   beside `readyPlans.removeValue` in `refreshSources` cleanup (`:504-517`). Execution end:
   after `applyExecutionResult`, all outcomes, and *before* the post-execution rebuild is
   scheduled (`:336-337`) so that rebuild seeds from disk truth.
4. **C4 interaction.** The coalesced post-settlement rebuilds (Stage 2) seed against claims
   that include the executing plan's not-yet-published names — strictly better than disk
   alone.

### Rejected variant: build-slot lock per destination

Serialize builds per D and register claims at ready: correct, and no retry path — but it
serializes the independent namespace reads decision 16 accepted (card B waits behind card
A's slow cloud enumeration) and needs per-destination queue machinery. The conflict check is
one set intersection and the retry reuses an existing code path.

### Tests (all UI-free)

- Pure planner: a second snapshot seeded with the first's claims yields disjoint
  destinations with advanced suffixes.
- Coordinator: two sources, one destination, colliding file names → both `.ready` with
  disjoint final paths (drives the publish-time conflict).
- Lifecycle: claims empty after supersede / detach / execution end; a replan after release
  collides with nothing.

## 6. Planning several sources at once

The planner is **already** safe to run concurrently: `MediaTransferPlanner` is `nonisolated`,
pure, accepts only immutable `Sendable` values, and performs no I/O in `planImport`
(`:9-12`). N sources can plan in parallel today with zero shared mutable state.

What they actually share is two things:

- **The name space of D** → solved by the ledger (§5).
- **The namespace *read* of D** → N cards planning into D each call `enumerateNamespace` over
  overlapping folder sets. **Owner decision: leave N independent reads.** The read is
  directory entries plus `lstat` over a small, bounded folder set with no byte reads, so
  duplicating it across a handful of attached cards is not worth the machinery. This is the
  measure-before-optimizing rule applied in its cheaper direction: do not build the
  deduplication until something proves the simple path insufficient.

Combined with the C4 fix — during any execution targeting D, suppress destination-driven
rebuilds for all sources mapped to D and coalesce them into one rebuild per source after
settlement — the concurrent case becomes: N pure plans, N independent reads, one ledger.

### Do we need a POC?

No. The remaining work is correctness work, and it is unit-testable against the existing pure
planner: a test that builds two snapshots for the same destination and asserts disjoint claims
is a better artifact than a prototype. With the shared read declined, there is no longer an
open empirical question gating a design choice, so no benchmark is a prerequisite either.

Instrumentation still lands — `op=plan.namespace.enumerate` (folder count, entry count,
elapsed) and `op=plan.rebuild` (trigger) — but as ordinary observability under CLAUDE.md's
"every meaningful path is observable before it is done", and as the evidence that the C4 fix
actually stopped the rebuilds. It is no longer a decision input.

**Recommended order:** C4 fix (pure win, no new structure) → instrument → ledger.

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
| `planning` 5b/5c | Yes, but the phase is one bounded enumeration plus one linear pass — worst case ~461 ms measured (ADR 0019) | One indeterminate `Preparing…`. A determinate bar over a sub-second phase flashes, and `enumerateNamespace` has no progress callback to drive it. Revisit only if `op=plan.namespace.enumerate` proves it slow (§17 F10) |
| `executing` | Yes — items and bytes | `412 of 1,204 · 1.1 GB of 3.2 GB` + Cancel. Bytes advance continuously during a single large copy (decision 21, §17 F9) |

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

**Wiring the delete-only path (2026-08-09 review).** The intent is currently dead:
`beginExecutionIfPossible` returns early when `copyCount == 0 && companionCopyCount == 0`
(`MediaOperationCoordinator.swift:231-244`), so execution never starts and the executor's
skip-preexisting source-deletion loop (`MediaImportExecutor.swift:308-319`) never runs.
Stage 9 lifts that guard for delete-requested runs, including the Done state of an execution
that publishes nothing and creates no batch (§17 F1).

**The blocked-withhold rule keeps its voice (decision 19).** Card deletion and auto-eject
stay withheld while any blocked entry remains (`MediaImportExecutor.swift:150`,
`MediaOperationCoordinator.swift:358-362`, ARC-049) — erasing a card whose import did not
fully complete is how photos die. Decision 3 removed the *sentence* that stated the rule,
not the rule, so the Done state states the outcome when it fires: "12 imported · 3 left on
the card — deletion and eject skipped until everything imports." The checkbox label never
carries a count the rule will withhold: with blocked entries it reads "Delete items from the
card after importing"; only when nothing is blocked does it carry "all N" (§17 F2).

**No destructive default action.** The Import button keeps
`.keyboardShortcut(.defaultAction)` (`ImportPlanFooter.swift:80`) only while it is the
additive `Import`. The delete-only `Delete from Card` variant drops the shortcut: in the
re-inserted-card scenario — all 212 preexisting, delete seeded on from Settings — Return
must not become card-wipe by muscle memory (§17 F7).

**Blocked is never a dead end.** When everything is blocked and `Import` is disabled, the
transient `namespaceUnreadable` cause has no natural re-wake — no occupancy change will
come, and the user cannot press Import. `N need attention` gets an explicit retry (rebuild
this source now), and selecting a blocked source re-validates its plan (§17 F5).

Because tiles carry no badges (§10), `N need attention` is not a link to anywhere — it is
self-explaining. Choosing it reveals the cause in plain language, and the fix where one
exists: "Otos couldn't read the destination folder for 3 items. This is usually temporary."
/ "3 items have no date. Set folder naming to None to import them." Never a raw disposition
kind, never `namespaceUnreadable`.

**Open question:** whether the button should carry the count (`Import 12 New Items`, the
Capture One pattern) or stay bare (`Import`) with the count one line above. Capture One's
button sits far from its counts; here they are adjacent. Recommended: bare, per decision 12's
preference for short titles.

## 10. Tiles carry no import badges

**Owner decision: no per-tile badges anywhere.** Neither grid marks import state on tiles.
An earlier revision of this plan proposed two badges — *already in your library* and *needs
attention*. Both are withdrawn, and the reasoning is recorded here so they are not
reinvented.

**No benchmarked app badges import state per tile.** The field has exactly three strategies:

| App | Treatment of already-imported items |
|---|---|
| Photo Mechanic | **Nothing.** Incremental Ingest is silent, and the ingest dialog has no source thumbnail grid at all |
| Image Capture | **Nothing** — no library, so no such concept |
| Capture One | `Exclude Duplicates` — a checkbox, i.e. **filtering** |
| Photos | **Sections** — "Already Imported Photos" above, "New Photos" below |
| Lightroom Classic | Per-photo **checkboxes** — selection, which decision 6 rules out |

Hide, group, or say nothing. Badging is not among them.

**The actionability test decides it.** With no per-item selection, learning that a given tile
is already imported changes nothing the user can do. Photos can afford its sections precisely
because Photos lets you select those items and re-import them; Otos deliberately does not. A
mark you cannot act on is decoration. The same test removes *needs attention*: blocked entries
are rare (§2), nothing per-item can be done about them, and the status line already carries the
cause and, where one exists, the fix — "Otos couldn't read the destination folder for 3 items.
This is usually temporary." / "3 items have no date. Set folder naming to None to import them."
That second one is a policy change, not a tile action.

Ordering already answers the "which ones are new?" question well enough: the grid sorts by
date, so a fresh shoot clusters at one end.

**Each grid's honest signal:**

| Grid | State it shows | How |
|---|---|---|
| Source (removable) | how many are new, and what will happen | status line (§9) and the checkboxes in the pinned bar |
| Batch (destination) | what has landed so far | tiles appearing as entries settle, plus the progress bar |

The batch grid needs nothing extra because **presence is the state** — everything in a batch is
in the library by definition, and decision 9 already has items appear as they import, so the
grid growing *is* the per-item progress. Badges could only ever have been source-side.

**Non-goal, recorded deliberately:** if "which ones are new?" ever becomes a real complaint, the
answer is a filter scope answered on demand, never a permanent mark on every tile. Even then it
carries a boundary cost worth weighing: `MediaFilter` today holds `kinds` and `formats`
(`CatalogQueryModels.swift:128`), both intrinsic media facts, whereas "new" is derived from the
coordinator's plan.

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
- **Cancel has an owner (decision 20).** The executor exposes `cancel()`
  (`MediaImportExecutor.swift:63`) but `runExecution` constructs it inline and keeps no
  reference (`MediaOperationCoordinator.swift:293`), so no UI intent can reach it today.
  Stage 6 holds one executor per executing source so the bar's Cancel reaches it, and a
  `.cancelled` result flows through the post-execution rebuild instead of republishing the
  stale pre-execution summary (`:366-376`) (§17 F4).
- **Batch rows appear at first settlement** — ARC-044 publishes nonempty batches only — so a
  batch row cannot show progress for the first item, possibly one huge video. Until the
  batch exists, the source row's determinate ring is that import's progress surface
  (§17 F8).

## 13. What this deletes

`ImportPlanOverlay.swift` and the `Details…` button · `ImportPlanFooter.totalsText` ·
`ImportPlanFooter.policyText` · the 11 prose cases of `readinessText` · the
`.waitingForDestination` user-facing state · `ImportPlanDetailReader` if nothing else consumes
it (confirm, do not assume — `CatalogWindowViewModelMediaOperations.swift:20-34` does). Every
deletion removes *display*, not capability.

Decisions 7 and 13 together also remove the attach-time selection switch
(`SidebarSelectionPolicy.selectionOnAttach`, `SidebarSelectionPolicy.swift:33-38`):
launch-time selection of a connected card is kept, the attach-time hijack goes. APP-002's
requirement row currently says attach selects and changes with this work (§17 F12, §19).

## 14. Stages

- **Stage 1 — planner correctness.** Block on `.noUsableDate` only when the selected policy
  needs a date (§2); make `shouldWaitForMetadata` policy-aware and give it a resume path
  (§17 F3).
- **Stage 2 — churn (C4).** During any execution targeting D, suppress destination-driven
  rebuilds for all sources mapped to D and coalesce one rebuild per source after settlement.
- **Stage 3 — instrumentation.** `op=plan.namespace.enumerate` (folders, entries, elapsed) and
  `op=plan.rebuild` (trigger), as ordinary observability and as the evidence that Stage 2
  actually stopped the rebuilds.
- **Stage 4 — reservation ledger (C1)** per §5: shape, invariants I1–I5, seed, publish-time
  conflict check, release points. The Done summary surfaces `.skippedForeign` **and** entry
  failures as the O1 backstop — on a volume whose rename is not exclusive, a collision can
  surface as `.failed`, not `.skippedForeign` (§17 F6). Same stage: fix
  `VolumeRenameCapability.probe` or correct the safety-floor claim — it returns `.renameExcl`
  whenever `getattrlist` succeeds without parsing the capability bits
  (`ExclusivePublication.swift:32-37`).
- **Stage 5 — destination identity.** Device-identity-keyed persistence; the three-step
  default, defined: saved mapping for this device identity → last-used destination →
  sole/first available fixed library; removal of `.waitingForDestination`; Destination
  column + Last Seen sort in Settings.
- **Stage 6 — four-state presentation.** Coordinator-owned presentation type; sidebar ring;
  honest denominators per §8 (planning stays indeterminate until measured slow); owned Cancel
  (§12); byte-level progress — decision 21, **implemented in this increment**:
  `ByteProgressTracker` in `MediaImportExecutor.swift`, `ImportExecutionProgressTests`, full
  suite green (§17 F9).
- **Stage 7 — per-source session overrides.** `sessionOptions` seeded from
  `ImportPreferences`, discarded on detach; the two checkboxes inline with live counts; the
  blocked-withhold voice and the honest label per decision 19 (§9, §17 F2).
- **Stage 8 — delete the sheet.** Remove `ImportPlanOverlay`, the `Details…` button, the
  totals/policy lines, and the `ImportPlanDetailReader` consumption in
  `CatalogWindowViewModelMediaOperations`. No tile work: §10 adds nothing to the grid.
- **Stage 9 — status/button matrix** (§9), including the delete-only execution path (lift
  the zero-copy guard in `beginExecutionIfPossible`, §17 F1), the non-destructive Return
  rule (§17 F7), and the blocked retry affordance (§17 F5).
- **Stage 10 — batch sidebar** (§11) and per-batch progress (§12), including the batch-row
  timing note (§17 F8).
- **Stage 11 — rescoped.** `.removableVolume` sources perform no full-file reads in
  enrichment (`MediaEnricher.swift:40,53`, ENR-013); the hashing-storm evidence that
  motivated this stage (2026-08-01) predates that exemption. Retarget to MTP device-staging
  hashing or delete the stage once the camera path is verified (§17 F11).
- **Stage 12 — accessibility** (§18). Each control ships with its VoiceOver, keyboard, and
  Reduce Motion support in the stage that introduces it; this stage is the sweep that proves
  none was forgotten.

## 15. Non-goals

Tokens in naming, secondary destinations, metadata templates, import presets, per-item
selection, post-copy byte verification, Photos-style grouped import sections, and any change
to the compare-pair meaning of grid selection (APP-021).

**Explicit non-claim:** Otos does not verify destination bytes. The XXH3-128 digest at
settlement is the *source* content hash reused as overlay
(`CatalogStoreImportJournal.swift:139-153`). The UI must never say "verified".

## 16. Open decisions

1. **Button count** — bare `Import` (recommended) or `Import 12 New Items`? Either answer
   keeps the §9 rule: the delete-only variant carries no default action and no count the
   blocked-withhold rule could void.

## 17. Design review findings, adopted 2026-08-09

Every code claim in this plan was re-verified against source during the review; these are
the defects the review found, each with its disposition.

- **F1 — `Delete from Card` was unwired.** `beginExecutionIfPossible` returns early on a
  zero-copy plan (`MediaOperationCoordinator.swift:231-244`), so the delete-only intent never
  reached the executor's skip-preexisting deletion loop (`MediaImportExecutor.swift:308-319`).
  → Stage 9.
- **F2 — the blocked-withhold rule broke the checkbox promise silently.** Card deletion and
  auto-eject are withheld while blocked entries remain (`MediaImportExecutor.swift:150`,
  `MediaOperationCoordinator.swift:358-362`, ARC-049); decision 3 removed the only sentence
  that said so while the §9 label still promised "all N". → Decision 19, Stage 7.
- **F3 — `.waitingForMetadata` never self-resumes.** Enrichment bumps neither occupancy nor
  plan revision (`CatalogStore.swift:1139`, `applyEnrichmentBatch` only notifies the
  catalog), so the state exits only via Import-press, an unrelated occupancy bump, or a
  preference change; the gate also waits on dates the selected policy may never use. Rare —
  mtime is nearly always present — but a four-state machine whose "not ready" can hang
  silently is a defect. → Stage 1.
- **F4 — Cancel had no path.** `MediaImportExecutor.cancel()` exists (`:63`) but
  `runExecution` constructs the executor inline and keeps no reference
  (`MediaOperationCoordinator.swift:293`); `.cancelled` also republished the stale
  pre-execution summary (`:366-376`). → Decision 20, Stage 6.
- **F5 — blocked was a dead end.** All-blocked disables `Import`, and transient
  `namespaceUnreadable` has no natural re-wake. → Stage 9.
- **F6 — the safety floor mis-probes.** `VolumeRenameCapability.probe` never parses
  `VOL_CAP_INT_RENAME_EXCL` (`ExclusivePublication.swift:32-37`); where `renamex_np` then
  fails with an errno other than `EEXIST`, a collision surfaces as `.failed`, not
  `.skippedForeign`. Still safe — no overwrite, source retained — but the Done summary must
  surface failures too, and §3's "probes the bit" claim is corrected here. → Stage 4.
- **F7 — Return flips to a destructive action.** `.keyboardShortcut(.defaultAction)`
  (`ImportPlanFooter.swift:80`) would follow the button's relabel to `Delete from Card` in
  the re-inserted-card scenario. → §9 rule, Stage 9.
- **F8 — batch rows appear at first settlement.** ARC-044 publishes nonempty batches only,
  so the first item's progress — possibly one huge video — has no batch row; the source
  row's ring is the surface until then. → §12 note, Stage 10.
- **F9 — byte progress was discarded.** `runPlanEntries` passed `{ _ in }` to
  `onByteProgress` (`MediaImportExecutor.swift:271`), so the §8 byte line could freeze for
  the duration of one large copy, against HIG's "keep progress indicators moving".
  → Decision 21, **implemented in this increment**: `ByteProgressTracker` (lock-protected,
  ≤10 emissions/s) in `MediaImportExecutor.swift`, verified by
  `ImportExecutionProgressTests` and a green full suite.
- **F10 — the determinate planning bar was superfluous.** One bounded enumeration with no
  progress callback; worst case ~461 ms measured (ADR 0019). → §8: indeterminate until
  measured slow.
- **F11 — Stage 11 chased a solved problem.** `.removableVolume` enrichment performs no
  full-file reads (ENR-013, `MediaEnricher.swift:40,53`); the 2026-08-01 hashing-storm
  evidence predates that exemption. → Stage 11 rescoped.
- **F12 — attach-time selection hijack goes.** Decisions 7 and 13 remove
  `SidebarSelectionPolicy.selectionOnAttach`; APP-002's row changes with it. → §13, §19.
- **F13 — accessibility was absent from the plan and the benchmark.** Neither read HIG
  accessibility before this review. → Decision 22, §18.

## 18. Accessibility requirements

Every control this plan introduces ships with:

- **VoiceOver.** Sidebar rings carry a full label — "CARD, importing, 412 of 1,204" — never
  a bare `ProgressView`; phase changes and status-line changes announce (a state change only
  a sighted user can see is not a state change); checkboxes announce their live labels.
- **Keyboard.** Checkboxes, Cancel, and the retry affordance are reachable with Tab and Full
  Keyboard Access; Import/Cancel keep Return/Esc semantics; the destructive variant carries
  no default action (§9).
- **Vision.** No state is encoded by ring color alone; status text meets contrast minimums;
  composed count strings (`12 new · 3.2 GB`) are built as localizable formatted values, not
  string interpolation, so pluralization survives translation.
- **Motion.** Ring and bar animation respects Reduce Motion.

## 19. Requirement and ADR impact

Behavior changes land with same-PR updates to: ARC-017 and ARC-047 (attention counts,
footer/presentation surface), ARC-044 (batch display cap and `All Imports…`), ARC-046/046A
(ledger claims and exclusivity), ARC-048/049 (withhold messaging), APP-002 (selection on
attach removed), APP-003 (Settings keeps defaults only). The ledger and concurrent-import
decision gets its own ADR superseding the relevant part of ADR 0019: context C1 plus the
publish-time race, decision ledger plus conflict check, rejected build-slot lock / O3 / O4.
