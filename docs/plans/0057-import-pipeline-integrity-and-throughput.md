# Plan 0057 — Import pipeline integrity, idempotent planning, and throughput

Evidence and design rationale: `docs/research/2026-07-14-import-planning-state-and-concurrency.md`.
All findings are from the live session of 2026-07-14 (121-file import, SD card →
OneDrive-synced library) with log excerpts recorded there.

## Invariants this plan establishes (new) or restores (regressed)

- **I1 (new): One execution per source.** At most one `MediaImportExecutor.execute()`
  runs per source at any time, regardless of replans, occupancy churn, or repeated
  clicks. A second Import intent during execution is a no-op.
- **I2 (new): Planning is idempotent and convergent.** A fully applied import plan
  replans to all-preexisting using catalog facts only — zero byte reads, zero
  materialization exposure, identical result across relaunches and after cloud
  eviction of destination bytes.
- **I3 (new): No self-replanning during execution.** Occupancy changes caused by an
  executing import never trigger plan rebuilds for that source until execution ends.
- **I4 (restored): Every user intent is observable.** A user intent that does
  nothing must still leave a log line identifying the intent and why it stopped.

## Work items

### 1. Single-execution guard (fixes double-batch import)

Root cause: `queuedStart[source]` is cleared only after `execute()` returns
(`MediaOperationCoordinator.swift:266`), and `buildPlan`'s completion re-enters
`beginExecutionIfPossible` while it is still set (`MediaOperationCoordinator.swift:552`),
starting a second executor ~2 s into the first (observed: interleaved batches
`1784083438029`/`1784083439983`, 111 foreign-occupant publish races, progress
flicker between the two executors' counts).

- Add `executing: Set<LibraryRootPath>` to `MediaOperationCoordinator`. Insert
  before `runExecution` awaits the executor; remove after `applyExecutionResult`.
- `beginExecutionIfPossible` returns early when `executing.contains(source)`.
- Clear `queuedStart[source]` when execution *begins*, not when it ends.
- Test: drive `queueImport`, then force a plan rebuild mid-execution (settle-driven
  occupancy bump through the store); assert exactly one batch ID exists in settled
  rows and the second `beginExecutionIfPossible` was rejected.

### 2. Settle-time provenance + planner short-circuit (establishes I2)

Root cause: `settleImportedAsset` (`CatalogStoreImportJournal.swift:56`) records
*what* landed but not *whence*; replans re-derive equality via byte comparison
(`MediaTransferPlanner.swift:447-478` → `ContentEqualityChecker`), which fails
with `.blocked(.comparisonRequiresMaterialization)` once OneDrive evicts the
destination bytes (observed: 70 preexisting + 51 blocked immediately after a
121-file import; destination files `compressed,dataless` in `ls -lO`).

- Schema: add nullable provenance columns to the settled destination row (or a
  1:1 provenance table keyed by root+relativePath — pick whichever keeps the
  upsert single-transaction): `source_root_path`, `source_relative_path`,
  `source_byte_size`, `source_modified_at_epoch`. Written in the same
  transaction as `settleImportedAsset`. Schema version bump per the existing
  policy.
- Planner: in `catalogDecision`, before requesting a byte comparison, check the
  destination occupant's provenance. If provenance names this member's source
  identity and the member's *current* size+mtime equal the recorded source
  facts → `.skip(candidate)` with no comparison request. Any mismatch falls
  through to the existing equality path unchanged.
- ADR-0008 gains a paragraph drawing the line: import provenance is filesystem
  facts about a copy Otos performed (path, size, mtime) — not a content
  fingerprint, which stays forbidden.
- `docs/requirements.md` gains the I2 invariant row mapped to the planner test.
- Tests: (a) import a source fully, evict nothing → replan yields all
  `skipPreexisting` with zero `ComparisonRequest`s issued (assert via injected
  equality checker that must not be called); (b) simulate destination eviction
  (dataless) → same result; (c) mutate a source file's mtime after settle →
  that member falls back to the comparison path.

### 3. Replan gating during execution (establishes I3)

Root cause: every settle bumps destination occupancy → `handlePlanningChange` →
full rebuild with occupancy probes and equality probes, continuously during the
import, competing for the same SD card and store actor.

- In `MediaOperationCoordinator.handlePlanningChange`, when the affected source
  is in `executing`, set the dirty bit and return without `scheduleBuildIfNeeded`.
- `runExecution` already ends with `dirty.insert(source)` +
  `scheduleBuildIfNeeded` — that single post-execution rebuild is the one that
  runs, and with item 2 it resolves from SQLite alone.
- Test: during a stubbed execution, deliver N planning changes for the source;
  assert zero plan builds started until execution completes, then exactly one.

### 4. Copy throughput instrumentation

Gap: `CopyfileTransfer.copy` success logs nothing; there is no batch span. The
"why is it slow" question was unanswerable from logs.

- Per file: `op=mediaOperation.copy phase=finish` with bytes, elapsed ms, MB/s,
  worker id, and staging→publish→settle phase timings.
- Per batch: `op=mediaOperation.batch phase=start/finish` with batch ID, file
  count, total bytes, elapsed, aggregate MB/s, worker count.
- Signpost intervals for the batch and per-file copy so `script/profile.sh`
  traces align with logs.

### 5. Concurrent copy workers (8)

Owner directive: 8 workers. Research (see research doc) supports bounded
parallelism on flash sources: no seek penalty, SD 6.0 command queueing, and the
dominant win is amortizing per-file latency and overlapping read/write/metadata
phases across files.

- Replace the serial `for entry in plan.entries` loop in
  `runPlanEntries` (`MediaImportExecutor.swift:170`) with a bounded
  `withTaskGroup` at width 8.
- A companion bundle (e.g. `.arw` + `.hif` pair sharing one plan entry) stays
  within one worker; entries are independent across workers because the planner
  already reserved distinct destinations per entry.
- Progress: completed counts/bytes accumulate through one owner (the executor)
  so `onProgress` stays monotonic; byte-level progress may coarsen to per-file
  granularity for non-active workers if needed — progress must never regress.
- Journal writes stay per-operation (crash-recovery semantics unchanged); the
  store serializes them as today.
- Cancellation: `cancelFlag` checked per entry before dispatch and inside
  copy loops as today; group drains before returning counts.
- Verification: run the 1/2/4/8 measurement matrix with item 4's spans on a
  real removable source and record results in the research doc. 8 ships per
  directive; the numbers document the curve.

### 6. Admission dequeue storm fix

Root cause: `dequeueDownloadWork` (`EnrichmentCoordinatorWorkSelection.swift:50`)
on a capacity-class rejection moves to the next candidate and logs again —
O(pending) scans and log lines per wakeup (observed: 381,881
`downloadReject reason=rootEagerFairness` lines in 12.5 minutes, ~500/s;
reconciles behind the same contention took up to 48 s for 3 files).

- Classify rejection reasons: capacity-class (`rootEagerFairness`, global
  in-flight caps — no later eager candidate can succeed this pass) vs
  candidate-class (this candidate only). Break the dequeue loop on
  capacity-class for eager background work; continue only past candidate-class.
- Log one summarized line per dequeue pass: first rejection reason + count of
  candidates not examined.
- Test: with in-flight at capacity and N pending eager items, one dequeue pass
  performs O(1) candidate evaluations for eager work and emits exactly one
  reject log (assert via injected log/counter seam if one exists; otherwise
  assert the loop exit behavior through returned work + policy call counts).

### 7. Eject observability and mount-state truth

Observed: sidebar Eject click produced zero log lines; the volume was already
unmounted at the OS level while the app still showed the source row with an
eject affordance. `ejectRemovableSource`
(`CatalogWindowViewModelMutation.swift:43`) returns silently when
`deviceIdentity` is nil; nothing logs intent entry.

- Log every user intent at its owner entry point (`op=intent.eject phase=received`
  with source path and guard outcome); extend the same pattern to the other
  catalog mutation intents in the same file.
- The nil-identity guard becomes a visible failure (log + user-facing alert path
  already exists via `handleEjectOutcome`).
- Availability truth: when the store marks a removable source unavailable
  (events dropped `reason=unavailable`) because the mount is gone, the sidebar
  row must reflect it — reuse the existing detach flow
  (`performDetachRemovableSource`) driven by `RemovableVolumeMonitor` unmount
  notifications; investigate why the unmount of `/Volumes/4152150790` did not
  detach (reproduce with a real card or a disk image) and fix the missed
  notification path.
- Test: eject intent with nil identity logs and surfaces the failure; unmount
  notification detaches the source row.

## Sequencing

Items 1 → 3 → 2 first (correctness, smallest diffs, each independently
testable), then 6 (isolated), then 4 → 5 (instrumentation before concurrency so
the worker measurements exist), then 7. One branch, one PR, one DoD; if review
size demands, 6+7 may split into a second PR — both land before the increment
is called done.

## Non-goals

- No cross-tool duplicate detection (Lightroom-style name+time heuristics).
- No persisted content hashes (ADR-0008 stands).
- No FSEvents `IgnoreSelf`-based suppression changes beyond what exists.
- No change to enrichment's eager-materialization policy itself — only its
  dequeue/logging efficiency.

## Definition of done

Per CLAUDE.md: lands on `main`, worktree/branch cleaned, `script/verify.sh`
green locally, remote CI green (or billing-waiver evidence), requirements/ADR
updates in the same PR, DoD report on the PR and sent in full, with
instrumentation evidence for: single batch ID per import, zero comparison
probes on post-import replan, admission storm eliminated (log-rate before/after),
and the 1/2/4/8 worker measurement table.
