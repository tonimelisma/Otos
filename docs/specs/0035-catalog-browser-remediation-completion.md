# Spec 0035: Catalog Browser Remediation Completion

## Status

Implemented in this increment.

## Current-State Note

Spec 0038 supersedes the earlier rendering assumption that nonanimated diffable
applies are a no-blank fix. On AppKit, `animatingDifferences: false` is a
reloadData-class path; the current invariant is enforced by synchronous tile
paint from decoded cache plus same-identity downgrade guards.

## Classification

Bug fix, refactor, and performance/instrumentation.

## Problem Statement And Goal

The real-library smoke workflow exposed user-visible catalog-browser problems
that an empty launch could not catch: thumbnails periodically disappeared and
reappeared while enrichment was running, ordered-ID and enrichment-candidate
queries recorded multi-second totals, and active-app main-run-loop stalls were
visible during catalog work. The goal of this increment is to finish the
remaining remediation plan after the session-scoped diagnostics increment, so
future smoke runs can explain where time is spent and the browser no longer
clears visible tiles during ordinary background updates.

## Scope

In scope:

- split Store query and write timings into database wait and execution spans
- correlate main-run-loop stalls with the current or most recently completed UI
  operation
- expose enrichment write pressure and WAL byte-size facts
- change structural collection applies to the diffable path and remove manual
  scroll-origin restoration
- split tile image reload identity from capture-date text so date-only changes do
  not clear thumbnails
- batch enrichment candidate claims when timing evidence confirms writer-queue
  pressure dominates
- keep query-intent generation semantics value-independent for rapid toggles
- remove brittle source-hygiene tests and keep only narrow smell guards
- update living documentation and focused file guides for current behavior

Out of scope:

- an in-memory thumbnail cache
- a new grid prefetching system
- schema-preserving migrations for old development catalogs
- changing thumbnail relative-name hashing input
- WAL tuning beyond measured visibility unless the new evidence proves it
- additional composite SQLite indexes without fresh query evidence

## Current Repo State

Inspection before implementation found these relevant current facts:

- Spec 0034 and PR 40 already landed session-scoped diagnostics, log de-spam,
  seeded smoke launches, and cancellation-aware tile-detail logging.
- `CatalogStore.orderedAssetIDs`, `mediaAssets`, and enrichment-candidate reads
  recorded only total `queryMs`, so the logs could not distinguish SQLite work
  from waiting behind the writer queue.
- `catalogedAssetCount`, `visibleAssetCount`, `filterOptions`, scan batch writes,
  and enrichment writes lacked the same split timing fields.
- `MainRunLoopStallMonitor` recorded latest grid handoff scalars, but not the
  UI operation active at the stall or the most recent long completed operation.
- `MediaAssetCollectionViewController.applyStructure` used nonanimated diffable
  applies and manually restored the clip-view origin for same-descriptor
  background updates.
- `MediaAssetTilePresentation.contentKey` included the capture date, causing a
  date-only enrichment change to restart the thumbnail load path.
- `EnrichmentCoordinator.dequeueEnrichmentWork` asked Store only for the free
  worker-slot count. With four enrichment workers, this can turn a full sweep into
  many tiny claim transactions.
- Shared filter menu content, symlink-resolving add-library behavior, startup
  symlink repair, and query-intent generation tests already existed on `main`.

## Captured Requirements

User guidance captured for this increment:

- Functional: A selected real library must not look empty simply because the
  selected path is a symlink spelling of the provider directory.
- Functional: Visible thumbnails must not periodically disappear and reappear
  during background enrichment when the tile's image product is unchanged.
- Tooling: Agent smoke tests must seed the user's main OneDrive Pictures library,
  wait, scroll down and up, capture logs/signposts, and treat an empty-library
  launch as useless evidence.
- Non-functional: Jank analysis must separate database queue wait, database
  execution time, UI apply time, enrichment write pressure, WAL size, and
  active-app run-loop stalls instead of relying on spammy aggregate logs.
- Non-functional: High-frequency UI instrumentation must stay in unified
  logs/signposts. JSONL is reserved for coarse Store, Projection, scan, write,
  WAL-size, and actual stall boundaries.
- Process: Already-satisfied recommendations from the restored plan are recorded
  as verified current behavior rather than reimplemented or duplicated.

Mapped current requirements: FND-006, FND-020, FND-025, FND-031, FND-043,
FND-070, APP-006, APP-010, APP-013, APP-014, ENR-001, ENR-002, ENR-009, and
ENR-010.

## Alternatives

### Alternative A: Add More Logs Around Existing Work

Pros:

- smallest code change
- preserves current behavior

Cons:

- still cannot distinguish database wait from execution
- does not remove the visible tile clear/repaint path
- keeps the many tiny enrichment claim queries

Failure modes:

- future smoke runs still report a giant `queryMs` with no owner to fix
- flicker remains because the tile reload key and structural apply behavior are
  unchanged

Rejected because it improves observability vocabulary but not the observed
browser failure.

### Alternative B: Add Caches, Prefetching, Or A Thumbnail Pool

Pros:

- could hide repeated thumbnail reloads
- may improve scroll warmth in large libraries

Cons:

- adds a cache before proving the current simple path is exhausted
- hides the root flicker cause instead of removing it
- creates lifecycle and memory policy that current requirements do not need

Failure modes:

- stale thumbnails or memory growth
- extra complexity makes later jank attribution harder

Rejected under the repo's measure-before-optimizing rule.

### Alternative C: Keep The Simple Ownership Model And Tighten The Proven Paths

Pros:

- keeps Store, Projection, ViewModel, and AppKit ownership unchanged
- makes wait/exec/write pressure measurable before tuning
- removes the tile reload trigger for date-only changes
- uses AppKit's diffable animation path instead of a manual scroll-origin patch
- batches enrichment claims only where the existing coordinator already owns
  scheduling

Cons:

- still relies on follow-up profiling if SQLite execution itself proves slow
- does not add a cache for cold scrolls

Failure modes:

- diffable applies could reveal a different AppKit hitch, which the new stall
  tags and apply summary logs must identify
- claim batching could keep stale candidates in a small actor queue after Store
  truth changes; process-local in-flight checks and claim leases bound that risk

Selected. It is the simplest correct approach because it removes known bad
triggers, instruments unknown timing, and only batches the already-owned
enrichment scheduling boundary when the evidence points at writer-queue pressure.

## Interfaces, Ownership, And Data Flow

- `CatalogStore` remains the only SQLite owner. Query APIs keep their existing
  return values and add bounded diagnostic fields.
- Database timings are reported as `waitMs`, `execMs`, and `queryMs` or
  `writeMs`, where the total remains for continuity.
- `MainRunLoopStallMonitor` remains a MainActor diagnostic helper. UI owners mark
  operation spans through begin/end calls that store only names, scalar durations,
  and timestamps.
- `MediaAssetCollectionViewController` remains the only AppKit media-grid
  boundary. It owns diffable structural applies, visible detail reads, selection
  preservation, and aggregate apply logging.
- `MediaAssetTilePresentation.imageContentKey` owns image reload identity.
  Capture-date text updates synchronously on configure and no longer participates
  in image reload identity.
- `EnrichmentCoordinator` owns a small actor-local claimed work queue. SQLite
  leases remain the cross-query guard; the queue is not durable catalog truth.

## Persistence Effects

The persisted `sort_key` separator changes from embedded NUL to U+0001. The
catalog is a rebuildable pre-user projection, so the migration identifier changes
and existing development catalogs are cleanly reset and rebuilt rather than
schema-migrated. Originals are untouched; app-owned thumbnails are purged by the
existing clean-reset policy.

File-backed catalogs set SQLite `synchronous = NORMAL` at open and log the
effective value. WAL visibility is diagnostic only: WAL byte size is sampled
around enrichment write boundaries without forcing checkpoints. This increment
does not change `wal_autocheckpoint` or add truncate checkpoints unless captured
evidence later proves that necessary.

## Concurrency And Cancellation

- Store timings measure the wait between API entry and GRDB closure entry, then
  the synchronous SQLite work inside that closure.
- Scan and enrichment writes continue to run off the MainActor inside Store-owned
  database transactions.
- The enrichment queued-claim buffer is actor-isolated and drained only into free
  enrichment slots. Store notifications still wake the coordinator, and failed or
  dataless paths keep the existing release/refresh semantics.
- UI operation tags are MainActor-only scalar diagnostics; they do not retain
  catalog state.
- Tile image loading remains a detached task with a generation guard. Raising its
  priority to `.userInitiated` changes scheduling priority only, not ownership.

## Instrumentation And Profiling Plan

Before and after implementation, collect:

- focused unit/source tests for changed boundaries
- `script/catalog-diagnostics.sh check` summaries from smoke output
- `script/logs.sh UI`, `script/logs.sh Persistence`, and `script/logs.sh
  Performance` as needed for live signpost/log checks
- `script/smoke-run.sh --verify` to seed the real library, wait, scroll down/up,
  capture session logs, summarize diagnostics, and quit

New fields:

- Store queries: `waitMs`, `execMs`, `queryMs`
- Store writes: `waitMs`, `execMs`, `writeMs`, `changed` or row counts
- Enrichment batches: attempted/applied counts, discarded thumbnails,
  promotion failure, transaction timings, and WAL bytes
- UI stalls: current operation and most recent completed operation over 100 ms
- Structural grid apply logs: insert/remove counts, apply time, reorder-only and
  animation status, and post-apply visible-detail request count

## Tests And Acceptance Criteria

- `MediaAssetCollectionTests` proves date-only changes leave the image content
  key unchanged, while thumbnail path, stamp, or source size changes alter it.
- Store/root-normalization tests continue proving symlinked selected roots persist
  as resolved provider paths and scan media.
- Query-intent tests continue proving rapid toggle-back stale states do not roll
  back controls.
- Source hygiene keeps the negative AppKit detail-prune guards while deleting
  brittle exact-string assertions.
- Query-plan tests continue proving Store SQL shapes and enrichment candidate
  query indexes.
- Runtime smoke evidence shows seeded real-library startup and automated scroll,
  plus diagnostics that can attribute query waits, writes, WAL state, and actual
  stalls.

## Code-Smell Review

Observed before implementation:

- MainActor gravity risk: UI stall diagnostics needed owner tags without moving
  catalog state onto MainActor.
- SwiftUI/AppKit body work risk: grid changes had to stay inside the AppKit
  bridge and tile configure path without catalog queries in views.
- State duplication risk: query-intent generation already existed; new work must
  not add a parallel descriptor owner.
- Diagnostic payload sprawl: prior console output was too noisy; new JSONL fields
  must stay bounded and scalar.
- Test coupling: source hygiene included exact-string positive assertions that
  made refactors look like behavior changes.

## Living Documentation Plan

Update current docs affected by this behavior:

- `docs/requirements.md`
- `docs/index.md`
- `docs/onboarding.md`
- `docs/adr/0006-catalog-grid-rendering.md`
- `docs/adr/0009-enrichment-storage-and-staleness.md`
- `docs/adr/0011-catalog-query-descriptor-best-values-and-cadence.md`
- `docs/process/performance.md`
- source file guides and focused comments in edited architecture boundaries

Stale-document audit must verify specs 0032 through 0034 remain current after
this completion spec and remove or rewrite superseded claims.
