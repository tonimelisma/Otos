# Spec 0013: Catalog Lifecycle Race Safety

## Classification

- Work type: Bug fix and reliability refactor
- Current requirement IDs: FND-019, FND-023, FND-027, FND-035, FND-037,
  FND-046
- ADRs: ADR 0002 and ADR 0005, amended in place
- Review evidence: unresolved inline findings on PRs 4, 5, and 7

## Problem And Goal

Review evidence identified three catalog lifecycle paths that resumed after an
actor await with assumptions that were no longer true:

1. Store startup does not claim ownership until after the database read. A
   concurrent mutation can enter startup again, and a completed startup load can
   replace catalog changes made while the first load was suspended.
2. Scan callbacks identify work only by normalized root path. Removing and
   re-adding the same path gives it a new private SQLite row while callbacks from
   the cancelled scan can still write, reconcile, or clear the replacement scan.
3. Projection normalizes a removed selected library in its output but retains
   the missing library as its internal selection. Re-adding the same path can
   silently select it again even though the UI already moved to All Media.

The goal is one serialized initial catalog load, exactly one automatic scan
request for roots restored by that load, replacement-safe transient scan
ownership, and selection normalization in the actor that owns selection input.
No durable scan identity or scan history is introduced.

## Current Repo State

- `CatalogStore` is an actor and the sole owner of GRDB, root runtime catalog
  truth, Store-owned catalog queries, availability, and serial scan lifecycle.
- every initial-load caller awaits one Store-owned startup task, and loaded state
  is applied exactly once before mutations proceed
- roots restored by that initial load retain an exactly-once launch-scan request
  independently of mutation initialization; newly added roots own their separate
  immediate scan request
- active scan callbacks carry normalized root path plus private root row ID and
  validate that lease around every awaited database mutation
- `library_root.id` is already a private persistence-instance identity and
  changes when the same normalized path is removed and added again.
- `CatalogProjection` owns the latest sidebar-selection input, resolves a missing
  library to All Media, and retains that fallback unless a newer input arrived
  during the build
- typed `MediaAssetID` and `.unknown` loaded-root availability already resolve
  two older review findings and require verification rather than new behavior.

## Scope

In scope:

- coalesce every concurrent Store initialization onto one owned startup task
- separate initial loading from the request to scan database-restored roots
- request those restored-root scans exactly once, even if a mutation initialized
  the Store first
- bind each active scan to `(rootPath, private root row ID)` for its process
  lifetime and validate that ownership before and after every awaited write
- ignore stale batch, completion, cancellation, and failure callbacks without
  changing replacement state
- commit missing-library selection normalization back into Projection only when
  no newer sidebar intent arrived while projection work was suspended
- deterministic regression tests, bounded diagnostics, comment updates, and a
  repository-wide stale-document audit
- reply to and resolve all seven still-open historical review threads with
  current code or this increment's verification evidence

Out of scope:

- durable scan IDs, scan-history tables, scan records, resumable scans, or
  first/last-seen state
- parallel scans, manual scans, or periodic availability (coarse FSEvents rescans:
  spec 0023)
  probing
- SQLite schema changes
- grid, media eligibility, metadata, thumbnail, or filesystem-fact changes
- changing Store/Projection/ViewModel ownership or the 10 Hz publication cadence

## Captured Requirements For User Verification

The user's instruction to fix every relevant PR finding as a completed increment
is explicit enough to record directly. It produces these atomic requirements:

| Label | Type | Captured requirement | Authority after landing |
| --- | --- | --- | --- |
| RACE-001 | Architecture | Concurrent Store callers shall share one initial database load; loaded state shall never overwrite a mutation that entered during that load. | FND-047 |
| RACE-002 | Functional | Roots restored from SQLite shall receive one automatic launch scan request even when a mutation initialized the Store before the window startup intent arrived. | FND-048 |
| RACE-003 | Architecture | Scan callbacks shall be accepted only while both normalized root identity and the same private root persistence instance remain active. | FND-049 |
| RACE-004 | Regression | Removing and re-adding the same path shall make every callback from its cancelled predecessor harmless to the replacement root and scan. | FND-049 |
| RACE-005 | Architecture | Projection shall retain its resolved fallback selection unless a newer explicit sidebar intent arrived during the build. | FND-050 |
| RACE-006 | Process | Every open historical review thread shall receive a factual disposition and be resolved after its fix or existing proof is verified. | This spec and PR evidence |

## Architectural Alternatives

### Alternative A: Actor-Owned Startup Task And Persistence-Instance Scan Lease

Store creates one finite startup task and every caller awaits it. The initial
load remembers only roots restored from SQLite that have not yet received their
automatic scan request. Each running scan carries normalized root path plus the
private SQLite root row ID already available in Store memory.

Pros:

- derives ownership from facts already owned by Store
- handles same-path remove/re-add without generating a scan domain identity
- preserves serial scans and the current schema
- makes checks before and after actor suspension explicit and testable

Cons:

- requires every scan callback and reconciliation path to carry the transient
  lease consistently

Failure mode:

- omitting one post-await validation could still allow stale in-memory mutation;
  focused tests and comments therefore cover each suspension boundary.

### Alternative B: Durable Or Random Scan IDs

Generate an identifier for every scan and compare callbacks against it.

Pros:

- distinguishes every invocation directly
- could support parallel or resumable scan infrastructure

Cons:

- invents identity for an operation that is deliberately idempotent and
  non-durable
- does not by itself prove the root persistence row still exists
- invites scan-history architecture that the product explicitly rejects

Failure mode:

- scan identity becomes accidental product state or is persisted later without
  a real requirement.

### Alternative C: Prevent Actor Reentrancy With Blocking Or One Giant Operation

Perform startup and an entire scan without suspension or queue all catalog work
behind a custom non-reentrant executor.

Pros:

- fewer intermediate states are observable inside Store

Cons:

- blocks unrelated catalog intents behind filesystem and database work
- conflicts with responsive cancellation and Swift actor conventions
- adds a scheduler rather than expressing ownership across normal suspension

Failure mode:

- user add/remove intents become unresponsive during slow disk or network work.

### Alternative D: ViewModel Repairs Projection Selection

When Projection emits All Media, send that selection back as a new input intent.

Pros:

- keeps Projection changes small

Cons:

- creates a feedback path and makes ViewModel responsible for Projection's
  internal state
- can overwrite a newer user selection while an older state is delivered

Failure mode:

- normalization and user intents cycle or race across actor boundaries.

## Selected Approach

Use Alternative A for Store and commit selection normalization inside Projection.
The Store's startup task is finite, actor-owned work with one cancellation and
error result shared by all callers. A scan lease is the pair of domain path and
the already-existing private root row ID; it exists only in process memory and
cannot become scan history. Projection updates its internal selection only when
the input used for the completed build is still current, so a newer intent wins.

This is the simplest correct design because it adds no schema, UUID, protocol,
queue, second catalog owner, or feedback loop. It makes existing ownership facts
explicit at the exact suspension boundaries where they matter.

## Interfaces, Ownership, And Data Flow

1. `start(scansSavedLibraries:)` awaits `loadIfNeeded()`.
2. The first caller creates the Store-owned startup task; later callers await the
   same task. Only that task opens/migrates/reads and applies the initial catalog.
3. The load captures the normalized paths restored from SQLite as pending
   initial scan requests. New roots added later are not part of this set because
   `addLibrary` already queues their scan.
4. The first caller requesting saved scans drains that set into the existing
   serial scan queue. A preceding mutation load does not consume it.
5. `startNextScanIfNeeded()` constructs a transient active-scan lease from the
   root path and current private SQLite row ID before creating scanner work.
6. Every callback proves that the same lease remains active and that both Store
   maps still associate the path with that row before mutating durable or
   in-memory state. Checks repeat after awaited GRDB operations because the actor
   may process removal and replacement while suspended.
7. Projection captures one sidebar input for a build. After the build, it adopts
   the resolved selection only if its input has not changed in the meantime.
   The yielded state and retained input then agree without ViewModel feedback.

## Cancellation And Errors

- removing an active root cancels its task and immediately retires its lease
- cancellation is cooperative; a scanner that resumes later is harmless because
  its callbacks cannot prove lease ownership
- startup errors are delivered to every waiter; the failed startup task is
  cleared so an explicit later call may retry
- failed or cancelled scans preserve existing media rows
- stale callbacks emit bounded developer diagnostics and never change
  availability, rows, scan activity, or the next queued scan

## Instrumentation And Performance

- keep existing persistence and catalog signposts around startup and scan writes
- add bounded Logger/JSONL evidence when Store coalesces startup or ignores a
  stale scan callback
- include only root path, callback phase, and private row ID as scalar developer
  evidence; do not retain batches or snapshots in diagnostics
- this reliability change adds constant-time ownership comparisons around
  existing work and no new cadence, polling, or high-frequency task production
- verify Catalog logs and diagnostics with repo scripts; profiling is not needed
  unless verification reveals a responsiveness regression

## Retirement Proof

- remove `currentScanRootPath` as independent ownership state
- remove mutation initialization through a nested
  `start(scansSavedLibraries: false)` call
- forbid path-only scan callback ownership in Store source
- retain no generated or durable scan identifier
- retain typed pair-based `MediaAssetID` and loaded `.unknown` availability as
  proof for the two historical findings already fixed
- update affected ADRs, requirements, specs, index entries, comments, tests, and
  review-thread dispositions so none describes the retired behavior as current

## Living Documentation And Comment Audit

- amend ADR 0002 with serialized initial loading, exactly-once restored-root scan
  request, and transient persistence-instance scan ownership
- amend ADR 0005 with Projection-owned retained selection normalization
- add FND-047 through FND-050 and update backlinks
- update Specs 0004, 0007, and 0009 only where their current lifecycle summaries
  need the sharper contract
- update `AGENTS.md` with the general actor-reentrancy and transient-operation
  ownership rule, explicitly distinguishing it from durable scan identity
- update `docs/index.md` for this current implementation spec
- review Store and Projection file guides plus every affected concurrency comment
  for current mechanics and rationale; remove path-only or feedback implications
- search all current docs and comments for stale startup, scan ownership, durable
  scan ID, and selection-normalization claims

## Code-Smell Review

- **Unsafe concurrency escape:** scanner callbacks cross from a detached task
  into Store; the transient lease and repeated checks make ownership explicit.
- **State duplication:** startup task state and loaded-state Boolean must describe
  different facts, not competing truth. The task means work is in flight; the
  Boolean means its result was applied.
- **Stringly typed domain facts:** root path and row ID remain typed by role in
  the private lease; no concatenated identity is introduced.
- **Test coupling:** tests assert observable preservation, scan invocation, and
  selected state rather than private flags.
- **Diagnostic payload sprawl:** stale-callback diagnostics remain scalar and do
  not capture asset batches or snapshots.

## Acceptance Criteria

- concurrent `start` and mutation calls cannot apply the database snapshot more
  than once or erase the completed mutation
- a mutation-first initialization followed by ordinary app startup scans every
  root restored by that initial database load exactly once
- adding a root before ordinary startup does not cause that newly added root to
  receive a duplicate launch scan
- removing and re-adding the same normalized path while its old scanner remains
  suspended leaves only replacement-root data and scan activity
- stale old callbacks cannot clear, fail, reconcile, or change availability for
  the replacement scan
- removed selected library resolves and remains All Media after the same path is
  re-added, including remove/add coalesced inside one publication cadence, unless
  a newer explicit selection chose it
- normal UI add/remove commands arrive through one serial ViewModel lane, while
  Store remains independently safe for direct concurrent callers
- `MediaAssetID` remains an unambiguous typed pair and loaded roots remain unknown
- no schema, durable scan ID, scan history, manual scan, or UI behavior is added
- all seven historical review threads have factual replies and are resolved

## Verification

- focused Store startup and replacement-scan race tests with controlled async
  barriers
- focused Projection tests for retained fallback and newer-intent precedence
- source hygiene for no path-only active scan and no durable/generated scan ID
- `script/verify.sh`
- `script/catalog-diagnostics.sh check`
- agent-controlled build/run verification and focused Catalog log capture
- repository-wide stale-document and code-comment accuracy audits
- remote CI or exact allowed GitHub Actions billing/quota blocker evidence
