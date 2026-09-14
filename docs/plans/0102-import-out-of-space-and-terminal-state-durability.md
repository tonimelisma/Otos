# Plan 0102 — import to the disk floor, stopped outcomes, and terminal-state durability

Opened 2026-09-09 from a live session: the owner clicked `Import 38 Items`, nothing
appeared to happen, and a second click made the import bar vanish. Re-observed
2026-09-13 with the same card grown to 680 items / 54.8 GB against 37.7 GB free: three
clicks, three correct `outOfSpace` verdicts drawn for 24, 10 and 10 ms. Evidence,
timings and the research behind this plan are in
`docs/research/2026-09-09-destination-free-space-and-import-failure-recovery.md`.

## The rule (owner decision, 2026-09-13)

> **Import never refuses to start because the whole card doesn't fit.** It copies
> entries in plan order and stops before the first entry that would leave the
> destination volume with less than **5 GB** free. The stop is a designed outcome:
> the copied items are a real batch, the un-copied ones stay on the card, the card's
> re-plan offers the remainder, and nothing is erased or ejected. Free space is
> measured before each entry, never predicted.

Consequences the rule fixes rather than leaves open:

- **A floor stop is structurally a Cancel, not a Failure.** Cancel already returns a
  partial result before the erase sweep, stores `lastCompletion` with
  `isFullyClean: false`, survives the post-settlement rebuild, and re-plans the
  remainder (`import-bar.md` J8). The floor stop lands on that path with one
  addition — a *stop reason* — instead of on state G.
- **The run-level precheck is deleted**, not kept as a courtesy: its only job was to
  refuse a run that would not fit whole, which the rule forbids. Deleting it also
  retires research finding 4's false-refusal risk — nothing refuses any more.
- **`ENOSPC` is the backstop, not a second outcome.** The capacity figure can be wrong
  or another process can take the space between check and write; a write that fails
  for space stops the run the same way the floor does.
- **One floor, one owner.** `DeviceStagingRegistry` carries a 10 GB staging floor and
  the precheck carried a 64 MB headroom — three floors for one promise. One constant,
  5 GB, used by both.
- **Stop at the first entry that does not fit; do not skip it and continue.** The
  result is a contiguous prefix in plan order — "the first 412 were imported" —
  predictable and matching how the bar counts. An entry with companions (RAW+HIF,
  video+SRT) is atomic at the boundary.
- **A floor stop is never fully clean**: no auto-eject, no end-of-run erase sweep.
  Delete-after-import of entries that landed is unchanged (each is erased on its own
  settle, once proven in the library); the un-copied items exist only on that card
  and are never touched.

## What this plan is not

- **No polling, no free-space service, no free space on the plan.** macOS has no
  notification for free space crossing an app-defined threshold, and the capacity
  figure is CacheDelete's cached calculation (research findings 3 and 4). A design
  that needs to know when the disk changed is unbuildable here.
- **No gating `Import` on space**, in either direction.
- **No pre-commit "won't fit" warning in Ready.** Not requested; recorded under
  *Deferred*.

## Increment order

**C → B1 → B2 → A → closure.** C is tiny and removes a hazard every later increment's
tests would otherwise trip over (a 0-copied stop must not navigate anywhere). B1 gives
"stopped early" a first-class outcome and rendering — a spec gap that exists today for
user cancel — and B2 puts the floor on that substrate. A is last because it depends on
C: `lastAttemptedBatch` is "set the moment execution begins and left alone", so a new
run's first frames advertise the *previous* run's batch (observed 17:10:56.053 on
2026-09-13); that stale carry is what kept the footer mounted between the owner's
clicks, and moving batch identity onto a recorded outcome before C lands would unmount
the footer at the *start* of the second click instead of at its failure.

## Increment C — never navigate to a batch with nothing in it

**The fault.** `followNewBatchesOnce`
(`Otos/ViewModels/CatalogWindowViewModelMediaOperations.swift`) moves the sidebar to a
batch the first time its ID appears on any presentation, without asking whether that
batch has anything in it. A run refused before any copy published `batchID` with
`publishedCount: 0`; the selection moved to an empty batch that will never have
content (`retainedResolvedSelection=true` — sidebar and grid disagreed). The next click
minted a *new* batch ID, `selectedImportPresentation` matched the `.importBatch`
selection by `batchID`, found nothing, and `ContentView`'s `if let presentation`
unmounted the footer until the next catalog publication — 8.3 s on 2026-09-09, ~2.5 s
on 2026-09-13.

**The change, and why it is narrow.** APP-029 already gates `.executing`'s `batchID` on
`store.importBatchAssetCount(batch) > 0` "so `followNewBatchesOnce` never navigates
to a batch row before there is anything in it to show", and deliberately exempts
terminal states so batch pinning keeps working. The requirement holds the right intent
and covers one of the two states that need it, because **carrying a batch identity
and choosing to navigate to it are the same field today.** Separate them: the terminal
presentation keeps carrying its `batchID` (identity, pinning, detach), and
`followNewBatchesOnce` moves the user only when the presentation proves the batch is
non-empty — `.executing` with an exposed `batchID` (already gated), or a settled state
whose count copied is greater than zero.

`OtosTests/MediaOperationCoordinatorAdversarialTests.swift#batchIDSurvivesAnImmediateFailureBeforeAnyCopy`
stays green **unmodified** — it asserts identity, which this does not touch.

**New tests** (`OtosTests/CatalogWindowViewModelMediaOperationsTests.swift`): a
terminal outcome with nothing copied does not move the selection; one with items
copied does; with the selection left on the card, a second run that fails before
copying does not unmount the footer.

**Docs.** APP-029's navigation clause states the rule for terminal states.

## Increment B1 — "stopped early" is a first-class outcome

**The gap.** `import-bar.md` J8 step 3 specifies `Stopped — 12 items copied` on the
batch row after a cancel. Nothing renders it: `ImportBarPresentation.map` handles
`.failed`, `.executing`, `.completed`, then derives Done only when the rebuilt plan has
`copyCount == 0`; a cancel with a remainder falls through to plain Ready for the
remainder, and the fact that a run just stopped is never stated. The data cannot say
it either — `MediaImportExecutionResult.cancelled` reaches `AttachmentCompletion` as
`isFullyClean: false` and nothing more, indistinguishable from a run that attempted
everything and lost some.

**The change.**
- `MediaImportExecutionResult.cancelled` becomes `.stopped(reason:…)` with
  `StopReason.user` (B2 adds `.diskFloor`). The reason is data; a stop is a stop.
- `AttachmentCompletion` and `MediaOperationSourcePresentation` carry `stopReason`
  and the run's own `attemptedTotal`, so the bar can state "412 of 680" from run facts
  rather than from a live plan that may since have changed.
- The mapper gains **F · Stopped**: L1 `Stopped — 12 of 42 items copied`, L3 one
  clause for the reason, and the act is the remainder's own `Import 30 Items` when
  the card is still attached (the live plan's `copyCount`) — an empty act zone when
  the card is gone (DES-053's "subject no longer exists" exception). Identical on the
  card row and the batch row, following state F's own rule.
- `import-bar.md`: state F gains the Stopped variant; J8 step 4 changes — the card row
  no longer reverts to C after a cancel, the Stopped bar carries the remainder's act
  itself. That is a rule change and lands in the same PR.

**Oracle.** `ImportBarPresentationTests` and the coordinator suites stay green apart
from the tests that asserted the old fall-through-to-Ready after cancel, which change
with the rule. New tests: the mapper renders Stopped with the remainder act while the
card is attached and an empty act when it is gone; the coordinator publishes
`stopReason` and `attemptedTotal` across the post-settlement rebuild; a stopped run is
never fully clean and never auto-dismisses (`nonCleanSettleDoesNotAutoDismiss` already
covers the second half).

**Docs.** APP-029 gains the Stopped variant; ARC-047's "given execution is cancelled"
clause states what is presented.

## Increment B2 — the disk floor

**The change in `MediaImportExecutor`.**
- Delete `freeSpaceRequired` / the run-level refusal at the top of `execute()`.
- In `runPlanEntries`, before each `submit(index)`: read the destination volume's
  `volumeAvailableCapacityForImportantUsage` fresh and require
  `capacity − inFlightBytes − entryBytes ≥ floor`, where `inFlightBytes` is the sum of
  submitted-but-unfinished entries' `byteSize`. With `workerCount = 8`, a check that
  ignores in-flight bytes overshoots the floor by up to eight items — with 500 MB
  clips, the whole floor. An unknown capacity (`nil`) admits the entry; `ENOSPC` is
  the backstop. Entries already in flight complete: they were admitted with their
  bytes counted.
- On the first entry that does not fit, stop submitting, let in-flight entries land,
  and return `.stopped(reason: .diskFloor(bytesFree:), publishedCount:, …)`. Do not
  raise `cancelFlag` — that is the user's, and the erase sweep keys on it.
- Add `EntryFailure.outOfSpace`, mapped from `NSFileWriteOutOfSpaceError` / POSIX
  `ENOSPC` at the transfer sites; a run that sees one stops the same way.
- Capacity is read through an injectable `@Sendable (URL) -> Int64?` on
  `MediaImportExecutor.init` with a default that reads `resourceValues` — the OS is a
  real substitution boundary, and the floor is otherwise untestable.
- `MediaOperationFailureReason.outOfSpace` and its `The disk is full` clause are
  removed: nothing produces them once the precheck is gone. The two tests that used
  `.outOfSpace` as a generic injected failure switch to the reason that fits their
  setup (`destinationUnavailable` for the one that removes the destination).

**The floor.** One `nonisolated enum FreeSpaceFloor { static let bytes }` at 5 GB in
`Otos/Models/`, used by the executor and by `DeviceStagingRegistry`, whose check
becomes `available − fileBytes ≥ floor` (it currently checks `available ≥ 10 GB`
without counting the file about to be staged — the same promise, applied
consistently).

**Presentation.** B1's Stopped state with the `.diskFloor` clause:
`Stopped — 412 of 680 items copied` / `Not enough room on the disk · 5.0 GB left`,
act `Import 268 Items` while the card is attached. A stop before the first entry reads
`Stopped — 0 of 680 items copied` with the same clause — one outcome, no special case.

**ADR 0027 — destination free space is measured only at the attempt.** Context
(research findings 3–5); decision (no gate, no plan state, no polling; per-entry floor
with in-flight accounting; `ENOSPC` as backstop; partial completion as the mechanism
that makes the absence of a forecast acceptable); rejected alternatives (timer polling;
free space on `MediaOperationPlanTotals`; a blocking Ready variant; skip-and-continue
past a non-fitting entry); consequences (a forecast is never shown; every stop is
resumable by construction because the plan is rebuilt from the filesystem and already
produces `skipCount` for what landed).

**Tests** (`OtosTests/MediaImportExecutorTests.swift`, using the injected capacity):
- capacity `floor + 25` over three 10-byte entries, decreasing as bytes land: two
  publish, the third is never attempted, result is `.stopped(.diskFloor)` with
  `publishedCount == 2`;
- the same with a constant (stale) capacity: in-flight accounting alone still stops
  at the right entry;
- capacity `nil` admits everything;
- an injected `ENOSPC` on entry *k* stops the run with `publishedCount == k − 1`;
- a floor stop returns before the erase sweep even with delete-after-import requested
  — nothing on the card is deleted.
- Coordinator: after a floor stop, the rebuilt plan's `copyCount` equals the
  remainder; no auto-eject fires.
- Mapper: the two Stopped strings above.
- `DeviceStagingRegistry`: staging respects the shared floor including the file's
  own bytes.

**Docs.** APP-029 (floor stop rendering, never clean), ARC-047 (no precheck; per-entry
floor; `ENOSPC`), ENR-011/APP-018 if the staging floor's value is stated there,
`import-bar.md` J9 (disk full is a Stopped outcome, not state G) and state G's clause
list, `docs/architecture.md` if the where-to-change row for imports names the
precheck.

## Increment A — the last run's failure is a fact, not a phase

**The fault.** `MediaOperationCoordinator` uses one `.failed` phase for two unrelated
things: *"a plan cannot be built right now"* (`noDestinationLibrary`,
`snapshotUnavailable`) and *"the run the user started finished unsuccessfully"*. The
first is a current state and a successful rebuild **should** replace it; the second is
a finished fact a rebuild **must not** touch. Because they share a phase, the
rebuild's correct behaviour for the first destroys the second: after every terminal
settlement the coordinator sets `isDirty = true` and schedules a build that ends at
`updated.phase = .ready(readyCtx)` with no check of what it replaces. A completed or
stopped run survives only because it is *separately* stored as `lastCompletion`;
failure has no carry and is erased — 24 ms on 2026-09-09, 10 ms on 2026-09-13,
violating state G's "Never auto-dismisses".

After B1/B2 this no longer sits on the disk-space path, but it still holds for a card
pulled or a destination lost mid-run, and the spec violation stands.

**The change.** An execution failure becomes a recorded fact about the last run, at
the same tier and lifetime as `lastCompletion`; `phase` keeps answering "what is this
session doing now". Planning failure stays a phase. Superseded when — and only when —
a new run starts for that attachment; `Try Again` therefore clears it by starting the
next run. Batch identity for a failed run comes from the recorded outcome, retiring
the stale `lastAttemptedBatch` carry described under *Increment order*.

**Test scaffolding to retire.** `batchIDSurvivesAnImmediateFailureBeforeAnyCopy`
says in its own comment that `.failed` "would be gone again within the same actor
turn, before any poll could observe it" and removes the destination first so the
rebuild fails too. After A the assertion stands and that workaround goes.

**New tests** (`OtosTests/MediaOperationCoordinatorAdversarialTests.swift`): a run
that fails still presents `.failed` after the rebuild it schedules completes; the
same when the rebuild's `ready` publishes in the same actor hop as the failure; a
*planning* failure is still replaced by a successful rebuild; `Try Again` leaves the
failed state.

**Docs.** APP-029 gains the durability clause; ARC-047 the outcome-vs-phase split;
`docs/architecture.md`'s coordinator row if its ownership sentence changes.

## Closure

- Delete this plan; `docs/plans/README.md` records where its decisions live
  (ADR 0027, APP-029, ARC-047, `import-bar.md` F/J8/J9).
- The open question C leaves for the owner, recorded rather than decided: with a
  real partial batch selected, starting a second run mints a new batch and the first
  batch's row then has no live presentation, so its bar disappears until the selection
  resolves elsewhere. `import-bar.md` describes two rows onto *the same* operation and
  does not say whether a superseded batch row keeps its own finished operation's bar.

## Deferred — owner decision, not built here

An advisory free-space line in Ready (`54.8 GB needed · 37.7 GB free`) beside a
still-live button, sampled when Ready is drawn and never on the plan cadence. Stale by
construction, gating nothing.

## Out of scope, found while diagnosing

1. **GRDB and MediaMetadata are linked twice** — into `OtosKit.framework` and
   `Otos.debug.dylib`; dyld warns of "spurious casting failures and mysterious
   crashes". `Otos.xcodeproj/project.pbxproj` has uncommitted local changes.
2. **`op=mainThreadStall stallMs=126`** attributed to
   `MediaGridViewController.reconfigureVisibleItems` while reporting
   `lastLongOperationMs=0` — the blamed op did nothing.
3. **Enrichment and import compete for the same finite disk** with no arbitration
   (ADR 0008 accepts the materialization cost but does not consider a concurrent
   import). The floor bounds the damage from Otos's own side only.
4. **Startup publishes `failed(unexpected("noDestinationLibrary"))`** for an ordinary
   not-yet-resolved condition; A's split is the place to reconsider it.
5. **Rebuild storm**: 2026-09-13 saw plan generations 27→34 in 50 s because OneDrive
   was syncing new files into the destination (`destinationOccupants` 8270→8277),
   200–470 ms of planning each. Harmless once A lands; still O(n) per arriving file.
6. **`op=ui.sidebarSelectionToPaint` leaves its span open** when a selection is
   abandoned, so an abandoned navigation is indistinguishable from a hung one.
7. Reaching Ready took 25.7 s for 680 items (`attachToReady elapsedMs=25688`) — the
   metadata wait scaling with the card (ADR 0024/0026), not a defect.
8. **Possible stale Ready between two Done frames.** After a *completed* run the
   coordinator moves `.completed` → `.building` within one actor turn while still
   holding the pre-run plan (`lastReadyContext`), so the mapper may draw Ready
   ("42 new items") for the rebuild window before the re-plan's `copyCount == 0`
   lets Done reappear. Found reading the code during B1; not observed live (no
   completed run in either capture). B1 drops the held plan on a *stop*; the same
   "a settled run invalidates the plan it ran from" rule would resolve this if it
   proves real, with the mapper rendering Done from `lastCompletion` while the
   re-plan is pending.
9. **Camera (MTP) writes that refuse for space** arrive as a string from the
   camera layer and classify as a per-file `.other`, not `.outOfSpace`; the
   per-entry floor admission covers that path, so only a lying capacity figure
   reaches this gap.

## Verification

`script/check.sh`, run in the background under a `Monitor` that emits every 60 s and is
stopped in the same action that reads it (AGENTS.md → Supervising long checks).
Evidence must come from the run that measured the final tree. Each increment is one
PR with its own DoD report on the PR.
