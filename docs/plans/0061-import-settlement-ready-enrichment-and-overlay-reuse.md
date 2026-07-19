# Plan 0061 — Import settlement correctness, ready-only enrichment, and overlay reuse

## Status

Active. Product direction confirmed 2026-07-19.

## Purpose

Correct three failures exposed by the 2026-07-18 removable-volume import:

1. A full destination scan used an observation snapshot that predated the import,
   then deleted one newly settled catalog row as missing. The filesystem watcher
   recreated the row without its import batch/provenance, so 159 successful imports
   appeared as 158 assets under Imports while a new card plan correctly found all
   159 destination files preexisting.
2. Enrichment discovery sends candidates to an enrichment worker before learning
   whether their bytes are materialized. Dataless work and completed-but-unflushed
   results remain in the same 32-entry `claimedWork` window used to discover ready
   work. In the observed run, visible imported thumbnails took 40–150 ms to generate
   but were claimed one at a time, approximately one per one-second apply flush.
3. Otos retains removable-source enrichment but import settlement copies none of it.
   The destination therefore repeats metadata extraction and thumbnail generation
   for bytes Otos already enriched on the card.

This plan restores the intended boundaries: destructive scan reconciliation is
conservative under concurrent namespace mutation; materialization produces ready
enrichment work but never consumes enrichment capacity; enrichment workers pull
continuously; persistence/UI publication remains coalesced; and a successful import
reuses valid derived overlay without deleting or weakening the source overlay.

Plan 0060 remains authoritative for XXH3-128 production and fact-only import
preexisting decisions. This plan supersedes only Plan 0060's statements that the
current enrichment scheduling lifecycle remains unchanged and that import settlement
must leave metadata/thumbnail enrichment incomplete even when the source has current,
validated overlay.

## Confirmed product contract

The implementation must preserve all of these statements together:

- Enrichment workers pull only files whose bytes are materialized and ready for
  immediate byte-reading work. A dataless file is routed to materialization before
  enrichment admission; `.notMaterialized` inside `MediaEnricher` remains only the
  final race-safety response to provider eviction between routing and byte access.
- Materialization demand, retries, and slow/failing providers consume no enrichment
  worker slot, ready-work slot, or ready-work discovery capacity. Materialization has
  its own bounded ownership and the shared `MaterializationCoordinator` remains the
  only physical-transfer scheduler.
- Ready enrichment priority is: current viewport first; newly materialized files
  second; other materialized removable-source files third; other materialized fixed-
  library files last. Existing byte-budget and video-concurrency admission still
  apply within that order.
- Enrichment workers pull continuously. Every completion immediately frees scheduler
  capacity and wakes another pull. The one-second cadence batches durable Store writes
  and UI notifications only; it never gates worker refill or candidate discovery.
- A viewport change is a newest-value priority hint. It can reorder queued ready work
  immediately but cannot cancel byte reads already in progress. No obsolete viewport
  is retained as a second source of priority truth.
- `FileMaterialization.status(of:)` remains transient and is never persisted. The
  coordinator performs a bounded off-main readiness-routing pass, and the enricher
  repeats the status check immediately before each byte-reading phase.
- A full scan may purge an item only from an observation that still owns destructive
  reconciliation for the current root namespace. A concurrent import settlement,
  reorganization settlement, targeted filesystem reconciliation, or other independent
  namespace mutation makes the scan's missing-set snapshot stale; stale observation
  may upsert observed facts but cannot delete catalog rows or overlay.
- Every import entry counted successful has one surviving destination row stamped with
  that batch ID and provenance. A successful batch of N published assets must query as
  N batch assets immediately after settlement, independent of concurrent scans/events.
- When the imported source row has current metadata, a current thumbnail outcome
  (app-owned JPEG or definitive unavailable), and a valid content signature for exactly
  the bytes published at the destination, settlement clones that derived overlay to the
  destination. It does not parse metadata or invoke Quick Look again.
- Source overlay remains attached to the source filesystem identity. Import creates a
  second destination overlay; it never moves or deletes the source thumbnail/metadata.
- Thumbnail filenames remain deterministic per filesystem identity. Reuse copies the
  app-owned JPEG to the destination identity's name; it does not point two catalog rows
  at a source-identity filename.
- If source overlay is absent, stale, malformed, source bytes do not match the imported
  bytes, or the thumbnail copy cannot be committed, import still succeeds and the
  destination follows ordinary ready-only enrichment. Reuse is an optimization guarded
  by correctness, never a condition for preserving user media.
- Import never copies source import history, source root identity, enrichment claims,
  retry state, or future authored per-path state. Only current, rebuildable extracted
  media metadata, normalized enrichment facts, and the derived thumbnail are cloned.
- Originals remain read-only except for the existing explicit import/reorganization
  operations. All reused overlay and thumbnails remain inside Application Support.

## Evidence and current-state oracle

Preserve the incident as a regression oracle rather than relying on inferred intent:

- Batch `1784443698433` planned and successfully settled 159 entries.
- The destination was the fixed OneDrive Camera Roll root; the source was removable
  volume `/Volumes/4152150790`.
- A destination full scan completed during the import with `deleted=1`.
- The affected source was `PRIVATE/M4ROOT/CLIP/C7295.MP4`; its destination was
  `2026/07/20260718_175619.mp4`.
- The destination file survived and a targeted event recreated its catalog row, but
  the recreated row had null `import_batch_unix_ms` and provenance. Batch queries
  returned 158 while a new plan classified all 159 files preexisting.
- For visible imported assets, `catalog.thumbnails.visibleLifecycle` repeatedly showed
  `claimed → generated` in roughly 40–150 ms, followed by about one second until
  `catalog.enrichment.coordinator phase=flush`, then the next single claim. Later claim
  diagnostics explicitly reported `limit=1`.
- The removable source retained metadata and thumbnails for the imported identities.
  Destination thumbnail names were all different and were generated later, proving
  settlement did not reuse source overlay.

Add a checked-in dated research note only if implementation gathers new platform or
benchmark evidence. This plan records the already-observed product/runtime facts; it
does not require online research.

## Current ownership problems

### Scan reconciliation

`CatalogStore.ActiveScan` proves only root instance and scan lease generation.
`scanCompleted` fetches *current* catalog rows after traversal, subtracts paths from the
earlier scanner observation, and deletes every difference. Rows inserted by another
owner after traversal passed their directory are therefore indistinguishable from rows
that existed before the scan and were proven absent.

FSEvents already retains typed dirty scopes while a scan lease is active, but those
events are drained only after `scanCompleted`; they cannot undo overlay/import history
that stale full-scan deletion already purged.

### Enrichment and materialization

`CatalogStore.enrichmentCandidates` orders viewport/fresh IDs first, then removable,
then fixed roots, but its eligibility predicate contains no live materialization fact.
The coordinator claims the row, marks it queued, dispatches it to `MediaEnricher`, and
only then converts `.notMaterialized` into `DownloadWork`.

`claimedWork` simultaneously contains `.queuedEnrichment`, `.enriching`,
`.awaitingApply`, `.awaitingMaterialization`, and `.materializing`. Its 32-entry cap is
checked before every Store query. Active enrichment has a separate eight-worker limit,
but the shared claim window means materialization waits and pending apply results can
leave eight workers idle with no ability to discover ready work.

`finishEnrich` signals immediately, but a completed result remains `.awaitingApply`
inside `claimedWork` until the one-second flush. Continuous pulling therefore works
only when already-queued work or unused claim-window capacity happens to remain.

### Import overlay settlement

`CatalogStoreImportJournal.settleImportedAsset` upserts destination filesystem facts,
then stamps batch/provenance and companions. It does not read the source row, copy
`asset_metadata`, copy normalized enrichment columns, or copy the app-owned thumbnail.
`ThumbnailStore` already derives different filenames from source and destination
filesystem identities and has atomic staging/promotion mechanics, but no copy-for-new-
identity operation.

## Invariants

- **S1 — Conservative deletion proof.** A full scan deletes only when its observation
  is still valid for destructive reconciliation. Uncertainty retains overlay and
  schedules another bounded reconciliation; it never guesses deletion.
- **S2 — Same-root mutation invalidates missing-set deletion.** Any independently
  settled namespace mutation after scan start invalidates that scan's delete phase,
  even when the mutation path is outside the scanner's current directory.
- **S3 — Observed upserts remain useful.** An invalidated scan may keep its already-
  applied observed fact batches; only missing-asset and missing-companion deletion is
  suppressed.
- **S4 — Eventual filesystem truth.** Suppressing stale deletion retains typed dirty
  work or enqueues exactly one follow-up full scan, so a real deletion eventually
  reconciles after a fresh complete observation.
- **S5 — Settlement is durable before success.** Executor reports `.published` only
  after the destination row, batch/provenance, reusable overlay decision, companions,
  and journal transition commit under existing FULL durability.
- **E1 — Ready means materialized now.** Only a positive live materialization probe may
  enter ready enrichment. `.unknown` is not ready and follows typed retry/reprobe,
  never a speculative byte read.
- **E2 — Independent capacities.** Ready/enriching work, materialization demand, and
  pending apply are separate bounded/finite state sets. No count from one is used to
  calculate capacity in another.
- **E3 — Work conservation.** If an admissible ready item exists and an enrichment
  worker is free, the coordinator dispatches it without waiting for apply cadence,
  projection cadence, materialization completion, scan notification, or an unrelated
  external wake.
- **E4 — Priority at every pull.** Newly visible ready items precede queued non-visible
  work at the next dispatch. Freshly materialized IDs precede removable/fixed fallback.
  Already-running work completes normally.
- **E5 — Publication isolation.** Completed results retain their Store lease until
  apply validation, but they leave scheduler capacity immediately. Store lease state
  prevents duplicate claims without occupying an in-memory ready slot.
- **E6 — Final safety gate.** Provider eviction after routing returns the identity to
  materialization without accidental byte fault and without poisoning ready capacity.
- **E7 — Bounded traversal.** A dataless library cannot make one wake scan the whole
  catalog. Readiness routing uses bounded batches/passes and materialization demand uses
  the existing physical admission limits and retry ledger.
- **O1 — Reuse proves byte equivalence.** Source enrichment is reusable only when its
  stored source signature is current and its Plan-0060 XXH3-128 digest equals the digest
  of the imported staging bytes recorded in the journal.
- **O2 — Destination stamps describe destination facts.** Cloned overlay carries the
  destination size/mtime/hash validity signature, not the source path or source mtime.
- **O3 — Two independent thumbnails.** Reuse atomically copies source thumbnail bytes
  to the deterministic destination name. Deleting either asset later cannot remove the
  other's thumbnail.
- **O4 — Crash recovery is idempotent.** Re-settling `.publishedPendingSettlement`
  either observes the already-copied destination thumbnail/overlay or repeats the same
  validated copy; it never requires source media bytes or creates duplicate metadata.
- **O5 — No stale overlay promotion.** If source overlay changes or becomes stale
  between snapshot and settlement, Store writes no cloned overlay and leaves the
  destination eligible for normal enrichment.

## Stage 0 — Lock documentation and dependency order

1. Implement Plan 0060's typed XXH3 digest, enrichment hash validity, import staging
   hash, and journal persistence before Stage 4 of this plan. Stages 1–3 may land in
   the same implementation increment only if their tests remain independently reviewable.
2. Rewrite ADR 0009 (or supersede it with the next ADR if its ownership would become
   non-MECE) so current architecture states three distinct lifecycles: transient
   readiness/materialization, continuous ready enrichment, and coalesced persistence.
3. Update ADR 0008 only where overlay cloning across an explicit import needs clarity:
   source and destination remain different path identities with independent lifecycles;
   copying valid rebuildable overlay does not make hashes or thumbnails asset identity.
4. Update `docs/architecture.md` ownership/dataflow and the where-to-change table.
5. In the implementation PR update requirements current truth, at minimum ARC-034,
   ARC-044, ARC-047, and ARC-048 plus the enrichment scheduling row(s). Requirements
   must say ready-only/continuous pull and batch-count survival observably, not encode
   private type names as product behavior.
6. Remove this plan when all stages are implemented and merged. Do not retain it as an
   increment history document.

## Stage 1 — Make full-scan deletion safe under concurrent namespace mutation

### 1.1 Add an explicit destructive-reconciliation epoch

Add a process-local per-root namespace mutation epoch owned by `CatalogStore` (either
on `RootRuntimeState` if every mutation owner naturally reaches it, or in one focused
Store dictionary if it must remain non-presentation runtime state). Extend `ActiveScan`
with the epoch captured immediately before traversal starts.

The epoch is not persisted and is not the import planner's `occupancyRevision`:

- scan batches must not invalidate their own scan;
- enrichment/detail writes never advance it;
- independent namespace owners do advance it: import settlement, reorganization
  settlement, targeted file/subtree reconciliation that adds/removes/replaces media,
  explicit root mutation, and any other path-membership mutation not produced by that
  active full scan;
- root row ID plus scan lease generation still protect remove/re-add identity races.

Keep one helper such as `recordIndependentNamespaceMutation(root:dirtyScope:)` so no
caller bumps an epoch without also retaining the exact reconciliation work that will
restore eventual truth.

### 1.2 Gate destructive completion

At `scanCompleted`, after every await and immediately before delete reconciliation:

1. Revalidate `owns(scan)`.
2. Compare the root's current independent namespace epoch with `scan.startEpoch`.
3. If equal, reconcile missing media and companions as today.
4. If different, skip *both* missing-media deletion and missing-companion deletion,
   retain/merge the typed dirty scopes recorded by the mutating owner, and emit one
   machine-greppable `catalog.scan.reconcile phase=deferredStaleObservation` event with
   root, lease generation, start/current epochs, and dirty-scope counts.
5. Clear the scan lease normally; `afterFilesystemLeaseCleared` drains retained file/
   subtree dirt. If a mutation owner cannot supply a complete typed scope, retain one
   root-dirty marker so exactly one fresh full scan proves deletion.

Do not solve this by statting only the reported missing path after the fact. A stat
narrows this incident but leaves a filesystem/SQLite check-then-delete race and cannot
protect companion or same-path replacement overlay. Epoch invalidation is conservative,
typed, and actor-owned.

### 1.3 Make import settlement participate before the SQLite write

`CatalogStore.settleImportedAsset` knows the exact destination path. Before its first
database await/write, record that file scope as an independent namespace mutation when
a full scan owns the same root. The marker and epoch advance occur synchronously in
Store isolation; after the await, revalidate root row identity before applying results.

The subsequent targeted reconcile must use the normal upsert path, which preserves the
batch/provenance and cloned overlay columns. It may refresh filesystem facts but cannot
replace the semantic settlement row with an untagged row.

Apply the same helper to reorganization settlement and other known concurrent mutation
owners so the fix is architectural rather than import-specific.

### 1.4 Add batch-integrity diagnostics

After the executor task group finishes and all successful settlements have returned:

- query Store for the batch asset count;
- log expected published count, stored batch count, skipped-preexisting, skipped-
  foreign, failed, and blocked counts in one `mediaOperation.batch phase=verified`
  event;
- emit a fault and surface the existing attention/failure path if stored count differs
  from successful published count. Do not silently report complete success for a batch
  whose durable history is already inconsistent.

This is a diagnostic/invariant check, not the primary repair. Correct scan ownership
must make the counts equal.

### Stage 1 tests

- Pause a full scan after it has passed the future destination directory, settle one
  import, then complete the old observation. The imported row, batch ID, provenance,
  metadata, thumbnail path, and hash survive; batch count is one.
- Repeat with 159 settlements interleaved across scan batches; expected/stored count is
  159 and a second plan sees 159 preexisting files.
- An independent same-path replacement during a scan preserves the replacement row and
  its overlay; the stale scan cannot purge either.
- A companion imported during a scan is not removed by stale companion reconciliation.
- A genuine deletion with no intervening mutation is purged after one complete scan.
- A genuine deletion concurrent with another mutation is conservatively retained by the
  stale scan and removed by the retained targeted/follow-up reconciliation.
- Mutation of root A does not invalidate root B's scan.
- Removed/re-added same-path root callbacks remain rejected by row ID and lease generation.
- The stale-observation diagnostic fires once with exact epoch/scope fields; normal scans
  do not emit it.

## Stage 2 — Separate readiness routing from enrichment work

### 2.1 Replace the five-state shared claim window

Refactor `EnrichmentCoordinator` so one dictionary no longer owns unrelated stages.
Keep the smallest explicit state model:

- `readyClaims`: Store-claimed, positively materialized work that is queued or actively
  enriching. Its capacity bounds only ready/enriching work.
- `materializationDemands`: dataless/unknown work submitted or waiting to submit to the
  shared materializer. It has its own handoff/retry bounds and Store-claim refresh.
- `pendingApply`: completed `EnrichmentResult`s awaiting the coalesced Store write. A
  pending result retains its SQLite lease but is absent from `readyClaims`.
- `retryLedger`: bounded pacing for released materialization failures, retained from
  current behavior.
- `freshly`: the bounded newest-first identity hint produced only by successful
  materialization, consumed when Store returns that identity ready.

Delete `ClaimedWorkState.awaitingMaterialization`, `.materializing`, and
`.awaitingApply` from ready scheduler ownership. Rename types/comments so “claim
window” cannot again be interpreted as a cross-pipeline capacity.

### 2.2 Add an injectable live readiness router

Add one small Sendable readiness dependency around `FileMaterialization.status(of:)`
for deterministic tests. Candidate routing runs off the main actor and produces typed
outcomes:

- `.ready(EnrichWork)` for `.materialized`;
- `.needsMaterialization(DownloadWork)` for `.dataless`;
- `.retryReadiness` for `.unknown`, paced without byte access.

Store continues to derive the durable “needs enrichment” backlog and lease candidates.
The readiness router handles each bounded claimed batch before admission:

1. Query prioritized Store candidates.
2. Probe each candidate without reading bytes.
3. Put only `.ready` candidates in `readyClaims`.
4. Move dataless candidates into independently bounded materialization demand without
   consuming ready capacity.
5. Release excess/unknown claims with a paced retry when materialization demand is full;
   never retain thousands of waiters merely to walk past them.
6. Continue bounded claim/probe passes until available enrichment slots are filled,
   Store is exhausted, or a small explicit per-wake routing bound is reached.

The pass bound prevents a 25k dataless catalog from monopolizing the coordinator actor.
Because routed dataless rows retain separate Store leases while demand is active, the
next pass naturally reaches later candidates instead of reclaiming the same head rows.

### 2.3 Preserve and make priority explicit

Build one deduplicated priority sequence for each Store claim:

1. current viewport IDs;
2. successful materialization IDs in newest-completion order;
3. Store fallback removable roots;
4. Store fallback fixed roots.

Within fallback keep newest best-capture date and stable path tie-breakers. Within the
viewport preserve the grid-provided visible order unless a measured/UI requirement
chooses another order; remove the unexplained reversal or document/test why it is
correct. A viewport update reorders queued `readyClaims` by current priority before
sequence fallback.

Materialization priority remains independently owned by `MaterializationCoordinator`.
Viewport dataless demand must be distinguishable from background eager demand so it can
use interactive admission without changing enrichment ordering; removable device
staging retains device priority.

### 2.4 Keep the final safety gate

`MediaEnricher.live` keeps `FileMaterialization.status` immediately before metadata,
hashing (after Plan 0060), and Quick Look byte reads. If a ready file regresses to
dataless:

- `finishEnrich(.notMaterialized)` removes it from `readyClaims` immediately;
- registers separate materialization demand with the correct current priority;
- signals refill so another ready asset can use the freed worker;
- never leaves the regressed item counted against ready capacity.

### Stage 2 tests

- A candidate reported dataless by readiness routing never invokes `MediaEnricher`.
- Thirty-two indefinitely failing materializations coexist with eight materialized
  viewport candidates; all eight viewport enrichments dispatch without waiting for a
  materialization transition.
- A bounded pass routes dataless head candidates aside and reaches a materialized ready
  candidate later in Store order.
- `.unknown` status performs no byte read, does not enter ready work, and is retried with
  bounded pacing.
- A provider eviction between routing and `MediaEnricher` returns to materialization and
  immediately refills the worker from another ready item.
- Materialization success adds exactly one fresh hint; the next ready claim ranks it
  after viewport and before removable/fixed fallback.
- Viewport materialization demand outranks background demand in the materializer while
  retaining the materializer's byte/video/root fairness.
- The 25k-dataless-library test proves ready state, separate materialization state,
  Store leases, and per-wake candidate probes are bounded independently.
- Shutdown cancels/releases ready claims and materialization waiters and discards staged
  pending thumbnails without leaking Store leases.

## Stage 3 — Make enrichment workers continuously work-conserving

### 3.1 Release scheduler ownership at completion

For `.complete(result)`:

1. Remove the identity from active `readyClaims` immediately.
2. Append a pending-apply record containing the result and its still-owned Store lease.
3. Schedule the existing one-second apply flush if none exists.
4. Signal the supervisor immediately.
5. On that wake, fill every admissible free enrichment slot from current ready priority,
   routing additional candidates as needed.

Do not wait for `CatalogStore.applyEnrichmentBatch` before steps 1–5. SQLite's
`enrichment_claimed_until` prevents the pending identity from being claimed again.

For `.transient`, release the Store claim and ready slot, pace if required, and signal
refill. For `.notMaterialized`, follow Stage 2.4. Zero-byte definitive results enter
pending apply without materialization and likewise release scheduler capacity.

### 3.2 Keep persistence and publication coalesced

`pendingApply` remains time-batched at one second. One flush:

- snapshots the pending buffer;
- validates every result's destination row/source signature;
- promotes accepted staged thumbnails;
- writes all accepted overlay in bounded Store transactions;
- releases Store leases exactly once in the Store-owned apply path;
- emits one detail-change notification for the accepted batch;
- requeues only validated stale drops, with write failure using existing backoff.

Remove the coordinator's duplicate post-apply claim release if Store remains the owner.
Results arriving during a flush stay in the next buffer and schedule the next cadence;
they do not block workers.

If measurement shows an unbounded number of sub-100-ms completions can accumulate in
one second, add a simple maximum batch size that triggers an earlier persistence flush.
That limit bounds pending result memory/disk staging only and must not become an
enrichment worker gate.

### 3.3 Add work-conservation instrumentation

Emit transition-only, machine-greppable snapshots with separate counts:

- ready queued, enriching, pending apply;
- materialization pending/in flight;
- free enrichment slots and rejection reason;
- readiness probes and routed outcomes per wake;
- worker completion-to-next-dispatch delay;
- flush batch count, oldest-result age, Store write time, and notification count.

Add a fault when `freeEnrichmentSlots > 0`, an admissible ready item exists, and no
dispatch occurs. Do not log every idle wake when Store has no ready work.

### Stage 3 tests and performance proof

- With eight workers and at least 24 fast materialized assets, the second group starts
  before the one-second flush fires; all worker slots stay occupied until ready work is
  exhausted.
- A controlled flush sleeper proves zero Store writes/notifications before the tick
  while multiple worker generations complete continuously.
- At the tick, completed results apply in one batch and produce one detail notification.
- Viewport change between worker generations makes newly visible queued work dispatch
  before old background work.
- Byte-budget and two-video caps still reject only actual active enrichment; pending
  apply and materialization bytes do not enter their snapshots.
- A Store write failure releases leases, preserves staged-thumbnail cleanup semantics,
  backs off, and does not create a read/generate tight loop.
- Instrument the incident-equivalent 159 materialized imports: record p50/p95/max
  generation time, completion-to-next-dispatch delay, active-worker utilization, apply
  batch sizes, time to first visible thumbnail, and time to fill the initial viewport.
  Compare against the captured one-at-a-time baseline.
- Run `script/profile.sh` with the appropriate Time Profiler/Hangs template while the
  initial imported viewport enriches. Attach the trace and worst-span summary; confirm
  no byte-reading or SQLite work moved to MainActor.

## Stage 4 — Clone valid removable-source enrichment during settlement

### 4.1 Define a typed reusable-overlay snapshot

Add a Store-private value containing only rebuildable enrichment state required for a
new destination identity:

- complete `AssetMetadata`/`asset_metadata` fields and extra JSON;
- normalized enriched kind/format and timestamp facts;
- duration and other enrichment-derived media columns;
- source thumbnail relative path plus whether the app-owned file exists;
- source enrichment size/mtime signature;
- Plan-0060 XXH3-128 digest and its source signature.

Do not expose this value to SwiftUI or persist it as a second table. It is a settlement
input read from the source row in the same catalog.

### 4.2 Validate reuse against the actual imported bytes

At normal and recovery settlement, inside Store ownership:

1. Resolve source and destination root row IDs from the journal's normalized paths;
   revalidate them after every await.
2. Fetch the source asset and overlay by `sourceRootPath + sourceRelativePath`.
3. Require the source enrichment and hash signatures to match the source row's current
   size/integer-second mtime.
4. Require the journal's import staging digest from Plan 0060 to equal the source's
   current XXH3 digest. The digest describes bytes only and is not identity or planner
   input.
5. Require settled destination size/mtime to match the journaled published facts.
6. If any condition fails, record a typed reuse miss and settle without enrichment
   stamps so ready-only enrichment later owns the destination.

Do not accept matching filename, size/mtime alone, provenance alone, or a thumbnail file
alone as proof that extracted metadata belongs to the published bytes.

### 4.3 Copy the thumbnail for the destination identity

Add `ThumbnailStore.stageCopy(sourceRelativeName:destinationID:in:)` (exact name may
vary) that:

- reads/copies only the app-owned thumbnail JPEG in Application Support, never source
  media bytes;
- stages beside the destination's deterministic thumbnail filename;
- validates that the source file is a readable regular app-owned file;
- promotes atomically using the same replace/no-orphan rules as generated thumbnails;
- leaves the source thumbnail untouched;
- is idempotent when recovery repeats settlement.

Coordinate file and SQLite failure as existing thumbnail promotion does. If copy or
promotion fails, discard temporary output, log the miss, and settle the destination as
needing normal enrichment. If SQLite settlement fails after promotion, remove only an
unreferenced destination copy on rollback/error; never remove the source thumbnail.

### 4.4 Clone overlay in the durable settlement transaction

Extend the semantic Store settlement—not the executor—with an optional validated
reuse decision. In the same FULL-durability transaction that upserts the destination
row and stamps batch/provenance:

- write destination enrichment columns using the cloned values;
- stamp `enriched_source_size` and `enriched_source_mtime` from destination facts;
- copy/upsert the `asset_metadata` row under destination identity;
- set the destination thumbnail path to its deterministic copied name;
- preserve the Plan-0060 imported content hash and destination hash signature;
- upsert companions and advance the journal phase as today.

Source rows and source thumbnail references are read-only in this transaction. Reuse
must work for filesystem removable volumes and MTP/camera catalog identities whenever
their source overlay and digest are present. Camera staging-byte reuse remains separate:
it avoids a second device download, while this stage avoids a second metadata/thumbnail
decode.

### 4.5 Define recovery and source-removal behavior

- `.publishedPendingSettlement` retries the same validation/copy using journaled source
  identity and digest. If the source has been detached or removed, it settles without
  cloned overlay and normal enrichment handles the destination; recovery never blocks
  the imported file on overlay reuse.
- Copy imports retain source rows and source overlay normally.
- Move/delete-source imports clone overlay before requesting source deletion. Later
  proven source deletion purges only source overlay; destination metadata and thumbnail
  remain independent.
- A successful clone means the destination is already enrichment-current and never
  enters ready work unless destination facts later change or Plan 0060 hash validity is
  missing/stale.

### 4.6 Instrument reuse

For every batch, aggregate—not per-file spam—the counts:

- reuse eligible;
- metadata cloned;
- thumbnail copied;
- miss by absent source row, stale source overlay, missing/mismatched hash, missing
  thumbnail, thumbnail copy failure, or detached source;
- destination assets left for enrichment.

Log batch reuse time and thumbnail bytes copied. For a diagnosed visible asset, retain a
single lifecycle event showing `overlaySource=reusedImport` so absence of redundant
enrichment is directly provable.

### Stage 4 tests

- A current enriched removable source plus matching staging digest settles a destination
  with identical metadata values, destination-valid stamps, destination thumbnail name,
  and copied thumbnail bytes; `needsEnrichment == false` immediately.
- Source metadata and thumbnail remain unchanged and survive destination deletion; the
  destination copy survives later source deletion/eject/reconciliation.
- Source and destination deterministic thumbnail names differ and both files exist.
- Missing source metadata, stale size, stale mtime, malformed/missing digest, digest
  mismatch, missing thumbnail file, and copy failure each settle media safely and leave
  destination eligible for ordinary enrichment.
- A definitive source “no thumbnail available” result clones metadata and the definitive
  nil-thumbnail outcome without retrying Quick Look merely because no JPEG exists.
- Recovery repeats a partially/fully completed thumbnail copy without duplicates or
  source deletion.
- MTP import with reusable staging bytes and current source overlay performs neither a
  second device download nor a second metadata/Quick Look pass.
- Importing the same source to two destination identities creates two independent
  destination thumbnail files and overlay rows.
- A source change after planning but before settlement defeats reuse even if path and
  filename are unchanged.
- The 159-asset incident fixture produces 159 batch rows and 159 immediately current
  destination overlays with zero destination `MediaEnricher` calls.

## Stage 5 — Integration sequence and verification

Implement in reviewable commits without leaving contradictory production states:

1. Scan reconciliation epoch + adversarial lifecycle tests + batch integrity logging.
2. Ready/materialization/pending-apply state separation and readiness routing.
3. Continuous worker refill, apply isolation, instrumentation, and profiler evidence.
4. Reusable overlay snapshot, thumbnail identity copy, settlement/recovery integration.
5. Requirements/ADR/architecture current-truth updates and final instrumentation review.

Run `script/verify.sh` after every stage that changes shared Store/coordinator models and
once on the final implementation. The final proof includes:

- Xcode/macOS versions;
- full verify result;
- focused scheduler, scan-race, settlement, recovery, and thumbnail lifecycle tests;
- incident-equivalent log artifact and counts;
- Time Profiler/Hangs trace and worst spans;
- confirmation that originals and removable-source overlay were not mutated;
- confirmation that logs contain paths/counts/timings but no metadata payloads or media
  bytes;
- code-smell review for state duplication, unsafe concurrency escape, MainActor gravity,
  diagnostic sprawl, and parallel action paths.

## Definition of done

This implementation is done only when:

- an adversarial concurrent scan cannot reduce a successful import batch count;
- ready enrichment remains work-conserving independently of materialization and the
  one-second apply cadence;
- viewport/fresh/removable/fixed priority is observable and tested;
- a valid enriched removable source produces an immediately enriched destination with
  no second media-byte enrichment pass;
- source and destination overlay lifecycles remain independent;
- requirements, ADRs, architecture, tests, and instrumentation describe the same
  current behavior;
- the implementation plan is deleted, the PR is merged, and branch/worktree cleanup is
  complete under the repository Definition of Done.
