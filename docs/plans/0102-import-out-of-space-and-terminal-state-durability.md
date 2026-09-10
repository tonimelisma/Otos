# Plan 0102 — import out of space, terminal-state durability, and batch navigation

Opened 2026-09-09 from a live session: the owner clicked `Import 38 Items`, nothing
appeared to happen, and a second click made the import bar vanish. Evidence, timings
and the design research behind this plan are in
`docs/research/2026-09-09-destination-free-space-and-import-failure-recovery.md`.

The import genuinely could not fit — 26,558,298,038 bytes into 18,183,512,064 free —
and Otos detected that correctly. Every defect below is in what happened *after* the
correct verdict was reached.

## What this plan is not

- **No polling, no free-space service, no free space on the plan.** macOS has no
  notification for free space crossing an app-defined threshold, and the capacity
  figure is CacheDelete's cached calculation that is documented to be wrong in both
  directions (research findings 3 and 4). A design that needs to know when the disk
  changed is unbuildable here.
- **No gating `Import` on space.** A blocker raised from an unobservable, unreliable
  number can never be cleared truthfully. The button stays live; the attempt is the
  check.
- **No pre-commit "won't fit" warning in Ready.** That is a product decision the owner
  has not made. Recorded under *Deferred* below, not built here.

## Increment A — the last run's outcome is a fact, not a phase

**The fault.** `MediaOperationCoordinator` uses one `.failed` phase for two unrelated
things: *"a plan cannot be built right now"* (`noDestinationLibrary`,
`snapshotUnavailable`) and *"the run the user started has finished, unsuccessfully"*.
The first is a current state and a successful rebuild **should** replace it. The
second is a finished fact and a rebuild **must not** touch it. Because they share a
phase, the rebuild's correct behaviour for the first destroys the second.

That rebuild is unconditional: after every terminal settlement the coordinator sets
`current.isDirty = true` and calls `scheduleBuildIfNeeded(source)`, and the build ends
at `updated.phase = .ready(readyCtx)` with no check of what it is replacing
(`Otos/Services/MediaOperationCoordinator.swift`, terminal settlement and build
completion). A completed run survives only because completion is *separately* stored
as `session.lastCompletion` and re-attached to every rebuilt presentation. Failure has
no such carry, so it is erased. In the incident the Failed bar lived 24 ms on the first
click and was coalesced away entirely on the second — violating
`docs/design/import-bar.md` state G, "Never auto-dismisses".

**The change.** An execution outcome stops being a phase and becomes a recorded fact
about the last run, at the same tier and lifetime as `lastCompletion`. `phase` keeps
answering "what is this session doing now"; the last run's result is a separate stored
fact that a rebuild has no business rewriting. Planning failure stays a phase, because
it genuinely is one.

- Files: `Otos/Services/MediaOperationCoordinator.swift`,
  `Otos/Models/MediaOperationModels.swift`.
- Superseded when — and only when — a new run starts for that attachment, exactly as
  `lastCompletion` is; `Try Again` therefore clears it by starting the next run.
- Reuse ARC-047's existing "a published plan survives the rebuilds that replace it"
  mechanism. Do not add a second holding mechanism beside it.

**Oracle.** Behaviour-preserving for every non-failure path: the existing
`MediaOperationCoordinator*Tests` and `ImportBarPresentationTests` stay green
*unmodified*, including `nonCleanSettleDoesNotAutoDismiss`,
`cleanSettleWithCardGoneAutoDismissesAfterDeadline` and
`batchPresentationSurvivesDetachAfterCleanSettle`.

**New tests** (`OtosTests/MediaOperationCoordinatorAdversarialTests.swift`):
- a run that fails still presents `.failed` after the rebuild it schedules completes;
- the same, when the rebuild's `ready` publishes in the same actor hop as the failure
  (the incident's shape — both published at 22:23:59.427);
- a *planning* failure is still replaced by a successful rebuild (the behaviour worth
  keeping);
- `Try Again` leaves the failed state.

## Increment B — out of space is a run outcome with an honest partial count

**The fault.** The only place Otos names out-of-space is the precheck before any bytes
move. The per-entry vocabulary is `sourceNotReady | sourceChanged | sourceAbsent |
other` (`Otos/Services/MediaImportExecutor.swift`), so an `ENOSPC` from a transfer
lands in `.other` — documented in that type as "inherently per-file", and never
promoted to a run-level classification. A 26.6 GB copy that exhausts the volume at item
20 of 38 therefore reports a vague per-file failure inside an otherwise clean-shaped
`.completed`, not "the disk filled up".

This is the case no precheck can cover, because it is exactly the case where free space
changed after the check — and it is likely in practice here, since
`EnrichmentCoordinator` materializes OneDrive placeholders onto the same volume
concurrently (ADR 0008).

**The change.**
- Add `EntryFailure.outOfSpace`; map `NSFileWriteOutOfSpaceError` and POSIX `ENOSPC` at
  the transfer sites.
- Stop the run at the first out-of-space rather than attempting the remaining entries:
  they will all fail, and each attempt opens and rolls back a journal entry.
- Promote it to `.failed(reason: .outOfSpace)` through the existing "every attempted
  entry failed for the same systemic reason" rule that `sourceNotReady` already uses.
- Carry the real count. `session.phase = .failed(reason: reason, publishedCount: 0)`
  hardcodes zero and would discard it.
- Author **ADR 0027 — destination free space is measured only at the attempt**:
  context (findings 3–5), decision (no gate, no plan state, no polling; precheck as a
  courtesy, `ENOSPC` as the authority, `Try Again` because a purge-blocked write may
  succeed next time), rejected alternatives (timer polling; free space on
  `MediaOperationPlanTotals`; a blocking Ready variant), consequences (a forecast is
  never shown, so partial completion must be honest — which is what makes the absence
  of a forecast acceptable).

**No presentation work is needed.** `MediaOperationSourcePresentation` already carries
`failed(reason:publishedCount:)` and `ImportBarPresentation` already renders
`"N items were copied before it stopped"` when the count is nonzero — the mapper is
waiting for a producer.

**New tests:**
- `OtosTests/MediaImportExecutorTests.swift` — with the Nth copy throwing `ENOSPC`, the
  run classifies as `.failed(reason: .outOfSpace)` with `publishedCount == N-1`, and
  entries after it are not attempted. Use the same seam
  `allEntriesFailingSourceNotReadyClassifiesRunAsFailed` uses.
- A mixed run (one `ENOSPC`, one per-file failure) stays `.completed`, mirroring
  `mixedFailureReasonsStayCompletedNotSystemic`.
- `OtosTests/ImportBarPresentationTests.swift` — the drawn Failed state reads
  `The disk is full · 19 items were copied before it stopped`.

**Resumption needs no new code, and the plan must prove it.** The plan is rebuilt from
the filesystem and already produces `skipCount` for items present at the destination,
so the next `Import` copies only what is left. Add a coordinator test that asserts it:
after a partial out-of-space run, the rebuilt plan's `copyCount` equals the unfinished
remainder.

## Increment C — never navigate to a batch with nothing in it

**The fault.** `followNewBatchesOnce`
(`Otos/ViewModels/CatalogWindowViewModelMediaOperations.swift`) moves the sidebar to a
batch the first time its ID appears on any presentation, without asking whether that
batch has anything in it. The failed run published `batchID=…439390` with
`publishedCount: 0`, so the selection moved to an empty batch that will never have
content — `retainedResolvedSelection=true` in the projection, i.e. the sidebar and the
grid disagreed.

The second click then minted a *new* batch ID. `selectedImportPresentation` matches a
`.importBatch` selection by `batchID`, found nothing, and `ContentView`'s
`if let presentation` unmounted the footer. The selection only recovered on the next
catalog publication — **8.3 seconds later**, because nothing in the catalog had
changed. That is the disappearing bar.

**The change is narrow, and it must respect APP-029.** APP-029 already gates
`.executing`'s `batchID` on `store.importBatchAssetCount(batch) > 0` "so
`followNewBatchesOnce` never navigates to a batch row before there is anything in it to
show", and deliberately exempts terminal states so batch pinning keeps working. So the
requirement already holds the right intent and covers only one of the two states that
need it — because **carrying a batch identity and choosing to navigate to it are the
same field today.** Separate them: the terminal presentation keeps carrying its
`batchID` (identity, pinning, detach), and `followNewBatchesOnce` consults the
outcome's `publishedCount` before moving the user.

`OtosTests/MediaOperationCoordinatorAdversarialTests.swift#batchIDSurvivesAnImmediateFailureBeforeAnyCopy`
must stay green **unmodified** — it asserts identity, which this does not touch.

**New tests** (`OtosTests/CatalogWindowViewModelMediaOperationsTests.swift`):
- a terminal failure with `publishedCount == 0` does not move the selection;
- a terminal failure with `publishedCount > 0` does move it, and the batch row holds
  those items;
- with the selection left on the card, a second failed run does not unmount the footer.

**Open question for the owner, not decided here.** With a real partial batch selected,
starting a second run mints a new batch and the first batch's row then has no live
presentation, so its bar disappears until the selection resolves elsewhere. Whether a
superseded batch row should keep showing its own finished operation's bar is a design
question `import-bar.md` does not answer (state F/G describe two rows onto *the same*
operation). Increment C's fix means the incident cannot reach that path; the question
stands on its own.

## Increment D — documentation closure

- `docs/requirements.md`: APP-029 gains terminal-state durability and the
  navigation-only-into-a-non-empty-batch clause; ARC-047 gains the outcome-vs-phase
  split. Both cite the new tests.
- `docs/adr/0027-destination-free-space-is-measured-at-the-attempt.md` (authored in B).
- `docs/architecture.md`: the coordinator's ownership line, if the outcome/phase split
  changes what that table says.
- `docs/design/import-bar.md`: no rule change expected — state G and journey J9 already
  specify this behaviour, and this plan implements them. If drafting proves otherwise,
  the rule changes in the same PR.
- Delete this plan at closure.

## Deferred — owner decision, not built here

An advisory free-space line in Ready (`26.6 GB needed · 17 GB free`) beside a still-live
button, sampled when Ready is drawn and never on the plan cadence. It would be stale by
construction and gate nothing. Worth doing only if the owner wants the warning; the
correctness work above does not depend on it.

## Out of scope, found while diagnosing

Logged here so they are not lost; none belongs in this plan.

1. **GRDB and MediaMetadata are linked twice** — into `OtosKit.framework` and
   `Otos.debug.dylib`. dyld warns of "spurious casting failures and mysterious
   crashes". `Otos.xcodeproj/project.pbxproj` has uncommitted local changes.
2. **`op=mainThreadStall stallMs=126`** (threshold 100) attributed to
   `MediaGridViewController.reconfigureVisibleItems` while reporting
   `lastLongOperationMs=0` — the blamed op did nothing, so the attribution misleads.
3. **Enrichment and import compete for the same finite disk** with no arbitration
   (ADR 0008 accepts the materialization cost but does not consider a concurrent
   import).
4. **Startup publishes `failed(unexpected("noDestinationLibrary"))`** for an ordinary
   not-yet-resolved condition. Increment A's outcome/phase split is the natural place
   to reconsider it.
5. **Enrichment claim queries waited 380 ms and 170 ms** behind 642/563/424 ms scan
   batch writes; one projection equality check spiked to 15.7 ms.

## Verification

`script/check.sh`, run in the background under a `Monitor` that emits every 60 s and is
stopped in the same action that reads it (AGENTS.md → Supervising long checks).
Evidence must come from the run that measured the final tree.

Increments A and C are provable by unit tests. Increment B's mid-copy path needs an
injected `ENOSPC` at the executor's transfer seam; if that seam does not admit
injection cleanly, adding it is part of B rather than a reason to assert the behaviour
untested.
