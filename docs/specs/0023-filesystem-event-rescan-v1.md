# Spec 0023: Filesystem Event Rescan V1

## Classification

- Work type: Feature
- User-visible feature: automatic catalog reconciliation while the app is running
- Current requirement IDs: adds FND-067; amends APP-005
- ADRs: amends ADR 0002
- Future ideas: per-path incremental FSEvents updates (V2)

## Problem And Goal

Today Otos reconciles the catalog with the filesystem only at launch and when the
user adds a library. Files created, deleted, or renamed while the app stays open
are invisible until the next relaunch.

The goal is V1 live reconciliation: macOS File System Events under saved library
roots schedule a **debounced full-root rescan** through the existing
`CatalogStore` scan pipeline. No manual rescan UI, no per-file catalog mutations,
and no Projection or ViewModel changes.

## Scope

In scope:

- `CatalogFilesystemWatcher` service with live `FSEventStream` and injectable test
  double.
- `CatalogStore` ownership of watcher lifecycle, per-root quiet-period debounce,
  arming after the first completed scan, and `rescanAfterCurrentScan` when events
  arrive during an active scan.
- Instrumentation under `FileAccess` and `Catalog` plus `catalog.filesystemEvent`
  diagnostics.
- Tests proving debounce, per-root scope, follow-up scan, arming, removal, and disk
  reconciliation.

Out of scope:

- Per-path incremental upsert/delete (V2).
- Manual scan controls (LIB-009 / APP-005 manual-scan prohibition unchanged).
- Availability re-probing when an offline root returns.
- Enrichment staleness, metadata, thumbnails.
- Polling or periodic rescans without an FSEvent.

## Definition Of Ready

- [x] Goal, scope, and non-goals are explicit.
- [x] Current repo state was inspected.
- [x] Captured requirements are listed for user verification.
- [x] At least three alternatives are compared.
- [x] Ownership, concurrency, persistence, cancellation, instrumentation, and tests
      are addressed.
- [x] Performance evidence is deferred until V1 proves insufficient (Pike rules).

## Captured Requirements For User Verification

| ID | Type | Captured requirement | Current or candidate | Storage location |
| --- | --- | --- | --- | --- |
| FND-067 | Architecture | While the app is running, filesystem changes under a saved available library root shall schedule an automatic debounced full-root reconciliation for **that root only**; no manual scan UI. | Current | `docs/requirements.md`, this spec |
| APP-005 (amended) | Functional | Automatic scans occur on launch, on add-library, and on debounced FSEvents while running; no manual scan control exists. | Current | `docs/requirements.md` |

## Behavioral Contract

### Quiet-period debounce (per root)

- Production default: `filesystemEventDebounce = 500 ms` (injectable for tests).
- Each qualifying event for root `R` cancels and restarts `R`'s debounce task.
- **Acceptance:** Given 10 events for `R` at t=0…400 ms, one rescan schedules at
  t=900 ms, not 10 rescans.

### Per-root scope only

- `scheduleFilesystemRescan(R)` calls `enqueueScans([R])` only.
- **Acceptance:** Given roots `A` and `B`, an event under `A` rescans only `A`.

### Full rescan of the affected root

- Re-enumerates the entire tree under `R` through `CatalogScanner`.

### `rescanAfterCurrentScan`

- If debounce fires while `activeScan?.rootPath == R`, record `R` and enqueue after
  `clearCurrentScan`.
- **Acceptance:** One event during an active scan for `R` yields exactly two scan
  invocations total.

### Arming

- FSEvents are ignored until the root's first scan completes (`scanCompleted` or
  `scanFailed`, not `scanCancelled`).
- **Acceptance:** Events during the initial add-library scan do not schedule a
  redundant second scan unless `rescanAfterCurrentScan` applies after completion.

### Root mapping

- Match `eventPath == root` or `eventPath.hasPrefix(root + "/")`.
- `kFSEventStreamEventFlagMustScanSubDirs`: debounced full rescan (no special case).

### Availability and removal

- Drop if root removed or unavailable when debounce fires.
- **Acceptance:** After `removeLibrary(R)`, synthetic events do not enqueue scans.

## Architectural Alternatives

### A (selected): Coarse debounced full rescan

FSEvents → per-root debounce → `enqueueScans([root])` → existing scanner.

Pros: one proven digestion path; simple ownership; easy to test with injectable
watcher. Cons: rescans entire root; cost accepted until measured.

### B: Immediate full rescan per event

Pros: lowest latency. Cons: scan storms during bulk copies; duplicates work.

### C: Per-path incremental updates

Pros: minimal I/O. Cons: new mutation path, delete handling, stale-callback story;
deferred to V2.

### D: Periodic polling

Pros: no FSEvents API. Cons: wasteful; misses product direction; not event-driven.

## Selected Approach

Alternative A. Reuse `CatalogScanner`, `recordScannedBatch`, and
`reconcileMissingAssets`. `CatalogFilesystemWatcher` is a narrow `FileAccess`
boundary; `CatalogStore` owns debounce and scan scheduling.

## Concurrency And Actor Ownership

| Work | Owner | Isolation |
| --- | --- | --- |
| FSEventStream callback | `CatalogFilesystemWatcher` | Dedicated serial `DispatchQueue`; callback hops to `CatalogStore` via `Task` |
| Debounce, enqueue, scan | `CatalogStore` | Actor |
| Enumeration | `CatalogScanner` | Detached utility task (unchanged) |
| UI publication | `CatalogProjection` / ViewModel | Unchanged |

Cancellation: debounce tasks cancel on new events, `removeLibrary`, and `shutdown`.
Watcher `stop()` on `shutdown`.

## Instrumentation

- Signposts: `FilesystemWatcherStart`, `FilesystemWatcherStop`, `FilesystemWatcherEvent`,
  `FilesystemEventDebounce`, `FilesystemRescanScheduled`.
- JSONL: `catalog.filesystemEvent` phases `receive`, `debounce`, `schedule`, `drop`.

## Test And Acceptance Criteria

See `OtosTests/CatalogStoreFilesystemEventTests.swift`.

## Code-Smell Review

Watch for: MainActor gravity on FSEvents callback; duplicate scan scheduling paths;
retain cycles between watcher queue and Store. Mitigation: weak Store hop, single
`scheduleFilesystemRescan` entry point.

## Linked Documents

- ADR 0002 (amended)
- `Otos/Services/CatalogFilesystemWatcher.swift`
- `Otos/Stores/CatalogStore.swift`
