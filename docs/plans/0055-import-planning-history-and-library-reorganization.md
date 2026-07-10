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
    distinct namespace-transformation semantics. Before any conflict work, compare
    the exact standardized source and proposed relative-path spelling: exact
    equality is a no-op. A case-only or Unicode-spelling change that addresses the
    same filesystem name is a real relabel operation through a temporary path, not
    a no-op. Reorganization **never content-deduplicates or collapses originals**,
    even when two files are byte-identical. Occupied targets use a dependency-aware
    move or deterministic suffix so every original remains represented.
15. Execution is user-started, bounded, observable, and crash-recoverable. Import
    cancellation stops between files; reorganization cancellation stops between
    dependency components. Cancellation does not undo already committed units.
    Import recovery may settle already-published files, finish requested cleanup,
    or remove abandoned staging; it never resumes an unstarted byte copy without a
    new user start intent.
16. A reorganization dependency component is the smallest interruption boundary.
    Once its first filesystem move starts, cancellation waits until that entire
    component is committed or restored. A crash recovery pass runs before normal
    scanning, finishes an unambiguous already-authorized component forward, or
    rolls its completed steps back when forward completion is unsafe. It never
    exposes a temporary path as durable media identity and never guesses when the
    observed namespace is ambiguous.

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
  - `PlannedNamespacePath`, `FilesystemNameKey`, and `VolumeIdentifier`: typed,
    volume-aware reorganization path facts; never bare comparison strings.
  - `ReorganizationPhysicalMember`, `ReorganizationMoveStep`, and
    `ReorganizationComponent`: pure complete-namespace graph/recipe values.
  - `ReorganizationComponentKey`: active-operation key only, never media identity.
  - `CatalogIdentityRemapBatch`: complete component old→new media mapping delivered
    atomically to Store/UI owners.
  - `MediaOperationSourceState`: `.inventory`, `.waitingForDestination`,
    `.waitingForMetadata(done:total:)`, `.planning`, `.ready(summary:generation:)`,
    `.queuedForReadiness`, `.executing(progress:)`, `.needsReplan`,
    `.completed(summary:)`, `.failed(problem:)`.
- `Otos/Services/MediaTransferPlanner.swift`: nonisolated pure planning functions.
- `Otos/Services/MediaOperationCoordinator.swift`: actor and lifecycle owner.
- `Otos/Services/ContentEqualityChecker.swift`: deliberate, ephemeral comparison.
- `Otos/Services/FilesystemNamespaceSemantics.swift`: off-main, volume-aware name,
  occupancy, ancestor, and resource-identity observations for planner requests.
- `Otos/Services/MediaFileOperator.swift`: coordinated copy/move/publish/delete.
- `Otos/Stores/MediaOperationGateway.swift`: Store-owned planning snapshot,
  history, revision, settlement, and journal SQL/mapping. This is an owned helper,
  not an actor and not a second database owner.
- `Otos/ViewModels/CatalogWindowViewModelMediaOperations.swift`: UI intents and
  named task lifecycle.
- `Otos/Views/ImportPlanFooter.swift`: source plan/readiness/progress controls.
- `Otos/Views/ImportPlanOverlay.swift`: optional per-visible-item disposition.

Keep architecture-boundary guides at the top of the coordinator, planner, gateway,
namespace service, and file operator explaining isolation, cancellation, revision
validation, reorganization leases, staging, component settlement, and recovery.

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

CREATE TABLE active_reorganization_component (
    component_key TEXT PRIMARY KEY,
    library_root_path TEXT NOT NULL,
    plan_generation INTEGER NOT NULL,
    planned_root_revision INTEGER NOT NULL,
    phase TEXT NOT NULL,
    next_step_index INTEGER NOT NULL,
    created_at DOUBLE NOT NULL,
    updated_at DOUBLE NOT NULL
);

CREATE TABLE active_reorganization_member (
    component_key TEXT NOT NULL,
    member_index INTEGER NOT NULL,
    member_kind TEXT NOT NULL,
    logical_source_relative_path TEXT NOT NULL,
    current_relative_path TEXT NOT NULL,
    final_relative_path TEXT NOT NULL,
    byte_size INTEGER NOT NULL,
    content_modified_at DOUBLE NOT NULL,
    PRIMARY KEY (component_key, member_index),
    FOREIGN KEY (component_key)
        REFERENCES active_reorganization_component(component_key)
        ON DELETE CASCADE
);

CREATE TABLE active_reorganization_step (
    component_key TEXT NOT NULL,
    step_index INTEGER NOT NULL,
    member_index INTEGER NOT NULL,
    source_relative_path TEXT NOT NULL,
    destination_relative_path TEXT NOT NULL,
    phase TEXT NOT NULL,
    PRIMARY KEY (component_key, step_index),
    FOREIGN KEY (component_key, member_index)
        REFERENCES active_reorganization_member(component_key, member_index)
        ON DELETE CASCADE
);

CREATE TABLE active_reorganization_directory (
    component_key TEXT NOT NULL,
    relative_path TEXT NOT NULL,
    phase TEXT NOT NULL,
    PRIMARY KEY (component_key, relative_path),
    FOREIGN KEY (component_key)
        REFERENCES active_reorganization_component(component_key)
        ON DELETE CASCADE
);
```

Refine column spelling to current conventions, but do not add a durable plan table,
content hash, asset UUID, import-batch table, or permanent per-file operation log.
The reorganization tables contain only the one dependency component that has
crossed its mutation boundary. They are a bounded recovery recipe, not persistence
for ready plans or completed history, and are deleted after component commit or
rollback.
`active_file_operation` is the import/copy settlement journal; reorganization uses
the component tables because its moves cannot be recovered independently. Component
phases are `prepared`, `moving`, `filesystemComplete`, `catalogCommitted`,
`rollingBack`, and `blocked`; step phases are `planned`, `willMove`, `didMove`, and
`rolledBack`; directory phases are `planned`, `created`, and `preexisting`. Use
typed Swift enums at the Store boundary and reject unknown durable phase strings.
`source_device_identity` is the existing removable-source identity, not a new media
identity; it lets pending cleanup find the same source after a remount/path change.

Why no `import_batch` table: a batch currently has exactly one durable fact—the
timestamp shared by newly imported surviving assets. `SELECT DISTINCT` provides
the sidebar rows, and a batch naturally disappears when its last asset is proven
deleted. Introduce a table only when a verified requirement adds batch-authored
metadata that cannot live on assets.

### 4.3 Set-based path remap and foreign keys

Reorganization changes the `media_asset` composite primary key. Make the existing
`asset_metadata` relationship `ON UPDATE CASCADE` (rebuild the table in the
migration if SQLite requires it). A component containing a swap cannot update rows
one at a time because the first update would collide with the other row's primary
key. Add one set-based Store transaction:

```swift
func settleRelocationComponent(
    component: ReorganizationComponentKey,
    remaps: [CatalogIdentityRemap],
    observedFacts: [MediaAssetID: ScannedFileFacts]
) throws -> CatalogIdentityRemapBatch
```

It must:

1. require the journaled component to be `.filesystemComplete` and prove every
   final media/companion path has the planned size/mtime and no unplanned occupant;
2. prove every logical source row still exists with its pre-operation facts and the
   exact source→final mapping matches the journal;
3. inside one SQLite transaction, remap every source row first to a unique
   transaction-private relative path, then from those private keys to final paths;
   the private keys never commit or publish;
4. rely on `ON UPDATE CASCADE` or explicit set-based updates to carry metadata and
   preserve `import_batch_unix_ms` unchanged;
5. update every companion relative path in the same transaction;
6. mark the component `.catalogCommitted` in that transaction;
7. return one complete old→new batch for ViewModel selection and
   `TileContentStore`, then publish one lossless catalog mutation and one root
   revision increment—never one event per member.

Thumbnail files live in Application Support and are derived overlay, but they must
not be discarded merely because identity moved. Preserve the existing thumbnail
file and validation stamps by carrying its stored relative reference with the row;
the filename does not need to be renamed just because its original deterministic
ID-derived name reflects the old identity. A later genuinely stale enrichment may
write the new identity's deterministic filename and delete the superseded stored
file through the existing lifecycle. This is smaller and safer than making an
original-file commit depend on an Application Support rename or thumbnail
regeneration. Add startup-cleanup, deletion, and re-enrichment tests for this
noncanonical-but-referenced filename state.

If any proof fails, roll back the catalog transaction and keep the root under its
reorganization recovery lease; never create a second catalog row, publish a
partial remap, or let a normal scan interpret temporary absence as deletion.

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

Reorganization is not a list of independent moves. It is a transformation from one
filesystem namespace to another while catalog identity remains path-based. The
planner must reason about the complete current and final namespaces at once, and
the executor must make each connected dependency component recoverable.

### 9.1 Shared planning core, distinct operation semantics

Shared with import:

- best-date/name/directory derivation;
- natural deterministic ordering;
- destination snapshot and reservation table;
- root revision invalidation and per-file size/mtime guard;
- companion association;
- progress, logging, typed problems, and Store settlement.

Distinct reorganization behavior:

- source and destination are the same fixed root;
- exact standardized relative-path spelling equality is `.noOp`;
- namespace-equivalent but differently spelled paths are relabel moves;
- content equality is never requested and never produces a skip;
- an occupied path may be vacated by another planned move;
- media and companion paths participate in one namespace graph;
- same-volume relocation is a rename/move, never copy+delete;
- import batch is nil and every existing import-batch value is preserved;
- cancellation is accepted between dependency components, never in the middle of
  one component's physical transformation.

### 9.2 Move strategy alternatives

#### A. Treat every currently occupied target as permanent and suffix

Pros: simple independent moves; no cycles; straightforward recovery.

Cons: creates avoidable suffixes when the occupant is itself moving, so the final
layout does not match the policy's natural result. Correct but materially worse.

#### B. Build a move dependency graph; use one temporary hop for cycles (selected)

For every physical relocation `source → target`, add a dependency when `target` is
another planned physical source. Execute chains from their free end. For each
cycle, move one member to a journaled same-volume temporary URL, rotate the
remaining moves, then move the temporary member to its final target.

Pros: produces the intended names without collapsing originals or unnecessary
suffixes; bounds temporary storage to one member per cycle; exposes formal graph
invariants and deterministic recovery units.

Cons: component recipes, catalog batch remaps, recovery, and cancellation boundaries
must all be explicit. A one-line “topological sort” implementation is insufficient.

#### C. Stage every moving file, then publish all targets

Pros: cycles disappear and phase order is conceptually simple.

Cons: temporarily relocates the entire library, may require library-sized staging,
does extra I/O, and maximizes interruption exposure. Not selected.

### 9.3 Filesystem namespace semantics

String equality, URL standardization, and filesystem name equality are three
different questions. Add a concrete `FilesystemNamespaceSemantics` service that
captures facts from the actual root volume before the pure planner runs:

```swift
nonisolated struct PlannedNamespacePath: Sendable, Equatable {
    let relativePath: String          // intended on-disk spelling
    let lookupKey: FilesystemNameKey  // occupancy/equality on this volume
    let volumeIdentifier: VolumeIdentifier
}
```

The implementation must distinguish:

- **exact path:** standardized relative components and spelling are identical →
  no-op;
- **namespace-equivalent self:** lookup keys identify the same existing directory
  entry but spelling differs (for example `IMG_1.JPG → IMG_1.jpg` on a
  case-insensitive volume) → a one-member cycle requiring a temporary hop;
- **occupied by another path:** lookup key matches a different physical member →
  dependency or stationary conflict;
- **free:** no current entry or reservation owns the lookup key.

Do not implement `FilesystemNameKey` as an unconditional `.lowercased()` string.
Stage G first probes APFS case-sensitive/case-insensitive volumes and the configured
cloud-provider filesystem, including composed/decomposed Unicode spellings. Use
volume capability facts plus Foundation filesystem representations, and retain the
OS no-overwrite result as the final namespace oracle. If two spellings cannot be
classified confidently, block before mutation with `.ambiguousFilesystemName`.

Symlinked files or target ancestors are blocked in the first implementation rather
than followed during mutation. Hard-linked paths remain separate path identities;
renaming one directory entry must not cause Otos to collapse or “deduplicate” the
other. A temporary filesystem resource identifier may be used as an execution
observation when available, but is never persisted as asset identity or content
identity.

### 9.4 Build the complete physical namespace first

Planning has two levels:

1. **Logical media entries** carry `MediaAssetID`, overlay, and batch history.
2. **Physical members** are every media file plus every paired recognized companion
   that must move with it. All physical members share one reservation namespace.

Algorithm:

1. Read one immutable Store snapshot containing every in-scope media/companion,
   current namespace key, volume identifier, size/mtime, and ideal logical target.
2. Derive the exact target for every physical member. Companion targets follow the
   primary's final directory and basename before any graph construction.
3. Mark only exact same-spelling media/companion paths as no-op.
4. Reserve final lookup keys globally. When two planned members want the same key,
   deterministically suffix the later logical media bundle; recalculate and reserve
   its companion targets with it. Never suffix one companion independently from its
   primary.
5. If a final key is occupied by a stationary/no-op member, suffix the moving
   bundle. If occupied by a moving member, retain it as a dependency.
6. Check every target ancestor. An existing regular file or symlink where a
   directory is required blocks the entire plan; a missing directory becomes an
   explicit creation prerequisite.
7. Build a directed graph over physical members. An edge means “this member's
   target must be vacated by that member.” Add undirected grouping edges between a
   primary and its companions so they share one recovery component even when their
   path dependencies are otherwise independent.
8. Partition the combined graph into deterministic connected components, ordered
   by the lowest natural logical source path. Each component contains chains,
   cycles, or namespace-equivalent self-renames plus its companion members.
9. Reject the plan if any final lookup key is duplicated, any physical member is
   absent from exactly one component, or a component cannot produce a finite
   no-overwrite move recipe.

The catalog intentionally contains only eligible media and recognized companions,
so it cannot prove that another user file does not occupy a proposed target. Like
the import planner's equality-request boundary, the pure reorganization planner
emits `NamespaceOccupancyRequest` values for every target/ancestor key not answered
by catalog facts. `MediaOperationCoordinator` resolves them off-main through
`FilesystemNamespaceSemantics` as `.free`, `.sameEntry`, `.regularFile`,
`.directory`, `.symlink`, or `.ambiguous`, then resumes the pure planner. Recheck
root revision after the await. This is targeted namespace observation, not a second
media scan, and is how unknown stationary files participate without being added to
the catalog.

Once final keys are unique, an ungrouped file graph has at most one outgoing move
per source and one incoming owner per final path. Its connected pieces reduce to
chains ending at free paths and cycles. Companion grouping may join pieces into one
larger recovery component but does not change their internal move order.

### 9.5 Deterministic component recipes

For a chain `A→B`, `B→C`, with `C` free, execute:

```text
B → C
A → B
```

For a swap `A→B`, `B→A`, execute:

```text
A → .otos-reorg-<component>-<member>
B → A
.otos-reorg-<component>-<member> → B
```

Longer cycles use the same rotation. A namespace-equivalent self-rename uses
`source → temporary → final`. Select the cycle pivot deterministically by the
lowest natural source path. Generate a collision-resistant operation key solely
for the active journal/temp name; it is not media identity. The temp path must:

- be a hidden sibling of the source on the same volume;
- be outside every current/final namespace key;
- be created/reserved with no-overwrite semantics;
- be persisted before the first move;
- never be cataloged or published as a `MediaAssetID`.

Before any physical mutation, Store persists the component row, all physical
members, every ordered step, and every directory-creation prerequisite with phase
`.planned` in one SQLite transaction. This bounded recipe is the mutation boundary.
It is not a durable ready plan.

For each step:

1. revalidate the component/root lease and expected current source facts;
2. prove the target is absent under actual filesystem semantics;
3. transactionally mark the step `.willMove` and record the member's expected
   current/next path;
4. use a fresh `NSFileCoordinator` off-main and a no-overwrite same-volume move;
5. transactionally mark `.didMove`, update member `current_relative_path`, and
   advance `next_step_index`;
6. after every await, reject a stale component owner before scheduling another
   step.

When all physical members are at final paths, mark the component
`.filesystemComplete`, then call the set-based Store settlement from section 4.3.
No logical catalog identity changes before this point. After catalog commit and
one UI remap publication, remove temporary/empty operation-created directories
when safe and delete the component journal.

### 9.6 Recovery-journal alternatives

#### A. Reuse one independent `active_file_operation` row per move

Pros: no additional schema and import recovery code is reusable.

Cons: a swap is not independently settleable; per-row recovery cannot know the
ordered component recipe or apply catalog identities atomically. Not correct.

#### B. Store the complete component recipe as JSON in one row

Pros: one table, atomic recipe insertion, easy in-memory decode.

Cons: every step rewrites an opaque payload; SQL cannot constrain member/step
relationships or inspect recovery state; schema evolution and adversarial fixture
construction are harder. Viable, but not selected.

#### C. Normalized active component/member/step tables (selected)

Pros: explicit invariants and phases, atomic batch updates, precise recovery tests,
and bounded state that disappears after completion.

Cons: four small tables rather than one. The added schema is justified by the
filesystem operation's real component-level atomicity boundary, not anticipated
scale.

The connected dependency component—not one file and not the whole library—is the
selected commit/cancellation unit. A single file is too small because swaps and
companion groups are inseparable. The whole library is too large because disjoint
components share no path dependency; pretending they are atomic would require
library-sized staging or rollback after already safe independent commits. Component
commit permits bounded recovery, useful cancellation, and idempotent replanning of
the remaining namespace.

### 9.7 Root lease, scanner, enrichment, and UI publication

Before persisting a component, `CatalogStore` acquires one typed reorganization
lease for the fixed root. While held:

- filesystem scans and targeted reconciliation for that root do not run;
- external FSEvents mark the root dirty and increment a deferred mutation fact,
  but never reconcile intermediate paths;
- enrichment stops claiming new rows from the root and in-flight completions are
  rejected by the changed lease/generation if they target a remapped identity;
- Projection continues to show the pre-component catalog identities; temporary
  paths are invisible;
- `IgnoreSelf` continues to suppress Otos-authored move events; component
  settlement explicitly updates Store;
- detach/unavailability or an external event does not prove deletion and prevents
  scheduling the next component until reconciliation/replanning.

While a component is physically moving but not catalog-committed, its old path IDs
may not currently resolve on disk. Keep their already-painted thumbnails visible,
show the root/component as reorganizing, and temporarily disable byte-reading,
Reveal in Finder, clipboard-file-URL, Image/Compare decode, and other path-based
intents for affected IDs. Do not report them missing or feed their temporary
absence into normal availability/deletion policy.

After `settleRelocationComponent` commits, ViewModel receives one
`CatalogIdentityRemapBatch`. Apply it atomically to media selection, compare/image
focus, pane requests, visible-detail generations, and `TileContentStore`. Move an
already-painted in-process thumbnail from old key to new key before publishing the
new ordered IDs so the grid's never-blank invariant survives the identity change.

Release the root lease only after catalog/UI settlement or a proven rollback. Then
run one deferred reconciliation scan before building the next plan. Completed
components remain completed if the user cancels; a fresh idempotent plan sees them
as no-op and the remaining components as work.

### 9.8 Crash, failure, and cancellation semantics

Recovery runs before ordinary startup scanning/enrichment. For each active
component, reconstruct the current physical location of every member from the
journal and actual paths. For a `.willMove` step whose post-step transaction may
not have committed:

| Source path | Target path | Interpretation |
|---|---|---|
| exists with planned facts | absent | move did not happen; step may run |
| absent | exists with planned facts | move happened; mark `.didMove` |
| exists | exists | ambiguous/external mutation; do not overwrite or guess |
| absent | absent | ambiguous/lost namespace; do not guess |

Temporary paths make every cycle step compare two distinct namespace keys, even
for case-only relabels. Validate size, mtime, regular-file type, and optional
ephemeral filesystem resource identifier at the observed path. Do not read bytes or
content-deduplicate during reorganization recovery.

Selected recovery policy:

1. If the observed namespace matches exactly one prefix of the journaled recipe,
   continue that already-authorized component forward to its final namespace.
2. If the next forward step is no longer safe, validate the exact reverse of every
   completed step and roll the component back when all reverse targets are free.
3. If neither direction is provably safe, retain the journal and root lease, show a
   blocking recovery problem with affected relative paths, and perform no scan,
   purge, overwrite, suffix improvisation, or new reorganization.
4. A component already `.filesystemComplete` retries only set-based catalog
   settlement. A `.catalogCommitted` component performs idempotent derived cleanup
   and journal deletion.

The Cancel intent sets `stopAfterCurrentComponent`. Before the first step of the
next component it stops immediately. Once any step is `.willMove`, cancellation
cannot strand the component; the coordinator completes or rolls it back. A process
termination is tested at both sides of every durable phase transition.

### 9.9 Directories, companions, and non-media filesystem facts

- Create missing target directories shallowest-first after journal insertion and
  before the first file move. Move a directory prerequisite from `.planned` to
  `.created` only after Otos successfully created it; if another process created a
  compatible directory first, mark it `.preexisting` so rollback never removes it.
- On rollback, remove those recorded directories deepest-first only when empty. A
  nonempty or externally modified directory is retained and logged, never removed.
- Do not remove old source directories in the first implementation. Empty-folder
  cleanup is a separate destructive product decision and not required for a
  correct reorganization.
- A media file and every paired recognized companion must be physically final
  before the component can become `.filesystemComplete`; catalog settlement remaps
  them together. Failure after moving a primary but before its companion invokes
  the same component recovery, not “success with an orphan.”
- Unknown files are stationary namespace occupants. They can force a deterministic
  suffix or block an ancestor directory, but Otos never moves/deletes them.
- Same-volume moves must preserve extended attributes, resource forks, sparse-file
  representation, and hard-link relationships according to OS move semantics;
  integration fixtures inspect these where the filesystem supports them.

### 9.10 Volume and provider boundaries

Capture `volumeIdentifier` for every physical source and target. The first
reorganization implementation supports only components whose members move within
one filesystem volume. A library root may contain a separately mounted descendant;
if any planned member crosses a volume boundary, block the whole reorganization
before mutation with `.crossVolumeReorganizationUnsupported` and list its count.

Alternatives considered:

- **Allow `FileManager.moveItem` to cross volumes implicitly:** smallest call site,
  but hides copy/delete progress and crash semantics inside an API used elsewhere
  as rename. It cannot satisfy the component journal as specified.
- **Reuse import staging to support cross-volume copy/publish/delete now:** can be
  made correct, but a cross-volume cycle requires destination-volume staging for
  several members before any source deletion and a new multi-volume recovery
  protocol. This is a serious future design, not a small executor branch.
- **Block before mutation (selected first release):** leaves every original
  untouched and makes the unsupported boundary visible. It is the only current
  choice that preserves the same-volume component proof without adding an
  unverified multi-volume product increment.

This boundary does not assume that one library can never span volumes. A separately
confirmed extension can add the second design later. Do not silently let
`FileManager.moveItem` turn the first release into copy/delete.

Cloud-synced paths on one reported volume remain eligible but use coordinated
moves. A provider refusal, eviction, or delayed rename is a typed step failure and
enters component recovery. Reorganization performs no deliberate byte read, so it
must not materialize dataless media merely to rename it.

### 9.11 Required invariants

Assert these in the planner and again before a component crosses its mutation
boundary:

- logical media count equals no-op plus relocate count;
- every physical media/companion source has exactly one final path;
- final namespace lookup keys are globally unique;
- exact source==final entries are no-op and never enter a move component;
- namespace-equivalent different-spelling entries use a temporary hop;
- no equality/duplicate/skip disposition exists in reorganization;
- every occupied moving target is represented by a graph dependency;
- every stationary conflict was suffixed or blocks the plan;
- every component has a deterministic finite recipe and at most one temporary
  physical member per simple cycle;
- no component crosses a filesystem volume;
- no temporary filesystem or transaction-private database path can publish as
  durable identity;
- media and companions commit together;
- Store publishes either the complete component remap or none of it;
- import-batch values and every authored/derived overlay field are preserved;
- cancellation can leave only whole committed components, never a partial one;
- rerunning the same policy after completion produces only no-op outcomes and no
  new paths.

### 9.12 Scope for first reorganization UI

Expose reorganization from the selected fixed library only, never All Media or a
removable source. The confirmation sheet shows plan counts, no-op count, moves,
companion moves, suffix conflicts, dependency-component/cycle counts, and any
cross-volume or namespace blockers. It must state that originals will move on
disk. No execution button is enabled while any blocked entry exists.

During execution, progress is component-based. Cancel says “Stopping after the
current group” when a component has crossed its mutation boundary. Recovery-blocked
roots surface a dedicated action/error state rather than disappearing into generic
catalog diagnostics.

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
- `op=mediaOperation.reorgComponent`: componentKey, generation, memberCount,
  chainCount, cycleCount, stepIndex, stepCount, phase, elapsedMs;
- `op=mediaOperation.reorgRecovery`: componentKey, durablePhase, observedPrefix,
  direction=forward|rollback|blocked, ambiguousMemberCount, outcome;
- `op=mediaOperation.reorgLease`: root hash, phase=acquire|deferEvent|release,
  deferredEventCount, outcome;
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
- exact swap produces one temporary-hop rotation;
- case-only and composed/decomposed Unicode spelling fixtures under injected
  case-sensitive and case-insensitive namespace semantics;
- case-only relabel is not incorrectly classified as no-op;
- primary/companion grouping joins otherwise independent path components;
- fan-in collisions suffix the whole bundle deterministically;
- file/symlink in a required directory ancestor blocks before mutation;
- unknown stationary files participate in occupancy but never become move nodes;
- cross-volume component blocks the whole plan;
- every component recipe is finite and deterministic;
- no plan has duplicate final namespace lookup keys.

### Store/migration tests

- prior schema migrates without erase;
- future schema refuses without erase;
- scan upsert preserves import batch;
- imported settlement and journal phase are atomic;
- distinct nonempty batch queries and deletion disappearance;
- companion full-scan/FSEvent reconcile;
- revision increments exactly for planning facts, not thumbnail-only changes;
- events during scan cause a follow-up reconciliation;
- normalized active component/member/step/directory journal relationships and
  cascade cleanup;
- set-based two-way and three-way catalog identity swaps succeed without a
  transient uniqueness violation;
- set-based settlement publishes all remaps or none;
- relocation preserves metadata, import history, companions, and selected
  thumbnail strategy;
- transaction-private catalog paths cannot survive commit or rollback;
- root reorganization lease defers scans/events and rejects stale enrichment;
- one batch remap/revision notification is emitted per component;
- stale or partial relocation settlement retains the recovery lease and journal.

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
- reorganization Cancel before a component stops immediately;
- Cancel after `.willMove` becomes stop-after-component;
- coordinator never schedules two components concurrently;
- external root mutation between components reconciles/replans before proceeding;
- startup recovery runs before scan/enrichment for an active reorganization root;
- completed components remain committed and replan as no-op after cancellation.

### File-operator integration tests

- destination-local staging never exposes partial final file;
- final publication never overwrites a concurrently created target;
- successful copy is not reopened for verification;
- source size/mtime race fails before copy;
- cancellation during OS call settles or removes staging deterministically;
- source deletion only after durable destination settlement;
- MTP download/delete fakes preserve the same phase semantics;
- coordinated file-provider failure maps to a typed problem;
- same-volume chain executes from free end;
- two-/three-way cycles and case-only relabels use collision-free temp paths;
- temp move preserves xattrs/resource forks/hard-link directory entries where the
  test filesystem supports them;
- no-overwrite failure at every reorganization step enters recovery;
- primary/companion partial movement cannot settle the component;
- operation-created directories are removed on rollback only when still empty;
- preexisting/external directories are never removed;
- dataless same-volume rename performs no deliberate byte read.

### ViewModel/UI tests

- footer totals ignore grid selection/filter;
- early click displays queued/waiting metadata;
- destination picker invalidates/replans;
- visible plan detail request rejects stale generation;
- sidebar batch selection/query/remove behavior;
- import sidecar Settings binding and persistence;
- errors and destructive policy are visible;
- thumbnail already displayed remains displayed across overlay changes;
- one remap batch preserves selection, Image/Compare focus, and painted tile
  content across a swap;
- cancellation text changes to stop-after-current-group inside a component;
- recovery and cross-volume blockers remain visible and actionable.

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
8. run free-ended chains, two-way swaps, longer cycles, and case-only relabels;
9. terminate immediately before/after every component, directory, step, filesystem-
   complete, catalog-commit, and cleanup transition;
10. inject external files/events at every vacated target and temp path;
11. prove unambiguous recovery completes forward, blocked forward recovery rolls
    back, and both/neither path ambiguity freezes without catalog deletion;
12. cancel before every step and prove only whole components are visible;
13. exercise companion failure, directory conflicts, hard links, symlinks,
    Unicode aliases, cloud-provider refusal, and a nested mounted volume;
14. confirm originals are never overwritten/collapsed and temporary paths never
    become catalog identities;
15. rerun the same completed reorganization and assert an all-no-op plan;
16. run `script/verify.sh`, `script/logs.sh`, and relevant `script/profile.sh`
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

- add volume-aware namespace semantics and APFS/cloud-provider name probes;
- add the complete physical-member reservation graph, companion grouping,
  deterministic component/chain/cycle recipes, and cross-volume blocker;
- add normalized active component recovery tables and typed root reorganization
  lease before enabling any filesystem mutation;
- add coordinated same-volume step execution, directory prerequisites, forward/
  rollback recovery, and cancellation only at component boundaries;
- add Store set-based identity/overlay/companion remap transaction plus the chosen
  thumbnail preservation mechanism;
- add atomic ViewModel/selection/TileContentStore remap-batch delivery;
- add confirmation UI for one selected fixed library;
- preserve import history and move useful companions as the same recovery unit;
- run the full namespace, uniqueness, termination, ambiguity, and idempotence
  matrix from section 12.

Done when every original remains represented, exact-path items are no-op,
case/Unicode relabels are real moves, no content dedup occurs, no temporary path is
published, overlay follows the component atomically, cancellation exposes only
whole components, ambiguous recovery freezes safely, and rerunning the policy is
all no-op.

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
