# Plan 0055 — Import planning, history, and library reorganization

Status: active architecture and implementation plan.  Product contract confirmed
by Taylor on 2026-07-10.  Research: [Import planning, filesystem operations, and
recovery](../research/2026-07-10-import-planning-filesystem-operations.md).
Delete this file when every stage is implemented and landed.

This plan adds a deterministic import-plan overlay for every attached removable
filesystem volume and MTP/PTP camera, imports the complete source into any fixed
library, records import batches in the sidebar, and then reuses the planning core
to reorganize originals already inside a library. It is written so an implementer
does not need the research conversation or the retired app.

Each stage below is its own worktree, PR, review, `script/verify.sh` run, runtime
evidence, and final DoD. Do not combine stages merely to reduce PR count. Where a
later stage depends on an earlier type, land the earlier boundary first.

---

## 1. Confirmed product contract

These are requirements, not implementation suggestions.

### Sources, destination, and scope

1. A source is an attached removable filesystem volume or an attached MTP/PTP
   camera represented by the current removable-source model. A destination is one
   user-configured fixed Otos library. Any source can target any fixed library.
2. An import always covers **every catalog-eligible image/raw/video asset on the
   source**. Browser selection, sidebar filters, media filters, and search never
   narrow it. Partial import is explicitly deferred.
3. Otos inventories immediately, enriches in the background, and greedily builds
   a complete ready plan for every attached source once that source's inventory,
   required metadata, companion enumeration, and destination choice are complete.
   Attaching media never auto-executes a plan.
4. The user may press Import before enrichment finishes. That records one queued
   start intent; the UI says it is waiting for metadata, and execution begins as
   soon as the complete source becomes plan-ready. A second press does not enqueue
   a second import.
5. Every media asset has a real best date. Embedded metadata wins; the final
   fallback is the source filesystem/camera modification date. A fabricated date
   such as planning time, staging time, download time, or “now” is forbidden. If a
   source API genuinely supplies no usable date, the source is blocked as invalid
   rather than producing dateless media.

### Destination policy and duplicate behavior

6. The naming policy matches the useful `gomediaimport` surface:
   `DestinationFolders.none` or `.yearMonth`, combined with
   `DestinationNames.original` or `.captureDateTime`. Date-time names use
   `YYYYMMDD_HHMMSS`; filename extensions are lowercased consistently with current
   catalog format handling. Same-second/conflicting names receive `_001`, `_002`,
   and so on in natural source-relative-path order.
7. Import duplicate classification applies only when a planned destination
   candidate already exists. Equal byte size is a cheap gate; exact equality is
   then proved by an on-demand content comparison. An unreadable/detached/provider-
   failed candidate is **blocked comparison**, not “probably duplicate.” A
   different file keeps both originals through deterministic suffixing.
8. A successful OS copy/download is trusted. Do not reread or checksum the new
   destination to prove it byte-identical. Staging plus no-overwrite publication
   prevents partial final files; OS errors are operation failures.
9. Import is idempotent. Formally: with unchanged source contents, destination
   contents, and settings, repeating plan plus execute creates no additional
   destination files and no new import-batch timestamps. It may only finish
   durable settlement, requested source cleanup, or eject left pending by an
   interrupted earlier execution.

### Sidecars, cleanup, and history

10. Recognized useful source companions are `.xmp`, `.srt`, and `.lrc` (case
    insensitive). A new global **Import sidecar files** toggle lives in an Import
    tab in Settings. When enabled, a recognized companion follows its primary's
    chosen directory and basename. Unknown companions and known device artifacts
    are ignored, never silently deleted. Otos does not generate metadata sidecars.
11. Source-original deletion is explicit opt-in and defaults off. Delete only a
    source whose destination outcome is a newly published copy or a proved
    pre-existing equal file. Sidecar cleanup follows the same rule. Auto-eject is
    explicit opt-in and happens only after every media/sidecar operation and
    requested source deletion succeeded. Cleanup/eject failure does not roll back
    a completed destination copy and is visible/retryable.
12. Every media asset newly published by an **import** receives the same import
    batch timestamp. Proved pre-existing skips do not acquire a new timestamp.
    Reorganization never creates a batch and preserves any existing batch value.
    Nonempty import batches appear newest-first under an Imports section in the
    sidebar and select their surviving assets across fixed libraries.

### Plan freshness, reorganization, and execution

13. Source or destination filesystem/catalog changes invalidate dependent plans
    and greedily rebuild them. FSEvents supplies invalidation; it is not a lock or
    proof of unchanged state. Start uses a cheap root-revision consistency guard,
    and each file operation checks its planned source size/mtime immediately
    before mutation. A race at publication fails safely without overwrite, then
    invalidates/replans. There is no whole-source byte-reading “preflight.”
14. Library reorganization uses the same date/name/reservation planning core but
    distinct move semantics. Before any conflict work, compare the normalized
    source and proposed destination paths: equality is a no-op. Reorganization
    **never content-deduplicates or collapses originals**, even when two files are
    byte-identical. Occupied targets use a dependency-aware move or deterministic
    suffix so every original remains represented.
15. Execution is user-started, cancellable between files, bounded, observable, and
    crash-recoverable. Cancellation stops scheduling new work but does not undo
    successfully published items. Recovery may settle already-published files,
    finish requested cleanup, or remove abandoned staging; it never resumes an
    unstarted byte copy without a new user start intent.

### Explicitly deferred

- Partial/import-selected-media workflows.
- Auto-import merely because a source attached.
- Content-based durable asset identity or persistent content fingerprints.
- Writing Otos metadata/edit overlay into XMP or other source sidecars.
- A permanent archive of old immutable plan payloads or per-file success logs.
- Multiple simultaneous imports/reorganizations. Start with one global execution.
- Undo after a completed reorganization. Recovery protects interruption; it is not
  a user-facing historical undo stack.

---

## 2. Current-state constraints the implementation must preserve

- The filesystem remains the media source of truth; a plan is an ephemeral
  proposed mutation, never catalog truth.
- `MediaAssetID == (LibraryRootPath, relativePath)`. Import creates a new identity
  in a fixed library. Reorganization changes identity and must atomically carry
  overlay to the new path.
- `CatalogStore` remains the only owner of GRDB, catalog rows, root runtime state,
  and persisted overlay. A new coordinator may call typed Store APIs; it does not
  open SQLite.
- `EnrichmentCoordinator` remains the only background owner that materializes and
  reads media bytes for enrichment. Duplicate comparison is deliberate user-
  initiated planning work and must check `FileMaterialization` immediately before
  each byte read.
- `CatalogProjection` remains the catalog browser projection. Import plans are a
  separate overlay and must not make Projection publish a full asset dictionary.
- `CatalogWindowViewModel` owns final MainActor assignment and task lifetimes.
  Views remain passive and call owner intents.
- The single-window invariant remains unchanged. Import Settings uses the existing
  Settings scene.
- Otos still never writes generated sidecars into user media folders. Supporting
  existing companion files means copying/moving user-owned files only during an
  explicit media operation.

One existing persistence policy must change before history ships: destructive
schema reset is incompatible with non-rebuildable import history. Stage A replaces
it with additive migrations and a clear future-schema refusal policy.

---

## 3. Architecture decision and ownership

### 3.1 Selected owner graph

```text
Removable monitor / camera monitor / FSEvents
                    │
                    ▼
             CatalogStore actor
  catalog truth + root revisions + companions + history + journal
          │ planning snapshots / typed notifications
          ▼
      MediaOperationCoordinator actor
  eager plan lifecycle + queued start + one execution + recovery
          │                         │
          │ pure inputs             │ byte/file operations off-main
          ▼                         ▼
  MediaTransferPlanner       ContentEqualityChecker
       (pure value)             MediaFileOperator
          │
          ▼ scalar state stream + visible detail reader
 CatalogWindowViewModel (@MainActor)
          │
          ▼
 passive sidebar / plan footer-overlay / Settings views
```

`CatalogStore` answers “what currently exists and what durable overlay belongs to
it?” `MediaOperationCoordinator` answers “what operation is ready/running?” The
pure planner answers “given one immutable snapshot and policy, what should happen?”
No other type answers any of those questions.

### 3.2 Coordinator alternatives

#### A. Put planning and execution in `CatalogStore`

Pros:

- one actor already receives every catalog and availability mutation;
- no cross-owner revision protocol;
- import history settlement is locally serial.

Cons:

- content comparison, file coordination, retry, recovery, and UI operation state
  would turn the database/catalog actor into a long-lived workflow engine;
- suspended file I/O would delay unrelated catalog queries and scans unless work
  were split into helper tasks with complicated lease revalidation;
- reorganization dependencies do not belong to catalog persistence.

This is viable for a tiny synchronous importer, but not the simplest ownership
once eager plans, queued starts, cancellation, and reorganization share a lifecycle.

#### B. One `MediaOperationCoordinator` actor, Store-owned durable facts (selected)

Pros:

- one owner serializes all plan invalidation, queued intent, active execution, and
  stale completion rejection;
- Store stays focused on catalog truth/SQL while typed snapshots retain one source
  of facts;
- a pure planner is straightforward to test for deterministic import and reorg;
- one global execution is natural and prevents source/destination overlap races.

Cons:

- revisions and Store notifications form an explicit protocol that must be tested;
- coordinator recovery calls Store across actor boundaries and must revalidate
  after every await;
- the ViewModel has one more owned stream/task.

#### C. One actor per source plus a registry/executor actor

Pros:

- source attach/detach cancellation is locally contained;
- independent sources can plan concurrently;
- eventual parallel imports would have an obvious shape.

Cons:

- destination conflicts are global, so per-source actors still need a shared
  reservation authority;
- actor/job lifetime and stream cleanup multiply with every remembered source;
- the retired app demonstrated the cost of a broad job graph before the product
  needs concurrent execution.

Do not choose C until measurement or a verified concurrent-import requirement
proves B inadequate.

### 3.3 Concrete types

Add these files/types; names are part of the plan so implementation stays coherent:

- `Otos/Models/MediaOperationModels.swift`
  - `MediaOperationMode`: `.import(source:destination:batch:)`,
    `.reorganize(library:)`.
  - `ImportBatchID`: typed UTC epoch milliseconds. Store as `Int64`; render in the
    user's locale/time zone only in the sidebar.
  - `ImportPolicy`: destination folder/name policies, sidecar import, source
    deletion, auto-eject.
  - `PlanningFileFacts`: asset ID, source URL, byte size, mtime, best date, media
    kind, extension, companions.
  - `MediaOperationPlan`: immutable generation, mode, source/destination root
    revisions, policy, naturally ordered entries, totals.
  - `MediaOperationPlanEntry`: source facts, ideal/final destination, companions,
    and `MediaOperationDisposition`.
  - dispositions: `.copy`, `.skipPreexisting`, `.relocate`, `.noOp`, `.blocked`.
  - `MediaOperationSourceState`: `.inventory`, `.waitingForDestination`,
    `.waitingForMetadata(done:total:)`, `.planning`, `.ready(summary:generation:)`,
    `.queuedForReadiness`, `.executing(progress:)`, `.needsReplan`,
    `.completed(summary:)`, `.failed(problem:)`.
- `Otos/Services/MediaTransferPlanner.swift`: nonisolated pure planning functions.
- `Otos/Services/MediaOperationCoordinator.swift`: actor and lifecycle owner.
- `Otos/Services/ContentEqualityChecker.swift`: deliberate, ephemeral comparison.
- `Otos/Services/MediaFileOperator.swift`: coordinated copy/move/publish/delete.
- `Otos/Stores/MediaOperationGateway.swift`: Store-owned planning snapshot,
  history, revision, settlement, and journal SQL/mapping. This is an owned helper,
  not an actor and not a second database owner.
- `Otos/ViewModels/CatalogWindowViewModelMediaOperations.swift`: UI intents and
  named task lifecycle.
- `Otos/Views/ImportPlanFooter.swift`: source plan/readiness/progress controls.
- `Otos/Views/ImportPlanOverlay.swift`: optional per-visible-item disposition.

Keep architecture-boundary guides at the top of the coordinator, planner, gateway,
and file operator explaining isolation, cancellation, revision validation, staging,
and settlement.

---

## 4. Persistence and model changes

### 4.1 Migration safety first

In `CatalogStorePersistence.swift`:

1. Remove `migrator.eraseDatabaseOnSchemaChange = true`.
2. Replace automatic unsupported-schema erasure with:
   - apply every known additive/transform migration in order;
   - if the database was written by a future unsupported app schema, refuse to
     open it and log/present a specific compatibility problem without erasing;
   - reserve an explicit user-confirmed “Rebuild Catalog” operation for a later
     requirement. Do not silently use it as migration behavior.
3. Add migration tests starting from every checked-in prior schema fixture plus a
   future-version fixture whose history row survives refusal.
4. Rewrite the persistence/version section of ADR 0008 (or supersede it with a
   persistence ADR) before adding history. Update `docs/architecture.md` and the
   affected ARC requirements in the same implementation PR.

### 4.2 Schema

Use the smallest durable schema:

```sql
ALTER TABLE media_asset
ADD COLUMN import_batch_unix_ms INTEGER;

CREATE INDEX idx_media_asset_import_batch
ON media_asset(import_batch_unix_ms, library_root_id, relative_path)
WHERE import_batch_unix_ms IS NOT NULL;

CREATE TABLE media_companion (
    library_root_id INTEGER NOT NULL,
    relative_path TEXT NOT NULL,
    primary_relative_path TEXT,
    kind TEXT NOT NULL,
    byte_size INTEGER NOT NULL,
    content_modified_at DOUBLE NOT NULL,
    PRIMARY KEY (library_root_id, relative_path),
    FOREIGN KEY (library_root_id) REFERENCES library_root(id) ON DELETE CASCADE
);

CREATE TABLE active_file_operation (
    operation_key TEXT PRIMARY KEY,
    mode TEXT NOT NULL,
    source_kind TEXT NOT NULL,
    source_device_identity TEXT,
    source_root_path TEXT NOT NULL,
    source_relative_path TEXT NOT NULL,
    destination_root_path TEXT NOT NULL,
    destination_relative_path TEXT NOT NULL,
    staging_path TEXT,
    import_batch_unix_ms INTEGER,
    source_byte_size INTEGER NOT NULL,
    source_modified_at DOUBLE NOT NULL,
    phase TEXT NOT NULL,
    delete_source_requested INTEGER NOT NULL,
    updated_at DOUBLE NOT NULL
);
```

Refine column spelling to current conventions, but do not add a durable plan table,
content hash, asset UUID, import-batch table, or per-file completed-operation log.
`source_device_identity` is the existing removable-source identity, not a new media
identity; it lets pending cleanup find the same source after a remount/path change.

Why no `import_batch` table: a batch currently has exactly one durable fact—the
timestamp shared by newly imported surviving assets. `SELECT DISTINCT` provides
the sidebar rows, and a batch naturally disappears when its last asset is proven
deleted. Introduce a table only when a verified requirement adds batch-authored
metadata that cannot live on assets.

### 4.3 Path remap and foreign keys

Reorganization changes the `media_asset` composite primary key. Make the existing
`asset_metadata` relationship `ON UPDATE CASCADE` (rebuild the table in the
migration if SQLite requires it). Add one Store transaction:

```swift
func settleRelocation(
    from: MediaAssetID,
    to: MediaAssetID,
    observedFacts: ScannedFileFacts
) throws -> CatalogIdentityRemap
```

It must:

1. prove the old row still has the planned size/mtime and the target row is absent;
2. update path identity and current scan facts;
3. carry metadata and `import_batch_unix_ms` unchanged;
4. update companion relative paths;
5. update/rename the deterministic thumbnail file and stored thumbnail reference;
6. return an old→new typed remap for ViewModel selection and `TileContentStore`;
7. increment the affected root revision and publish one lossless mutation event.

If any proof fails, roll back the database transaction and report stale settlement;
never create a second catalog row for the moved original.

### 4.4 Best-date invariant

Change the persisted best-date contract from nullable to logically total for every
cataloged media row:

```text
embedded capture candidates
→ source creation date when already part of the accepted metadata policy
→ source content-modification date (mandatory final fallback)
```

Do not use enrichment completion time. The scanner already owns source mtime and
must store a valid value for every regular file. Camera enumeration must use the
first valid real value from `fileModificationDate`, `modificationDate`, and
`exifModificationDate` when embedded metadata has no date. Add a planning query
that explicitly reports any invariant violation rather than silently omitting it.

The generated `best_capture_unix` expression may remain if its final mtime branch
is non-null by schema, or migrate to a non-null stored scalar if making the
invariant legible requires it. Compare both in the Stage A migration PR; prefer the
generated expression unless tests demonstrate ambiguity.

---

## 5. Sidecar/companion model

### Alternatives

#### A. Store sidecars as `media_asset` rows

Pros: existing scan/reconcile/query machinery and identity work unchanged.

Cons: sidecars leak into media counts, eligibility, grid ordering, enrichment, and
overlay lifecycle; every query must exclude them. This weakens the image/video
domain and is not selected.

#### B. Enumerate sidecars only when building a plan

Pros: no schema; planner sees live filesystem state at the moment it runs.

Cons: planning would have a second enumerator/source of truth, FSEvents could not
target companion changes through current Store reconciliation, and camera sidecars
would need a separate ImageCapture lifecycle. This is viable for a CLI but creates
split ownership in Otos.

#### C. Lightweight `media_companion` projection (selected)

Pros: scanner/camera enumeration remains the sole inventory path; complete-scan
reconciliation and FSEvents cover companions; they never enter browser media
queries or enrichment; planner gets one immutable Store snapshot.

Cons: one table and reconciliation path are added; pairing ambiguity must be
defined.

### Pairing and behavior

- Recognize `.xmp`, `.srt`, `.lrc` case-insensitively.
- Pair only within the same directory by case-insensitive basename before the
  final extension. If exactly one eligible primary matches, set
  `primary_relative_path`. If zero or multiple match, retain the companion fact
  but mark it unpaired; do not import/delete it automatically.
- Filesystem scanner reads only URL resource facts, never sidecar bytes.
- Camera enumeration sets `.sidecarFiles: true` and maps `ICCameraFile.sidecarFiles`
  to the owning camera primary directly.
- Import with setting off ignores companion actions. With setting on, copy each
  paired useful companion using its primary's final basename.
- Reorganization always relocates paired recognized companions with their primary
  so an existing library is not internally orphaned; the import-only setting does
  not disable this.
- Never delete THM/CTG/AAE/LRF/MPL/CPI or source trash in the first implementation.
  They are not useful Otos companions and destructive artifact cleanup is not a
  confirmed requirement.

Stage B must update the “no sidecars” wording in AGENTS, ADR 0008, ARC-007/031/033,
and scanner requirements precisely: Otos still generates no sidecars and uses none
for identity, but may inventory and explicitly transfer existing useful companion
files.

---

## 6. Root planning revisions and greedy lifecycle

### 6.1 Notification alternatives

#### A. Reuse broad `CatalogStoreChange` notifications

Pros: no second stream; Projection and enrichment already consume it.

Cons: it is deliberately coarse, so thumbnail/metadata/UI-only mutations would
replan unrelated sources; it does not carry a dependency revision; growing its
payload couples import to Projection cadence.

#### B. Store-owned root planning revision stream (selected)

Add `planRevision: UInt64` to `RootRuntimeState` and a separate lossless
`AsyncStream<RootPlanningChange>`. Increment only when planning inputs change:

- media/companion insert, delete, or size/mtime/date change;
- enrichment changes a best date;
- root availability, scan/enumeration completion, or source identity/path changes;
- a destination file appears/disappears/changes;
- the operation coordinator settles an Otos-authored copy/move/delete.

Pros: precise scalar dependency, cheap start guard, no Projection coupling.

Cons: Store must publish two typed streams for some mutations and tests must ensure
neither is lost.

#### C. Derive a snapshot content hash/version on every plan query

Pros: no notification changes; exact snapshot identity.

Cons: hashing every row is repeated O(n) work, cannot wake the coordinator by
itself, and tempts persistent content fingerprints. Not selected.

### 6.2 Fix the scan/watch race

Current Store ignores root events while `filesystemWatchingArmed` is false. Change
the rule:

- start/retain the watcher before enumeration as Apple recommends;
- while a known available root is scanning or enumeration owns its lease, any
  event marks `rescanAfterCurrentLease = true` and increments plan revision;
- after the current lease settles, immediately queue one reconciliation scan;
- dropped/ambiguous/root events queue a full root scan; precise regular-file events
  retain targeted handling;
- detach/unavailable cancels plan readiness but never proves deletion.

Add adversarial tests where a file is created/removed during initial scan and
where an event arrives between scan completion and arming. The final catalog and
revision must include it without user action.

### 6.3 Coordinator state machine

On startup:

1. run journal recovery before accepting a new execution;
2. subscribe to `RootPlanningChange` weakly across indefinite waits;
3. fetch every available removable source and schedule one plan build per source;
4. restore source→destination policy mappings from preferences.

For each source:

1. no fixed library/mapping → `.waitingForDestination`;
2. inventory active → `.inventory`;
3. inventory complete but any media is not enriched to a definitive best date →
   `.waitingForMetadata(done:total:)`;
4. all inputs ready → capture one immutable source+destination snapshot and
   revisions, set `.planning`, invoke the pure planner;
5. after every awaited equality check/planner phase, refetch scalar revisions;
   publish `.ready` only if both still match, otherwise discard and rebuild;
6. a user start before step 5 sets `queuedStartGeneration = desired policy
   generation`, visible as `.queuedForReadiness`;
7. when a matching ready plan publishes, start it once; if settings/destination
   changed, the intent follows the newest policy and waits for its plan;
8. detach cancels planning/execution scheduling for that source and keeps the
   queued intent only until the explicit operation reports source unavailable. Do
   not auto-run days later after reattach without a still-visible queued state;
   Stage C tests must define this lifecycle exactly.

Coalesce dirtiness per source: at most one plan build in flight and one dirty bit.
Destination changes invalidate every source targeting that root, but still use one
build at a time. Do not create a generalized worker pool until profiling demands
it.

### 6.4 What “no pre-execution validation” means

There is no second complete enumeration, duplicate sweep, checksum sweep, or disk
read before start. The start guard is one Store query comparing source/destination
revision integers. It closes already-observed invalidation without delaying the
button. Per-entry source size/mtime and no-overwrite publication close the race
that an asynchronous watcher cannot close.

If revisions mismatch, transition to `.needsReplan`, keep the user's queued start,
and greedily rebuild. If a file changes after the guard, fail only that operation
safely, stop new scheduling, invalidate, and show a retryable stale-plan result.

---

## 7. Pure deterministic planner

### 7.1 Inputs and ordering

`MediaTransferPlanner` accepts only immutable Sendable values; it performs no I/O,
database calls, logging side effects, or actor hops.

Sort all source media by natural, case-insensitive relative path before assigning
destinations. When date-time naming is enabled, sort primarily by best date and
then natural relative path. Do not use enrichment completion order, SQLite rowid,
or dictionary iteration.

For each media:

1. derive directory (`destination root` or `root/YYYY/MM`);
2. derive basename (original stem or local-calendar `YYYYMMDD_HHMMSS` using one
   documented calendar/time-zone policy; use the capture instant rendered in the
   user's current zone at plan time and store the policy in the plan);
3. normalize extension and construct ideal path;
4. consult snapshot occupants plus paths already reserved by this plan;
5. apply the operation-mode collision policy below;
6. reserve the final media and companion destinations together;
7. emit summary counts/bytes from dispositions, not a second pass over filesystem.

### 7.2 Import collision algorithm

For candidate `ideal`, then `ideal_001`, `ideal_002`, ...:

1. absent in destination snapshot/reservations → `.copy(candidate)` and reserve;
2. occupied with different size → try next suffix;
3. occupied with equal size → coordinator asks `ContentEqualityChecker` for exact
   equality; equal → `.skipPreexisting(candidate)`; different → next suffix;
4. equality cannot be read/proved → `.blocked(.comparisonUnavailable(candidate,
   underlyingProblem))`; do not skip, overwrite, or guess;
5. an equal file reserved earlier in the same plan is a skip only if its published
   source will exist before cleanup; otherwise reserve a distinct suffix to keep
   execution/recovery simple in the first implementation.

Equality checks are planning effects around the pure reservation loop. Express
them as `ComparisonRequest` values and resume planning with typed results; do not
inject an async closure into the pure planner.

### 7.3 Exact equality alternatives

#### A. CryptoKit SHA-256, ephemeral memo

After equal-size gate, stream both files through CryptoKit SHA-256 off-main and
memoize digests only for the current plan generation.

Pros: Apple-native, deterministic, fixed memory, easy fixture tests, no dependency;
one source digest can be reused across several candidates.

Cons: reads both files, cryptographic hashing is more CPU than necessary, and even
a cryptographic digest is technically a content claim rather than direct byte
equality. It is viable if measured repeated comparisons make direct reads
dominant, but is not the initial choice.

#### B. xxHash64 like `gomediaimport`

Pros: very fast and proven by the CLI's tests.

Cons: third-party dependency/custom implementation requires an ADR; probabilistic
hash is less direct than exact bytes; persistent reuse would conflict with current
identity. Viable if measurement proves A dominates planning.

#### C. Chunk-by-chunk byte equality (selected initial implementation)

Pros: exact, no hash algorithm, early exit on difference.

Cons: repeated candidate comparisons reread shared files unless a more complex
cache is added; harder to share one source result across many candidates. This is
the smallest implementation that literally proves equality and does not introduce
content fingerprints. Measure before replacing it.

All choices must call `FileMaterialization.status` immediately before reading each
file. Planning initiated by the user's import intent may deliberately materialize
a source/destination candidate; background greedy planning must not unexpectedly
materialize dataless fixed-library candidates. If a greedy comparison encounters a
dataless file, leave the plan `.blocked(.comparisonRequiresMaterialization)` and
let the explicit Import intent authorize the read, then finish planning. Log this
distinction.

### 7.4 Idempotence tests

Property/fixture tests must assert:

- plan same snapshot twice → structurally identical plan except diagnostic timing;
- execute, rescan, plan again → every former copy is `skipPreexisting`, no copy;
- repeat execute → no files and no new batch timestamp;
- interruption after destination publish but before settlement → recovery settles
  the original batch, replan skips, no suffix copy;
- collision sets produce the same suffixes under shuffled input/enrichment order;
- changing one source file changes only its necessary reservation chain;
- attaching the same stable source at a different mount path does not change
  source-relative deterministic names.

---

## 8. File operation, journal, and recovery design

### 8.1 File operation alternatives

#### A. `FileManager` copy/move only

Pros: smallest native implementation; OS handles APFS clones, metadata, and
cross-volume moves; documented move fails if destination exists.

Cons: does not coordinate with file providers/presenters; synchronous cancellation
is only between operations; the final no-overwrite race deserves a focused probe.

#### B. Per-operation `NSFileCoordinator` plus `FileManager` (selected)

Pros: coordinates user-owned/cloud-provider paths while retaining OS copy/move;
clear read/write/move intent; no custom byte-copy loop.

Cons: blocking and more failure modes; must be isolated off-main and never use one
coordinator concurrently across workers.

#### C. Raw `copyfile`/POSIX rename implementation

Pros: explicit exclusive flags, clone/copy flags, progress callbacks, and finer
cancellation.

Cons: metadata/xattr/error behavior becomes Otos's responsibility; substantially
more code despite the requirement to trust OS copy. Keep only as a narrow final-
publish fallback if Stage E's probe proves Foundation insufficient.

### 8.2 Import operation phases

Use one bounded executor with maximum four filesystem copies and one camera
download, but one coordinator-owned active operation. Start with these conservative
lanes because they match the proven engines; instrument them and simplify to fewer
if contention appears. Never run file work on MainActor.

For each `.copy` entry:

1. check source still exists and size/mtime equal planned facts;
2. check destination candidate remains absent;
3. check free destination space for the remaining planned-copy byte total plus a
   documented safety margin; failure blocks without touching sources;
4. create a unique hidden staging URL adjacent to the final destination so staging
   and final publication share a volume. This is a short-lived, journaled write
   performed only inside the explicit Import action—not an app-owned library or
   persistent cache. Remove empty temporary directories immediately; never leave
   originals in an opaque long-lived vault;
5. insert `active_file_operation(phase = copying)` before bytes move;
6. coordinate and `FileManager.copyItem` (or ImageCapture download) to staging;
7. on OS success, transactionally set phase `readyToPublish`;
8. publish staging to the final absent URL without overwrite; then set phase
   `publishedPendingSettlement`;
9. call Store settlement to upsert destination facts, set the operation's batch
   timestamp, add companion rows, and increment destination revision;
10. if source deletion was requested, set `sourceDeletionPending`, perform it,
    explicitly settle the source removal, then clear the journal row;
11. otherwise clear the journal row after destination settlement.

Do not expose final filenames until step 8. On cancellation, finish the current OS
operation and its safe settlement, then stop scheduling new entries.

For `.skipPreexisting`, write no journal/copy/history. If source deletion is
requested, use a small journal row in `sourceDeletionPending` before deleting so
the cleanup is recoverable. A pre-existing skip still does not gain a batch date.

### 8.3 Recovery alternatives

#### A. No durable operation state

Pros: minimal schema/code.

Cons: a crash after publish/before history settlement loses the required batch;
source cleanup may repeat ambiguously; abandoned staging cannot be distinguished.
Not adequate.

#### B. Persist every immutable plan and job transition

Pros: exact resume/progress and complete audit trail; strongest crash semantics.

Cons: duplicates catalog truth, requires plan migrations and stale-plan recovery,
and recreates the retired engine's largest complexity. Not required because plans
are cheap to rebuild and unstarted copies must not auto-resume.

#### C. Minimal active settlement journal (selected)

Pros: closes the only irreversible crash gaps while ready plans remain ephemeral;
small schema and bounded startup recovery.

Cons: progress for unstarted entries is lost after quit; recovery must use precise
phase/file existence rules.

Startup recovery rules:

| Durable phase | Staging | Final | Recovery |
|---|---:|---:|---|
| `copying` | exists | absent | remove staging, clear; fresh user start replans |
| `copying` | absent | absent | clear |
| `readyToPublish` | exists | absent | remove staging, clear; do not auto-publish |
| `readyToPublish` or `publishedPendingSettlement` | absent | exists | settle destination/history using recorded batch, then continue cleanup policy |
| `publishedPendingSettlement` | exists | exists | final wins only if journal proves this exact publication; remove staging and settle; otherwise block for diagnosis |
| `sourceDeletionPending` | any settled final | source exists | retry explicitly requested deletion when source is available |
| `sourceDeletionPending` | any settled final | source absent | settle catalog removal only if root is reachable and absence is proved; clear |

Recovery is an owned coordinator task with signposts and typed failures. It runs
before new execution and never assumes temporary source absence means deletion.
When a removable source path changed, resolve the journal's existing device
identity through Store before retrying cleanup; never treat the stale mount path as
the durable source identity.

### 8.4 Import history settlement

Generate `ImportBatchID` exactly once when a ready plan begins executing, not when
it was greedily built. Every newly published media entry uses that value. If no
entry is newly published (all pre-existing/no-op), no sidebar batch is created.

Store APIs:

```swift
func importBatches() throws -> [ImportBatchSummary]
func settleImportedFile(
    operationKey: OperationKey,
    destination: PlanningFileFacts,
    batch: ImportBatchID
) throws
func assetIDs(in batch: ImportBatchID, descriptor: CatalogQueryDescriptor) throws
    -> [MediaAssetID]
```

Settlement and journal-phase advancement must be one SQLite transaction so a
published file cannot be marked complete without its batch overlay. A subsequent
scan upsert preserves `import_batch_unix_ms`; proven deletion/root removal cascades
it with the row.

---

## 9. Reorganization using the same engine

### 9.1 Shared and different behavior

Shared:

- best-date/name/directory derivation;
- natural deterministic ordering;
- destination snapshot and reservation table;
- root revision invalidation and per-file size/mtime guard;
- companion association;
- journal, cancellation, progress, logging, and Store settlement.

Different:

- source and destination are the same fixed root;
- first rule is normalized source URL == ideal destination URL → `.noOp`;
- content equality is never requested and never produces a skip;
- an occupied path may be vacated by another planned move;
- operation is relocate, not copy+delete, whenever the filesystem can move;
- import batch is nil and existing batch overlay is preserved.

### 9.2 Move strategy alternatives

#### A. Treat every currently occupied target as permanent and suffix

Pros: simple independent moves; no cycles; straightforward recovery.

Cons: creates avoidable suffixes when the occupant is itself moving, so the final
layout does not match the policy's natural result. Correct but materially worse.

#### B. Build a move dependency graph; use one temporary hop for cycles (selected)

For every relocation `source → target`, add a dependency when `target` is another
planned source. Topologically execute nodes whose target is free. For each cycle,
move one source to a journaled same-volume temporary URL, rotate the remaining
moves, then publish the temporary file to its target.

Pros: produces the intended names without collapsing originals or unnecessary
suffixes; bounded temporary storage; deterministic graph tests.

Cons: more planner/executor logic and recovery states; path remap must be lossless.

#### C. Stage every moving file, then publish all targets

Pros: cycles disappear and phase order is simple.

Cons: temporarily relocates the entire library, doubles cross-volume work in bad
cases, requires large storage, and maximizes interruption exposure. Not selected.

### 9.3 Reorganization algorithm

1. Build ideal targets for every in-scope library asset.
2. Mark exact normalized source==ideal as no-op before looking at occupancy.
3. Build `movingSources` set. An ideal target occupied by a no-op/nonmoving asset
   is a real conflict → deterministically suffix until target is absent, reserved,
   or occupied by another moving source.
4. Reserve one unique final path per original and pair companions.
5. Build directed dependencies for moving-source occupancy.
6. Execute acyclic leaves, then deterministic cycles (lowest natural source path
   is the temporary-hop pivot).
7. After each filesystem move, immediately call `settleRelocation`; update the
   remaining graph's current path only after Store accepts the remap.
8. If settlement fails, stop. The journal and observed filesystem paths drive
   recovery; never continue with a guessed identity.

Add a pure invariant check over every ready reorganization plan:

- number of media sources == number of no-op+relocate outcomes;
- all final paths unique;
- no equality/skip dispositions;
- every relocation has a recoverable dependency order;
- companions never reserve a media destination;
- all existing import batch values are carried, never synthesized.

### 9.4 Scope for first reorganization UI

Expose reorganization from the selected fixed library only, never All Media or a
removable source. The confirmation sheet shows plan counts, no-op count, moves,
companion moves, and conflicts/suffixes. It must state that originals will move on
disk. No execution button is enabled while any blocked entry exists.

This UI ships only after import/recovery is proven; do not leave an enabled seam in
earlier stages.

---

## 10. Preferences and UI integration

### 10.1 Preferences

Add `ImportPreferences` as a small Codable/UserDefaults-backed owner following the
existing narrow settings patterns, not SQLite:

- global `importsSidecars` (default `true`, as approved sidecar support);
- global source deletion (default `false`);
- global auto-eject (default `false`);
- folder and filename policies;
- stable removable-source identity → fixed `LibraryRootPath` destination mapping.

If a mapped fixed library was removed or unavailable, do not silently choose a
different library. State becomes `.waitingForDestination`. With exactly one fixed
library and no saved mapping, select it and persist the explicit mapping once the
user imports. With multiple libraries, require selection the first time.

`SettingsView` gains a third `Import` tab receiving only bindings/closures for
these settings. It must not receive `CatalogWindowViewModel` or plan payloads.

### 10.2 Sidebar history

Extend `SidebarSelection` with `.importBatch(ImportBatchID)`. This remains a
sidebar query scope, not media selection, so it respects ARC-012.

`CatalogWindowState` adds `[ImportBatchSummary]` from Store (timestamp and count
only). `SidebarView` adds an Imports section, newest first, after Libraries and
before Removable. Row label format is localized date+time; identical rendered
labels include a disambiguating seconds/time-zone representation rather than
changing identity.

`CatalogQueryGateway` treats batch scope as fixed-library assets only and applies
the current sort/filter descriptor inside that batch. Empty batches never appear.
Root unavailable behavior follows existing fixed-library hiding; history persists
on rows but temporarily unavailable assets do not render.

### 10.3 Plan overlay without full-map publication

Do not add `[MediaAssetID: PlanEntry]` to `CatalogWindowState`. Prior grid work
established that full-map copies are expensive and the current visible-detail
reader boundary is deliberate.

Coordinator publishes only:

- `[LibraryRootPath: MediaOperationSourceState]` scalar summaries;
- active source/generation/progress;
- one cheap change notification when visible plan details may have changed.

Add `ImportPlanDetailReader`, analogous to `MediaTileDetailReader`, that accepts
visible IDs plus plan generation and returns only dispositions for those IDs. The
AppKit grid preserves its current thumbnail invariant; badges/overlay text are
separate presentation state and must not clear/redecode thumbnails.

### 10.4 Main window flow

When a removable source is selected, a bottom `ImportPlanFooter` shows:

- destination picker (fixed libraries only);
- readiness: inventory, waiting for metadata count, planning, ready, blocked;
- planned copy/pre-existing/companion counts and bytes;
- Import button, or Cancel while executing;
- cleanup/eject policy summary so destructive behavior is never hidden.

The button is enabled during metadata wait and records queued intent. It is
disabled only without a destination, during inventory with no complete item set,
for a blocked plan, or while another global operation runs. Filters/selection do
not alter footer totals.

Errors are typed and actionable: source unavailable, destination unavailable,
comparison needs explicit materialization, insufficient space, source changed,
destination changed, copy failed, settlement failed, cleanup failed, eject failed.
Do not reuse the generic catalog alert boundary. Destructive cleanup/eject failures
remain retryable after successful import.

The ViewModel owns named tasks:

- `mediaOperationStateConsumptionTask` (weak across stream wait);
- `mediaOperationDetailInvalidationTask`;
- explicit one-shot destination/settings mutation delivery using lossless serial
  semantics;
- coordinator startup/recovery lifetime.

Cancel them in isolated deinit with the existing ViewModel lifetimes.

---

## 11. Instrumentation and diagnostics

Before claiming a stage complete, instrument through `OtosLog`/signposts:

- `op=mediaOperation.plan` fields: source kind/path hash, destination path hash,
  generation, sourceRevision, destinationRevision, phase, mediaCount,
  companionCount, comparisonCount, blockedCount, elapsedMs;
- `op=mediaOperation.execute`: mode, batch (privacy-safe numeric), phase,
  disposition, bytes, lane, elapsedMs;
- `op=mediaOperation.invalidate`: root, old/new revision, reason, inFlight, queued;
- `op=mediaOperation.recover`: operationKey, durablePhase, observed staging/final/
  source booleans, outcome;
- `op=mediaOperation.settle`: import/relocate/delete, old/new ID hashes, outcome;
- `op=mediaOperation.materialize`: background vs user-authorized, source vs
  destination candidate, outcome;
- `op=mediaOperation.ui`: queued/start/cancel/destination-change/error-retry.

Never log raw metadata, filenames, full paths, content digests, or diagnostic plan
payloads. Reuse privacy-safe path/ID descriptions. Plan details are bounded scalar
diagnostics, not a second retained full plan.

Performance evidence:

- fixtures at 10, 1,000, and the largest locally available real removable corpus;
- signpost worst and p95 plan time, comparison time, and Store snapshot time;
- Time Profiler during greedy planning, active copy, and 23k-item grid scrolling;
- prove MainActor spans stay below 100 ms and grid behavior does not regress;
- prove at most one source plan build per source plus one dirty rerun;
- measure direct equality-read cost before considering hashes or caching changes;
- measure file-copy concurrency before changing the initial bounds.

---

## 12. Tests and adversarial verification

### Pure planner tests (`MediaTransferPlannerTests.swift`)

- four folder/name policy combinations;
- mtime fallback and no synthetic date;
- natural deterministic same-second suffixes;
- existing equal/different/unreadable candidates;
- same-plan collision reservations;
- companion pairing/naming and setting off;
- shuffled input produces identical plan;
- import idempotence fixtures;
- reorg exact-path no-op first;
- byte-identical reorg sources remain two outcomes;
- occupied stationary target suffix;
- vacating dependency chain and two-/three-node cycles;
- no plan has duplicate final destinations.

### Store/migration tests

- prior schema migrates without erase;
- future schema refuses without erase;
- scan upsert preserves import batch;
- imported settlement and journal phase are atomic;
- distinct nonempty batch queries and deletion disappearance;
- companion full-scan/FSEvent reconcile;
- revision increments exactly for planning facts, not thumbnail-only changes;
- events during scan cause a follow-up reconciliation;
- relocation cascades metadata, history, companion, thumbnail identity;
- stale relocation settlement rolls back.

### Coordinator tests

- greedy plan for every attached source;
- source waits for all metadata, then becomes ready;
- early Import queues once and starts once;
- source/destination change invalidates and replans;
- stale async comparison/build cannot publish;
- detach/reattach and destination removal semantics;
- dataless greedy comparison waits for explicit authorization;
- only one global execution;
- cancellation finishes current settlement and stops scheduling;
- each recovery table row produces the specified outcome;
- no recovery resumes an unstarted copy;
- all-preexisting run creates no batch;
- cleanup/eject ordering and retry.

### File-operator integration tests

- destination-local staging never exposes partial final file;
- final publication never overwrites a concurrently created target;
- successful copy is not reopened for verification;
- source size/mtime race fails before copy;
- cancellation during OS call settles or removes staging deterministically;
- source deletion only after durable destination settlement;
- MTP download/delete fakes preserve the same phase semantics;
- coordinated file-provider failure maps to a typed problem.

### ViewModel/UI tests

- footer totals ignore grid selection/filter;
- early click displays queued/waiting metadata;
- destination picker invalidates/replans;
- visible plan detail request rejects stale generation;
- sidebar batch selection/query/remove behavior;
- import sidecar Settings binding and persistence;
- errors and destructive policy are visible;
- thumbnail already displayed remains displayed across overlay changes.

### Runtime adversarial passes

Automate with temporary volumes/directories and fakes where physical media is not
available. Do not require the user to operate the app.

1. mutate source during inventory, enrichment, planning, and copy;
2. mutate destination between plan, start guard, and final publish;
3. detach source at each durable phase;
4. terminate/relaunch at each journal phase;
5. fill destination disk before and during copy;
6. make candidate unreadable and dataless;
7. import twice and assert tree+history unchanged on second run;
8. run reorganization cycles and terminate after every move;
9. confirm originals are never overwritten or collapsed;
10. run `script/verify.sh`, `script/logs.sh`, and relevant `script/profile.sh`
    templates; attach machine-readable evidence to each PR.

---

## 13. Delivery stages

### Stage A — Durable-history-safe persistence and total best dates

Branch: `refactor/import-persistence-foundation`

- replace destructive schema reset policy;
- add import batch scalar/index and migration/future-schema tests;
- enforce total best date including camera date cascade;
- add Store import-history queries, no sidebar yet;
- update/supersede persistence ADR, current architecture, and affected requirement
  rows only for behavior actually shipped.

Done when old catalog fixtures migrate without loss, future schema is retained and
refused, and every cataloged planning candidate has a real best date.

### Stage B — Companion inventory and Import Settings

Branch: `feat/import-companion-inventory`

- add `media_companion`, filesystem/camera enumeration, pairing/reconcile tests;
- request ImageCapture sidecars;
- add `ImportPreferences` and Import Settings tab;
- revise no-sidecar docs precisely (existing companions supported; no generation,
  identity, or authored-overlay sidecars).

Done when useful companions survive scan/event/camera lifecycles without entering
media queries and the setting persists.

### Stage C — Planning snapshots, revisions, and pure planner

Branch: `feat/import-planner`

- add planning models/gateway/root revision stream;
- fix event-during-scan loss;
- implement deterministic pure planner plus comparison-request protocol;
- implement ContentEqualityChecker and dataless authorization boundary;
- prove collision, duplicate, companion, and idempotence cases.

Done when an immutable ready plan can be produced from Store snapshots with no UI
or file mutation and stale inputs cannot publish.

### Stage D — Greedy coordinator and plan UI overlay

Branch: `feat/import-plan-overlay`

- add coordinator eager lifecycle for all attached sources;
- add queued start state but keep actual execution unavailable/feature-gated;
- add destination mapping, footer, visible detail reader/overlay;
- add import batch sidebar scope using Stage A data;
- update architecture/requirements for shipped plan/history UI.

Done when attach/enrich/invalidate/replan is automatic, Import can queue while
metadata finishes, filter/selection do not affect totals, and the grid publishes
no full plan map.

### Stage E — Import journal and filesystem executor

Branch: `feat/removable-media-import`

- add active operation journal and startup recovery;
- implement coordinated staging/copy/no-overwrite publish/settlement;
- run exclusive-publication probe and document whether a narrow POSIX primitive is
  necessary;
- implement bounded filesystem execution, cancellation, free-space handling;
- enable Import for removable filesystem volumes;
- establish runtime/instrumentation/idempotence proof.

Done when repeated and crash-injected filesystem imports cannot overwrite, create
extra suffix copies, or lose history.

### Stage F — Camera import, cleanup, and eject

Branch: `feat/camera-import-cleanup`

- adapt ImageCapture downloads to the same journal/settlement phases;
- implement explicit source deletion for filesystem and camera sources;
- implement auto-eject only after complete success;
- expose cleanup/eject retry outcomes;
- verify detach/recovery/device capability paths.

Done when all removable source kinds share one user-visible import semantics and
destructive actions never precede durable settlement.

### Stage G — Library reorganization planner/executor

Branch: `feat/library-reorganization`

- add reorganization mode, move graph, cycle staging, and invariant tests;
- add Store identity/overlay/thumbnail remap transaction;
- add confirmation UI for one selected fixed library;
- preserve import history and move useful companions;
- run termination tests at every graph/journal phase.

Done when every original remains represented, exact-path items are no-op, no
content dedup occurs, overlay follows path, and interrupted cycles recover.

### Stage H — Final integration and measurement

Branch: `perf/import-operation-evidence` (only if code changes are evidence-driven;
otherwise attach evidence to Stage G and create no code PR)

- run large-corpus plan/import/reorg profiles;
- address only measured bottlenecks;
- audit all requirements/ADRs/architecture against final current truth;
- remove temporary feature gates and this plan after every stage is landed;
- post the final per-increment DoD through the normal PR workflow.

---

## 14. Review gates for every stage

- Establish the stage's requirement/test oracle before implementation.
- Cold-review Store, executor, recovery, and reorganization diffs under both
  implementation-fidelity and blank-slate architecture lenses.
- Prove one owner per fact: Store/catalog, Coordinator/operation, Planner/decision,
  ViewModel/final UI assignment.
- Invert the safety claims: try to overwrite, double-import, lose a batch, collapse
  equal originals, orphan a sidecar, apply stale async results, and purge a
  temporarily absent source.
- Confirm no MainActor file/database/hash work and no unchecked Sendable escape.
- Confirm no raw path/content/metadata/hash diagnostic leaks.
- Confirm changes to originals occur only after an explicit user start/confirmation
  and match the visible plan/policy.
- Run `script/verify.sh`; inspect logs; attach profiles for stages touching byte I/O
  or grid overlay responsiveness.
- Update `docs/requirements.md`, ADRs, and `docs/architecture.md` only with behavior
  that the stage actually implements. This plan remains non-authoritative until
  implementation lands.

## 15. Definition of the completed feature

The work is complete only when an attached filesystem card or camera is inventoried,
fully dated, automatically planned to a chosen fixed library, visibly ready, and
can be imported exactly once with useful companions, durable history, safe
cleanup/eject, invalidation, cancellation, and crash recovery; and when the same
planner can reorganize a fixed library without overwriting, deduplicating, or
losing any original or overlay. At that point current requirements/ADRs describe
the implemented behavior, all stages are merged and cleaned, and this plan is
deleted.
