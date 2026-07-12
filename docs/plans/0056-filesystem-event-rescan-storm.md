# Plan 0056 — Filesystem-event rescan storm on enriching cloud roots

Status: active implementation plan. Diagnosed 2026-07-11 from live-log evidence on
a running build while investigating the import-planning hang fixed in PR #111
(`fix: settle import planning against enriching cloud destinations`, commit
`b662d4f`). Delete this file when the work has landed on `main`.

This plan is self-contained: an implementer does not need the diagnosis
conversation. All line numbers are approximate and were taken against `main` at
`b662d4f`; confirm the exact site by function name before editing.

---

## 1. Symptoms

A large cloud-synced library (observed: `~/Library/CloudStorage/OneDrive-Personal/
Pictures/Camera Roll`, 23,036 files) that is being background-materialized by
enrichment drives an endless loop of **full-tree rescans**. Live unified-log
evidence (`script/logs.sh show --last 5m`) showed, repeating every ~2–4 seconds
for minutes:

```
op=catalog.scan phase=finish rootPath=…/Camera Roll observed=23036 deleted=0 … (changedCount=0)
op=catalog.filesystemEvent phase=schedule mode=deferred rootPath=…/Camera Roll eventCount=1..6
op=catalog.enrichment.batch phase=finish …            (materialization running concurrently)
```

Every rescan re-enumerates all 23,036 entries and finds **nothing changed**
(`changedCount=0`), yet another rescan is scheduled seconds later. The loop ends
only when materialization of the whole library finishes, the root is removed, or
it goes offline.

## 2. Impact (what we are fixing)

- **Sustained wasted CPU/IO.** O(23k) directory enumeration + O(23k) SQLite
  upsert-compares every few seconds, indefinitely, for zero catalog change. On a
  laptop: background CPU, disk churn, battery, thermals.
- **SQLite/WAL pressure and self-interference.** Each rescan cycle contends with
  the concurrent `enrichment.batch` writes for the same database, which can slow
  the very enrichment that is generating the events (mild positive feedback that
  prolongs the storm).
- **Duration.** Persists for the entire materialization pass of the library
  (potentially the whole library — CLAUDE.md sanctions eager materialization "up
  to eagerly materializing the whole library"), i.e. a long time for a large cloud
  root.
- **Observability.** Log spam (`mode=deferred` + `scan phase=finish observed=…`
  every few seconds) drowns other diagnostics.

There is **no correctness defect**: originals are never touched and the catalog
stays correct (rescans find nothing). This is purely an efficiency/energy defect.
The import-planning livelock that this storm also used to cause is already fixed
(PR #111): the import coordinator now ignores the `planRevision` churn.

## 3. Code smells

- **Wrong-granularity escalation.** A single-file filesystem event is answered
  with a whole-tree re-enumeration whenever a scan happens to be active — O(1)
  information triggering O(n) work.
- **Information thrown away.** The defer path discards the actual events
  (`filesystemEventBatches.removeValue`) and substitutes a blind rescan, so the
  cheap targeted-reconcile path can never run for events that arrive during a
  scan.
- **Self-inflicted churn.** The system reacts to filesystem events that it itself
  caused (enrichment materialization), with no suppression of its own writes.
- **Unbounded self-perpetuation.** `clearCurrentScan` re-enqueues a full rescan
  whenever any event deferred during the scan, and the rescan is long enough that
  new materialization events always arrive during it — a self-sustaining loop with
  no damping and no exit except external state change.

## 4. Investigation / research

### 4.1 The codepath (trace)

Event source: `EnrichmentCoordinator` materializes dataless placeholders (hydrates
them) as a deliberate, sanctioned background activity. Each hydration writes bytes,
so macOS FSEvents emits an `itemModified`/`itemInodeMetaMod` on that file path.

1. **Watcher → `handleFilesystemEvent`** (`CatalogStore.swift` ~:2646). Arms
   watching if needed, then appends to `filesystemEventBatches[root]` (~:2682) and
   calls `debounceFilesystemReconcile`.
2. **Debounce** (~:2713). Waits `filesystemEventDebounce` (**1 s** default, ~:184),
   then `processFilesystemEventBatch`.
3. **Classify** (~:2762 → `FilesystemReconciler.decide`,
   `FilesystemReconciler.swift:23`). The **first** check is `hasActiveScanForRoot`
   → returns `.deferUntilScanCompletes` (`FilesystemReconciler.swift:35`),
   short-circuiting before the single-file-vs-full classification is considered.
4. **Defer handling** (~:2783). Does three things: `markRescanAfterCurrentScan(root)`,
   `bumpPlanRevision(root)`, and **discards the events**
   (`filesystemEventBatches.removeValue`, ~:2786).
5. **Scan finishes → `clearCurrentScan`** (~:2538). `clearFilesystemScan` returns
   `needsRescan == true`, so it calls `enqueueScans([root])` (~:2551) → a new full
   scan of all files.
6. **New scan runs** (`startNextScanIfNeeded` ~:2216; arms watcher at ~:2239).
   Re-enumerates the whole tree, `upsertScannedFile` per file, `changedCount=0`.
   More materialization events arrive during it → back to step 1.

`markRescanAfterCurrentScan` writes to a `Set`, so the rescan is coalesced to **one
per scan cycle** — but that one rescan is O(entire tree), and the loop frequency is
bounded only by scan duration (~2–4 s).

### 4.2 The cheap path already exists

When no scan is active and the event is single-file, `decide` returns `.targeted`
(`FilesystemReconciler.swift:53`) and `processFilesystemEventBatch` runs
`reconcileFilesystemEvent` per event (~:2802 → ~:2822): one `lstat` + one row
compare for that path only, bumping occupancy only if the row actually changed.
**"Rescan only affected files" is already implemented** — the storm is purely that
`.deferUntilScanCompletes` bypasses it while a scan is active.

Full re-enumeration is only genuinely required when the event carries
`requiresFullRootScan` flags — `kFSEventStreamEventFlagMustScanSubDirs`,
kernel/user-dropped, directory, symlink, or unknown
(`FilesystemEventFlags.swift:18`). In those cases FSEvents will not tell us which
files changed, so re-enumeration is the only correct reconcile. This case must be
preserved.

### 4.3 Materialization concurrency (the "handful" number)

`EnrichmentCoordinator` runs a bounded pool: `downloadConcurrency = 4` and
`enrichConcurrency = 4` by default (`EnrichmentCoordinator.swift:130–131`), not
overridden in production (`CatalogWindowViewModel.swift:192`). The set of files
currently being materialized already exists in memory as
`inFlightDownload: Set<MediaAssetID>` (`EnrichmentCoordinator.swift:107`). So at any
instant **at most ~4 files are hydrating**, and the coordinator already knows which.

### 4.4 Evidence still to capture before coding (cheap, do first)

The `mode=deferred` log line does not record event flags, so we have not proven the
storm's events are single-file `itemModified` (vs. `MustScanSubDirs` coalescing).
Add the flags to that log line and capture a short trace from the running app:

- Temporarily include `flags=\(FilesystemEventFlags(event:).diagnosticDescription)`
  in the `mode=deferred` notice (or log per retained event).
- Run the repro (attach nothing needed — just have the enriching cloud library
  present) and `script/logs.sh show --last 3m | grep mode=deferred`.
- **Expectation:** predominantly `itemModified`/`itemInodeMetaMod,itemIsFile`
  (single-file, targeted-eligible). If instead they are `mustScanSubDirs`, Part A
  will legitimately still escalate to one rescan per cycle, and Part B (fuel cut)
  plus the overflow cap become the primary mitigations — record that outcome in the
  DoD.

## 5. Solution

Two complementary changes. **Part A is the structural fix and must land; Part B is
a cheap fuel cut that complements it.**

### 5.1 Part A — retain deferred events, replay as a targeted reconcile after the scan

Instead of discarding events and blindly re-enumerating, **retain** the events that
arrive during a scan in a per-root buffer, and when the scan finishes **re-classify
and replay** them through the existing decision path (now with no active scan): a
targeted per-path reconcile in the common case, and a single full rescan only if a
retained event genuinely requires it or the buffer overflows.

This removes the amplifier: an event during a scan becomes O(affected paths), not
O(entire tree), so the loop cannot sustain itself for single-file events.

### 5.2 Part B — suppress self-inflicted materialization events

When a filesystem event's path is currently being materialized by enrichment (or was
within a short grace window), drop it before it enters the batch/debounce pipeline.
This removes the dominant fuel source at the door, so we do not even do the cheap
targeted reconcile for our own no-op hydration events.

It is intentionally **best-effort** (event latency means some events arrive after the
download completes) and it accepts a vanishingly rare miss (a real user change to a
file at the exact moment we hydrate it), which self-corrects on the next event or
scan. This is safe because Part A makes any missed/leaked event cheap anyway.

### 5.3 Why both, and in this order

- Part A alone fully fixes the perf problem for single-file events and is robust
  (it does not depend on catching every event).
- Part B alone is insufficient: it is best-effort and leaves the amplifier armed, so
  a single leaked or foreign event during a scan re-triggers a full rescan.
- Together: our materializations produce ~zero work (B), any residual/foreign
  single-file event is a cheap targeted reconcile (A), and only genuinely ambiguous
  coarse events trigger one full rescan (unchanged).

Land **Part A first** (kills the storm), then **Part B** (trims residual self-noise).
They can be one PR or two; if two, A precedes B.

## 6. Alternatives considered and rejected

- **Rate-limit / coalesce full rescans (damping).** Cap full rescans to one per root
  per N seconds. Reduces frequency ~10× but still re-enumerates a huge tree for no
  reason, adds a timing knob, and is damping rather than a fix. Rejected in favor of
  removing the wrong escalation entirely (Part A). (Damping-style fixes have been
  rejected elsewhere in this codebase for the grid invariant.)
- **Part B alone (suppress self-events, keep full-rescan escalation).** Simplest, but
  best-effort suppression + intact amplifier means one leaked/foreign event per scan
  cycle re-sustains the storm. Insufficient as a standalone fix.
- **Filter events inside `CatalogFilesystemWatcher` instead of the store.** The store
  already has the event, the owning root, and (via Part B) the suppression set, and
  it is where reconciliation decisions live. Filtering in the watcher would split the
  decision across two owners for no benefit.
- **Build an incremental/targeted scanner (avoid full re-enumeration entirely).** A
  large new subsystem; against "simplest correct" and "measure before optimizing."
  Part A already gets the same benefit by reusing the existing targeted-reconcile
  path, so a new scanner is unjustified.
- **Stop or throttle enrichment materialization.** Eager materialization is a
  deliberate, sanctioned product decision (CLAUDE.md). The defect is how we react to
  its events, not that it materializes.

## 7. Exactly what changes where

> All sites in `Otos/Stores/CatalogStore.swift` unless noted. Confirm line numbers by
> function name; they are approximate against `main @ b662d4f`.

### Part A — retain and replay

**A1. New Store state** (near the other filesystem-event fields, ~:170).
```swift
/// Events retained while a scan owns the root, replayed as a targeted reconcile
/// after the scan completes (see §5.1 of plan 0056). Keyed by root; coalesced by
/// path at replay time.
private var deferredFilesystemEvents: [LibraryRootPath: [FilesystemEvent]] = [:]

/// Distinct-path ceiling for the deferred buffer. Beyond this, replaying targeted
/// reconciles approaches full-scan cost, so fall back to a single full rescan.
private let deferredFilesystemEventPathCap = 512
```

**A2. `processFilesystemEventBatch`, `.deferUntilScanCompletes` case** (~:2783).
Replace the current body (which marks a rescan, bumps planRevision, and discards):
- Append `pendingEvents` to `deferredFilesystemEvents[root]`.
- `filesystemEventBatches.removeValue(forKey: root)`.
- Compute the buffer's **distinct path count**. If it exceeds
  `deferredFilesystemEventPathCap`: clear `deferredFilesystemEvents[root]` and call
  `scanLeases.markRescanAfterCurrentScan(root)` (the overflow fallback → one full
  rescan via `clearCurrentScan`).
- **Do not** call `bumpPlanRevision` here (retention is not itself a planning
  change; the post-scan replay bumps occupancy iff a row actually changes). This
  also removes the last remaining source of `planRevision` churn from the storm.
- Keep the `mode=deferred` notice; add a `retainedPaths=<distinct count>` field.

**A3. New drain method.**
```swift
/// After a scan releases a root, replay any events retained during it. With no
/// active scan, `decide` yields `.targeted` (reconcile only affected paths) or,
/// for coarse/dropped events, `.rescanRoot` — reusing the normal execution path.
private func drainDeferredFilesystemEvents(for root: LibraryRootPath) async {
    guard !scanLeases.hasActiveFilesystemScan(for: root),
          let retained = deferredFilesystemEvents[root], !retained.isEmpty
    else { return }
    deferredFilesystemEvents.removeValue(forKey: root)
    filesystemEventBatches[root, default: []].append(contentsOf: retained)
    await processFilesystemEventBatch(for: root)
}
```
Reusing `processFilesystemEventBatch` means the retained events flow through the
exact same `decide` + switch, so `.targeted`/`.rescanRoot`/`.drop`/`.noop` all
behave identically to a live batch. No duplicated logic.

**A4. Invoke the drain from the scan-terminal handlers**, after the lease is cleared:
- `scanCompleted` (~:2341): after `clearCurrentScan(scan, …)` (~:2402), add
  `await drainDeferredFilesystemEvents(for: scan.rootPath)`.
- `scanCancelled` (~:2478, clears at ~:2487) and `scanFailed` (~:2490, clears at
  ~:2535): same call, so retained events are never stranded.
- Ordering note: `clearCurrentScan` calls `startNextScanIfNeeded` at its end. If the
  overflow fallback (A2) marked a rescan, a new scan for this root may already be
  active when the drain runs; the drain's `hasActiveFilesystemScan` guard makes it a
  no-op in that case (the overflow rescan covers it). Non-overflow: no new scan for
  the root, so the drain proceeds as a targeted replay.

**A5. Do not change `clearCurrentScan`/`ScanLeaseController`.** The
`markRescanAfterCurrentScan` / `takeRescanAfterCurrentScan` machinery stays — it is
still used by the reorganization-lease deferral (`startNextScanIfNeeded` ~:2226 and
lease release) and now by the Part A overflow fallback. We only stop the FS-defer
path from using it in the common case.

### Part B — suppress self-materialization events

**B1. New Store state and constant** (near the filesystem-event fields).
```swift
/// Absolute paths currently (or very recently) being materialized by enrichment,
/// mapped to the instant the suppression expires. FS events for these are our own
/// hydration writes and are dropped before batching (see §5.2 of plan 0056).
private var materializationSuppressedUntil: [String: ContinuousClock.Instant] = [:]
private let materializationSuppressionGrace: Duration = .seconds(3)
private let materializationSuppressionCeiling: Duration = .seconds(60)
```

**B2. New Store methods** (internal — the coordinator holds `store`).
```swift
/// Enrichment is about to hydrate `absolutePath`; suppress its FS event.
func beginMaterializationSuppression(path absolutePath: String) {
    materializationSuppressedUntil[absolutePath] =
        ContinuousClock().now.advanced(by: materializationSuppressionCeiling)
}

/// Hydration finished; keep suppressing briefly since the FS event can lag the write.
func endMaterializationSuppression(path absolutePath: String) {
    materializationSuppressedUntil[absolutePath] =
        ContinuousClock().now.advanced(by: materializationSuppressionGrace)
}
```
The ceiling on `begin` guarantees no permanent leak if `end` never fires (task
cancellation); the grace on `end` covers FSEvents delivery lag.

**B3. Drop check in `handleFilesystemEvent`** (~:2646), after resolving the owning
root and after the arming block (so arming still happens), before the reorg-lease
branch / batch append:
```swift
let now = ContinuousClock().now
if let until = materializationSuppressedUntil[event.path] {
    if until > now {
        recordFilesystemEventDrop(path: event.path, root: root, reason: "selfMaterialization")
        return
    }
    materializationSuppressedUntil.removeValue(forKey: event.path)   // lazy prune
}
```
Path-matching gotcha: use the same absolute-path spelling on both sides.
`event.path` is the raw FSEvents path; the coordinator must pass
`work.url.path(percentEncoded: false)`. If in doubt, normalize both through the same
helper. (A small periodic/lazy prune of expired entries keeps the map bounded; the
map is ≤ ~4 live entries plus recently-expired, so lazy prune on lookup is enough.)

**B4. Wire begin/end around materialization** in `EnrichmentCoordinator.runLoop`, the
download worker (`EnrichmentCoordinator.swift:293–303`). The coordinator already
holds `store` (`:193`). Change the worker body to:
```swift
group.addTask {
    let start = Date()
    let path = work.url.path(percentEncoded: false)
    await self.store.beginMaterializationSuppression(path: path)
    let result = await materialize(work.url)
    await self.store.endMaterializationSuppression(path: path)
    await self.finishDownload(work, result: result,
                              attemptMs: DiagnosticsTiming.milliseconds(since: start))
}
```
Scope: only **download** workers materialize (write bytes). Enrich workers byte-read
already-materialized files and do not write, so they need no suppression. Confirm the
coordinator's `store` property name.

## 8. Correctness argument (for review)

- **Retain/replay is complete for received events.** For a file X changed during the
  scan window: if X changed *before* the scan enumerated it, the scan already wrote
  the new state and the replayed event is a redundant no-op; if X changed *after* the
  scan enumerated it, the scan wrote stale state and the replayed targeted reconcile
  corrects the row. Either way the catalog ends correct.
- **Dropped/ambiguous events still full-rescan.** FSEvents signals lost events via
  `KernelDropped`/`UserDropped`/`MustScanSubDirs`, which set `requiresFullRootScan`.
  Because the drain re-runs `decide`, any such retained event yields `.rescanRoot` —
  today's "we don't know what changed → re-enumerate" guarantee is preserved.
- **Overflow is bounded.** A pathological burst of distinct changed paths during a
  long scan falls back to one full rescan (A2 cap), never an unbounded targeted
  replay.
- **Accepted residuals (same best-effort standard used elsewhere):** (1) the
  sub-millisecond FSEvents stream-startup gap at scan start for an already-enumerated
  file that changes with no delivered event and no dropped-flag; (2) Part B dropping a
  genuine user change to a file at the exact instant we hydrate it. Both are
  vanishingly rare and self-correct on the next event or scan.

## 9. Tests

Add to `OtosTests/` (Swift Testing). Follow the existing `CatalogStoreFilesystemEvent`
support helpers; assert observable behavior, not internals.

1. **Deferred events replay targeted, not full rescan** (Part A, core regression):
   with an active scan on a root, deliver single-file events for two paths; complete
   the scan; assert the two paths are reconciled (catalog reflects them) and that **no
   full rescan is enqueued** for the root (e.g. observe scan-start count / a test seam
   that counts full scans). A file created-after-enumeration is picked up by the
   replay.
2. **Coarse event during scan still full-rescans** (Part A safety valve): a retained
   `MustScanSubDirs`/dropped event yields exactly one `.rescanRoot` after the scan.
3. **Overflow falls back to one rescan** (Part A cap): retaining more than
   `deferredFilesystemEventPathCap` distinct paths escalates to a single full rescan.
4. **Suppressed self-materialization event is dropped** (Part B): after
   `beginMaterializationSuppression(path:)`, an event for that path is dropped
   (`reason=selfMaterialization`) and does not reconcile; after
   `endMaterializationSuppression` + grace, an event for the path is processed
   normally.
5. **No planRevision/occupancy churn from no-op deferral+replay** (guards the storm):
   deferring then replaying no-op events (unchanged files) produces no occupancy bump
   and no rescan loop.

Prefer a test seam that counts full-root scans per root (or reuse an existing
scan-start signal) so tests can assert "no full rescan" rather than sleeping.

## 10. Instrumentation and evidence

- **Before coding:** capture the event-flags evidence from §4.4.
- **After A+B:** re-run the repro with the enriching cloud library present and
  `script/logs.sh show --last 5m`. Expected: `mode=deferred` disappears (or is rare),
  `op=catalog.scan phase=finish observed=23036 … changedCount=0` no longer recurs
  every few seconds, and per-event `mode=targeted` reconciles (or drops with
  `reason=selfMaterialization`) replace it. Attach the before/after worst-span summary
  to the DoD. This is a performance change, so the DoD must carry log evidence per
  CLAUDE.md.

## 11. Documentation to update (same increment)

- `docs/requirements.md` **ARC-046**: the clause "events during an active scan defer
  follow-up reconciliation instead of being dropped when watching is unarmed" now
  becomes: events retained during a scan are **replayed as a targeted reconcile after
  the scan** (full rescan only on coarse/dropped events or buffer overflow); and
  enrichment-materialization events for in-flight paths are suppressed. Update the
  behavior and add `Otos/Services/EnrichmentCoordinator.swift` +
  `OtosTests/CatalogStoreFilesystemEventTests.swift` (or the new test file) to the
  refs.
- `docs/architecture.md`: update the filesystem-event / scan flow note to describe
  retain-and-replay and the materialization-event suppression.

## 12. Definition of Done

Standard CLAUDE.md DoD: dedicated worktree/branch; `script/verify.sh` green on Xcode
27 beta (requirements + lint + build + test); before/after log evidence attached;
code smells from §3 addressed or explicitly accepted; ARC-046 and architecture.md
updated; PR + review; merge to `main`; branch/worktree cleanup; this plan file
deleted. Remote CI is currently billing-blocked (jobs fail in ~2 s with zero steps) —
local `script/verify.sh` is the authoritative build/test proof; waive CI only with
that evidence pasted.
